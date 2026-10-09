--!strict
-- Parses `suitecloud account:manageauth --list` and `--info <authId>`
-- (SuiteCloud CLI 3.x wording). A list row is `<authId> | <role> @ <company>`
-- followed by ` | <domain>` only when the auth id's host is not a production
-- one, so production rows carry no account id; account-specific domains
-- (`1234567-sb1.app.netsuite.com`) encode the account id.

export type Entry = {
	authId: string,
	accountId: string?,
	accountName: string?,
	role: string?,
	domain: string?,
	-- The CLI's "Account Type" wording: "Sandbox", "Release Preview" or "Production".
	kind: string?,
}

export type Info = Entry

local M = {}

-- The CLI clears its spinner line (ESC[2K ESC[1G) before the first result line.
local function clean(line: string): string
	local s = string.gsub(line, "\27%[[%d;?]*[%a]", "")
	s = string.gsub(s, "\r", "")
	return s
end

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") :: string
end

local function nonEmpty(s: string?): string?
	if s == nil then
		return nil
	end
	local v = trim(s)
	return if v == "" then nil else v
end

-- Same patterns the CLI uses for its "Account Type" line.
function M.kindOf(accountId: string): string
	local id = string.upper(accountId)
	if string.find(id, ".+_SB%d*$") then
		return "Sandbox"
	elseif string.find(id, ".+_RP%d*$") then
		return "Release Preview"
	end
	return "Production"
end

function M.accountFromDomain(domain: string): string?
	local host = string.match(string.lower(domain), "^([%w%-]+)%.app%.netsuite%.com$")
	if host == nil or host == "system" then
		return nil
	end
	return (string.upper((string.gsub(host, "%-", "_"))))
end

local function listEntry(raw: string): Entry?
	local line = clean(raw)
	local authId, rest = string.match(line, "^(%S+) | (.*)$")
	if authId == nil or rest == nil then
		return nil
	end
	local body, domain = string.match(rest, "^(.-) | (%S+%.%S+)%s*$")
	if body == nil then
		body = rest
	end
	local role, company = string.match(body :: string, "^(.-) @ (.*)$")
	if role == nil then
		return nil
	end
	local accountId = if domain then M.accountFromDomain(domain) else nil
	return {
		authId = authId,
		role = nonEmpty(role),
		accountName = nonEmpty(company),
		domain = domain,
		accountId = accountId,
		kind = if accountId then M.kindOf(accountId) else nil,
	}
end

-- nil when no line looks like a list row.
function M.parseList(lines: { string }): { Entry }?
	local out: { Entry } = {}
	for _, line in lines do
		local e = listEntry(line)
		if e then
			table.insert(out, e)
		end
	end
	return if #out > 0 then out else nil
end

local INFO_FIELDS: { [string]: string } = {
	["Authentication ID"] = "authId",
	["Account Name"] = "accountName",
	["Account ID"] = "accountId",
	["Role"] = "role",
	["Domain"] = "domain",
	["Account Type"] = "kind",
}

-- nil unless an "Authentication ID:" line is present.
function M.parseInfo(lines: { string }): Info?
	local fields: { [string]: string } = {}
	for _, raw in lines do
		local label, value = string.match(clean(raw), "^([%a ]-):%s*(.-)%s*$")
		local key = if label then INFO_FIELDS[label] else nil
		if key and value and value ~= "" and fields[key] == nil then
			fields[key] = value
		end
	end
	local authId = fields.authId
	if authId == nil then
		return nil
	end
	return {
		authId = authId,
		accountName = fields.accountName,
		accountId = if fields.accountId then string.upper(fields.accountId) else nil,
		role = fields.role,
		domain = fields.domain,
		kind = fields.kind,
	}
end

-- Non-blank lines (escape codes removed) that are not list rows: Node
-- warnings, notices, anything a newer CLI adds.
function M.unrecognizedList(lines: { string }): { string }
	local out: { string } = {}
	for _, raw in lines do
		local line = trim(clean(raw))
		if line ~= "" and listEntry(raw) == nil then
			table.insert(out, line)
		end
	end
	return out
end

-- Non-blank lines (escape codes removed) that are not a known --info field.
function M.unrecognizedInfo(lines: { string }): { string }
	local out: { string } = {}
	for _, raw in lines do
		local line = trim(clean(raw))
		local label = string.match(line, "^([%a ]-):")
		if line ~= "" and (label == nil or INFO_FIELDS[label] == nil) then
			table.insert(out, line)
		end
	end
	return out
end

-- The first non-blank line of a failed call, without escape codes.
function M.errorText(lines: { string }): string?
	for _, raw in lines do
		local s = nonEmpty(clean(raw))
		if s then
			return s
		end
	end
	return nil
end

function M.lines(text: string): { string }
	local out: { string } = {}
	for line in string.gmatch(text, "[^\n]+") do
		table.insert(out, line)
	end
	return out
end

return M
