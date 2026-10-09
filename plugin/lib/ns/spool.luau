--!strict
-- The host <-> window channel. Credentials live in the window half only
-- (`tern.secrets` is nil in the host VM), so the host half asks the window:
-- it writes a request file under `<plugin data>/ns/`, then opens
-- `tern-netsuite://ns/<action>?id=<id>` with a block or lens cx; the
-- window's route reads and deletes the request, does the work and writes
-- `<id>.resp.json`, which the host polls for, reads and deletes. URLs carry
-- only the random id: SQL and credentials never appear in a link. Files are
-- written 0600 through `umask 077` and renamed into place, so a reader
-- never sees a partial file.

local Crypto = require("./crypto")
local Errors = require("./errors")

local M = {}

type NsError = Errors.NsError

M.SCHEME = "tern-netsuite://"
M.AREA = "ns"
M.VERSION = 1

M.MAX_REQUEST_BYTES = 262144
M.MAX_CREDENTIAL_BYTES = 262144
M.MAX_RESPONSE_BYTES = 8388608
-- A request older than this is a leftover (a crash, a closed window), not
-- something a user is waiting for.
M.STALE_SECONDS = 300

export type Action = "query" | "store" | "forget"

local ACTIONS: { [string]: boolean } = { query = true, store = true, forget = true }

-- jwt: the (non-secret) JWT signing input openssl reads while the private
-- key arrives on its stdin.
export type Kind = "query" | "cred" | "resp" | "jwt"

function M.validId(id: string): boolean
	return string.find(id, "^[a-f0-9]+$") ~= nil and #id >= 16 and #id <= 64
end

-- A request id unique per (seed, counter); the seed mixes clock and PRNG
-- entropy once per VM. Ids only have to be unguessable enough that another
-- link cannot name a pending request by accident.
function M.newId(seed: string, counter: number): string
	return string.sub(Crypto.hex(Crypto.sha256("spool:" .. seed .. ":" .. tostring(counter))), 1, 24)
end

function M.link(action: Action, id: string): string
	return string.format("%s%s/%s?id=%s", M.SCHEME, M.AREA, action, id)
end

-- The action and id of a `tern-netsuite://ns/...` link, or nil when it is
-- not one this protocol produces.
function M.parseLink(url: string): (Action?, string?)
	local action, id = string.match(url, "^tern%-netsuite://ns/([a-z]+)%?id=([a-f0-9]+)$")
	if action == nil or id == nil or not ACTIONS[action] or not M.validId(id) then
		return nil, nil
	end
	return action :: Action, id
end

function M.dir(data: string): string
	return data .. "/ns"
end

function M.path(dir: string, kind: Kind, id: string): string
	return string.format("%s/%s.%s.json", dir, id, kind)
end

-- argv that creates `dir` (0700) and atomically writes stdin to `path`
-- (0600). Secrets travel on stdin, never in argv.
function M.writeArgv(dir: string, path: string): { string }
	return {
		"/bin/sh",
		"-c",
		'umask 077 && mkdir -p "$1" && chmod 700 "$1" && cat >"$2.tmp" && mv -f "$2.tmp" "$2"',
		"sh",
		dir,
		path,
	}
end

export type QueryRequest = {
	v: number,
	id: string,
	connection: string,
	sql: string,
	params: { any },
	max_rows: number?,
	-- os.time() when written.
	at: number,
}

export type StoreRequest = {
	v: number,
	id: string,
	connection: string,
	values: { [string]: string },
	at: number,
}

export type Response = {
	v: number,
	id: string,
	ok: boolean,
	rows: { any }?,
	truncated: boolean?,
	pages: number?,
	error: NsError?,
	ms: number?,
}

local function decodeObject(text: string, decode: (string) -> any): any
	local ok, doc = pcall(decode, text)
	if not ok or type(doc) ~= "table" then
		return nil
	end
	return doc
end

