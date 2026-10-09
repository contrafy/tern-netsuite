--!strict
-- The health checks of every configured connection and how a result turns
-- into a state. Built-in checks (all read-only SuiteQL, verified against a
-- sandbox) come first; the configured `monitor.checks` follow.
--
-- Time: SuiteQL returns wall-clock times of the account's time zone and
-- `scriptnote.date` is date-only unless wrapped in TO_CHAR. Recent-error
-- windows are therefore computed server-side against SYSDATE, and the
-- `errors` check also returns TO_CHAR(SYSDATE) so freshness checks measure
-- ages against the server's clock, not the local one. `SYSDATE - date`
-- arithmetic is refused by SuiteQL ("Invalid or unsupported search"), while
-- `date >= SYSDATE - 1/24` and scalar subqueries from DUAL work.
--
-- Left out: map/reduce and scheduled script run status. No SuiteQL table
-- for script instances could be verified, so there is no check for it.

local Config = require("../../config")
local Dates = require("./dates")
local Errors = require("../../ns/errors")

type NsError = Errors.NsError

local M = {}

export type Kind = "errors" | "hourly" | "last_error" | "deployments" | "clock" | "count" | "freshness"
export type State = "ok" | "warn" | "error" | "pending" | "failed"

export type Spec = {
	-- Unique across connections: `<connection>/<id>`.
	key: string,
	id: string,
	connection: string,
	kind: Kind,
	label: string,
	sql: string,
	max_rows: number,
	-- Seconds between runs.
	interval: number,
	warn_at: number?,
	error_at: number?,
	max_age_minutes: number?,
	-- Built-ins that only feed details (sparkline, last error), not a row.
	detail: boolean,
}

-- The server's clock: naive seconds `server` observed at local `at`.
export type Clock = { server: number, at: number }

export type LastError = { at: string, title: string, detail: string, script: string?, scriptName: string? }
export type Deployment = { scriptid: string, title: string, status: string, deployed: boolean, script: string? }

export type Result = {
	state: State,
	-- Local seconds of the answer.
	at: number,
	value: string?,
	threshold: string?,
	error: string?,
	code: string?,
	errorKind: string?,
	h1: number?,
	h24: number?,
	clock: Clock?,
	series: { number }?,
	-- `YYYY-MM-DD HH:00` server time of the last bucket.
	seriesEnd: string?,
	lastError: LastError?,
	deployments: { Deployment }?,
	more: boolean?,
}

M.MAX_DEPLOYMENTS = 100
M.MAX_DETAIL = 400
M.HOURS = 24

local ERROR_TYPES = "('ERROR', 'EMERGENCY')"

local SQL = {
	errors = "SELECT TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS') AS server_now,"
		.. " (SELECT COUNT(*) FROM scriptnote WHERE type IN "
		.. ERROR_TYPES
		.. " AND date >= SYSDATE - 1/24) AS h1,"
		.. " (SELECT COUNT(*) FROM scriptnote WHERE type IN "
		.. ERROR_TYPES
		.. " AND date >= SYSDATE - 1) AS h24"
		.. " FROM DUAL",
	hourly = "SELECT TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS') AS server_now,"
		.. " TO_CHAR(date, 'YYYY-MM-DD HH24') AS hour, COUNT(*) AS n"
		.. " FROM scriptnote WHERE type IN "
		.. ERROR_TYPES
		.. " AND date >= SYSDATE - 1"
		.. " GROUP BY TO_CHAR(date, 'YYYY-MM-DD HH24')",
	last_error = "SELECT TO_CHAR(n.date, 'YYYY-MM-DD HH24:MI:SS') AS at, n.title,"
		.. " SUBSTR(n.detail, 1, "
		.. M.MAX_DETAIL
		.. ") AS detail, s.scriptid AS script, s.name AS script_name"
		.. " FROM scriptnote n LEFT JOIN script s ON s.id = n.scripttype"
		.. " WHERE n.type IN "
		.. ERROR_TYPES
		.. " AND n.date >= SYSDATE - 1"
		.. " ORDER BY n.date DESC, n.internalid DESC FETCH FIRST 1 ROWS ONLY",
	-- Scheduled and map/reduce deployments sit in SCHEDULED / NOTSCHEDULED
	-- by design, so only TESTING counts as not released.
	deployments = "SELECT d.scriptid, d.title, d.status, d.isdeployed, s.scriptid AS script"
		.. " FROM scriptdeployment d LEFT JOIN script s ON s.id = d.script"
		.. " WHERE d.status = 'TESTING' OR d.isdeployed = 'F'"
		.. " ORDER BY d.scriptid FETCH FIRST "
		.. (M.MAX_DEPLOYMENTS + 1)
		.. " ROWS ONLY",
	-- Only polled when script errors are off: freshness still needs the
	-- server clock the `errors` query normally returns.
	clock = "SELECT TO_CHAR(SYSDATE, 'YYYY-MM-DD HH24:MI:SS') AS server_now FROM DUAL",
}

