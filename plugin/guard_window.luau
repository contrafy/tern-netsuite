--!strict
-- Window glue for the production deploy guard: `tern open --wait
-- <spool>/req-<nonce>.json` from shell/tern-netsuite-guard opens the approve
-- block instead of an editor. Any other open runs the built-in.

local Protocol = require("./lib/guard/protocol")

local M = {}

M.BLOCK = "tern-netsuite.approve"

function M.register()
	tern.route.open(function(req: OpenRequest, _cx: WindowCx): RouteDecision?
		if req.origin ~= "cli" or not Protocol.isRequestPath(req.path) then
			return nil
		end
		return { block = M.BLOCK, args = { req.path } }
	end)
end

return M
