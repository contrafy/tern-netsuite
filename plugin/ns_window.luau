--!strict
-- Window half of the NetSuite connection layer. Credentials can only live
-- here: `tern.secrets` exists in the window VM and is nil in the host VM
-- (verified on Tern 0.6.3). This half therefore owns the SuiteQL client
-- (signing, token cache, fetch, paging) and serves the host half through
-- `tern-netsuite://ns/<action>?id=<id>` links whose payloads travel in
-- 0600 spool files (lib/ns/spool.luau). Window-side features (status line,
-- timers) call `query` directly.

local Config = require("./lib/config")
local ConfigHost = require("./config_host")
local Credentials = require("./lib/ns/credentials")
local Endpoints = require("./lib/ns/endpoints")
local Errors = require("./lib/ns/errors")
local Oauth1 = require("./lib/ns/oauth1")
local Oauth2 = require("./lib/ns/oauth2")
local Query = require("./lib/ns/query")
local Spool = require("./lib/ns/spool")
local Transport = require("./lib/ns/transport")

type NsError = Errors.NsError
type Connection = Config.Connection

export type QueryOptions = { max_rows: number? }
export type Result = Query.Result
export type Callback = (result: Result?, err: NsError?) -> ()

export type Status = {
	state: "ok" | "error",
	-- os.time() of the last query.
	at: number,
	ms: number,
	kind: Errors.Kind?,
	message: string?,
	code: string?,
}

local M = {}

local log = tern.log
-- pcall that keeps the error message for calls returning nothing.
local function try(f: () -> ()): (boolean, string?)
	local ok, err = pcall(function()
		f()
		return nil
	end)
	return ok, if ok then nil else tostring(err)
end

local seed = string.format("%d:%.6f:%.17g:%s", os.time(), os.clock(), math.random(), tostring({}))
local counter = 0

local function nextNonce(): string
	counter += 1
	return Oauth1.nonce(seed, counter)
end

local function spoolDir(): string
	return Spool.dir(tern.plugin.data)
end

-- Connection id -> stored values. Dropped when credentials change or a
-- query fails authentication (they may have been replaced in the keychain).
local secretsCache: { [string]: { [string]: string } } = {}
local tokens: { [string]: Oauth2.Token } = {}
local tokenWaiters: { [string]: { (string?, NsError?) -> () } } = {}

local function forgetCaches(connectionId: string)
	secretsCache[connectionId] = nil
	tokens[connectionId] = nil
end

local function statusKey(connectionId: string): string
	return "ns.status." .. connectionId
end

local function record(connectionId: string, started: number, err: NsError?)
	local status: Status = {
		state = if err then "error" else "ok",
		at = os.time(),
		ms = math.floor(tern.now() - started),
		kind = if err then err.kind else nil,
		message = if err then err.message else nil,
		code = if err then err.code else nil,
	}
	pcall(tern.kv.set, statusKey(connectionId), status)
end

-- The status of `connectionId`'s last query from any half, or nil.
function M.status(connectionId: string): Status?
	local ok, v = pcall(tern.kv.get, statusKey(connectionId))
	return if ok and type(v) == "table" then v else nil
end

type Resolved = { connection: Connection, account_id: string }

local function resolve(connectionId: string): (Resolved?, NsError?)
	local cfg = ConfigHost.current()
	for _, c in cfg.connections do
		if c.id == connectionId then
			for _, a in cfg.accounts do
				if a.id == c.account then
					return { connection = c, account_id = a.account_id }, nil
				end
			end
		end
	end
	return nil,
		Errors.new(
			"query",
			string.format("no connection %q in the config (connections[])", connectionId),
			Errors.NO_CONNECTION
		)
end

