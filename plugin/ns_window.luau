--!strict
-- Window half of the NetSuite connection layer. Credentials can only live
-- here: `tern.secrets` exists in the window VM and is nil in the host VM
-- (verified on Tern 0.6.3). This half therefore owns the SuiteQL client
-- (signing, token cache, fetch, paging) and the record metadata reader
-- (field labels, GET only: lib/ns/metadata.luau), and serves the host half
-- through `tern-netsuite://ns/<action>?id=<id>` links whose payloads travel
-- in 0600 spool files (lib/ns/spool.luau). Window-side features (status
-- line, timers) call `query` directly.

local lazy = require("./lib/lazy")
local Config = require("./lib/config")
local ConfigHost = require("./config_host")
local Credentials = lazy(function()
	return require("./lib/ns/credentials")
end)
local Endpoints = require("./lib/ns/endpoints")
local Errors = require("./lib/ns/errors")
local Metadata = lazy(function()
	return require("./lib/ns/metadata")
end)
local Oauth1 = lazy(function()
	return require("./lib/ns/oauth1")
end)
local Oauth2 = lazy(function()
	return require("./lib/ns/oauth2")
end)
local Query = lazy(function()
	return require("./lib/ns/query")
end)
local Spool = require("./lib/ns/spool")
local Transport = lazy(function()
	return require("./lib/ns/transport")
end)

type NsError = Errors.NsError
type Connection = Config.Connection
type HttpRequest = typeof(Transport().rest("", "", 0, 0))
type HttpResult = Errors.HttpResult
type Token = typeof(Oauth2().parseToken(nil :: any, nil :: any, 0))

export type QueryOptions = { max_rows: number? }
-- lib/ns/query.luau's Result (that module loads on the first query).
export type Result = { rows: { any }, truncated: boolean, pages: number }
export type Callback = (result: Result?, err: NsError?) -> ()

export type MetadataOptions = {
	-- Ask NetSuite even when the cache holds labels younger than a week.
	refresh: boolean?,
}
-- Field labels (lower-case field name -> label), when NetSuite sent them
-- (os.time()) and whether they came from the cache.
export type MetadataResult = { labels: { [string]: string }, fetched: number, cached: boolean }
export type MetadataCallback = (result: MetadataResult?, err: NsError?) -> ()

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
	return Oauth1().nonce(seed, counter)
end

local function spoolDir(): string
	return Spool.dir(tern.plugin.data)
end

-- Connection id -> stored values. Dropped when credentials change or a
-- query fails authentication (they may have been replaced in the keychain).
local secretsCache: { [string]: { [string]: string } } = {}
local tokens: { [string]: Token } = {}
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
	local fields = Credentials().FIELDS[conn.auth]
	local why = Credentials().unstorable(conn.id, conn.auth)
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
		local name = Credentials().secretName(conn.id, f.id) :: string
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

