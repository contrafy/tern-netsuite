--!strict
-- NetSuite account-specific endpoints. The account id appears in two
-- spellings: the OAuth 1.0a realm is the id upper case with "_"
-- (`1234567_SB1`), the host label lower case with "-" (`1234567-sb1`).

local Encoding = require("./encoding")

local M = {}

-- REST SuiteQL returns at most 1000 rows per page.
M.MAX_PAGE = 1000
-- REST SuiteQL refuses offsets past 100000 rows; larger result sets need
-- keyset paging (lib/ns/paging.luau).
M.MAX_OFFSET = 100000

-- Whether `accountId` is safe to place in a host name.
function M.valid(accountId: string): boolean
	return string.find(accountId, "^[%w][%w_%-]*$") ~= nil and #accountId <= 64
end

local function check(accountId: string)
	if not M.valid(accountId) then
		error(string.format("invalid NetSuite account id %q", accountId), 3)
	end
end

function M.realm(accountId: string): string
	check(accountId)
	return (string.gsub(string.upper(accountId), "%-", "_"))
end

function M.host(accountId: string): string
	check(accountId)
	return (string.gsub(string.lower(accountId), "_", "-"))
end

function M.suiteql(accountId: string, limit: number, offset: number): string
	return string.format(
		"https://%s.suitetalk.api.netsuite.com/services/rest/query/v1/suiteql?limit=%d&offset=%d",
		M.host(accountId),
		limit,
		offset
	)
end

function M.restlet(accountId: string, script: string, deploy: string): string
	return string.format(
		"https://%s.restlets.api.netsuite.com/app/site/hosting/restlet.nl?%s",
		M.host(accountId),
		Encoding.query({ { "script", script }, { "deploy", deploy } })
	)
end

function M.token(accountId: string): string
	return string.format("https://%s.suitetalk.api.netsuite.com/services/rest/auth/oauth2/v1/token", M.host(accountId))
end

return M
