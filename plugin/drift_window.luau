--!strict
-- Window glue for drift (lib/drift/state.luau): the palette command
-- "Tern NetSuite: Drift", which opens the block on the focused pane's
-- directory, and the `drift` link area: `tern-netsuite://drift[?cwd=<dir>]`,
-- which any program can print, opens the block held (lib/drift/link.luau):
-- it runs nothing until Enter.

local lazy = require("./lib/lazy")
local Link = lazy(function()
	return require("./lib/drift/link")
end)

local M = {}

local function focusedCwd(cx: WindowCx): string?
	local id = cx.session:focused()
	local info = if id then cx.session:pane(id) else nil
	local cwd = if info then info.cwd else nil
	return if cwd and string.sub(cwd, 1, 1) == "/" then cwd else nil
end

function M.route(link: LinkRequest, cx: WindowCx): RouteDecision?
	local parsed = Link().parse(link.url)
	if parsed == nil then
		cx:toast("error", "Tern NetSuite: invalid drift link", link.url)
		return { handled = true }
	end
	return { block = Link().BLOCK, args = Link().blockArgs(parsed.cwd, true) }
end

function M.register()
	tern.command({
		id = "drift",
		title = "Tern NetSuite: Drift",
		icon = "cloud",
		run = function(cx: WindowCx)
			if cx:new_block(Link().BLOCK, Link().blockArgs(focusedCwd(cx), false), "beside") == nil then
				cx:toast("error", "Tern NetSuite is not loaded on this host")
			end
		end,
	})
end

return M
