--!strict
-- Host half of the NetSuite connection layer. The SuiteQL client and the
-- credentials live in the window half (`tern.secrets` is nil here, verified
-- on Tern 0.6.3), so host blocks and lenses query through it: a request
-- file in the 0700 spool directory plus a `tern-netsuite://ns/...` link
-- opened with the caller's cx; the window writes `<id>.resp.json`, which a
-- timer here notices and reads. Also defines the `connect` block.

local Config = require("./lib/config")
local ConfigHost = require("./config_host")
local Connect = require("./lib/ns/connect")
local Errors = require("./lib/ns/errors")
local Query = require("./lib/ns/query")
local Spool = require("./lib/ns/spool")
local Sql = require("./lib/ns/sql")

type NsError = Errors.NsError

export type Result = Query.Result & { ms: number? }
export type Callback = (result: Result?, err: NsError?) -> ()

export type QueryOptions = {
	-- The cx of the block or lens asking; its window answers. Required:
	-- host timers have no cx of their own.
	cx: EffectCx,
	max_rows: number?,
	-- Whole-query deadline (default: the connection's timeout per 1000 rows
	-- plus 15 s for the window round trip).
	timeout_ms: number?,
}

export type Status = {
	state: "ok" | "error",
	at: number,
	ms: number,
	kind: Errors.Kind?,
	message: string?,
	code: string?,
}

local M = {}

local log = tern.log

local POLL_MS = 200
local ROUND_TRIP_MS = 15000

local seed = string.format("host:%d:%.6f:%.17g:%s", os.time(), os.clock(), math.random(), tostring({}))
local counter = 0

local function newId(): string
	counter += 1
	return Spool.newId(seed, counter)
end

local function spoolDir(): string
	return Spool.dir(tern.plugin.data)
end

type Pending = {
	deadline: number,
	-- The request file, removed on timeout so a late window never runs it.
	request: string,
	reading: boolean,
	cb: (Spool.Response) -> (),
}

local pending: { [string]: Pending } = {}
local polling = false

-- pcall that keeps the error message for calls returning nothing.
local function try(f: () -> ()): (boolean, string?)
	local ok, err = pcall(function()
		f()
		return nil
	end)
	return ok, if ok then nil else tostring(err)
end

local function deliver(p: Pending, resp: Spool.Response)
	local ok, err = try(function()
		p.cb(resp)
	end)
	if not ok then
		log.warn("tern-netsuite ns callback failed", err)
	end
end

local poll: () -> ()

local function arm()
	if not polling and next(pending) ~= nil then
		polling = true
		tern.timer(POLL_MS, poll)
	end
end

-- Timer callbacks must stay cheap (a slow one disables timers for the VM):
-- this only checks for answers; reading and decoding run in a process
-- callback.
function poll()
	polling = false
	local dir = spoolDir()
	local now = tern.now()
	for id, p in pending do
		if p.reading then
			continue
		end
		local path = Spool.path(dir, "resp", id)
		local okExists, present = pcall(tern.fs.exists, path)
		if okExists and present then
			p.reading = true
			local ok = pcall(
				tern.process.run,
				{ "/bin/sh", "-c", 'cat "$1" && rm -f "$1"', "sh", path },
				{ timeout_ms = 10000 },
				function(r: ProcessResult)
					pending[id] = nil
					local text = if r.status == 0 and #r.stdout <= Spool.MAX_RESPONSE_BYTES then r.stdout else ""
					deliver(p, Spool.decodeResponse(text, id, tern.json.decode))
				end
			)
			if not ok then
				pending[id] = nil
				deliver(p, {
					v = Spool.VERSION,
					id = id,
					ok = false,
					error = Errors.new("server", "could not read the window's answer", Errors.BAD_RESPONSE),
				})
			end
		elseif now > p.deadline then
			pending[id] = nil
			pcall(tern.fs.remove, p.request)
			deliver(p, {
				v = Spool.VERSION,
				id = id,
				ok = false,
				error = Errors.new(
					"network",
					"no Tern window answered in time; NetSuite queries run in the window half, so a window must be open",
					Errors.NO_WINDOW
				),
			})
		end
	end
	arm()
end

