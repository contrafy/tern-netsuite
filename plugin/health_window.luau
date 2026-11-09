--!strict
-- Window half of the account health monitor. Credentials only exist in the
-- window VM, so the poller runs here and queries through NsWindow.query
-- directly. One window per machine polls (a lease in tern.kv); every window
-- reads the summaries the poller writes to `health.summary.<connection>`,
-- which also feed the host `health` block and the status-line badge.
-- Timer callbacks only start queries; results arrive in fetch callbacks.

local lazy = require("./lib/lazy")
local Checks = lazy(function()
	return require("./lib/monitor/health/checks")
end)
local Config = require("./lib/config")
local ConfigHost = require("./config_host")
local Errors = require("./lib/ns/errors")
local Model = lazy(function()
	return require("./lib/monitor/health/model")
end)
local NsWindow = require("./ns_window")
local Refresh = lazy(function()
	return require("./lib/monitor/health/refresh")
end)
local Scheduler = require("./lib/monitor/scheduler")
local StatusWindow = require("./status_window")

-- Types of lazily required modules, read off what their functions return:
-- `typeof` is evaluated by the type checker only, so this loads nothing.
type Spec = typeof(Checks().specs(nil :: any)[1])
type Conn = typeof(Model().conns(nil :: any)[1])
type ConnState = typeof(Model().state(nil :: any, {}))
type Summary = typeof(Model().summary(nil :: any, {}, 0, 0))

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
local specs: { Spec } = {}
local jobs: { Scheduler.Job } = {}
local specByKey: { [string]: Spec } = {}
local conns: { [string]: Conn } = {}
local order: { string } = {}
-- os.time() when a connection was found without usable credentials.
local disconnectedAt: { [string]: number } = {}
local lastState: { [string]: ConnState } = {}
local latest: { [string]: Summary } = {}
local badgeSig = ""
local timer: TimerHandle? = nil
local polling = false
-- os.time() of the last refresh link that polled.
local lastRefresh: number? = nil

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
	local list: { Summary } = {}
	for _, id in order do
		local s = latest[id]
		if s then
			table.insert(list, s)
		end
	end
	local map = Model().badges(list)
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
	specs = Checks().specs(cfg)
	jobs, specByKey = {}, {}
	for _, s in specs do
		table.insert(jobs, { key = s.key, group = s.connection, interval = s.interval })
		specByKey[s.key] = s
	end
	local fresh: { [string]: Conn } = {}
	order = {}
	for _, c in Model().conns(cfg) do
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

-- Query callbacks carry no WindowCx and a stored one is only valid during
-- its call, so a toast gets a fresh cx from a timer.
local function toast(text: string, sub: string)
	tern.timer(0, function(cx: WindowCx?)
		if cx then
			cx:toast("error", text, sub)
		end
	end)
end

local function publish(c: Conn, now: number)
	local s = Model().summary(c, specs, now, (config :: Config.Config).monitor.poll_seconds)
	if not Model().publishable(c, specs, latest[c.id]) then
		-- Right after a takeover: keep what the previous poller published
		-- until every check of this connection has run here.
		return
	end
	pcall(tern.kv.set, M.summaryKey(c.id), s)
	latest[c.id] = s
	if Model().shouldToast(lastState[c.id], s.state) then
		guarded("toast", function()
			toast(
				"NetSuite health: " .. c.label .. " " .. (if s.state == "error" then "has errors" else "check failed"),
				s.badge or "Open Tern NetSuite: Account health for details"
			)
		end)
	end
	lastState[c.id] = s.state
	updateBadges()
end

local function run(job: Scheduler.Job, spec: Spec, now: number)
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
				Model().disconnect(c, qerr.message)
				Scheduler.pause(sched, c.id)
				disconnectedAt[c.id] = at
			else
				Model().record(c, spec, Checks().evaluate(spec, if result then result.rows else nil, qerr, at, c.clock))
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
			Model().reconnect(c)
			Scheduler.resume(sched, id)
			publish(c, now)
		end
	end
end

local function follow()
	for _, id in order do
		local ok, v = pcall(tern.kv.get, M.summaryKey(id))
		local s = if ok then Model().decode(v) else nil
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
	local action, lease = Scheduler.leaseStep(okGet, if okGet then current else nil, me, now, M.LEASE_SECONDS, force)
	if action == "wait" then
		schedule(M.TICK_MS)
		return
	end
	if lease then
		pcall(tern.kv.set, M.LEASE_KEY, lease)
	end
	if action == "claim" then
		-- Another window may have claimed at the same moment: poll only if
		-- our claim is the one stored.
		local okBack, back = pcall(tern.kv.get, M.LEASE_KEY)
		if not (okBack and Scheduler.holds(back, me)) then
			action = "follow"
		end
	end
	if action == "follow" then
		polling = false
		follow()
		schedule(M.TICK_MS)
		return
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
	timer = tern.timer(ms, function()
		timer = nil
		guarded("tick", function()
			tick()
		end)
	end)
end

-- Takes refresh grant `id`; false when it is unknown, used or expired.
local function takeGrant(id: string): boolean
	local ok, granted = pcall(function(): boolean
		local live, rest = Refresh().take(tern.kv.get(Refresh().GRANTS_KEY), id, os.time())
		tern.kv.set(Refresh().GRANTS_KEY, rest)
		return live
	end)
	return ok and granted == true
end

-- Handles `tern-netsuite://health/<action>`; window.luau dispatches area
-- "health" here. `refresh?grant=<id>` (the health block's r) reloads the
-- config and polls everything now, at most every Refresh.MIN_SECONDS.
-- Connections paused after an authentication failure stay paused: only the
-- connect flow (reconnect) or a config change (sync) resumes them.
function M.route(link: LinkRequest, cx: WindowCx): RouteDecision?
	local action, id = Refresh().parse(link.url)
	if action == nil then
		cx:toast("error", "Tern NetSuite: unknown health link", link.url)
		return { handled = true }
	end
	if id == nil or not takeGrant(id) then
		-- Printed by something other than the health block: ignore quietly.
		log.debug("tern-netsuite health: ignored a refresh link without a valid grant")
		return { handled = true }
	end
	local now = os.time()
	if not Refresh().allowed(lastRefresh, now) then
		cx:toast(
			"info",
			"Tern NetSuite: health was refreshed moments ago",
			string.format("Refreshes are at least %d s apart; polling continues on schedule.", Refresh().MIN_SECONDS)
		)
		return { handled = true }
	end
	lastRefresh = now
	ConfigHost.load()
	sync()
	Scheduler.runNow(sched, now)
	tick(true)
	return { handled = true }
end

function M.register()
	-- After `tern plugin reload` window_start does not fire again and a
	-- timer armed during load never fired (Tern 0.6.3), so the first focus
	-- event also starts the chain.
	tern.on("focus", function(_ev: FocusEvent, _cx: WindowCx)
		if timer == nil then
			schedule(0)
		end
	end)
	tern.on("window_start", function(_cx: WindowCx)
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
