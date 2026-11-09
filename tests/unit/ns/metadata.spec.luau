--!strict
local Config = require("../../../plugin/lib/config")
local Encoding = require("../../../plugin/lib/ns/encoding")
local Errors = require("../../../plugin/lib/ns/errors")
local Metadata = require("../../../plugin/lib/ns/metadata")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local ACCOUNT = "1234567_SB1"
local URL = "https://1234567-sb1.suitetalk.api.netsuite.com/services/rest/record/v1/metadata-catalog/salesorder"

local function conn(transport: Config.Transport): Config.Connection
	return {
		id = "acme-" .. transport,
		account = "sb",
		auth = "tba",
		transport = transport,
		read_only = true,
		timeout_ms = 30000,
		restlet = if transport == "restlet"
			then {
				script = "customscript_acme_suiteql",
				deploy = "customdeploy_acme_suiteql",
				query_field = "query",
				params_field = "params",
				rows_path = "rows",
				extra = {},
			}
			else nil,
	}
end

local function schema(status: number?): Metadata.HttpResult
	return { status = status or 200, body = fixtures.read("inspector/metadata-salesorder.json") }
end

describe("record metadata request", function()
	it(
		"is a body-less GET of the record type's catalog entry asking for JSON Schema, which carries field titles",
		function()
			local req = Metadata.request(conn("rest"), ACCOUNT, "salesorder") :: Metadata.HttpRequest
			expect(req.method).toBe("GET")
			expect(req.url).toBe(URL)
			expect(req.body).toBe("")
			expect(req.headers.Accept).toBe("application/schema+json")
			expect(req.headers["Content-Type"]).toBeNil()
			expect(req.headers.Authorization).toBeNil()
			expect(Metadata.guard(req, ACCOUNT, "salesorder")).toBeNil()
		end
	)

	it("reads custom record types too, whose script ids are REST record types", function()
		local req = Metadata.request(conn("rest"), ACCOUNT, "customrecord_acme_box") :: Metadata.HttpRequest
		expect(req.url).toBe(
			"https://1234567-sb1.suitetalk.api.netsuite.com/services/rest/record/v1/metadata-catalog/customrecord_acme_box"
		)
	end)

	it("is refused for RESTlet connections, which cannot reach the REST record service", function()
		local req, err = Metadata.request(conn("restlet"), ACCOUNT, "salesorder")
		expect(req).toBeNil()
		expect((err :: Errors.NsError).code).toBe(Errors.REST_ONLY)
		expect((err :: Errors.NsError).message).toContain("RESTlet")
	end)

	it("refuses record types that could change the path or add a query", function()
		for _, bad in { "", "../query/v1/suiteql", "salesorder?select=x", "sales order", "SalesOrder/1", "a%2f" } do
			local req, err = Metadata.request(conn("rest"), ACCOUNT, bad)
			expect(req).toBeNil()
			expect((err :: Errors.NsError).kind).toBe("query")
		end
		expect(Metadata.validType(string.rep("a", 101))).toBe(false)
	end)
end)

