--!strict
-- One JSON line per approve-block decision for `<plugin data>/audit.log`.
-- Built from an explicit whitelist: the request's notes and file list never
-- reach the log (only the file count). SuiteCloud deploy/upload argv carries
-- no credentials.

local M = {}

export type Decision = "approved" | "denied" | "cancelled"

export type Event = {
	decision: Decision,
	-- Unix seconds.
	decidedAt: number,
	command: string,
	argv: { string },
	cwd: string,
	folder: string,
	authId: string?,
	accountId: string?,
	accountLabel: string,
	production: boolean,
	fingerprint: string,
	files: number,
	branch: string?,
	head: string?,
	dirty: boolean?,
	reason: string?,
}

-- Fixed key order; absent fields are omitted.
local ORDER: { { string } } = {
	{ "v", "v" },
	{ "decided_at", "decidedAt" },
	{ "decision", "decision" },
	{ "command", "command" },
	{ "account_id", "accountId" },
	{ "account_label", "accountLabel" },
	{ "production", "production" },
	{ "auth_id", "authId" },
	{ "cwd", "cwd" },
	{ "folder", "folder" },
	{ "argv", "argv" },
	{ "files", "files" },
	{ "fingerprint", "fingerprint" },
	{ "branch", "branch" },
	{ "head", "head" },
	{ "dirty", "dirty" },
	{ "reason", "reason" },
}

local function quote(s: string): string
	local escaped = string.gsub(s, '[%c"\\]', function(c: string): string
		if c == '"' then
			return '\\"'
		elseif c == "\\" then
			return "\\\\"
		elseif c == "\n" then
			return "\\n"
		elseif c == "\r" then
			return "\\r"
		elseif c == "\t" then
			return "\\t"
		end
		return string.format("\\u%04x", string.byte(c))
	end)
	return '"' .. escaped .. '"'
end

local function value(v: any): string
	local tv = type(v)
	if tv == "string" then
		return quote(v)
	elseif tv == "number" then
		return string.format("%d", v)
	elseif tv == "boolean" then
		return tostring(v)
	end
	local parts: { string } = {}
	for _, item in v do
		table.insert(parts, quote(item))
	end
	return "[" .. table.concat(parts, ",") .. "]"
end

function M.line(event: Event): string
	local e = event :: any
	local parts: { string } = {}
	for _, pair in ORDER do
		local v = if pair[2] == "v" then 1 else e[pair[2]]
		if v ~= nil then
			table.insert(parts, quote(pair[1]) .. ":" .. value(v))
		end
	end
	return "{" .. table.concat(parts, ",") .. "}\n"
end

return M
