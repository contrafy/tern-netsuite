--!strict
local Query = require("../../../plugin/lib/deployments/query")
local Sql = require("../../../plugin/lib/ns/sql")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local function items(path: string): { any }
	return json.decode(fixtures.read("deployments/" .. path)).items
end

describe("deployment queries", function()
	it("pass the read-only guard, so they run on default (read-only) connections", function()
		expect((Sql.readOnly(Query.LIST_SQL))).toBe(true)
		expect((Sql.readOnly(Query.ACTIVITY_SQL))).toBe(true)
	end)

	it("read the internal ids the NetSuite pages need", function()
		expect(Query.LIST_SQL).toContain("d.primarykey AS id")
		expect(Query.LIST_SQL).toContain("d.script AS script_id")
	end)

	it("count only the last 24 hours of log lines per script", function()
		expect(Query.ACTIVITY_SQL).toContain("n.date >= SYSDATE - 1")
		expect(Query.ACTIVITY_SQL).toContain("GROUP BY n.scripttype")
	end)
end)

describe("deployment rows", function()
	it("models every REST row with its ids, status and log level", function()
		local list = Query.fromRows(items("list-rest.json"))
		expect(#list).toBe(5)
		expect(list[3]).toEqual({
			key = "customscript_acme_order_ue:customdeploy_acme_order_ue",
			id = 203,
			scriptId = "customdeploy_acme_order_ue",
			title = "Order Guard",
			status = "RELEASED",
			deployed = true,
			logLevel = "DEBUG",
			recordType = "SALESORDER",
			scriptInternalId = 103,
			script = "customscript_acme_order_ue",
			scriptName = "Acme Order Guard",
			scriptType = "USEREVENT",
		})
	end)

	it("keeps a not-deployed deployment apart from its status", function()
		local d = Query.fromRows(items("list-rest.json"))[4]
		expect(d.status).toBe("TESTING")
		expect(d.deployed).toBe(false)
	end)

	it("accepts RESTlet rows with numbers, booleans and nulls", function()
		local d = Query.fromRow({
			id = 7,
			scriptid = "CUSTOMDEPLOY_X",
			isdeployed = true,
			status = "released",
			loglevel = "audit",
			recordtype = json.null,
			script_id = 3,
		})
		expect(d).toEqual({
			key = ":customdeploy_x",
			id = 7,
			scriptId = "customdeploy_x",
			title = "",
			status = "RELEASED",
			deployed = true,
			logLevel = "AUDIT",
			scriptInternalId = 3,
		})
	end)

	it("skips rows without a deployment id rather than showing a blank row", function()
		expect(Query.fromRow({ title = "x" })).toBeNil()
		expect(Query.fromRow("x")).toBeNil()
	end)

	it("indexes 24 h activity by script internal id", function()
		local a = Query.activity(items("activity-rest.json"))
		expect(a[101]).toEqual({ total = 42, errors = 3 })
		expect(a[103]).toEqual({ total = 7, errors = 0 })
		expect(a[102]).toBeNil()
	end)

	it("labels script types and shows unknown codes as they are", function()
		expect(Query.typeLabel("MAPREDUCE")).toBe("Map/Reduce")
		expect(Query.typeLabel("SOMETHINGNEW")).toBe("SOMETHINGNEW")
		expect(Query.typeLabel(nil)).toBe("?")
	end)
end)

return nil