M.SQL = table.freeze(SQL)

type Builtin = { id: string, kind: Kind, label: string, max_rows: number, detail: boolean, scriptErrors: boolean }

local BUILTIN: { Builtin } = {
	{ id = "errors", kind = "errors", label = "Script errors", max_rows = 1, detail = false, scriptErrors = true },
	{
		id = "hourly",
		kind = "hourly",
		label = "Errors per hour",
		max_rows = M.HOURS + 2,
		detail = true,
		scriptErrors = true,
	},
	{ id = "last_error", kind = "last_error", label = "Last error", max_rows = 1, detail = true, scriptErrors = true },
	{
		id = "deployments",
		kind = "deployments",
		label = "Deployments",
		max_rows = M.MAX_DEPLOYMENTS + 1,
		detail = false,
		scriptErrors = false,
	},
}

local CLOCK: Builtin =
	{ id = "clock", kind = "clock", label = "Server clock", max_rows = 1, detail = true, scriptErrors = false }

local function key(connection: string, id: string): string
	return connection .. "/" .. id
end

-- Every check to poll, connection by connection in config order. The
-- clock source (`errors`, else `clock`) comes first so freshness checks can
-- be evaluated in the first round.
function M.specs(cfg: Config.Config): { Spec }
	local out: { Spec } = {}
	local interval = cfg.monitor.poll_seconds
	local se = cfg.monitor.script_errors
	for _, c in cfg.connections do
		local builtins: { Builtin } = {}
		if not se.enabled then
			for _, ch in cfg.monitor.checks do
				if ch.connection == c.id and ch.kind == "freshness" then
					table.insert(builtins, CLOCK)
					break
				end
			end
		end
		for _, b in BUILTIN do
			if se.enabled or not b.scriptErrors then
				table.insert(builtins, b)
			end
		end
		for _, b in builtins do
			table.insert(out, {
				key = key(c.id, b.id),
				id = b.id,
				connection = c.id,
				kind = b.kind,
				label = b.label,
				sql = SQL[b.kind],
				max_rows = b.max_rows,
				interval = interval,
				warn_at = if b.kind == "errors" then se.day_warn_at else nil,
				error_at = if b.kind == "errors" then se.hour_error_at else nil,
				detail = b.detail,
			})
		end
		for _, ch in cfg.monitor.checks do
			if ch.connection == c.id then
				table.insert(out, {
					-- `user:` keeps a configured id from shadowing a built-in.
					key = key(c.id, "user:" .. ch.id),
					id = ch.id,
					connection = c.id,
					kind = ch.kind,
					label = ch.label,
					sql = ch.query,
					max_rows = 1,
					interval = interval,
					warn_at = ch.warn_at,
					error_at = ch.error_at,
					max_age_minutes = ch.max_age_minutes,
					detail = false,
				})
			end
		end
	end
	return out
end

-- Values ----------------------------------------------------------------------

local function str(v: any): string?
	if type(v) == "string" then
		return if v == "" then nil else v
	elseif type(v) == "number" then
		return tostring(v)
	end
	return nil
end

-- REST returns numbers as strings, the RESTlet as numbers; nil = null.
local function num(v: any): (number?, boolean)
	if v == nil or v == "" then
		return nil, true
	end
	if type(v) == "number" then
		return v, true
	end
	local n = if type(v) == "string" then tonumber(v) else nil
	return n, n ~= nil
end

local function columns(row: { [string]: any }): { string }
	local out: { string } = {}
	for k in row do
		if k ~= "links" then
			table.insert(out, k)
		end
	end
	table.sort(out)
	return out
end