local function common(doc: any, id: string, now: number): string?
	if doc == nil then
		return "the request file is not a JSON object"
	elseif doc.v ~= M.VERSION then
		return "the request file has an unknown version"
	elseif doc.id ~= id then
		return "the request file does not belong to this link"
	elseif type(doc.connection) ~= "string" or doc.connection == "" then
		return "the request names no connection"
	elseif type(doc.at) ~= "number" or math.abs(now - doc.at) > M.STALE_SECONDS then
		return "the request is stale"
	end
	return nil
end

function M.decodeQuery(text: string, id: string, now: number, decode: (string) -> any): (QueryRequest?, string?)
	local doc = decodeObject(text, decode)
	local err = common(doc, id, now)
	if err then
		return nil, err
	end
	if type(doc.sql) ~= "string" or doc.sql == "" then
		return nil, "the request has no SQL"
	end
	local params = doc.params
	if params == nil then
		params = {}
	elseif type(params) ~= "table" then
		return nil, "the request parameters are not a list"
	end
	local maxRows = if type(doc.max_rows) == "number" then doc.max_rows else nil
	return {
		v = doc.v,
		id = id,
		connection = doc.connection,
		sql = doc.sql,
		params = params,
		max_rows = maxRows,
		at = doc.at,
	},
		nil
end

function M.decodeStore(text: string, id: string, now: number, decode: (string) -> any): (StoreRequest?, string?)
	local doc = decodeObject(text, decode)
	local err = common(doc, id, now)
	if err then
		return nil, err
	end
	if type(doc.values) ~= "table" then
		return nil, "the request carries no credential values"
	end
	local values: { [string]: string } = {}
	for k, v in doc.values do
		if type(k) ~= "string" or type(v) ~= "string" then
			return nil, "credential values must be strings"
		end
		values[k] = v
	end
	return { v = doc.v, id = id, connection = doc.connection, values = values, at = doc.at }, nil
end

function M.decodeResponse(text: string, id: string, decode: (string) -> any): Response
	local doc = decodeObject(text, decode)
	if doc == nil or doc.id ~= id or type(doc.ok) ~= "boolean" then
		return {
			v = M.VERSION,
			id = id,
			ok = false,
			error = Errors.new("server", "the window wrote an unreadable answer", Errors.BAD_RESPONSE),
		}
	end
	local e = doc.error
	local err: NsError? = nil
	if not doc.ok then
		if type(e) == "table" and Errors.KINDS[e.kind] and type(e.message) == "string" then
			err = {
				kind = e.kind :: Errors.Kind,
				message = e.message,
				status = if type(e.status) == "number" then e.status else nil,
				code = if type(e.code) == "string" then e.code else nil,
			}
		else
			err = Errors.new("server", "the window reported a failure without details", Errors.BAD_RESPONSE)
		end
	end
	return {
		v = M.VERSION,
		id = id,
		ok = doc.ok,
		rows = if doc.ok and type(doc.rows) == "table" then doc.rows else (if doc.ok then {} else nil),
		truncated = doc.truncated == true,
		pages = if type(doc.pages) == "number" then doc.pages else nil,
		error = err,
		ms = if type(doc.ms) == "number" then doc.ms else nil,
	}
end

-- A response that fits `max` bytes once encoded: rows are dropped from the
-- end (and `truncated` set) until it does. Halving keeps this to a few
-- encodes even for large results.
function M.fit(resp: Response, encode: (any) -> string, max: number?): (Response, string)
	local limit = max or M.MAX_RESPONSE_BYTES
	local text = encode(resp)
	if #text <= limit or resp.rows == nil then
		return resp, text
	end
	local rows = resp.rows :: { any }
	local keep = #rows
	local fitted = table.clone(resp)
	fitted.truncated = true
	while keep > 0 do
		keep = math.floor(keep / 2)
		fitted.rows = table.move(rows, 1, keep, 1, {})
		text = encode(fitted)
		if #text <= limit then
			return fitted, text
		end
	end
	return fitted, text
end

return M
