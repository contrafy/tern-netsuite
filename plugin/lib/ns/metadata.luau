--!strict
-- Field labels from NetSuite's REST record metadata catalog: the one request
-- this plugin sends to the REST record service, and it only reads.
--
--   GET <host>.suitetalk.api.netsuite.com/services/rest/record/v1/metadata-catalog/<type>
--   Accept: application/schema+json
--
-- With `application/schema+json` NetSuite answers one record type's JSON
-- Schema, whose `properties.<field>.title` is the label the UI shows
-- (`tranId` -> "Order #"); `application/swagger+json` would describe every
-- operation as well. `request` builds the unsigned request, `guard` checks
-- the signed one right before it is sent (GET, no body, exactly that URL),
-- `parse` reads the titles. Only REST-transport connections can reach the
-- record service; RESTlet connections get a REST_ONLY error.
--
-- Labels are cached per account and record type in the plugin data
-- directory (`<data>/metadata/<ACCOUNT>/<type>.json`) for TTL_SECONDS.

local Config = require("../config")
local Endpoints = require("./endpoints")
local Errors = require("./errors")

local M = {}

type NsError = Errors.NsError

export type HttpRequest = { method: string, url: string, headers: { [string]: string }, body: string }
export type HttpResult = Errors.HttpResult

-- Lower-case field name -> label.
export type Labels = { [string]: string }

export type Entry = { v: number, account: string, record: string, fetched: number, labels: Labels }

M.ACCEPT = "application/schema+json"
M.TTL_SECONDS = 7 * 86400
M.CACHE_VERSION = 1
M.MAX_LABELS = 4000
M.MAX_LABEL = 200
-- REST members of every record that are not fields.
local SKIP: { [string]: boolean } = { links = true }

M.validType = Endpoints.validRecordType

-- Why `record` cannot be read on `conn`, or nil.
function M.refusal(conn: Config.Connection, record: string): NsError?
	if conn.transport ~= "rest" then
		return Errors.new(
			"query",
			string.format(
				'connection %q uses a RESTlet; field labels need NetSuite\'s REST record service (transport "rest")',
				conn.id
			),
			Errors.REST_ONLY
		)
	end
	if not M.validType(record) then
		return Errors.new("query", string.format("%q is not a REST record type", record))
	end
	return nil
end

-- The unsigned metadata request for `record` on `conn`, or nil and why.
function M.request(conn: Config.Connection, accountId: string, record: string): (HttpRequest?, NsError?)
	local refused = M.refusal(conn, record)
	if refused then
		return nil, refused
	end
	if not Endpoints.valid(accountId) then
		return nil,
			Errors.new("query", string.format("%q is not a NetSuite account id", accountId), Errors.NO_CONNECTION)
	end
	return {
		method = "GET",
		url = Endpoints.metadata(accountId, record),
		headers = { Accept = M.ACCEPT },
		body = "",
	},
		nil
end

-- Why `req` must not be sent as the metadata request of `record`, or nil.
-- Runs on the signed request, the last step before the fetch.
function M.guard(req: HttpRequest, accountId: string, record: string): NsError?
	local why: string? = nil
	if req.method ~= "GET" then
		why = "only GET may reach the record metadata catalog"
	elseif req.body ~= "" then
		why = "a metadata request carries no body"
	elseif not Endpoints.valid(accountId) or not M.validType(record) then
		why = "invalid account or record type"
	elseif req.url ~= Endpoints.metadata(accountId, record) then
		why = "the request is not for the metadata catalog entry of " .. record
	end
	return if why then Errors.new("query", "refused metadata request: " .. why, Errors.READ_ONLY) else nil
end

local function label(v: any): string?
	if type(v) ~= "string" then
		return nil
	end
	local s = string.gsub(v, "%c", " ")
	s = string.gsub(s, "%s+", " ")
	s = string.match(s, "^%s*(.-)%s*$") or ""
	if s == "" then
		return nil
	end
	return if #s > M.MAX_LABEL then string.sub(s, 1, M.MAX_LABEL) else s
end

-- Labels from untrusted JSON (a spool answer, a cache file): string keys
-- (lower-cased) to non-empty string labels, at most MAX_LABELS.
function M.clean(v: any): Labels
	local out: Labels = {}
	if type(v) ~= "table" then
		return out
	end
	local n = 0
	for k, l in v do
		local text = label(l)
		if type(k) == "string" and text and #k <= 100 then
			out[string.lower(k)] = text
			n += 1
			if n >= M.MAX_LABELS then
				break
			end
		end
	end
	return out
end

-- The labels of a metadata answer, or nil and NetSuite's error.
function M.parse(res: HttpResult, decode: (string) -> any): (Labels?, NsError?)
	local err = Errors.fromHttp(res, decode)
	if err then
		return nil, err
	end
	local ok, doc = pcall(decode, res.body)
	if not ok or type(doc) ~= "table" or type(doc.properties) ~= "table" then
		return nil,
			Errors.new(
				"server",
				string.format("NetSuite answered HTTP %d without a record schema", res.status),
				Errors.BAD_RESPONSE,
				res.status
			)
	end
	local titles: { [string]: any } = {}
	for name, prop in doc.properties do
		if type(name) == "string" and not SKIP[name] and type(prop) == "table" then
			titles[name] = prop.title
		end
	end
	return M.clean(titles), nil
end

-- Cache ------------------------------------------------------------------------

function M.cacheDir(data: string, accountId: string): string?
	if not Endpoints.valid(accountId) then
		return nil
	end
	return data .. "/metadata/" .. Endpoints.realm(accountId)
end

function M.cachePath(data: string, accountId: string, record: string): string?
	local dir = M.cacheDir(data, accountId)
	if dir == nil or not M.validType(record) then
		return nil
	end
	return dir .. "/" .. record .. ".json"
end

function M.cacheEntry(accountId: string, record: string, labels: Labels, fetched: number): Entry
	return {
		v = M.CACHE_VERSION,
		account = Endpoints.realm(accountId),
		record = record,
		fetched = fetched,
		labels = labels,
	}
end

-- The cached entry in `text` when it is for this account and record type and
-- younger than TTL_SECONDS at `now`, else nil.
function M.readCache(text: string, accountId: string, record: string, now: number, decode: (string) -> any): Entry?
	local ok, doc = pcall(decode, text)
	if not ok or type(doc) ~= "table" or doc.v ~= M.CACHE_VERSION then
		return nil
	end
	if not Endpoints.valid(accountId) or doc.account ~= Endpoints.realm(accountId) or doc.record ~= record then
		return nil
	end
	local fetched = doc.fetched
	if type(fetched) ~= "number" or fetched > now or now - fetched > M.TTL_SECONDS then
		return nil
	end
	return M.cacheEntry(accountId, record, M.clean(doc.labels), fetched)
end

return M
