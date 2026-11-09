--!strict
-- NetSuite UI pages of a script and a script deployment on the account's
-- own domain (`<account>.app.netsuite.com`, the host the SuiteCloud CLI
-- prints for an auth ID). Oracle's help documents the menu path
-- (Customization > Scripting > Script Deployments) but not these URLs; the
-- paths are the ones the NetSuite UI itself uses: script records at
-- /app/common/scripting/script.nl, deployment records at
-- /app/common/scripting/scriptrecord.nl, both by internal id.

local Endpoints = require("../ns/endpoints")

local M = {}

M.SCRIPT_PATH = "/app/common/scripting/script.nl"
M.DEPLOYMENT_PATH = "/app/common/scripting/scriptrecord.nl"

local function page(accountId: string, path: string, id: number?): string?
	if id == nil or id < 1 or id ~= math.floor(id) or not Endpoints.valid(accountId) then
		return nil
	end
	return string.format("https://%s.app.netsuite.com%s?id=%d", Endpoints.host(accountId), path, id)
end

-- The deployment record page, or nil without a usable id.
function M.deployment(accountId: string, internalId: number?): string?
	return page(accountId, M.DEPLOYMENT_PATH, internalId)
end

-- The script record page, or nil without a usable id.
function M.script(accountId: string, internalId: number?): string?
	return page(accountId, M.SCRIPT_PATH, internalId)
end

return table.freeze(M)
