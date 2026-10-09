--!strict
-- Window half of the account health monitor. Credentials only exist in the
-- window VM, so the poller runs here and queries through NsWindow.query
-- directly. One window per machine polls (a lease in tern.kv); every window
-- reads the summaries the poller writes to `health.summary.<connection>`,
-- which also feed the host `health` block and the status-line badge.
-- Timer callbacks only start queries; results arrive in fetch callbacks.

local Checks = require("./lib/monitor/health/checks")
local Config = require("./lib/config")
local ConfigHost = require("./config_host")
local Errors = require("./lib/ns/errors")
local Model = require("./lib/monitor/health/model")
local NsWindow = require("./ns_window")
local Scheduler = require("./lib/monitor/scheduler")
local StatusWindow = require("./status_window")

local log = tern.log

local M = {}

M.BLOCK = "tern-netsuite.health"
M.TICK_MS = 5000
-- Without connections the tick only watches for a config change.
M.IDLE_TICK_MS = 30000
M.LEASE_KEY = "health.lease"
M.LEASE_SECONDS = 60

function M.summaryKey(connectionId: string): string
	return "health.summary." .. connectionId
end

local me = string.format("w%d-%d", os.time(), math.random(1, 2 ^ 30))

local sched = Scheduler.new()
local config: Config.Config? = nil
local generation = 0
local specs: { Checks.Spec } = {}
local jobs: { Scheduler.Job } = {}
local specByKey: { [string]: Checks.Spec } = {}
local conns: { [string]: Model.Conn } = {}
local order: { string } = {}
-- os.time() when a connection was found without usable credentials.
local disconnectedAt: { [string]: number } = {}
local lastState: { [string]: Model.ConnState } = {}
local latest: { [string]: Model.Summary } = {}
local badgeSig = ""
local lastCx: WindowCx? = nil
local timer: TimerHandle? = nil
local polling = false

local function guarded(what: string, fn: () -> ())
	local ok, err = pcall(function()
		fn()
		return nil
	end)
	if not ok then
		log.warn("tern-netsuite health " .. what .. " failed", tostring(err))
	end
end

local function updateBadges()
	local list: { Model.Summary } = {}
	for _, id in order do
		local s = latest[id]
		if s then
			table.insert(list, s)
		end
	end
	local map = Model.badges(list)
	local keys: { string } = {}
	for k, v in map do
		table.insert(keys, k .. "=" .. v)
	end
	table.sort(keys)
	local sig = table.concat(keys, "\n")
	if sig ~= badgeSig then
		badgeSig = sig
		StatusWindow.setHealthBadges(map)
		pcall(tern.chrome.refresh)
	end
end

-- Config loads happen often (every host query reloads it); only a change to
-- what is monitored rebuilds the checks and retries paused connections.
local configSig: string? = nil

local function sync()
	local cfg = ConfigHost.current()
	if cfg == config then
		return
	end
	config = cfg
	local watched: any = { accounts = cfg.accounts, connections = cfg.connections, monitor = cfg.monitor }
	local ok, sig = pcall(tern.json.encode, watched)
	local signature = if ok then sig else tostring(cfg)
	if signature == configSig then
		return
	end
	configSig = signature
	generation += 1
	specs = Checks.specs(cfg)
	jobs, specByKey = {}, {}
	for _, s in specs do
		table.insert(jobs, { key = s.key, group = s.connection, interval = s.interval })
		specByKey[s.key] = s
	end
	local fresh: { [string]: Model.Conn } = {}
	order = {}
	for _, c in Model.conns(cfg) do
		local old = conns[c.id]
		if old then
			c.results, c.clock = old.results, old.clock
		end
		fresh[c.id] = c
		table.insert(order, c.id)
		-- A config load is a chance to retry missing credentials.
		Scheduler.resume(sched, c.id)
	end
	conns = fresh
	disconnectedAt = {}
	for id in latest do
		if fresh[id] == nil then
			latest[id] = nil
		end
	end
	updateBadges()
end

local function publish(c: Model.Conn, now: number)
	local s = Model.summary(c, specs, now, (config :: Config.Config).monitor.poll_seconds)
	pcall(tern.kv.set, M.summaryKey(c.id), s)
	latest[c.id] = s
	if Model.shouldToast(lastState[c.id], s.state) and lastCx then
		local cx = lastCx :: WindowCx
		pcall(function()
			cx:toast(
				"error",
				"NetSuite health: " .. c.label .. " " .. (if s.state == "error" then "has errors" else "check failed"),
				s.badge or "Open Tern NetSuite: Account health for details"
			)
		end)
	end
	lastState[c.id] = s.state
	updateBadges()
end

