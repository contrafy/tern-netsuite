--!strict
-- Window glue for the account browser: the palette command "Browse account
-- objects" and the `browser` link area. `tern-netsuite://browser?cwd=<dir>`
-- (the suitecloud lens chip) opens the block; `.../browser/import?grant=<id>`
-- (from the block) takes the single-use grant, re-validates it and runs the
-- import in a split under the clicked pane, in the project directory so the
-- CLI picks the project's auth ID.

local ConfigHost = require("./config_host")
local Imports = require("./lib/browser/imports")
local Link = require("./lib/browser/link")

local log = tern.log

local M = {}

M.CONFIG_FILE = "suitecloud.config.js"

local function exists(path: string): boolean
	local ok, present = pcall(tern.fs.exists, path)
	return ok and present == true
end

local function focusedCwd(cx: WindowCx): string?
	local id = cx.session:focused()
	local info = if id then cx.session:pane(id) else nil
	local cwd = if info then info.cwd else nil
	return if cwd and string.sub(cwd, 1, 1) == "/" then cwd else nil
end

local function runImport(link: LinkRequest, cx: WindowCx, id: string)
	local grant, rest, why = Link.takeGrant(tern.kv.get(Link.GRANTS_KEY), id, os.time())
	tern.kv.set(Link.GRANTS_KEY, rest)
	if grant == nil then
		cx:toast("error", "Tern NetSuite: import not started", why)
		return
	end
	local req = grant.request
	if not exists(req.root .. "/" .. M.CONFIG_FILE) then
		cx:toast("error", "Tern NetSuite: import not started", req.root .. " is no longer an SDF project")
		return
	end
	local argv, err = Imports.argv(ConfigHost.current().suitecloud.program, req)
	if argv == nil then
		cx:toast("error", "Tern NetSuite: import not started", err)
		return
	end
	local line = Imports.commandLine(argv)
	local at = if link.pane ~= 0 then link.pane else cx.session:focused()
	-- A shell pane, not a `command` launch: a command pane closes when the
	-- command exits, taking its output with it.
	local opened = if at then cx.layout:split(at, "down", { cwd = req.root }) else nil
	log.info("tern-netsuite import", req.root, line, "pane=" .. tostring(opened))
	if opened == nil then
		cx:toast("error", "Tern NetSuite: could not open a pane for the import", "Nothing was run")
		return
	end
	cx:run(opened, line .. "\r")
	cx:toast("info", "Tern NetSuite: importing " .. (req.scriptId or req.path or "?"), grant.label)
end

function M.route(link: LinkRequest, cx: WindowCx): RouteDecision?
	local parsed = Link.parse(link.url)
	if parsed == nil then
		cx:toast("error", "Tern NetSuite: invalid browser link", link.url)
		return { handled = true }
	end
	if parsed.t == "browse" then
		local cwd = parsed.cwd
		return { block = Link.BLOCK, args = if cwd then { cwd } else {} }
	end
	runImport(link, cx, parsed.id :: string)
	return { handled = true }
end

function M.register()
	tern.command({
		id = "browser",
		title = "Tern NetSuite: Browse account objects",
		icon = "cloud",
		run = function(cx: WindowCx)
			local cwd = focusedCwd(cx)
			if cx:new_block(Link.BLOCK, if cwd then { cwd } else {}, "beside") == nil then
				cx:toast("error", "Tern NetSuite is not loaded on this host")
			end
		end,
	})
end

return M
