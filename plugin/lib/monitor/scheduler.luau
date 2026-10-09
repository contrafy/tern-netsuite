--!strict
-- One schedule for every NetSuite poll. Jobs are grouped by connection; a
-- group runs at most one query at a time (NetSuite counts concurrent
-- requests per integration), backs off as a whole after a rate limit or
-- network failure, and can be paused (no credentials). Times are seconds on
-- one clock chosen by the caller; randomness is injected as a draw in [0, 1).

local M = {}

-- Intervals vary by ±10% so windows and connections drift apart.
M.JITTER = 0.1
M.MAX_BACKOFF_SECONDS = 1800
-- A query without an answer after this long is given up on.
M.STALE_SECONDS = 600

export type Job = { key: string, group: string, interval: number }
export type Outcome = "ok" | "retry" | "fail"

type JobState = { nextAt: number }
type GroupState = {
	running: string?,
	token: number,
	startedAt: number,
	failures: number,
	holdUntil: number,
	paused: boolean,
}

export type State = {
	jobs: { [string]: JobState },
	groups: { [string]: GroupState },
	tokens: number,
}

export type Lease = { owner: string, expires: number, ttl: number }

function M.new(): State
	return { jobs = {}, groups = {}, tokens = 0 }
end

local function group(s: State, id: string): GroupState
	local g = s.groups[id]
	if g == nil then
		g = { running = nil, token = 0, startedAt = 0, failures = 0, holdUntil = 0, paused = false }
		s.groups[id] = g
	end
	return g
end

local function busy(g: GroupState, now: number): boolean
	return g.running ~= nil and now - g.startedAt < M.STALE_SECONDS
end

local function nextAt(s: State, j: Job): number
	local js = s.jobs[j.key]
	return if js then js.nextAt else 0
end

-- The jobs to start now: per idle, unpaused, unheld group the most overdue
-- one (the first listed on ties), in the order their groups first appear.
function M.due(s: State, jobs: { Job }, now: number): { Job }
	local best: { [string]: Job } = {}
	local order: { string } = {}
	for _, j in jobs do
		local g = group(s, j.group)
		if not g.paused and not busy(g, now) and now >= g.holdUntil and nextAt(s, j) <= now then
			local cur = best[j.group]
			if cur == nil then
				table.insert(order, j.group)
				best[j.group] = j
			elseif nextAt(s, j) < nextAt(s, cur) then
				best[j.group] = j
			end
		end
	end
	local out: { Job } = table.create(#order)
	for i, id in order do
		out[i] = best[id]
	end
	return out
end

-- Marks `j` in flight; the token identifies this run to `finish`.
function M.start(s: State, j: Job, now: number): number
	s.tokens += 1
	local g = group(s, j.group)
	g.running = j.key
	g.token = s.tokens
	g.startedAt = now
	return s.tokens
end

local function jittered(seconds: number, draw: number): number
	return seconds * (1 + M.JITTER * (2 * draw - 1))
end

-- Records the outcome of a run. False (and no change) when `token` names a
-- run that was already given up on.
function M.finish(s: State, j: Job, now: number, outcome: Outcome, draw: number, token: number?): boolean
	local g = group(s, j.group)
	if token ~= nil and token ~= g.token then
		return false
	end
	if g.running == j.key then
		g.running = nil
	end
	local delay: number
	if outcome == "retry" then
		g.failures += 1
		delay = jittered(math.min(M.MAX_BACKOFF_SECONDS, j.interval * 2 ^ g.failures), draw)
		g.holdUntil = now + delay
	else
		g.failures = 0
		g.holdUntil = 0
		delay = jittered(j.interval, draw)
	end
	s.jobs[j.key] = { nextAt = now + delay }
	return true
end

function M.running(s: State, groupId: string): boolean
	local g = s.groups[groupId]
	return g ~= nil and g.running ~= nil
end

function M.pause(s: State, groupId: string)
	group(s, groupId).paused = true
end

function M.resume(s: State, groupId: string)
	group(s, groupId).paused = false
end

function M.paused(s: State, groupId: string): boolean
	local g = s.groups[groupId]
	return g ~= nil and g.paused
end

-- Makes every known job due at `now` and lifts backoffs (manual refresh).
function M.runNow(s: State, now: number)
	for _, js in s.jobs do
		js.nextAt = math.min(js.nextAt, now)
	end
	for _, g in s.groups do
		g.holdUntil = 0
	end
end

-- When something may next become due (never before `now`), or nil when no
-- job can run without a resume.
function M.nextWake(s: State, jobs: { Job }, now: number): number?
	local wake: number? = nil
	for _, j in jobs do
		local g = group(s, j.group)
		if not g.paused then
			local at = if busy(g, now) then g.startedAt + M.STALE_SECONDS else math.max(nextAt(s, j), g.holdUntil)
			at = math.max(at, now)
			if wake == nil or at < wake then
				wake = at
			end
		end
	end
	return wake
end

-- The lease `me` should hold after this check, or nil when another live
-- holder keeps it. `force` takes it regardless (manual refresh).
function M.lease(current: Lease?, me: string, now: number, ttl: number, force: boolean?): Lease?
	local c: any = current
	local valid = type(c) == "table" and type(c.owner) == "string" and type(c.expires) == "number"
	if force or not valid or c.owner == me or c.expires <= now then
		return { owner = me, expires = now + ttl, ttl = ttl }
	end
	return nil
end

-- Whether a held lease is past half its life and should be written again.
function M.needsRenewal(l: Lease, now: number): boolean
	return l.expires - now < l.ttl / 2
end

return M
