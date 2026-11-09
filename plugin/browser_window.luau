--!strict
-- Window glue for the account browser: the palette command "Browse account
-- objects" and the `browser` link area (lib/browser/link.luau):
--   - `tern-netsuite://browser?grant=<id>` (the suitecloud lens chip) takes
--     the single-use grant and opens the block on its directory;
--   - a bare `tern-netsuite://browser[?cwd=<dir>]`, which any program can
--     print, opens the block held: it runs nothing until Enter;
--   - `.../browser/import?grant=<id>` (from the block) takes the grant,
--     re-validates it and runs the import in a split under the clicked
--     pane, in the project directory (where the CLI reads the auth ID) and
--     in that auth ID's CLI slot (cli_slot_host.luau).

local lazy = require("./lib/lazy")
local CliSlotHost = lazy(function()
	return require("./cli_slot_host")
end)
local ConfigHost = require("./config_host")
local Imports = lazy(function()
	return require("./lib/browser/imports")
end)
local Link = lazy(function()
	return require("./lib/browser/link")
end)

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
	local grant, rest, why = Link().takeGrant(tern.kv.get(Link().GRANTS_KEY), id, os.time())
	tern.kv.set(Link().GRANTS_KEY, rest)
	if grant == nil then
		cx:toast("error", "Tern NetSuite: import not started", why)
		return
	end
	local req = grant.request
	if not exists(req.root .. "/" .. M.CONFIG_FILE) then
		cx:toast("error", "Tern NetSuite: import not started", req.root .. " is no longer an SDF project")
		return
	end
	local l, err = Imports().launch(ConfigHost.current().suitecloud.program, req, CliSlotHost().lock(grant.authId))
	if l == nil then
		cx:toast("error", "Tern NetSuite: import not started", err)
		return
	end
	local at = if link.pane ~= 0 then link.pane else cx.session:focused()
	-- The pane script waits for Enter after the import, so the output stays.
	local opened = if at then cx.layout:split(at, "down", { command = l.line, cwd = l.cwd }) else nil
	log.info("tern-netsuite import", req.root, Imports().commandLine(l.argv), "pane=" .. tostring(opened))
	if opened == nil then
		cx:toast("error", "Tern NetSuite: could not open a pane for the import", "Nothing was run")
		return
	end
	cx:toast("info", "Tern NetSuite: importing " .. (req.scriptId or req.path or "?"), grant.label)
end

function M.route(link: LinkRequest, cx: WindowCx): RouteDecision?
	local parsed = Link().parse(link.url)
	if parsed == nil then
		cx:toast("error", "Tern NetSuite: invalid browser link", link.url)
		return { handled = true }
	end
	if parsed.t == "browse" then
		return { block = Link().BLOCK, args = Link().blockArgs(parsed.cwd, true) }
	end
	if parsed.t == "grant" then
		local cwd, rest, why = Link().takeBrowse(tern.kv.get(Link().BROWSE_KEY), parsed.id :: string, os.time())
		tern.kv.set(Link().BROWSE_KEY, rest)
		if cwd == nil then
			cx:toast("error", "Tern NetSuite: browser not opened", why)
			return { handled = true }
		end
		return { block = Link().BLOCK, args = Link().blockArgs(cwd, false) }
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
			if cx:new_block(Link().BLOCK, Link().blockArgs(cwd, false), "beside") == nil then
				cx:toast("error", "Tern NetSuite is not loaded on this host")
			end
		end,
	})
end

return M
