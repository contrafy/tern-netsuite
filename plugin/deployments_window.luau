--!strict
-- Window half of the script deployments view: the palette command and the
-- `deployments` link area. `tern-netsuite://deployments?...` opens the
-- `deployments` block held until the user presses Enter (any program can
-- print such a link); the URL format is documented in
-- lib/deployments/link.luau.

local lazy = require("./lib/lazy")
local Link = lazy(function()
	return require("./lib/deployments/link")
end)

local M = {}

local BLOCK = "tern-netsuite.deployments"

-- Handles `tern-netsuite://deployments...`; window.luau dispatches area
-- "deployments" here.
function M.route(link: LinkRequest, cx: WindowCx): RouteDecision?
	local decision, err = Link().route(link.url)
	if decision == nil then
		cx:toast("error", "Tern NetSuite: invalid deployments link", err)
		return { handled = true }
	end
	return { block = decision.block, args = decision.args }
end

function M.register()
	tern.command({
		id = "deployments",
		title = "Tern NetSuite: Script deployments",
		icon = "cloud",
		run = function(cx: WindowCx)
			if cx:new_block(BLOCK, {}, "beside") == nil then
				cx:toast("error", "Tern NetSuite: the deployments block is not available on this host")
			end
		end,
	})
end

return M
