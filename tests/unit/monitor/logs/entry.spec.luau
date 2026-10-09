--!strict
local Entry = require("../../../../plugin/lib/monitor/logs/entry")
local fixtures = require("../../../lib/fixtures")
local json = require("../../../lib/json")
local t = require("../../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local restlet = json.decode(fixtures.read("monitor/logs/restlet-rows.json"))
local rest = json.decode(fixtures.read("monitor/logs/rest-rows.json"))

describe("execution log entries", function()
	it("reads typed RESTlet rows and all-string REST rows the same way", function()
		local a = Entry.fromRow(restlet[1]) :: Entry.Entry
		local b = Entry.fromRow(rest[1]) :: Entry.Entry
		expect(a.id).toBe(5771427)
		expect(b.id).toBe(5771427)
		expect(b.script).toBe(3561)
		expect(a.script).toBe(b.script)
		expect(b.scriptId).toBe("customscript_demo_suiteql")
		expect(b.logged).toBe("2026-10-08 22:15:40")
	end)

	it("drops rows without a numeric internal id, since they cannot be deduplicated", function()
		expect(Entry.fromRow({ internalid = "abc", title = "x" })).toBeNil()
		expect(Entry.fromRow({ title = "x" })).toBeNil()
		expect(Entry.fromRow("not a row")).toBeNil()
	end)

	it("keeps a row whose script did not join, showing the numeric script id", function()
		local e = Entry.fromRow(restlet[7]) :: Entry.Entry
		expect(e.scriptId).toBeNil()
		expect(e.scriptName).toBeNil()
		expect(Entry.scriptLabel(e)).toBe("script 4902")
	end)

	local function split(title: string): { ns: string?, event: string }
		local ns, event = Entry.splitTitle(title)
		return { ns = ns, event = event }
	end

	it("splits namespace:event titles at the last colon so nested namespaces stay together", function()
		expect(split("suiteql:exec.start")).toEqual({ ns = "suiteql", event = "exec.start" })
		expect(split("storefront:order-metrics:list.start")).toEqual({
			ns = "storefront:order-metrics",
			event = "list.start",
		})
	end)

	it("does not mistake prose or plain codes for a namespace", function()
		for _, title in { "Error: sync failed", "JS_EXCEPTION", "restlet.error", ":x", "a:" } do
			expect(split(title)).toEqual({ event = title })
		end
	end)

	it("orders levels DEBUG < AUDIT < ERROR < EMERGENCY with uncaught SYSTEM errors at ERROR", function()
		expect(Entry.rank("DEBUG") < Entry.rank("AUDIT")).toBe(true)
		expect(Entry.rank("AUDIT") < Entry.rank("ERROR")).toBe(true)
		expect(Entry.rank("ERROR") < Entry.rank("EMERGENCY")).toBe(true)
		expect(Entry.rank("SYSTEM")).toBe(Entry.rank("ERROR"))
		expect(Entry.rank("debug")).toBe(Entry.rank("DEBUG"))
	end)

	it("shows unknown levels at the audit threshold rather than hiding them", function()
		expect(Entry.rank("SOMETHING_NEW")).toBe(Entry.rank("AUDIT"))
	end)
end)

return nil