local function loadSecrets(conn: Connection, cb: ({ [string]: string }?, NsError?) -> ())
	local cached = secretsCache[conn.id]
	if cached then
		cb(cached, nil)
		return
	end
	local fields = Credentials.FIELDS[conn.auth]
	local why = Credentials.unstorable(conn.id, conn.auth)
	if why then
		cb(nil, Errors.new("auth", why, Errors.NO_CREDENTIALS))
		return
	end
	local values: { [string]: string } = {}
	local remaining = #fields
	local done = false
	local function fail(message: string)
		if not done then
			done = true
			cb(nil, Errors.new("auth", message, Errors.NO_CREDENTIALS))
		end
	end
	for _, f in fields do
		local name = Credentials.secretName(conn.id, f.id) :: string
		local ok, err = try(function()
			tern.secrets.get(name):next(function(v: string?, e: string?)
				if done then
					return
				end
				if e then
					fail(string.format("the keychain could not be read (%s)", e))
				elseif v == nil or v == "" then
					fail(
						string.format(
							"no stored %s for connection %q; run Tern NetSuite: Connect account",
							string.lower(f.label),
							conn.id
						)
					)
				else
					values[f.id] = v
					remaining -= 1
					if remaining == 0 then
						done = true
						secretsCache[conn.id] = values
						cb(values, nil)
					end
				end
			end)
		end)
		if not ok then
			fail(string.format("the keychain could not be read (%s)", tostring(err)))
			return
		end
	end
end

type HttpResult = Transport.HttpResult

local function send(req: Transport.HttpRequest, timeoutMs: number, cb: (HttpResult) -> ())
	local ok, err = try(function()
		tern.fetch(req.url, {
			method = req.method,
			headers = req.headers,
			body = req.body,
			timeout_ms = timeoutMs,
		}, function(r: FetchResult)
			cb({ status = r.status, body = r.body, error = r.error, timed_out = r.timed_out })
		end)
	end)
	if not ok then
		cb({ status = 0, body = "", error = err, timed_out = false })
	end
end

local function fetchToken(
	conn: Connection,
	accountId: string,
	values: { [string]: string },
	cb: (string?, NsError?) -> ()
)
	local waiting = tokenWaiters[conn.id]
	if waiting then
		table.insert(waiting, cb)
		return
	end
	local waiters = { cb }
	tokenWaiters[conn.id] = waiters
	local function finish(token: string?, err: NsError?)
		tokenWaiters[conn.id] = nil
		for _, w in waiters do
			w(token, err)
		end
	end
	counter += 1
	local id = Spool.newId(seed, counter)
	local now = os.time()
	local input = Oauth2.signingInput(
		values.certificate_id,
		Oauth2.claims({ client_id = values.client_id, account_id = accountId, now = now, jti = id })
	)
	local dir = spoolDir()
	local path = Spool.path(dir, "jwt", id)
	local wrote = pcall(tern.fs.write, path, input)
	if not wrote then
		finish(nil, Errors.new("auth", "could not stage the JWT for signing in " .. dir, Errors.SIGNING))
		return
	end
	local ok, err = try(function()
		tern.process.run(
			Oauth2.signArgv(path),
			{ stdin = values.private_key, timeout_ms = 15000 },
			function(r: ProcessResult)
				pcall(tern.fs.remove, path)
				local signature = string.match(r.stdout, "^%s*([%w+/=]+)%s*$")
				if r.status ~= 0 or signature == nil then
					finish(
						nil,
						Errors.new(
							"auth",
							"openssl could not sign the client assertion (is the private key an RSA PEM key?)",
							Errors.SIGNING
						)
					)
					return
				end
				local req = Oauth2.tokenRequest(accountId, Oauth2.assertion(input, signature :: string))
				send(req, conn.timeout_ms, function(res: HttpResult)
					local token, terr = Oauth2.parseToken(res, tern.json.decode, os.time())
					if token then
						tokens[conn.id] = token
						finish(token.access_token, nil)
					else
						finish(nil, terr)
					end
				end)
			end
		)
	end)
	if not ok then
		pcall(tern.fs.remove, path)
		finish(nil, Errors.new("auth", "could not run openssl: " .. tostring(err), Errors.SIGNING))
	end
end

