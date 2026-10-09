--!strict
-- Host glue for the `scaffold` block (lib/scaffold/form.luau): finds and
-- scans the SDF project of the directory it was opened for, reads the user's
-- script templates (config `scaffold.templates_dir`), writes the planned
-- files and edits into the local project, and feeds every result back.
-- Writing refuses to replace any file, and an edit only applies when the
-- file still holds the text the plan was made from.

local ConfigHost = require("./config_host")
local Form = require("./lib/scaffold/form")
local Kinds = require("./lib/scaffold/kinds")
local Plan = require("./lib/scaffold/plan")
local ProjectHost = require("./project_host")

local log = tern.log

type Effect = Form.Effect
type Msg = Form.Msg

type Host = { s: Form.State, cx: BlockCx, stopped: boolean, warned: boolean }

local M = {}

M.MAX_TEMPLATE_BYTES = 262144
-- deploy.xml / manifest.xml re-read before an edit.
M.MAX_EDIT_BYTES = 4 * 1024 * 1024

local function warnOnce(h: Host, what: string, err: any)
	if not h.warned then
		h.warned = true
		log.warn("tern-netsuite scaffold " .. what .. " failed", tostring(err))
	end
end

local exec: (h: Host, effects: { Effect }) -> ()

local function deliver(h: Host, msg: Msg)
	if h.stopped then
		return
	end
	local ok, s, effects = pcall(Form.update, h.s, msg)
	if not ok then
		warnOnce(h, "update " .. msg.t, s)
		return
	end
	h.s = s
	exec(h, effects)
	pcall(function()
		h.cx:render()
	end)
end

local function exists(path: string): boolean
	local ok, present = pcall(tern.fs.exists, path)
	return ok and present == true
end

local function dirname(path: string): string
	return (string.match(path, "^(.*)/[^/]*$") or "/") :: string
end

-- Not in lib/config yet; read defensively so its absence is harmless.
local function templatesDir(): string?
	local cfg: any = ConfigHost.current()
	local section = cfg.scaffold
	local dir = if type(section) == "table" then section.templates_dir else nil
	if type(dir) ~= "string" or dir == "" then
		return nil
	end
	if string.sub(dir, 1, 2) == "~/" then
		local home = tern.getenv("HOME")
		if home == nil then
			return nil
		end
		dir = home .. string.sub(dir, 2)
	end
	return (string.gsub(dir, "/+$", ""))
end

local function loadTemplates(h: Host)
	local dir = templatesDir()
	local texts: { [string]: string } = {}
	local problems: { string } = {}
	if dir then
		for _, id in Kinds.ORDER do
			local path = dir .. "/" .. id .. ".js"
			if exists(path) then
				local ok, text = pcall(tern.fs.read, path, M.MAX_TEMPLATE_BYTES)
				if ok then
					texts[id] = text
				else
					table.insert(problems, "Template " .. path .. " was not read: " .. tostring(text))
				end
			end
		end
	end
	deliver(h, { t = "templates", dir = dir, texts = texts, problems = problems })
end

-- Checks everything first, so a refusal writes nothing. Returns what was
-- written and the error that stopped it.
local function writeAll(root: string, writes: { Plan.Write }, edits: { Plan.Edit }): ({ string }, string?)
	local written: { string } = {}
	for _, w in writes do
		if exists(root .. "/" .. w.path) then
			return written, w.path .. " already exists; nothing was written"
		end
	end
	for _, ed in edits do
		local ok, text = pcall(tern.fs.read, root .. "/" .. ed.path, M.MAX_EDIT_BYTES)
		if not ok then
			return written, string.format("could not re-read %s (%s); nothing was written", ed.path, tostring(text))
		elseif text ~= ed.from then
			return written, ed.path .. " changed since the scan; nothing was written"
		end
	end
	for _, w in writes do
		local path = root .. "/" .. w.path
		local ok, err = pcall(function()
			tern.fs.mkdir(dirname(path))
			tern.fs.write(path, w.content)
		end)
		if not ok then
			return written, "could not write " .. w.path .. ": " .. tostring(err)
		end
		table.insert(written, w.path)
	end
	for _, ed in edits do
		local ok, err = pcall(function()
			tern.fs.write(root .. "/" .. ed.path, ed.to)
		end)
		if not ok then
			return written, "could not write " .. ed.path .. ": " .. tostring(err)
		end
		table.insert(written, ed.path)
	end
	return written, nil
