--!strict
local Config = require("../../../plugin/lib/config")
local Errors = require("../../../plugin/lib/ns/errors")
local Query = require("../../../plugin/lib/ns/query")
local Transport = require("../../../plugin/lib/ns/transport")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local RESTLET: Config.Restlet = {
	script = "customscript_acme_suiteql",
	deploy = "customdeploy_acme_suiteql",
	query_field = "query",
	params_field = "params",
	rows_path = "rows",
	extra = { action = "suiteql" },
}

local function conn(transport: Config.Transport, readOnly: boolean?): Config.Connection
	return {
		id = "sandbox-" .. transport,
		account = "sandbox",
		auth = "tba",
		transport = transport,
		read_only = if readOnly == nil then true else readOnly,
		timeout_ms = 30000,
		restlet = if transport == "restlet" then RESTLET else nil,
	}
end

local function http(status: number, path: string): Transport.HttpResult
	return { status = status, body = fixtures.read(path) }
end

local function err(status: number, path: string): Errors.NsError
	return Errors.fromHttp(http(status, path), json.decode) :: Errors.NsError
end

describe("normalizing NetSuite errors so blocks can say what went wrong", function()
	it("reads REST problem documents (o:errorDetails), as captured from a sandbox", function()
		local e = err(401, "ns/errors/rest-401-invalid-login.json")
		expect(e.kind).toBe("auth")
		expect(e.code).toBe("INVALID_LOGIN")
		expect(e.status).toBe(401)
		expect(e.message).toContain("Invalid login attempt")
		local q = err(400, "ns/errors/rest-400-invalid-query.json")
		expect(q.kind).toBe("query")
		expect(q.code).toBe("INVALID_PARAMETER")
		expect(q.message).toContain("Unknown identifier 'nope'")
		expect(err(429, "ns/errors/rest-429-concurrency.json").kind).toBe("rate_limit")
	end)

	it("reads RESTlet platform errors, whose failed login is a 403 rather than a 401", function()
		local e = err(403, "ns/errors/restlet-403-invalid-login.json")
		expect(e.kind).toBe("auth")
		expect(e.code).toBe("INVALID_LOGIN_ATTEMPT")
		expect(err(403, "ns/errors/restlet-403-permission.json").kind).toBe("permission")
	end)

	it("treats request-limit codes as rate limits even when NetSuite sends them as 403", function()
		local e = err(403, "ns/errors/restlet-403-request-limit.json")
		expect(e.kind).toBe("rate_limit")
		expect(Errors.retryable(e)).toBe(true)
	end)

	it("unwraps SuiteScriptError JSON nested in a RESTlet error message", function()
		local e = err(400, "ns/errors/restlet-400-script-error.json")
		expect(e.kind).toBe("server")
		expect(e.code).toBe("SSS_USAGE_LIMIT_EXCEEDED")
		expect(e.message).toBe("Script Execution Usage Limit Exceeded")
	end)

	it("classifies OAuth 2.0 token endpoint refusals as authentication failures", function()
		local e = err(400, "ns/errors/token-400-invalid-grant.json")
		expect(e.kind).toBe("auth")
		expect(e.code).toBe("invalid_grant")
	end)

	it("falls back to the status for HTML pages and strips the markup", function()
		local e = err(503, "ns/errors/html-503.html")
		expect(e.kind).toBe("server")
		expect(e.message).toContain("HTTP 503")
		expect(e.message).toContain("Service Unavailable")
		expect((string.find(e.message, "<", 1, true))).toBeNil()
	end)

	it("reports transport failures and timeouts as network errors", function()
		local timeout = Errors.fromHttp({ status = 0, body = "", error = "timed out", timed_out = true }, json.decode)
		expect(timeout and timeout.kind).toBe("network")
		expect(timeout and timeout.code).toBe(Errors.TIMEOUT)
		local dns = Errors.fromHttp({ status = 0, body = "", error = "dns error" }, json.decode)
		expect(dns and dns.message).toContain("dns error")
		expect(Errors.fromHttp({ status = 200, body = "{}" }, json.decode)).toBeNil()
	end)

	it("never lets a huge error body flood the view", function()
		local e = Errors.new("server", string.rep("x", 5000))
		expect(#e.message <= 600).toBe(true)
	end)
end)

describe("REST SuiteQL transport", function()
	it("posts the query with Prefer: transient on the account's suitetalk host", function()
		local req = Transport.rest("1234567_SB1", "SELECT 1 AS ok FROM DUAL", 1000, 0)
		expect(req.method).toBe("POST")
		expect(req.url).toBe(
			"https://1234567-sb1.suitetalk.api.netsuite.com/services/rest/query/v1/suiteql?limit=1000&offset=0"
		)
		expect(req.headers.Prefer).toBe("transient")
		expect(json.decode(req.body).q).toBe("SELECT 1 AS ok FROM DUAL")
		expect(req.headers.Authorization).toBeNil()
	end)

	it("drops the per-row links metadata NetSuite adds to every item", function()
		local page = Transport.parseRest(http(200, "ns/rest/page1.json"), json.decode)
		expect(page and page.hasMore).toBe(true)
		expect(page and page.rows[1]).toEqual({ id = "101", title = "first" })
	end)

	it("reads the sandbox's answer to the connection test, where every value is a string", function()
		local rest = Transport.parseRest(http(200, "ns/rest/select1.json"), json.decode)
		expect(rest and rest.rows).toEqual({ { ok = "1" } })
		expect(rest and rest.hasMore).toBe(false)
		local rl = Transport.parseRestlet(http(200, "ns/restlet/select1.json"), RESTLET, json.decode)
		expect(rl and rl.rows).toEqual({ { ok = 1 } })
	end)
end)

describe("RESTlet transport", function()
	it("builds the body from the configured extra fields, query field and params field", function()
		local req = Transport.restlet("1234567_SB1", RESTLET, "SELECT id FROM t WHERE id = ?", { 5 })
		expect(req.url).toBe(
			"https://1234567-sb1.restlets.api.netsuite.com/app/site/hosting/restlet.nl"
				.. "?script=customscript_acme_suiteql&deploy=customdeploy_acme_suiteql"
		)
		expect(req.body).toBe('{"action":"suiteql","params":[5],"query":"SELECT id FROM t WHERE id = ?"}')
		local empty = Transport.restlet("1234567_SB1", RESTLET, "SELECT 1 FROM DUAL", {})
		expect(json.decode(empty.body).params).toEqual({})
		expect(string.find(empty.body, '"params":[]', 1, true) ~= nil).toBe(true)
	end)

	it("reads rows at a nested rows_path", function()
		local nested = table.clone(RESTLET)
		nested.rows_path = "data.items"
		local page =
			Transport.parseRestlet({ status = 200, body = '{"data":{"items":[{"a":1}]}}' }, nested, json.decode)
		expect(page and page.rows[1].a).toBe(1)
	end)

	it("surfaces application errors a RESTlet returns with HTTP 200", function()
		local _, e = Transport.parseRestlet(http(200, "ns/errors/restlet-200-app-error.json"), RESTLET, json.decode)
		expect(e and e.kind).toBe("query")
		expect(e and e.message).toContain("Unknown identifier 'nope'")
		local _, throttle =
			Transport.parseRestlet(http(200, "ns/errors/restlet-200-app-throttle.json"), RESTLET, json.decode)
		expect(throttle and throttle.kind).toBe("rate_limit")
	end)

	it("explains a missing row list instead of returning nothing", function()
		local _, e = Transport.parseRestlet({ status = 200, body = '{"ok":true}' }, RESTLET, json.decode)
		expect(e and e.code).toBe(Errors.BAD_RESPONSE)
		expect(e and e.message).toContain("rows_path")
		local _, notJson = Transport.parseRestlet({ status = 200, body = "<html>" }, RESTLET, json.decode)
		expect(notJson and notJson.kind).toBe("server")
	end)
end)

describe("query plans", function()
	local function plan(c: Config.Connection, sql: string, params: { any }?, maxRows: number?): Query.Plan
		local p, e =
			Query.plan({ connection = c, account_id = "1234567_SB1", sql = sql, params = params, max_rows = maxRows })
		assert(p, e and e.message)
		return p
	end

	it("refuses a write on a read-only connection before building any request", function()
		local p, e = Query.plan({ connection = conn("rest"), account_id = "1234567_SB1", sql = "DELETE FROM customer" })
		expect(p).toBeNil()
		expect(e and e.code).toBe(Errors.READ_ONLY)
		expect(e and e.kind).toBe("query")
	end)

	it("refuses an account id that could point a signed request elsewhere", function()
		local p = Query.plan({ connection = conn("rest"), account_id = "x.evil.com/", sql = "SELECT 1 FROM DUAL" })
		expect(p).toBeNil()
	end)

	it("pages REST results with offsets until hasMore is false", function()
		local p = plan(conn("rest"), "SELECT id, title FROM t", nil, 10)
		expect(Query.request(p).url).toContain("limit=10&offset=0")
		local s1 = Query.advance(p, http(200, "ns/rest/page1.json"), json.decode)
		assert(s1.kind == "next", "expected another page")
		expect(Query.request(s1.plan).url).toContain("limit=8&offset=2")
		local s2 = Query.advance(s1.plan, http(200, "ns/rest/page2.json"), json.decode)
		assert(s2.kind == "done", "expected the last page")
		expect(#s2.result.rows).toBe(3)
		expect(s2.result.rows[3].id).toBe("103")
		expect(s2.result.truncated).toBe(false)
		expect(s2.result.pages).toBe(2)
		expect(#p.pages).toBe(0)
	end)

	it("stops at max_rows and says the result was truncated", function()
		local p = plan(conn("rest"), "SELECT id, title FROM t", nil, 2)
		local s = Query.advance(p, http(200, "ns/rest/page1.json"), json.decode)
		assert(s.kind == "done", "expected done")
		expect(#s.result.rows).toBe(2)
		expect(s.result.truncated).toBe(true)
	end)

	it("never asks for more than 1000 rows per page or past the 100000-row offset cap", function()
		local p = plan(conn("rest"), "SELECT id FROM t", nil, 5000)
		expect(Query.request(p).url).toContain("limit=1000&")
		local far = table.clone(p)
		far.offset = 99500
		far.max_rows = 100000
		expect(Query.request(far).url).toContain("limit=500&offset=99500")
	end)

	it("binds parameters into the REST query and sends them as a list to a RESTlet", function()
		local rest = plan(conn("rest"), "SELECT id FROM t WHERE title = ?", { "a'b" })
		expect(json.decode(Query.request(rest).body).q).toBe("SELECT id FROM t WHERE title = 'a''b'")
		local rl = plan(conn("restlet"), "SELECT id FROM t WHERE title = ?", { "a'b" })
		expect(json.decode(Query.request(rl).body).params).toEqual({ "a'b" })
	end)

	it("takes a RESTlet's single answer as the whole result, capped at max_rows", function()
		local p = plan(conn("restlet"), "SELECT id FROM t", nil, 1)
		local s = Query.advance(p, http(200, "ns/restlet/rows.json"), json.decode)
		assert(s.kind == "done", "expected done")
		expect(#s.result.rows).toBe(1)
		expect(s.result.truncated).toBe(true)
	end)

	it("passes normalized errors through", function()
		local p = plan(conn("restlet"), "SELECT id FROM t")
		local s = Query.advance(p, http(403, "ns/errors/restlet-403-invalid-login.json"), json.decode)
		assert(s.kind == "error", "expected an error")
		expect(s.error.kind).toBe("auth")
	end)

	it("lets a connection with read_only = false send other statements", function()
		local p =
			Query.plan({ connection = conn("rest", false), account_id = "1234567_SB1", sql = "UPDATE x SET y = 1" })
		expect(p ~= nil).toBe(true)
	end)
end)

return nil