-- Writes `payload` (a JSON value) as request `kind`, opens the link, and
-- calls `cb` with the window's response.
local function exchange(
	cx: EffectCx,
	action: Spool.Action,
	kind: Spool.Kind,
	payload: { [string]: any },
	timeoutMs: number,
	cb: (Spool.Response) -> ()
)
	local id = newId()
	payload.id = id
	payload.v = Spool.VERSION
	payload.at = os.time()
	local dir = spoolDir()
	local path = Spool.path(dir, kind, id)
	local text = tern.json.encode(payload)
	local function fail(message: string)
		deliver({ deadline = 0, request = path, reading = false, cb = cb }, {
			v = Spool.VERSION,
			id = id,
			ok = false,
			error = Errors.new("server", message, Errors.NO_WINDOW),
		})
	end
	local ok, err = try(function()
		tern.process.run(Spool.writeArgv(dir, path), { stdin = text, timeout_ms = 10000 }, function(r: ProcessResult)
			if r.status ~= 0 then
				fail("could not write the request file: " .. r.stderr)
				return
			end
			pending[id] = { deadline = tern.now() + timeoutMs, request = path, reading = false, cb = cb }
			local opened, oerr = try(function()
				cx:open(Spool.link(action, id))
			end)
			if not opened then
				pending[id] = nil
				pcall(tern.fs.remove, path)
				fail("could not reach the window: " .. tostring(oerr))
				return
			end
			arm()
		end)
	end)
	if not ok then
		fail("could not write the request file: " .. tostring(err))
	end
end

local function findConnection(connectionId: string): Config.Connection?
	for _, c in ConfigHost.current().connections do
		if c.id == connectionId then
			return c
		end
	end
	return nil
end

-- Runs `sql` on connection `connectionId` through the window half and calls
-- `cb` once with the rows or a normalized error. Read-only connections
-- refuse anything but a single SELECT / WITH here and again in the window.
function M.query(connectionId: string, sql: string, params: { any }?, opts: QueryOptions, cb: Callback)
	local function finish(result: Result?, err: NsError?)
		local ok, e = try(function()
			cb(result, err)
		end)
		if not ok then
			log.warn("tern-netsuite ns query callback failed", e)
		end
	end
	local conn = findConnection(connectionId)
	if conn == nil then
		finish(
			nil,
			Errors.new(
				"query",
				string.format("no connection %q in the config (connections[])", connectionId),
				Errors.NO_CONNECTION
			)
		)
		return
	end
	if conn.read_only then
		local ok, why = Sql.readOnly(sql)
		if not ok then
			finish(
				nil,
				Errors.new(
					"query",
					string.format("refused by the read-only guard of connection %q: %s", conn.id, why or "not a query"),
					Errors.READ_ONLY
				)
			)
			return
		end
	end
	local maxRows = math.clamp(math.floor(opts.max_rows or Query.DEFAULT_MAX_ROWS), 1, Query.MAX_ROWS)
	local timeout = opts.timeout_ms or (conn.timeout_ms * math.ceil(maxRows / 1000) + ROUND_TRIP_MS)
	exchange(
		opts.cx,
		"query",
		"query",
		{
			connection = connectionId,
			sql = sql,
			params = tern.json.array(table.clone(params or {})),
			max_rows = maxRows,
		},
		timeout,
		function(resp: Spool.Response)
			if resp.ok then
				finish({
					rows = resp.rows or {},
					truncated = resp.truncated == true,
					pages = resp.pages or 0,
					ms = resp.ms,
				}, nil)
			else
				finish(nil, resp.error)
			end
		end
	)
end

-- The outcome of `connectionId`'s last query (written by the window half
-- after every query, also those started there), or nil.
function M.status(connectionId: string): Status?
	local ok, v = pcall(tern.kv.get, "ns.status." .. connectionId)
	return if ok and type(v) == "table" then v else nil
end

-- Hands credential values to the window half, which validates them and
-- stores them in the keychain. `values` never appear in a URL or a log.
function M.storeCredentials(cx: EffectCx, connectionId: string, values: { [string]: string }, cb: (err: NsError?) -> ())
	exchange(cx, "store", "cred", { connection = connectionId, values = values }, ROUND_TRIP_MS, function(resp)
		cb(if resp.ok then nil else resp.error)
	end)