end

local function write(h: Host, e: Effect)
	local writes: { Plan.Write } = e.writes or {}
	local edits: { Plan.Edit } = e.edits or {}
	local written, err = writeAll(e.root :: string, writes, edits)
	if err and #written > 0 then
		err ..= " (already written: " .. table.concat(written, ", ") .. ")"
	end
	deliver(h, { t = "written", gen = e.gen, written = written, err = err })
end

local function focus(h: Host, id: string)
	-- The input arrives with this render; focus it on the next tick.
	pcall(function()
		h.cx:render()
	end)
	tern.timer(1, function()
		if not h.stopped then
			pcall(function()
				h.cx:frame({ { "focus", id } })
			end)
		end
	end)
end

function exec(h: Host, effects: { Effect })
	for _, e in effects do
		if h.stopped then
			return
		end
		if e.t == "find" then
			ProjectHost.find(e.cwd :: string, function(root: string?)
				deliver(h, { t = "found", root = root })
			end)
		elseif e.t == "scan" then
			ProjectHost.scan(e.root :: string, nil, function(snapshot, err)
				deliver(h, { t = "scanned", gen = e.gen, snapshot = snapshot, err = err })
			end)
		elseif e.t == "templates" then
			loadTemplates(h)
		elseif e.t == "focus" then
			focus(h, e.id :: string)
		elseif e.t == "write" then
			write(h, e)
		elseif e.t == "copy" then
			h.cx:copy(e.text or "")
			h.cx:toast("info", "Copied the validate command")
		elseif e.t == "exit" then
			h.stopped = true
			h.cx:exit(0)
		end
	end
end

local function errorView(err: any): BlockView
	return {
		main = {
			k = "col",
			p = { gap = "sm" },
			c = {
				{
					k = "text",
					p = { spans = { { t = "New SuiteScript could not render: " .. tostring(err), s = "error" } } },
				},
			},
		} :: any,
	}
end

local function dispatch(h: Host, msg: Msg): boolean
	local before = h.s
	local ok, s, effects = pcall(Form.update, h.s, msg)
	if not ok then
		warnOnce(h, "update " .. msg.t, s)
		return false
	end
	h.s = s
	exec(h, effects)
	return s ~= before or #effects > 0
end

function M.register()
	tern.block.define("scaffold", {
		init = function(cx: BlockCx, args: { string }, _saved: any): Host
			local cwd = args[1] or cx.cwd or "/"
			local s, effects = Form.init({ cwd = cwd, program = ConfigHost.current().suitecloud.program })
			local h: Host = { s = s, cx = cx, stopped = false, warned = false }
			exec(h, effects)
			return h
		end,
		view = function(h: Host, _cx: BlockCx): BlockView
			local ok, v = pcall(Form.view, h.s)
			if not ok then
				warnOnce(h, "view", v)
				return errorView(v)
			end
			return v :: any
		end,
		title = function(h: Host): string?
			return Form.title(h.s)
		end,
		key = function(h: Host, key: Key, cx: BlockCx): boolean?
			h.cx = cx
			return dispatch(h, { t = "key", key = key :: any })
		end,
		event = function(h: Host, ev: UiEvent, cx: BlockCx)
			h.cx = cx
			local prefix = Form.INPUT_PREFIX
			if ev.ev == "focus" and type(ev.id) == "string" and string.sub(ev.id, 1, #prefix) == prefix then
				dispatch(h, { t = "action", act = "field", value = string.sub(ev.id, #prefix + 1) })
			elseif ev.ev == "action" and type(ev.act) == "string" then
				dispatch(h, {
					t = "action",
					act = ev.act,
					value = if type(ev.value) == "string" then ev.value else nil,
				})
			end
		end,
	})
end

return M