local function authorize(
	conn: Connection,
	accountId: string,
	values: { [string]: string },
	req: Transport.HttpRequest,
	cb: (Transport.HttpRequest?, NsError?) -> ()
)
	local headers = table.clone(req.headers)
	local signed = table.clone(req)
	signed.headers = headers
	if conn.auth == "tba" then
		headers.Authorization = Oauth1.header({
			method = req.method,
			url = req.url,
			realm = Endpoints.realm(accountId),
			credentials = values :: any,
			nonce = nextNonce(),
			timestamp = os.time(),
		})
		cb(signed, nil)
		return
	end
	local token = tokens[conn.id]
	if Oauth2.fresh(token, os.time()) then
		headers.Authorization = "Bearer " .. (token :: Oauth2.Token).access_token
		cb(signed, nil)
		return
	end
	fetchToken(conn, accountId, values, function(access: string?, err: NsError?)
		if access == nil then
			cb(nil, err)
			return
		end
		headers.Authorization = "Bearer " .. access
		cb(signed, nil)
	end)
end

-- Runs `sql` on connection `connectionId` and calls `cb` once with every
-- row (up to opts.max_rows, default 1000) or a normalized error. Read-only
-- connections refuse anything but a single SELECT / WITH before sending.
function M.query(connectionId: string, sql: string, params: { any }?, opts: QueryOptions?, cb: Callback)
	local started = tern.now()
	local called = false
	local function finish(result: Result?, err: NsError?)
		if called then
			return
		end
		called = true
		record(connectionId, started, err)
		if err and err.kind == "auth" then
			forgetCaches(connectionId)
		end
		local ok, cerr = try(function()
			cb(result, err)
		end)
		if not ok then
			log.warn("tern-netsuite ns query callback failed", cerr)
		end
	end
	local target, rerr = resolve(connectionId)
	if target == nil then
		finish(nil, rerr)
		return
	end
	local conn = target.connection
	local plan, perr = Query.plan({
		connection = conn,
		account_id = target.account_id,
		sql = sql,
		params = params,
		max_rows = if opts then opts.max_rows else nil,
	})
	if plan == nil then
		finish(nil, perr)
		return
	end
	loadSecrets(conn, function(values: { [string]: string }?, serr: NsError?)
		if values == nil then
			finish(nil, serr)
			return
		end
		local function step(p: Query.Plan)
			authorize(
				conn,
				target.account_id,
				values,
				Query.request(p),
				function(req: Transport.HttpRequest?, aerr: NsError?)
					if req == nil then
						finish(nil, aerr)
						return
					end
					send(req, conn.timeout_ms, function(res: HttpResult)
						local s = Query.advance(p, res, tern.json.decode)
						if s.kind == "next" then
							step(s.plan)
						elseif s.kind == "done" then
							finish(s.result, nil)
						else
							finish(nil, s.error)
						end
					end)
				end
			)
		end
		step(plan :: Query.Plan)
	end)
end

-- Spool service for the host half -----------------------------------------------

local function respond(id: string, resp: Spool.Response)
	local dir = spoolDir()
	local _, text = Spool.fit(resp, function(v: any): string
		return tern.json.encode(v)
	end)
	local ok, err = try(function()
		tern.process.run(
			Spool.writeArgv(dir, Spool.path(dir, "resp", id)),
			{ stdin = text, timeout_ms = 10000 },
			function(r: ProcessResult)
				if r.status ~= 0 then
					log.warn("tern-netsuite ns: could not write a response", r.stderr)
				end
			end
		)
	end)
	if not ok then
		log.warn("tern-netsuite ns: could not write a response", err)
	end
end

local function failure(id: string, err: NsError): Spool.Response
	return { v = Spool.VERSION, id = id, ok = false, error = err }
end

-- Reads and deletes a request file; nil when it is gone (another window of
-- the same key claimed it) or unreadable.
local function claim(path: string, max: number): string?
	local ok, text = pcall(tern.fs.read, path, max)
	pcall(tern.fs.remove, path)
	return if ok then text else nil
end

