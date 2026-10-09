--!strict
-- SuiteQL for the execution log tail. Observed on a sandbox (2026-10):
--   * `scriptnote.internalid` is NOT ordered by time: ids come in blocks of
--     100 per server session, so a long-running script keeps writing ids
--     below ones a newer request already used. Polling `internalid > last`
--     would lose those lines; the tail polls a time window instead and
--     dedupes by id (buffer.luau).
--   * `SELECT * FROM (... ORDER BY ...) WHERE ROWNUM <= n` returns the right
--     n rows but not in order through the RESTlet, so callers sort.
--   * `date` is date-only unless wrapped in TO_CHAR; SYSDATE uses the same
--     time zone as `date`.
-- User input only ever reaches the query as `?` parameters.

local Paging = require("../../ns/paging")

local M = {}

export type Since = { at: string?, minutes: number? }

export type Scope = {
	-- Script ids (`customscript_x`, lower case) or numeric internal ids, as
	-- validated by link.luau.
	scripts: { string },
	since: Since?,
}

export type Clause = { sql: string, params: { any } }

M.MAX_ROWS = 1000
-- Rows re-read before the newest timestamp on every poll, for lines that
-- become visible after newer ones.
M.OVERLAP_SECONDS = 120

local FORMAT = "'YYYY-MM-DD HH24:MI:SS'"

M.COLUMNS = "n.internalid, TO_CHAR(n.date, "
	.. FORMAT
	.. ") AS logged, n.type, n.title, n.detail, n.scripttype, s.scriptid, s.name AS scriptname"
	.. " FROM scriptnote n LEFT JOIN script s ON s.id = n.scripttype"

local function limit(n: number): number
	return math.clamp(math.floor(n), 1, M.MAX_ROWS)
end

local function scriptCondition(scripts: { string }, params: { any }): string?
	local ids: { any } = {}
	local numeric: { any } = {}
	for _, s in scripts do
		local n = if string.find(s, "^%d+$") then tonumber(s) else nil
		if n then
			table.insert(numeric, n)
		else
			table.insert(ids, s)
		end
	end
	local parts: { string } = {}
	for _, c in Paging.inList("LOWER(s.scriptid)", ids) do
		table.insert(parts, c.sql)
		table.move(c.params, 1, #c.params, #params + 1, params)
	end
	for _, c in Paging.inList("n.scripttype", numeric) do
		table.insert(parts, c.sql)
		table.move(c.params, 1, #c.params, #params + 1, params)
	end
	if #parts == 0 then
		return nil
	end
	return "(" .. table.concat(parts, " OR ") .. ")"
end

local function build(scope: Scope, extra: { string }, extraParams: { any }, order: string, n: number): Clause
	local params: { any } = {}
	local conds: { string } = {}
	local scripts = scriptCondition(scope.scripts, params)
	if scripts then
		table.insert(conds, scripts)
	end
	table.move(extra, 1, #extra, #conds + 1, conds)
	table.move(extraParams, 1, #extraParams, #params + 1, params)
	local where = if #conds > 0 then " WHERE " .. table.concat(conds, " AND ") else ""
	return {
		sql = string.format(
			"SELECT * FROM (SELECT %s%s ORDER BY %s) WHERE ROWNUM <= %d",
			M.COLUMNS,
			where,
			order,
			limit(n)
		),
		params = params,
	}
end

local ASC = "n.date, n.internalid"
local DESC = "n.date DESC, n.internalid DESC"

-- The first load: the newest `n` rows, or the first `n` from `scope.since`.
function M.first(scope: Scope, n: number): Clause
	local since = scope.since
	if since and since.at then
		return build(scope, { "n.date >= TO_DATE(?, " .. FORMAT .. ")" }, { since.at }, ASC, n)
	elseif since and since.minutes then
		return build(scope, { "n.date >= SYSDATE - (? / 1440)" }, { since.minutes }, ASC, n)
	end
	return build(scope, {}, {}, DESC, n)
end

-- A poll: up to `n` rows logged at or after `from`, oldest first.
function M.poll(scope: Scope, from: string, n: number): Clause
	return build(scope, { "n.date >= TO_DATE(?, " .. FORMAT .. ")" }, { from }, ASC, n)
end

local function daysFromCivil(y: number, m: number, d: number): number
	-- Howard Hinnant's algorithm (proleptic Gregorian).
	y = if m <= 2 then y - 1 else y
	local era = (if y >= 0 then y else y - 399) // 400
	local yoe = y - era * 400
	local doy = (153 * (if m > 2 then m - 3 else m + 9) + 2) // 5 + d - 1
	local doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
	return era * 146097 + doe - 719468
end

local function civilFromDays(z: number): (number, number, number)
	z += 719468
	local era = (if z >= 0 then z else z - 146096) // 146097
	local doe = z - era * 146097
	local yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
	local y = yoe + era * 400
	local doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
	local mp = (5 * doy + 2) // 153
	local d = doy - (153 * mp + 2) // 5 + 1
	local m = if mp < 10 then mp + 3 else mp - 9
	return (if m <= 2 then y + 1 else y), m, d
end

-- `ts` (`YYYY-MM-DD HH:MM:SS`) moved by `seconds`; nil when `ts` is not one.
-- Pure calendar arithmetic: both sides are in the account's time zone.
function M.shift(ts: string, seconds: number): string?
	local y, mo, d, h, mi, s = string.match(ts, "^(%d%d%d%d)%-(%d%d)%-(%d%d) (%d%d):(%d%d):(%d%d)$")
	if y == nil then
		return nil
	end
	local total = daysFromCivil(tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number) * 86400
		+ (tonumber(h) :: number) * 3600
		+ (tonumber(mi) :: number) * 60
		+ (tonumber(s) :: number)
		+ math.floor(seconds)
	local days = total // 86400
	local rest = total - days * 86400
	local yy, mm, dd = civilFromDays(days)
	return string.format("%04d-%02d-%02d %02d:%02d:%02d", yy, mm, dd, rest // 3600, (rest // 60) % 60, rest % 60)
end

-- Where the next poll starts: the overlap window before `watermark`, or
-- `watermark` itself after a full page so a busy account still advances.
function M.nextFrom(watermark: string, full: boolean): string
	if full then
		return watermark
	end
	return M.shift(watermark, -M.OVERLAP_SECONDS) or watermark
end

return M