-- The column a single-value check reads: the only one, else the first of
-- `preferred` present. JSON objects have no column order to fall back on.
local function pick(row: { [string]: any }, preferred: { string }): (string?, string?)
	local cols = columns(row)
	if #cols <= 1 then
		return cols[1], nil
	end
	for _, name in preferred do
		if row[name] ~= nil then
			return name, nil
		end
	end
	return nil,
		string.format(
			"the query returns several columns (%s); return one, or name it %s",
			table.concat(cols, ", "),
			preferred[1]
		)
end

local function fmtNum(n: number): string
	return if n == math.floor(n) then string.format("%d", n) else tostring(n)
end

function M.ageText(seconds: number): string
	if seconds < 60 then
		return "just now"
	elseif seconds < 3600 then
		return string.format("%d min ago", seconds // 60)
	elseif seconds < 86400 then
		local h, mi = seconds // 3600, (seconds % 3600) // 60
		return if mi == 0 then string.format("%d h ago", h) else string.format("%d h %d min ago", h, mi)
	end
	return string.format("%d d ago", seconds // 86400)
end

local function serverNow(clock: Clock, now: number): number
	return clock.server + (now - clock.at)
end

local function clockOf(row: any, now: number): Clock?
	local s = if type(row) == "table" then Dates.parse(row.server_now) else nil
	return if s then { server = s.t, at = now } else nil
end

-- Evaluators ------------------------------------------------------------------

local function result(state: State, now: number): Result
	return { state = state, at = now }
end

local function failed(now: number, message: string): Result
	local r = result("failed", now)
	r.error = message
	return r
end

local function errors(spec: Spec, rows: { any }, now: number): Result
	local row = rows[1]
	if type(row) ~= "table" then
		return failed(now, "NetSuite returned no row for the error count")
	end
	local h1, ok1 = num(row.h1)
	local h24, ok24 = num(row.h24)
	if not ok1 or not ok24 then
		return failed(now, "the error counts are not numbers")
	end
	local a, b = h1 or 0, h24 or 0
	local errorAt, warnAt = spec.error_at or 1, spec.warn_at or 1
	local r = result(if a >= errorAt then "error" elseif b >= warnAt then "warn" else "ok", now)
	r.h1, r.h24 = a, b
	r.value = string.format("%s in 1 h · %s in 24 h", fmtNum(a), fmtNum(b))
	r.threshold = string.format("error ≥ %s in 1 h · warn ≥ %s in 24 h", fmtNum(errorAt), fmtNum(warnAt))
	r.clock = clockOf(row, now)
	return r
end

local function hourly(rows: { any }, now: number, clock: Clock?): Result
	local c = clockOf(rows[1], now) or clock
	local series = table.create(M.HOURS, 0)
	local r = result("ok", now)
	r.series = series
	if c == nil then
		return r
	end
	local current = (serverNow(c, now) // 3600) * 3600
	for _, row in rows do
		local hour = if type(row) == "table" then Dates.parse(row.hour) else nil
		local n = if type(row) == "table" then num(row.n) else nil
		if hour and n then
			local i = M.HOURS - (current - hour.t) // 3600
			if i >= 1 and i <= M.HOURS then
				series[i] += n
			end
		end
	end
	r.seriesEnd = string.sub(Dates.format(current), 1, 16)
	local peak = 0
	for _, n in series do
		peak = math.max(peak, n)
	end
	r.value = string.format("peak %s/h", fmtNum(peak))
	return r
end

local function lastError(rows: { any }, now: number): Result
	local r = result("ok", now)
	local row = rows[1]
	if type(row) ~= "table" then
		r.value = "none in 24 h"
		return r
	end
	local e: LastError = {
		at = str(row.at) or "",
		title = str(row.title) or "",
		detail = string.sub(str(row.detail) or "", 1, M.MAX_DETAIL),
		script = str(row.script),
		scriptName = str(row.script_name),
	}
	r.lastError = e
	r.value = e.at
	return r
end

local function deployments(rows: { any }, now: number): Result
	local list: { Deployment } = {}
	local testing, undeployed = 0, 0
	for i, row in rows do
		if i > M.MAX_DEPLOYMENTS then
			break
		end
		if type(row) == "table" then
			local d: Deployment = {
				scriptid = str(row.scriptid) or "?",
				title = str(row.title) or "",
				status = str(row.status) or "",
				deployed = row.isdeployed ~= "F" and row.isdeployed ~= false,
				script = str(row.script),
			}
			table.insert(list, d)
			if d.status == "TESTING" then
				testing += 1
			end
			if not d.deployed then
				undeployed += 1
			end
		end
	end
	local more = #rows > M.MAX_DEPLOYMENTS
	local r = result(if testing > 0 then "warn" else "ok", now)
	r.deployments = list
	r.more = more
	local function n(v: number): string
		return if more and v > 0 then v .. "+" else tostring(v)
	end
	r.value = if #list == 0
		then "all released and deployed"
		else string.format("%s testing · %s not deployed", n(testing), n(undeployed))
	return r
end

local function count(spec: Spec, rows: { any }, now: number): Result
	local row = rows[1]
	local value = 0
	if type(row) == "table" then
		local col, why = pick(row, { "count", "value", "n", "total" })
		if why then
			return failed(now, why)
		end
		local n, ok = num(if col then row[col] else nil)
		if not ok then
			return failed(now, string.format("%q is not a number", tostring(row[col :: string])))
		end
		value = n or 0
	end
	local state: State = if spec.error_at and value >= spec.error_at
		then "error"
		elseif spec.warn_at and value >= spec.warn_at then "warn"
		else "ok"
	local r = result(state, now)
	r.value = fmtNum(value)
	local parts: { string } = {}
	if spec.warn_at then
		table.insert(parts, "warn ≥ " .. fmtNum(spec.warn_at))
	end
	if spec.error_at then
		table.insert(parts, "error ≥ " .. fmtNum(spec.error_at))
	end
	r.threshold = if #parts > 0 then table.concat(parts, " · ") else nil
	return r
end

local function freshness(spec: Spec, rows: { any }, now: number, clock: Clock?): Result
	local maxAge = (spec.max_age_minutes or 0) * 60
	local threshold = string.format("max %s min", fmtNum(spec.max_age_minutes or 0))
	local row = rows[1]
	local raw: any = nil
	if type(row) == "table" then
		local col, why = pick(row, { "at", "last", "timestamp", "value" })
		if why then
			return failed(now, why)
		end
		raw = if col then row[col] else nil
	end
	if raw == nil or raw == "" then
		local r = result("error", now)
		r.value, r.threshold = "never", threshold
		return r
	end
	local stamp = Dates.parse(raw)
	if stamp == nil then
		return failed(
			now,
			string.format("%q is not a date NetSuite returns (M/D/YYYY or YYYY-MM-DD HH24:MI:SS)", tostring(raw))
		)
	end
	if clock == nil then
		local r = result("pending", now)
		r.value, r.threshold = "waiting for the server clock", threshold
		return r
	end
	-- A bare date says "some time that day": measure from its last second.
	local t = stamp.t + (if stamp.dateOnly then 86399 else 0)
	local age = math.max(0, serverNow(clock, now) - t)
	local r = result(if age > maxAge then "error" else "ok", now)
	r.value = if stamp.dateOnly then tostring(raw) .. " (date only)" else M.ageText(age)
	r.threshold = threshold
	return r
end

-- The result of `spec` given its rows or error. `now` is local seconds;
-- `clock` the connection's last server clock reading.
function M.evaluate(spec: Spec, rows: { any }?, err: NsError?, now: number, clock: Clock?): Result
	if err or rows == nil then
		local r = failed(now, if err then err.message else "no answer")
		if err then
			r.code, r.errorKind = err.code, err.kind
		end
		return r
	end
	local list = rows :: { any }
	if spec.kind == "errors" then
		return errors(spec, list, now)
	elseif spec.kind == "clock" then
		local r = result("ok", now)
		r.clock = clockOf(list[1], now)
		if r.clock == nil then
			return failed(now, "NetSuite returned no server time")
		end
		r.value = Dates.format(r.clock.server)
		return r
	elseif spec.kind == "hourly" then
		return hourly(list, now, clock)
	elseif spec.kind == "last_error" then
		return lastError(list, now)
	elseif spec.kind == "deployments" then
		return deployments(list, now)
	elseif spec.kind == "count" then
		return count(spec, list, now)
	end
	return freshness(spec, list, now, clock)
end

return M