local function run(job: Scheduler.Job, spec: Checks.Spec, now: number)
	local token = Scheduler.start(sched, job, now)
	local gen = generation
	local function onResult(result: NsWindow.Result?, qerr: Errors.NsError?)
		guarded("result", function()
			local at = os.time()
			local outcome: Scheduler.Outcome = if qerr == nil
				then "ok"
				elseif Errors.retryable(qerr) then "retry"
				else "fail"
			if not Scheduler.finish(sched, job, at, outcome, math.random(), token) or gen ~= generation then
				return
			end
			local c = conns[spec.connection]
			if c == nil then
				return
			end
			if qerr and qerr.kind == "auth" then
				-- Missing or rejected credentials: stop until a config load
				-- or a successful query (the connect flow) says otherwise.
				Model.disconnect(c, qerr.message)
				Scheduler.pause(sched, c.id)
				disconnectedAt[c.id] = at
			else
				Model.record(c, spec, Checks.evaluate(spec, if result then result.rows else nil, qerr, at, c.clock))
			end
			publish(c, at)
		end)
	end
	local ok, err = pcall(function()
		NsWindow.query(spec.connection, spec.sql, nil, { max_rows = spec.max_rows }, onResult)
		return nil
	end)
	if not ok then
		Scheduler.finish(sched, job, now, "retry", math.random(), token)
		log.warn("tern-netsuite health: could not start a query", tostring(err))
	end
end

-- Resumes connections whose credentials work again: any query on them
-- (the connect flow runs one) succeeded after they were paused.
local function reconnect(now: number)
	for id, since in disconnectedAt do
		local st = NsWindow.status(id)
		local c = conns[id]
		if c and st and st.state == "ok" and st.at >= since then
			disconnectedAt[id] = nil
			Model.reconnect(c)
			Scheduler.resume(sched, id)
			publish(c, now)
		end
	end
end

local function follow()
	for _, id in order do
		local ok, v = pcall(tern.kv.get, M.summaryKey(id))
		local s = if ok then Model.decode(v) else nil
		if s then
			latest[id] = s
		else
			latest[id] = nil
		end
	end
	updateBadges()
end

local schedule: (ms: number) -> ()

local function tick(force: boolean?)
	sync()
	if #jobs == 0 then
		schedule(M.IDLE_TICK_MS)
		return
	end
	local now = os.time()
	local okGet, current = pcall(tern.kv.get, M.LEASE_KEY)
	local held: Scheduler.Lease? = if okGet then current else nil
	local lease = Scheduler.lease(held, me, now, M.LEASE_SECONDS, force)
	if lease == nil then
		polling = false
		follow()
		schedule(M.TICK_MS)
		return
	end
	if held == nil or (held :: any).owner ~= me or Scheduler.needsRenewal(held :: Scheduler.Lease, now) then
		pcall(tern.kv.set, M.LEASE_KEY, lease)
	end
	if not polling then
		-- Taking over: adopt what the previous poller published.
		polling = true
		follow()
	end
	reconnect(now)
	for _, job in Scheduler.due(sched, jobs, now) do
		run(job, specByKey[job.key], now)
	end
	schedule(M.TICK_MS)
end

function schedule(ms: number)
	if timer then
		pcall(function()
			(timer :: TimerHandle):cancel()
		end)
	end
	timer = tern.timer(ms, function(cx: WindowCx?)
		timer = nil
		if cx then
			lastCx = cx
		end
		guarded("tick", function()
			tick()
		end)
	end)
end

-- Handles `tern-netsuite://health/<action>`; window.luau dispatches area
-- "health" here. `refresh` reloads the config and polls everything now.
function M.route(link: LinkRequest, cx: WindowCx): RouteDecision?
	local action = string.match(link.url, "^tern%-netsuite://health/([%w_%-]+)")
	if action ~= "refresh" then
		cx:toast("error", "Tern NetSuite: unknown health link", link.url)
		return { handled = true }
	end
	lastCx = cx
	ConfigHost.load()
	sync()
	for id in disconnectedAt do
		local c = conns[id]
		if c then
			Model.reconnect(c)
		end
		Scheduler.resume(sched, id)
	end
	disconnectedAt = {}
	Scheduler.runNow(sched, os.time())
	tick(true)
	return { handled = true }
end

function M.register()
	-- After `tern plugin reload` window_start does not fire again and a
	-- timer armed during load never fired (Tern 0.6.3), so the first focus
	-- event also starts the chain.
	tern.on("focus", function(_ev: FocusEvent, cx: WindowCx)
		lastCx = cx
		if timer == nil then
			schedule(0)
		end
	end)
	tern.on("window_start", function(cx: WindowCx)
		lastCx = cx
		if timer == nil then
			schedule(0)
		end
	end)

	tern.command({
		id = "health",
		title = "Tern NetSuite: Account health",
		icon = "activity",
		run = function(cx: WindowCx)
			if cx:new_block(M.BLOCK, {}, "beside") == nil then
				cx:toast("error", "Tern NetSuite: the health block is not available on this host")
			end
		end,
	})
end

return M