local function serveQuery(id: string)
	local text = claim(Spool.path(spoolDir(), "query", id), Spool.MAX_REQUEST_BYTES)
	if text == nil then
		return
	end
	local req, err = Spool.decodeQuery(text, id, os.time(), tern.json.decode)
	if req == nil then
		respond(id, failure(id, Errors.new("query", err or "unreadable request")))
		return
	end
	local started = tern.now()
	M.query(req.connection, req.sql, req.params, { max_rows = req.max_rows }, function(result: Result?, qerr: NsError?)
		local ms = math.floor(tern.now() - started)
		if result then
			respond(id, {
				v = Spool.VERSION,
				id = id,
				ok = true,
				rows = tern.json.array(result.rows),
				truncated = result.truncated,
				pages = result.pages,
				ms = ms,
			})
		else
			respond(id, failure(id, qerr :: NsError))
		end
	end)
end

local function setSecrets(names: { { string } }, i: number, cb: (string?) -> ())
	local pair = names[i]
	if pair == nil then
		cb(nil)
		return
	end
	local ok, err = try(function()
		tern.secrets.set(pair[1], pair[2] :: any):next(function(_: any, e: string?)
			if e then
				cb(e)
			else
				setSecrets(names, i + 1, cb)
			end
		end)
	end)
	if not ok then
		cb(err)
	end
end

local function serveCredentials(id: string, forget: boolean)
	local text = claim(Spool.path(spoolDir(), "cred", id), Spool.MAX_CREDENTIAL_BYTES)
	if text == nil then
		return
	end
	local req, err = Spool.decodeStore(text, id, os.time(), tern.json.decode)
	text = nil
	if req == nil then
		respond(id, failure(id, Errors.new("auth", err or "unreadable request", Errors.NO_CREDENTIALS)))
		return
	end
	ConfigHost.load()
	local target, rerr = resolve(req.connection)
	if target == nil then
		respond(id, failure(id, rerr :: NsError))
		return
	end
	local conn = target.connection
	local why = Credentials.unstorable(conn.id, conn.auth)
	if why then
		respond(id, failure(id, Errors.new("auth", why, Errors.NO_CREDENTIALS)))
		return
	end
	local writes: { { string } } = {}
	if forget then
		for _, f in Credentials.FIELDS[conn.auth] do
			table.insert(writes, { Credentials.secretName(conn.id, f.id) :: string })
		end
	else
		local values, verr = Credentials.validate(conn.auth, req.values)
		if values == nil then
			respond(id, failure(id, Errors.new("auth", verr or "invalid credentials", Errors.NO_CREDENTIALS)))
			return
		end
		for _, f in Credentials.FIELDS[conn.auth] do
			table.insert(writes, { Credentials.secretName(conn.id, f.id) :: string, values[f.id] })
		end
	end
	forgetCaches(conn.id)
	setSecrets(writes, 1, function(serr: string?)
		forgetCaches(conn.id)
		if serr then
			respond(id, failure(id, Errors.new("auth", "the keychain refused the credentials: " .. serr)))
		else
			respond(id, { v = Spool.VERSION, id = id, ok = true })
		end
	end)
end

-- Handles `tern-netsuite://ns/...`; window.luau dispatches area "ns" here.
function M.route(link: LinkRequest, cx: WindowCx): RouteDecision?
	local action, id = Spool.parseLink(link.url)
	if action == nil or id == nil then
		cx:toast("error", "Tern NetSuite: unknown NetSuite link", link.url)
		return { handled = true }
	end
	if action == "query" then
		ConfigHost.load()
		serveQuery(id)
	else
		serveCredentials(id, action == "forget")
	end
	return { handled = true }
end

function M.register()
	-- Leftovers of a crash or a closed window may hold credentials: the
	-- directory is private and anything older than the stale limit goes.
	pcall(tern.process.run, {
		"/bin/sh",
		"-c",
		'umask 077 && mkdir -p "$1" && chmod 700 "$1" && find "$1" -type f -mmin +"$2" -delete',
		"sh",
		spoolDir(),
		tostring(math.ceil(Spool.STALE_SECONDS / 60)),
	}, { timeout_ms = 10000 }, function() end)

	tern.command({
		id = "connect",
		title = "Tern NetSuite: Connect account",
		icon = "cloud",
		run = function(cx: WindowCx)
			if cx:new_block("tern-netsuite.connect", {}, "beside") == nil then
				cx:toast("error", "Tern NetSuite: the connect block is not available on this host")
			end
		end,
	})
end

return M