end

-- Deletes the connection's stored credentials.
function M.forgetCredentials(cx: EffectCx, connectionId: string, cb: (err: NsError?) -> ())
	exchange(cx, "forget", "cred", { connection = connectionId, values = {} }, ROUND_TRIP_MS, function(resp)
		cb(if resp.ok then nil else resp.error)
	end)
end

-- Connect block ------------------------------------------------------------------

type BlockState = { ui: Connect.State, cx: BlockCx }

local function rerender(st: BlockState)
	pcall(function()
		st.cx:render()
	end)
end

local function test(st: BlockState, prefix: string?)
	local tg = Connect.target(st.ui)
	if tg == nil then
		return
	end
	st.ui = Connect.busy(st.ui, "testing", (prefix or "") .. "Testing: " .. Connect.TEST_SQL)
	rerender(st)
	M.query(tg.id, Connect.TEST_SQL, {}, { cx = st.cx, max_rows = 1 }, function(result: Result?, err: NsError?)
		if result then
			local ms = if result.ms then string.format(" in %d ms", result.ms) else ""
			st.ui = Connect.settle(
				st.ui,
				{ tone = "success", text = (prefix or "") .. string.format("Connected to %s%s.", tg.account_id, ms) }
			)
		else
			st.ui = Connect.settle(
				st.ui,
				{ tone = "error", text = (prefix or "") .. "The test query failed.", error = err }
			)
		end
		rerender(st)
	end)
end

local function run(st: BlockState, effect: Connect.Effect, cx: BlockCx)
	local tg = Connect.target(st.ui)
	if effect == "close" then
		cx:exit(0)
		return
	elseif tg == nil then
		return
	elseif effect == "test" then
		test(st)
	elseif effect == "save" then
		local values, why = Connect.collect(st.ui)
		if values == nil then
			st.ui = Connect.settle(st.ui, { tone = "error", text = why or "The credentials are incomplete." })
			return
		end
		st.ui = Connect.busy(st.ui, "saving", "Saving to the keychain...")
		M.storeCredentials(cx, tg.id, values, function(err: NsError?)
			if err then
				st.ui = Connect.settle(st.ui, { tone = "error", text = "The credentials were not saved.", error = err })
				rerender(st)
				return
			end
			st.ui = Connect.settle(st.ui, { tone = "info", text = "Saved." }, true)
			test(st, "Saved. ")
		end)
	elseif effect == "forget" then
		st.ui = Connect.busy(st.ui, "saving", "Removing the stored credentials...")
		M.forgetCredentials(cx, tg.id, function(err: NsError?)
			st.ui = if err
				then Connect.settle(st.ui, { tone = "error", text = "The credentials were not removed.", error = err })
				else Connect.settle(st.ui, { tone = "success", text = "Stored credentials removed." }, true)
			rerender(st)
		end)
	end
end

function M.register()
	tern.block.define(
		"connect",
		{
			init = function(cx: BlockCx, args: { string }, saved: any): BlockState
				local snap = ConfigHost.load()
				local pre = args[1] or (if type(saved) == "table" then saved.connection else nil)
				return { ui = Connect.new(Connect.targets(snap.config), pre), cx = cx }
			end,
			view = function(st: BlockState): BlockView
				return Connect.view(st.ui) :: any
			end,
			title = function(st: BlockState): string?
				return Connect.title(st.ui)
			end,
			key = function(st: BlockState, key: Key, cx: BlockCx): boolean?
				local s, effect, changed = Connect.key(st.ui, key :: any)
				st.ui = s
				if effect then
					run(st, effect :: Connect.Effect, cx)
					return true
				end
				return changed
			end,
			event = function(st: BlockState, ev: UiEvent, cx: BlockCx)
				if ev.ev ~= "action" then
					return
				end
				local s, effect = Connect.event(st.ui, ev.act, ev.value)
				st.ui = s
				if effect then
					run(st, effect :: Connect.Effect, cx)
				end
			end,
			save = function(st: BlockState): any
				return Connect.saved(st.ui)
			end,
		} :: BlockDef<BlockState>
	)
end

return M
