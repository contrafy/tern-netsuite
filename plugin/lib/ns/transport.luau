--!strict
-- Request builders and response parsers for the two SuiteQL transports.
-- Requests carry no Authorization header: the adapter signs them last, so
-- the signature covers the final URL.
--
-- REST SuiteQL: POST <host>.suitetalk.api.netsuite.com/services/rest/query/v1/suiteql
--   ?limit=&offset=, body {"q": sql}, `Prefer: transient`; pages of at most
--   1000 rows with `hasMore`.
-- RESTlet: POST <host>.restlets.api.netsuite.com/app/site/hosting/restlet.nl
--   ?script=&deploy=, body = restlet.extra + {query_field: sql,
--   params_field: [params]}; rows at the dotted restlet.rows_path.

local Config = require("../config")
local Encoding = require("./encoding")
local Endpoints = require("./endpoints")
local Errors = require("./errors")

local M = {}

type NsError = Errors.NsError
type Restlet = Config.Restlet

export type HttpRequest = {
	method: string,
	url: string,
	headers: { [string]: string },
	body: string,
}

export type HttpResult = Errors.HttpResult

export type Page = {
	rows: { any },
	-- REST: whether NetSuite has rows past this page. RESTlets answer with
	-- every row at once.
	hasMore: boolean,
	total: number?,
}

function M.rest(accountId: string, sql: string, limit: number, offset: number): HttpRequest
	return {
		method = "POST",
		url = Endpoints.suiteql(accountId, limit, offset),
		headers = {
			["Content-Type"] = "application/json",
			Accept = "application/json",
			Prefer = "transient",
		},
		body = Encoding.json({ q = sql }),
	}
end

function M.restlet(accountId: string, restlet: Restlet, sql: string, params: { any }): HttpRequest
	local body: { [string]: any } = table.clone(restlet.extra)
	body[restlet.query_field] = sql
	body[restlet.params_field] = params
	return {
		method = "POST",
		url = Endpoints.restlet(accountId, restlet.script, restlet.deploy),
		headers = {
			["Content-Type"] = "application/json",
			Accept = "application/json",
		},
		body = Encoding.json(body),
	}
end

local function decodeBody(res: HttpResult, decode: (string) -> any): (any, NsError?)
	local err = Errors.fromHttp(res, decode)
	if err then
		return nil, err
	end
	local ok, doc = pcall(decode, res.body)
	if not ok or type(doc) ~= "table" then
		return nil,
			Errors.new(
				"server",
				string.format("NetSuite answered HTTP %d with a body that is not JSON", res.status),
				Errors.BAD_RESPONSE,
				res.status
			)
	end
	return doc, nil
end

-- REST rows carry a `links` array each; it is metadata, not a column.
local function stripLinks(items: { any }): { any }
	local rows = table.create(#items)
	for i, item in items do
		if type(item) == "table" and item.links ~= nil then
			local row = table.clone(item)
			row.links = nil
			rows[i] = row
		else
			rows[i] = item
		end
	end
	return rows
end

function M.parseRest(res: HttpResult, decode: (string) -> any): (Page?, NsError?)
	local doc, err = decodeBody(res, decode)
	if err then
		return nil, err
	end
	local items = doc.items
	if items == nil then
		items = {}
	end
	if type(items) ~= "table" then
		return nil, Errors.new("server", "NetSuite's SuiteQL answer has no items list", Errors.BAD_RESPONSE, res.status)
	end
	return {
		rows = stripLinks(items),
		hasMore = doc.hasMore == true,
		total = if type(doc.totalResults) == "number" then doc.totalResults else nil,
	},
		nil
end

local function at(doc: any, path: string): any
	local v = doc
	for key in string.gmatch(path, "[^%.]+") do
		if type(v) ~= "table" then
			return nil
		end
		v = v[key]
	end
	return v
end

function M.parseRestlet(res: HttpResult, restlet: Restlet, decode: (string) -> any): (Page?, NsError?)
	local doc, err = decodeBody(res, decode)
	if err then
		return nil, err
	end
	-- Application errors arrive as HTTP 200 (a typical SuiteQL RESTlet answers
	-- { ok: false, error }): read them before looking for rows.
	if doc.ok == false or (doc.error ~= nil and at(doc, restlet.rows_path) == nil) then
		return nil,
			Errors.fromDocument(doc, res.status, decode) or Errors.new(
				"query",
				"the RESTlet reported a failure without a message",
				nil,
				res.status
			)
	end
	local rows = at(doc, restlet.rows_path)
	if type(rows) ~= "table" then
		return nil,
			Errors.new(
				"server",
				string.format("the RESTlet answer has no row list at %q (check restlet.rows_path)", restlet.rows_path),
				Errors.BAD_RESPONSE,
				res.status
			)
	end
	return { rows = rows, hasMore = false, total = #rows }, nil
end

return M
