--!strict
-- Window half of the execution log tail: the palette command and the `logs`
-- link area. `tern-netsuite://logs?...` opens the `logs` block with validated
-- arguments; `tern-netsuite://logs/connect?connection=<id>` opens the connect
-- block (the logs block links there when credentials are missing). The URL
-- format is documented in lib/monitor/logs/link.luau.

local Link = require("./lib/monitor/logs/link")

local M = {}

-- Handles `tern-netsuite://logs...`; window.luau dispatches area "logs" here.
function M.route(link: LinkRequest, cx: WindowCx): RouteDecision?
	local decision, err = Link.route(link.url)
	if decision == nil then
		cx:toast("error", "Tern NetSuite: invalid logs link", err)
		return { handled = true }
	end
	return { block = decision.block, args = decision.args }
end

function M.register()
	tern.command({
		id = "logs",
		title = "Tern NetSuite: Execution logs",
		icon = "cloud",
		run = function(cx: WindowCx)
			if cx:new_block(Link.BLOCK, {}, "beside") == nil then
				cx:toast("error", "Tern NetSuite: the logs block is not available on this host")
			end
		end,
	})
end

return M
