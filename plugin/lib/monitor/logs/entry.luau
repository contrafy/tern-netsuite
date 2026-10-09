--!strict
-- One execution log line (a SuiteQL `scriptnote` row joined to `script`).
-- The REST transport returns every value as a string and the RESTlet returns
-- typed values; both read the same here.

local M = {}

export type Entry = {
	id: number,
	-- `YYYY-MM-DD HH:MM:SS` in the account's time zone (TO_CHAR of `date`).
	logged: string,
	-- Upper-case log type: DEBUG, AUDIT, ERROR, EMERGENCY or SYSTEM.
	level: string,
	rank: number,
	title: string,
	detail: string,
	-- The script's numeric internal id (`scriptnote.scripttype`).
	script: number?,
	scriptId: string?,
	scriptName: string?,
	namespace: string?,
	event: string,
	-- Lower-cased title and detail, for the text filter.
	hay: string,
}

-- Minimum-level choices, lowest first.
M.LEVELS = table.freeze({ "DEBUG", "AUDIT", "ERROR", "EMERGENCY" })

-- SYSTEM notes are uncaught exceptions NetSuite logs itself.
local RANK: { [string]: number } = { DEBUG = 1, AUDIT = 2, ERROR = 3, SYSTEM = 3, EMERGENCY = 4 }

function M.rank(level: string): number
	return RANK[string.upper(level)] or RANK.AUDIT
end

local function str(v: any): string?
	if type(v) == "string" then
		return v
	elseif type(v) == "number" then
		return string.format("%.14g", v)
	end
	return nil
end

local function num(v: any): number?
	local n = if type(v) == "number" then v elseif type(v) == "string" then tonumber(v) else nil
	if n == nil or n ~= n or n % 1 ~= 0 then
		return nil
	end
	return n
end

-- (namespace, event) of a `namespace:event` title, split at the last colon;
-- (nil, title) for prose ("Error: x") and titles without a colon.
function M.splitTitle(title: string): (string?, string)
	local ns, event = string.match(title, "^(%S+):([^:]+)$")
	if ns == nil or event == nil or string.find(event, "^%s") or string.sub(ns, 1, 1) == ":" then
		return nil, title
	end
	return ns, event
end

function M.fromRow(row: any): Entry?
	if type(row) ~= "table" then
		return nil
	end
	local id = num(row.internalid)
	if id == nil then
		return nil
	end
	local title = str(row.title) or ""
	local detail = str(row.detail) or ""
	local level = string.upper(str(row.type) or "")
	local namespace, event = M.splitTitle(title)
	local scriptId = str(row.scriptid)
	local scriptName = str(row.scriptname)
	return {
		id = id,
		logged = str(row.logged) or "",
		level = level,
		rank = M.rank(level),
		title = title,
		detail = detail,
		script = num(row.scripttype),
		scriptId = if scriptId and scriptId ~= "" then string.lower(scriptId) else nil,
		scriptName = if scriptName and scriptName ~= "" then scriptName else nil,
		namespace = namespace,
		event = event,
		hay = string.lower(title .. "\n" .. detail),
	}
end

function M.scriptLabel(e: Entry): string
	return e.scriptName or e.scriptId or (if e.script then "script " .. string.format("%d", e.script) else "?")
end

-- The theme tone of a level.
function M.tone(level: string): string
	local r = M.rank(level)
	if r >= 3 then
		return "error"
	elseif level == "AUDIT" then
		return "accent"
	elseif level == "DEBUG" then
		return "muted"
	end
	return "warning"
end

return M
