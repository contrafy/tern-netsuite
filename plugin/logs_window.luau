--!strict
-- Window half of the execution log tail: the palette command and the `logs`
-- link area. `tern-netsuite://logs?...` opens the `logs` block with validated
-- arguments, held until the user presses Enter (any program can print such
-- a link); `tern-netsuite://logs/start?grant=<id>` (the lens chip) takes a
-- single-use grant and opens a tail that starts at once;
-- `tern-netsuite://logs/connect?connection=<id>` opens the connect block
-- (the logs block links there when credentials are missing). The URL
-- format is documented in lib/monitor/logs/link.luau.

local lazy = require("./lib/lazy")
local Link = lazy(function()
	return require("./lib/monitor/logs/link")
end)

local M = {}

-- Handles `tern-netsuite://logs...`; window.luau dispatches area "logs" here.
function M.route(link: LinkRequest, cx: WindowCx): RouteDecision?
	local decision, err = Link().route(link.url)
	if decision == nil then
		cx:toast("error", "Tern NetSuite: invalid logs link", err)
		return { handled = true }
	end
	local args = Link().blockArgs(decision)
	if decision.grant then
		local granted, rest, why = Link().takeStart(tern.kv.get(Link().GRANTS_KEY), decision.grant, os.time())
		tern.kv.set(Link().GRANTS_KEY, rest)
		if granted == nil then
			cx:toast("error", "Tern NetSuite: logs not started", why)
			return { handled = true }
		end
		args = granted
	end
	return { block = decision.block, args = args }
end

function M.register()
	tern.command({
		id = "logs",
		title = "Tern NetSuite: Execution logs",
		icon = "cloud",
		run = function(cx: WindowCx)
			if cx:new_block(Link().BLOCK, {}, "beside") == nil then
				cx:toast("error", "Tern NetSuite: the logs block is not available on this host")
			end
		end,
	})
end

return M