local function send(req: HttpRequest, timeoutMs: number, cb: (HttpResult) -> ())
	local ok, err = try(function()
		tern.fetch(req.url, {
			method = req.method,
			headers = req.headers,
			-- GET (record metadata) sends no body at all.
			body = if req.body == "" then nil else req.body,
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
	local input = Oauth2().signingInput(
		values.certificate_id,
		Oauth2().claims({ client_id = values.client_id, account_id = accountId, now = now, jti = id })
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
			Oauth2().signArgv(path),
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
				local req = Oauth2().tokenRequest(accountId, Oauth2().assertion(input, signature :: string))
				send(req, conn.timeout_ms, function(res: HttpResult)
					local token, terr = Oauth2().parseToken(res, tern.json.decode, os.time())
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
	req: HttpRequest,
	cb: (HttpRequest?, NsError?) -> ()
)
	local headers = table.clone(req.headers)
	local signed = table.clone(req)
	signed.headers = headers
	if conn.auth == "tba" then
		headers.Authorization = Oauth1().header({
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
	if token and Oauth2().fresh(token, os.time()) then
		headers.Authorization = "Bearer " .. token.access_token
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
	local plan, perr = Query().plan({
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
		local function step(p)
			authorize(conn, target.account_id, values, Query().request(p), function(req: HttpRequest?, aerr: NsError?)
				if req == nil then
					finish(nil, aerr)
					return
				end
				send(req, conn.timeout_ms, function(res: HttpResult)
					local s = Query().advance(p, res, tern.json.decode)
					if s.kind == "next" then
						step(s.plan)
					elseif s.kind == "done" then
						finish(s.result, nil)
					else
						finish(nil, s.error)
					end
				end)
			end)
		end
		step(plan)
	end)
end

local MAX_METADATA_CACHE = 1048576

-- Reads the field labels of REST record type `recordType` on connection
-- `connectionId` and calls `cb` once with them or a normalized error. Labels
-- come from the plugin data cache while younger than a week (unless
-- opts.refresh), else from one GET of NetSuite's metadata catalog, never
-- any other method or path (Metadata.guard runs on the signed request).
-- RESTlet connections cannot reach that service: REST_ONLY.
function M.metadata(connectionId: string, recordType: string, opts: MetadataOptions?, cb: MetadataCallback)
	local called = false
	local function finish(result: MetadataResult?, err: NsError?)
		if called then
			return
		end
		called = true
		if err and err.kind == "auth" then
			forgetCaches(connectionId)
		end
		local ok, cerr = try(function()
			cb(result, err)
		end)
		if not ok then
			log.warn("tern-netsuite ns metadata callback failed", cerr)
		end
	end
	local target, rerr = resolve(connectionId)
	if target == nil then
		finish(nil, rerr)
		return
	end
	local conn, account = target.connection, target.account_id
	local req, qerr = Metadata().request(conn, account, recordType)
	if req == nil then
		finish(nil, qerr)
		return
	end
	local data = tern.plugin.data
	local path = Metadata().cachePath(data, account, recordType) :: string
	if not (opts and opts.refresh) then
		local okRead, text = pcall(tern.fs.read, path, MAX_METADATA_CACHE)
		local entry = if okRead and type(text) == "string"
			then Metadata().readCache(text, account, recordType, os.time(), tern.json.decode)
			else nil
		if entry then
			finish({ labels = entry.labels, fetched = entry.fetched, cached = true }, nil)
			return
		end
	end
	loadSecrets(conn, function(values: { [string]: string }?, serr: NsError?)
		if values == nil then
			finish(nil, serr)
			return
		end
		authorize(conn, account, values, req, function(signed: HttpRequest?, aerr: NsError?)
			if signed == nil then
				finish(nil, aerr)
				return
			end
			local refused = Metadata().guard(signed, account, recordType)
			if refused then
				finish(nil, refused)
				return
			end
			send(signed, conn.timeout_ms, function(res: HttpResult)
				local labels, perr = Metadata().parse(res, tern.json.decode)
				if labels == nil then
					finish(nil, perr)
					return
				end
				local fetched = os.time()
				local dir = Metadata().cacheDir(data, account) :: string
				pcall(tern.process.run, Spool.writeArgv(dir, path), {
					stdin = tern.json.encode(Metadata().cacheEntry(account, recordType, labels, fetched)),
					timeout_ms = 10000,
				}, function(r: ProcessResult)
					if r.status ~= 0 then
						log.warn("tern-netsuite ns: could not cache field labels", r.stderr)
					end
				end)
				finish({ labels = labels, fetched = fetched, cached = false }, nil)
			end)
		end)
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

local function serveQuery(id: string, recorded: string)
	local text = claim(Spool.path(spoolDir(), "query", id), Spool.MAX_REQUEST_BYTES)
	if text == nil then
		return
	end
	local req, err = Spool.decodeQuery(text, id, os.time(), tern.json.decode)
	if req == nil then
		respond(id, failure(id, Errors.new("query", err or "unreadable request")))
		return
	end
	if req.connection ~= recorded then
		respond(id, failure(id, Errors.new("query", "the request names another connection than was recorded")))
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

local function serveMetadata(id: string, recorded: string)
	local text = claim(Spool.path(spoolDir(), "meta", id), Spool.MAX_REQUEST_BYTES)
	if text == nil then
		return
	end
	local req, err = Spool.decodeMetadata(text, id, os.time(), tern.json.decode)
	if req == nil then
		respond(id, failure(id, Errors.new("query", err or "unreadable request")))
		return
	end
	if req.connection ~= recorded then
		respond(id, failure(id, Errors.new("query", "the request names another connection than was recorded")))
		return
	end
	local started = tern.now()
	M.metadata(req.connection, req.record, { refresh = req.refresh }, function(result: MetadataResult?, merr: NsError?)
		if result then
			respond(id, {
				v = Spool.VERSION,
				id = id,
				ok = true,
				labels = result.labels,
				fetched = result.fetched,
				cached = result.cached,
				ms = math.floor(tern.now() - started),
			})
		else
			respond(id, failure(id, merr :: NsError))
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

local function serveCredentials(id: string, forget: boolean, recorded: string, cx: WindowCx)
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
	if req.connection ~= recorded then
		respond(id, failure(id, Errors.new("auth", "the request names another connection than the connect block")))
		return
	end
	ConfigHost.load()
	local target, rerr = resolve(req.connection)
	if target == nil then
		respond(id, failure(id, rerr :: NsError))
		return
	end
	local conn = target.connection
	local why = Credentials().unstorable(conn.id, conn.auth)
	if why then
		respond(id, failure(id, Errors.new("auth", why, Errors.NO_CREDENTIALS)))
		return
	end
	local writes: { { string } } = {}
	if forget then
		for _, f in Credentials().FIELDS[conn.auth] do
			table.insert(writes, { Credentials().secretName(conn.id, f.id) :: string })
		end
	else
		local values, verr = Credentials().validate(conn.auth, req.values)
		if values == nil then
			respond(id, failure(id, Errors.new("auth", verr or "invalid credentials", Errors.NO_CREDENTIALS)))
			return
		end
		for _, f in Credentials().FIELDS[conn.auth] do
			table.insert(writes, { Credentials().secretName(conn.id, f.id) :: string, values[f.id] })
		end
	end
	forgetCaches(conn.id)
	setSecrets(writes, 1, function(serr: string?)
		forgetCaches(conn.id)
		if serr then
			respond(id, failure(id, Errors.new("auth", "the keychain refused the credentials: " .. serr)))
		else
			pcall(function()
				cx:toast(
					"info",
					string.format(
						"Tern NetSuite: %s the stored credentials of connection %q",
						if forget then "removed" else "replaced",
						conn.id
					)
				)
			end)
			respond(id, { v = Spool.VERSION, id = id, ok = true })
		end
	end)
end

local PENDING_TRIES = 10
local PENDING_RETRY_MS = 50

-- Handles `tern-netsuite://ns/...`; window.luau dispatches area "ns" here.
function M.route(link: LinkRequest, cx: WindowCx): RouteDecision?
	local action, id = Spool.parseLink(link.url)
	if action == nil or id == nil then
		cx:toast("error", "Tern NetSuite: unknown NetSuite link", link.url)
		return { handled = true }
	end
	-- Served only when the host half recorded this id for this action; the
	-- record is removed first, so a link works once. The host sets it just
	-- before opening the link; a VM notices another's kv write on its next
	-- read, so a missing record is looked up again for a moment.
	local key = Spool.pendingKey(id)
	local requestPath = Spool.path(spoolDir(), Spool.requestKind(action :: Spool.Action), id)
	local tries = 0
	local function attempt()
		tries += 1
		local okGet, stored = pcall(tern.kv.get, key)
		if okGet and stored ~= nil then
			pcall(tern.kv.set, key, nil)
		elseif tries < PENDING_TRIES then
			tern.timer(PENDING_RETRY_MS, attempt)
			return
		end
		local why = Spool.checkPending(if okGet then stored else nil, action, os.time())
		if why then
			pcall(tern.fs.remove, requestPath)
			pcall(function()
				cx:toast("error", "Tern NetSuite: " .. why)
			end)
		elseif action == "query" then
			ConfigHost.load()
			serveQuery(id, stored.connection)
		elseif action == "metadata" then
			ConfigHost.load()
			serveMetadata(id, stored.connection)
		else
			serveCredentials(id, action == "forget", stored.connection, cx)
		end
	end
	attempt()
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
