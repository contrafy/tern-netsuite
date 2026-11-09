--!strict
-- Window half of the record inspector: the palette command and the
-- `inspect` link area. `tern-netsuite://inspect?...` opens the `inspect`
-- block with validated arguments, held until the user presses Enter (any
-- program can print such a link); `tern-netsuite://inspect/start?grant=<id>`
-- takes a single-use grant the plugin's own UI stored and inspects at once.
-- The URL format is documented in lib/inspector/link.luau.

local lazy = require("./lib/lazy")
local Link = lazy(function()
	return require("./lib/inspector/link")
end)

local M = {}

-- Handles `tern-netsuite://inspect...`; window.luau dispatches area "inspect" here.
function M.route(link: LinkRequest, cx: WindowCx): RouteDecision?
	local decision, err = Link().route(link.url)
	if decision == nil then
		cx:toast("error", "Tern NetSuite: invalid inspect link", err)
		return { handled = true }
	end
	local args = Link().blockArgs(decision)
	if decision.grant then
		local granted, rest, why = Link().takeStart(tern.kv.get(Link().GRANTS_KEY), decision.grant, os.time())
		tern.kv.set(Link().GRANTS_KEY, rest)
		if granted == nil then
			cx:toast("error", "Tern NetSuite: record not inspected", why)
			return { handled = true }
		end
		args = granted
	end
	return { block = decision.block, args = args }
end

function M.register()
	tern.command({
		id = "inspect",
		title = "Tern NetSuite: Inspect record",
		icon = "cloud",
		run = function(cx: WindowCx)
			if cx:new_block(Link().BLOCK, {}, "beside") == nil then
				cx:toast("error", "Tern NetSuite: the inspect block is not available on this host")
			end
		end,
	})
end

return M
