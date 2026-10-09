--!strict
-- Host glue for the SDF explorer block (lib/explorer/state.luau): loads the
-- config, locates the repository, finds and scans projects through
-- project_host, asks the CLI which account an auth id is, opens files,
-- copies text, and hands uploads to the window as a single-use grant
-- (lib/explorer/link.luau). Every answer goes back to the core as a message.

local ConfigHost = require("./config_host")
local Context = require("./lib/account/context")
local Link = require("./lib/explorer/link")
local Manageauth = require("./lib/account/manageauth")
local ProjectHost = require("./project_host")
local Render = require("./lib/explorer/render")
local Resolve = require("./lib/account/resolve")
local State = require("./lib/explorer/state")

local log = tern.log

type Effect = State.Effect
type Msg = State.Msg

type Host = { s: State.State, cx: BlockCx, stopped: boolean, warned: boolean }

local M = {}

M.INFO_TIMEOUT_MS = 60000

local seed = string.format("explorer:%d:%.6f:%.17g:%s", os.time(), os.clock(), math.random(), tostring({}))
local counter = 0

local function exists(path: string): boolean
	local ok, present = pcall(tern.fs.exists, path)
	return ok and present == true
end

local function warnOnce(h: Host, what: string, err: any)
	if not h.warned then
		h.warned = true
		log.warn("tern-netsuite explorer " .. what .. " failed", tostring(err))
	end
end

local exec: (h: Host, effects: { Effect }) -> ()

local function dispatch(h: Host, msg: Msg): boolean
	local ok, s, effects, changed = pcall(State.update, h.s, msg)
	if not ok then
		warnOnce(h, "update " .. msg.t, s)
		return false
	end
	h.s = s
	exec(h, effects)
	return changed or #effects > 0
end

local function deliver(h: Host, msg: Msg)
	if h.stopped then
		return
	end
	if dispatch(h, msg) then
		-- Synchronous answers arrive during init, before the block is mounted.
		pcall(function()
			h.cx:render()
		end)
	end
end

local function lookup(h: Host, authId: string)
	local program = ConfigHost.current().suitecloud.program
	local function done(entry: Resolve.CacheEntry)
		deliver(h, { t = "resolved", entry = entry, now = tern.now() })
	end
	local ok, err = pcall(function()
		tern.process.run(
			{ program, "account:manageauth", "--info", authId },
			{ timeout_ms = M.INFO_TIMEOUT_MS },
			function(r: ProcessResult)
				local info = if r.status == 0 then Manageauth.parseInfo(Manageauth.lines(r.stdout)) else nil
				if info and info.accountId then
					done(Resolve.fromInfo(info, tern.now()))
					return
				end
				local why = if r.timed_out
					then "timed out"
					else Manageauth.errorText(Manageauth.lines(r.stderr .. "\n" .. r.stdout))
				done(Resolve.fromError(authId, why or ("exit " .. r.status), tern.now()))
			end
		)
	end)
	if not ok then
		done(Resolve.fromError(authId, tostring(err), tern.now()))
	end
end

local function requestUpload(h: Host, e: Effect)
	local grant = e.grant
	if grant == nil then
		return
	end
	counter += 1
	local id = Link.newId(seed, counter)
	local ok, err = pcall(function()
		tern.kv.set(Link.GRANTS_KEY, Link.addGrant(tern.kv.get(Link.GRANTS_KEY), id, grant, os.time()))
		h.cx:open(Link.uploadUrl(id))
	end)
	if not ok then
		h.cx:toast("error", "Tern NetSuite: upload not started", tostring(err))
	end
end

function exec(h: Host, effects: { Effect })
	for _, e in effects do
		if h.stopped then
			return
		end
		if e.t == "config" then
			local snap = ConfigHost.load()
			deliver(h, { t = "config", gen = e.gen, config = snap.config, now = tern.now() })
		elseif e.t == "locate" then
			local cwd = e.cwd or "/"
			deliver(h, {
				t = "located",
				gen = e.gen,
				repoRoot = Context.repoRoot(cwd, exists),
				projectRoot = Context.findRoot(cwd, exists),
			})
		elseif e.t == "discover" then
			local roots = e.roots or {}
			ProjectHost.discover(e.base or "/", if #roots > 0 then roots else nil, function(found, err)
				deliver(h, { t = "discovered", gen = e.gen, roots = found, err = err })
			end)
		elseif e.t == "scan" then
			local root = e.root :: string
			-- A superseded scan of the same root (another explorer) still calls
			-- back, with the newer scan's result.
			ProjectHost.scan(root, nil, function(snapshot, err)
				deliver(h, { t = "scanned", gen = e.gen, root = root, snapshot = snapshot, err = err })
			end)
		elseif e.t == "lookup" then
			lookup(h, e.authId :: string)
		elseif e.t == "open" then
			-- Tern opens `<path>:<line>` in a file block at that line.
			h.cx:open(e.target :: string)
		elseif e.t == "copy" then
			h.cx:copy(e.text :: string)
			h.cx:toast("info", "Tern NetSuite: copied", e.note)
		elseif e.t == "upload" then
			requestUpload(h, e)
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
					p = { spans = { { t = "SDF explorer could not render: " .. tostring(err), s = "error" } } },
				},
			},
		} :: any,
	}
end

function M.register()
	tern.block.define("explorer", {
		init = function(cx: BlockCx, args: { string }, _saved: any): Host
			local s, effects = State.init(args, { cwd = cx.cwd, height = cx.rows, width = cx.cols })
			local h: Host = { s = s, cx = cx, stopped = false, warned = false }
			exec(h, effects)
			return h
		end,
		view = function(h: Host, _cx: BlockCx): BlockView
			local ok, v = pcall(Render.view, h.s)
			if not ok then
				warnOnce(h, "view", v)
				return errorView(v)
			end
			return v :: any
		end,
		title = function(h: Host): string?
			return Render.title(h.s)
		end,
		key = function(h: Host, key: Key, cx: BlockCx): boolean?
			h.cx = cx
			return dispatch(h, { t = "key", key = key })
		end,
		event = function(h: Host, ev: UiEvent, cx: BlockCx)
			h.cx = cx
			if ev.ev == "action" and ev.act == "row" and type(ev.value) == "string" then
				deliver(h, { t = "click", value = ev.value })
			end
		end,
		resize = function(h: Host, cols: number, rows: number, cx: BlockCx)
			h.cx = cx
			dispatch(h, { t = "resize", rows = rows, cols = cols })
		end,
	})
end

return M
