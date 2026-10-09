--!strict
-- Per-connection health: the latest result of each check, the overall
-- state, the compact summary the window stores in tern.kv for the host block
-- and the status line, and when a change deserves a toast.

local Checks = require("./checks")
local Config = require("../../config")

local M = {}

M.VERSION = 1
-- Status-line badge parts before "+n".
M.MAX_BADGE_PARTS = 2

export type ConnState = "ok" | "warn" | "error" | "failed" | "pending" | "not_connected"

export type Conn = {
	id: string,
	label: string,
	accountId: string,
	results: { [string]: Checks.Result },
	clock: Checks.Clock?,
	-- Why the connection has no usable credentials; nil when it has.
	notConnected: string?,
}

export type CheckRow = {
	id: string,
	label: string,
	kind: string,
	state: string,
	value: string?,
	threshold: string?,
	at: number?,
	error: string?,
}

export type Summary = {
	v: number,
	connection: string,
	label: string,
	account: string,
	state: ConnState,
	badge: string?,
	-- Local seconds when written.
	at: number,
	poll: number,
	message: string?,
	checks: { CheckRow },
	spark: { number }?,
	sparkEnd: string?,
	deployments: { Checks.Deployment }?,
	deploymentsMore: boolean?,
	lastError: Checks.LastError?,
}

-- One Conn per configured connection, in config order.
function M.conns(cfg: Config.Config): { Conn }
	local out: { Conn } = {}
	for _, c in cfg.connections do
		local label, accountId = c.account, ""
		for _, a in cfg.accounts do
			if a.id == c.account then
				label = a.label or a.id
				accountId = string.upper(a.account_id)
			end
		end
		table.insert(out, { id = c.id, label = label, accountId = accountId, results = {}, notConnected = nil })
	end
	return out
end

function M.record(c: Conn, spec: Checks.Spec, r: Checks.Result)
	c.results[spec.key] = r
	if r.clock then
		c.clock = r.clock
	end
end

function M.disconnect(c: Conn, message: string)
	c.notConnected = message
end

function M.reconnect(c: Conn)
	c.notConnected = nil
end

local RANK: { [string]: number } = { ok = 0, pending = 1, warn = 2, failed = 3, error = 4 }

function M.state(c: Conn, specs: { Checks.Spec }): ConnState
	if c.notConnected then
		return "not_connected"
	end
	local worst = "ok"
	for _, s in specs do
		if s.connection == c.id then
			local r = c.results[s.key]
			local st = if r then r.state else "pending"
			if RANK[st] > RANK[worst] then
				worst = st
			end
		end
	end
	return worst :: ConnState
end

local function badge(c: Conn, specs: { Checks.Spec }): string?
	local parts: { string } = {}
	for _, s in specs do
		local r = if s.connection == c.id then c.results[s.key] else nil
		if r and r.state == "error" then
			if s.kind == "errors" then
				table.insert(parts, string.format("%d err/1h", r.h1 or 0))
			else
				table.insert(parts, s.label)
			end
		end
	end
	if #parts == 0 then
		return nil
	end
	local shown = table.concat(parts, " · ", 1, math.min(#parts, M.MAX_BADGE_PARTS))
	return if #parts > M.MAX_BADGE_PARTS then shown .. " +" .. (#parts - M.MAX_BADGE_PARTS) else shown
end

function M.summary(c: Conn, specs: { Checks.Spec }, now: number, poll: number): Summary
	local state: ConnState = M.state(c, specs)
	local s: Summary = {
		v = M.VERSION,
		connection = c.id,
		label = c.label,
		account = c.accountId,
		state = state,
		badge = if state == "error" then badge(c, specs) else nil,
		at = now,
		poll = poll,
		message = c.notConnected,
		checks = {},
	}
	for _, spec in specs do
		local r = if spec.connection == c.id then c.results[spec.key] else nil
		if spec.connection == c.id and (not spec.detail or (r and r.state == "failed")) then
			local row: CheckRow = {
				id = spec.id,
				label = spec.label,
				kind = spec.kind,
				state = if r then r.state else "pending",
				value = if r then r.value else nil,
				threshold = if r then r.threshold else nil,
				at = if r then r.at else nil,
				error = if r then r.error else nil,
			}
			table.insert(s.checks, row)
		end
		if r and spec.kind == "hourly" and r.series then
			s.spark, s.sparkEnd = r.series, r.seriesEnd
		elseif r and spec.kind == "deployments" and r.deployments then
			s.deployments, s.deploymentsMore = r.deployments, r.more
		elseif r and spec.kind == "last_error" then
			s.lastError = r.lastError
		end
	end
	return s
end

-- A summary read back from tern.kv, or nil for anything else.
function M.decode(v: any): Summary?
	if
		type(v) ~= "table"
		or v.v ~= M.VERSION
		or type(v.connection) ~= "string"
		or type(v.state) ~= "string"
		or type(v.checks) ~= "table"
	then
		return nil
	end
	return v
end

-- Account id (upper case) -> status-line badge, from every summary in error.
function M.badges(summaries: { Summary }): { [string]: string }
	local out: { [string]: string } = {}
	for _, s in summaries do
		if s.badge and s.account ~= "" then
			local cur = out[s.account]
			out[s.account] = if cur then cur .. " · " .. s.badge else s.badge
		end
	end
	return out
end

local HEALTHY: { [string]: boolean } = { ok = true, warn = true }
local BAD: { [string]: boolean } = { error = true, failed = true }

-- Whether going from `prev` to `next` is news: a healthy connection turning
-- bad. Startup (nil/pending) and missing credentials never toast.
function M.shouldToast(prev: ConnState?, next: ConnState): boolean
	return prev ~= nil and HEALTHY[prev] == true and BAD[next] == true
end

return M