describe("record metadata guard", function()
	local good = Metadata.request(conn("rest"), ACCOUNT, "salesorder") :: Metadata.HttpRequest

	it("never lets anything but GET reach the metadata path", function()
		for _, method in { "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "get" } do
			local req = table.clone(good)
			req.method = method
			expect((Metadata.guard(req, ACCOUNT, "salesorder") :: Errors.NsError).message).toContain("GET")
		end
	end)

	it("refuses a request with a body", function()
		local req = table.clone(good)
		req.body = "{}"
		expect(Metadata.guard(req, ACCOUNT, "salesorder") ~= nil).toBe(true)
	end)

	it("refuses any URL but the catalog entry of that account and record type", function()
		for _, url in
			{
				"https://1234567-sb1.suitetalk.api.netsuite.com/services/rest/record/v1/salesorder/123",
				"https://1234567-sb1.suitetalk.api.netsuite.com/services/rest/query/v1/suiteql",
				URL .. "?select=customer",
				"https://1234567.suitetalk.api.netsuite.com/services/rest/record/v1/metadata-catalog/salesorder",
				"https://1234567-sb1.suitetalk.api.netsuite.com/services/rest/record/v1/metadata-catalog/customer",
			}
		do
			local req = table.clone(good)
			req.url = url
			expect(Metadata.guard(req, ACCOUNT, "salesorder") ~= nil).toBe(true)
		end
	end)
end)

describe("record metadata answer", function()
	it("maps each top-level field's lower-case name to its title, as SuiteQL columns are lower case", function()
		local labels = Metadata.parse(schema(), json.decode) :: Metadata.Labels
		expect(labels.tranid).toBe("Order #")
		expect(labels.trandate).toBe("Date")
		expect(labels.entity).toBe("Customer")
		expect(labels.createdfrom).toBe("Created From")
		expect(labels.custbody_acme_channel).toBe("Sales channel")
		expect(labels.id).toBe("Internal ID")
	end)

	it("skips REST-only members and untitled fields, and flattens whitespace in titles", function()
		local labels = Metadata.parse(schema(), json.decode) :: Metadata.Labels
		expect(labels.links).toBeNil()
		expect(labels.shipdate).toBeNil()
		expect(labels.billaddress).toBe("Billing address")
		-- nested sublist and reference members are not record fields
		expect(labels.refname).toBeNil()
	end)

	it("reports NetSuite's error, e.g. a record type the REST service does not expose", function()
		local labels, err = Metadata.parse({
			status = 404,
			body = '{"title":"Not Found","status":404,"o:errorDetails":[{"detail":"Record type \'noninventoryitem\' was not found.","o:errorCode":"NONEXISTENT_ID"}]}',
		}, json.decode)
		expect(labels).toBeNil()
		expect((err :: Errors.NsError).status).toBe(404)
		expect((err :: Errors.NsError).message).toContain("noninventoryitem")
	end)

	it("refuses an answer that is not a JSON Schema object", function()
		local _, err = Metadata.parse({ status = 200, body = '{"items":[]}' }, json.decode)
		expect((err :: Errors.NsError).code).toBe(Errors.BAD_RESPONSE)
		local _, err2 = Metadata.parse({ status = 200, body = "<html>" }, json.decode)
		expect((err2 :: Errors.NsError).code).toBe(Errors.BAD_RESPONSE)
	end)

	it("keeps only string labels from untrusted JSON (spool answers, cache files)", function()
		local labels = Metadata.clean({ tranid = "Order #", bad = 5, [1] = "x", memo = "", Entity = "Customer" })
		expect(labels).toEqual({ tranid = "Order #", entity = "Customer" })
		expect(Metadata.clean("nope")).toEqual({})
	end)
end)

describe("record metadata cache", function()
	local labels = { tranid = "Order #", memo = "Memo" }

	it("keeps one file per account and record type under the plugin data directory", function()
		expect(Metadata.cachePath("/data", ACCOUNT, "salesorder")).toBe("/data/metadata/1234567_SB1/salesorder.json")
		expect(Metadata.cachePath("/data", "1234567_sb1", "salesorder")).toBe(
			"/data/metadata/1234567_SB1/salesorder.json"
		)
		expect(Metadata.cachePath("/data", "../x", "salesorder")).toBeNil()
		expect(Metadata.cachePath("/data", ACCOUNT, "../x")).toBeNil()
	end)

	it("serves labels for a week, then asks NetSuite again", function()
		local text = Encoding.json(Metadata.cacheEntry(ACCOUNT, "salesorder", labels, 1000))
		local entry = Metadata.readCache(text, ACCOUNT, "salesorder", 1000 + Metadata.TTL_SECONDS, json.decode)
		expect(entry and entry.labels).toEqual(labels)
		expect(entry and entry.fetched).toBe(1000)
		expect(Metadata.readCache(text, ACCOUNT, "salesorder", 1001 + Metadata.TTL_SECONDS, json.decode)).toBeNil()
	end)

	it("ignores a file written for another account or record type, or from the future", function()
		local text = Encoding.json(Metadata.cacheEntry(ACCOUNT, "salesorder", labels, 1000))
		expect(Metadata.readCache(text, "1234567", "salesorder", 1000, json.decode)).toBeNil()
		expect(Metadata.readCache(text, ACCOUNT, "invoice", 1000, json.decode)).toBeNil()
		expect(Metadata.readCache(text, ACCOUNT, "salesorder", 900, json.decode)).toBeNil()
		expect(Metadata.readCache("{", ACCOUNT, "salesorder", 1000, json.decode)).toBeNil()
	end)
end)

return nil
