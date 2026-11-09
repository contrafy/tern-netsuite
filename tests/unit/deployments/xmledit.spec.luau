--!strict
local Values = require("../../../plugin/lib/deployments/values")
local XmlEdit = require("../../../plugin/lib/deployments/xmledit")
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local MR = fixtures.read("deployments/customscript_acme_billing_sync.xml")
local UE = fixtures.read("deployments/customscript_acme_order_ue.xml")

local function lines(text: string): { string }
	local out: { string } = {}
	for l in string.gmatch(text, "([^\n]*)\n") do
		table.insert(out, l)
	end
	return out
end

-- Lines that differ between two texts with the same line count.
local function changed(a: string, b: string): { number }
	local la, lb = lines(a), lines(b)
	local out: { number } = {}
	expect(#la).toBe(#lb)
	for i = 1, #la do
		if la[i] ~= lb[i] then
			table.insert(out, i)
		end
	end
	return out
end

describe("locating a deployment in an object file", function()
	it("reads the type, current values and schedule of the deployment, not of a commented-out copy", function()
		local tg = XmlEdit.locate(MR, "customdeploy_acme_billing_sync")
		assert(tg, "target")
		expect(tg.tag).toBe("mapreducescript")
		expect(tg.values).toEqual({ loglevel = "AUDIT", status = "NOTSCHEDULED" })
		expect(tg.recurrence).toBe(true)
		expect(tg.spans.loglevel.line).toBe(17)
	end)

	it("tells deployments of one object apart", function()
		local tg = XmlEdit.locate(MR, "customdeploy_acme_billing_sync_adhoc")
		assert(tg, "target")
		expect(tg.values).toEqual({ loglevel = "ERROR", status = "NOTSCHEDULED" })
		expect(tg.recurrence).toBe(false)
		expect(tg.spans.loglevel.line).toBe(33)
	end)

	it("matches the deployment id case-insensitively, as NetSuite does", function()
		expect(XmlEdit.locate(UE, "CUSTOMDEPLOY_ACME_ORDER_UE") ~= nil).toBe(true)
	end)

	it("refuses a file without the deployment or one that does not parse", function()
		local _, why = XmlEdit.locate(UE, "customdeploy_missing")
		expect(why).toContain("no deployment customdeploy_missing")
		local _, perr = XmlEdit.locate("<usereventscript>", "customdeploy_x")
		expect(perr).toContain("does not parse")
	end)

	it("refuses two deployments with the same id instead of guessing", function()
		local twice = string.gsub(UE, "customdeploy_acme_order_ue_po", "customdeploy_acme_order_ue")
		local _, why = XmlEdit.locate(twice, "customdeploy_acme_order_ue")
		expect(why).toContain("2 deployments")
	end)

	it("refuses values with entities, which a text edit could corrupt", function()
		local odd = string.gsub(UE, "<status>RELEASED</status>", "<status>&#82;ELEASED</status>")
		local _, why = XmlEdit.locate(odd, "customdeploy_acme_order_ue")
		expect(why).toContain("entities")
	end)
end)

describe("planning an edit", function()
	it("changes only the value on its line and keeps every other byte", function()
		local tg = XmlEdit.locate(MR, "customdeploy_acme_billing_sync")
		assert(tg, "target")
		local plan = XmlEdit.plan(MR, tg, "loglevel", "DEBUG")
		assert(plan, "plan")
		expect(plan.line).toBe(17)
		expect(plan.before).toBe("      <loglevel>AUDIT</loglevel>")
		expect(plan.after).toBe("      <loglevel>DEBUG</loglevel>")
		expect(changed(MR, plan.text)).toEqual({ 17 })
		expect(#plan.text).toBe(#MR)
	end)

	it("keeps the whitespace around a padded value and the tab indentation", function()
		local tg = XmlEdit.locate(UE, "customdeploy_acme_order_ue")
		assert(tg, "target")
		expect(tg.values.loglevel).toBe("DEBUG")
		local plan = XmlEdit.plan(UE, tg, "loglevel", "ERROR")
		assert(plan, "plan")
		expect(plan.after).toBe("\t\t\t<loglevel> ERROR </loglevel>")
		expect(changed(UE, plan.text)).toEqual({ 11 })
	end)

	it("keeps CRLF line endings", function()
		local crlf = string.gsub(UE, "\n", "\r\n")
		local tg = XmlEdit.locate(crlf, "customdeploy_acme_order_ue")
		assert(tg, "target")
		local plan = XmlEdit.plan(crlf, tg, "status", "TESTING")
		assert(plan, "plan")
		expect(plan.after).toBe("\t\t\t<status>TESTING</status>")
		expect(select(2, string.gsub(plan.text, "\r\n", ""))).toBe(select(2, string.gsub(crlf, "\r\n", "")))
	end)

	it("offers SCHEDULED only to a deployment that has a schedule", function()
		local scheduled = XmlEdit.locate(MR, "customdeploy_acme_billing_sync")
		local adhoc = XmlEdit.locate(MR, "customdeploy_acme_billing_sync_adhoc")
		assert(scheduled and adhoc, "targets")
		expect(XmlEdit.plan(MR, scheduled, "status", "SCHEDULED") ~= nil).toBe(true)
		local _, why = XmlEdit.plan(MR, adhoc, "status", "SCHEDULED")
		expect(why).toContain("SCHEDULED is not a status")
	end)

	it("refuses values SDF or the script type do not allow", function()
		local tg = XmlEdit.locate(UE, "customdeploy_acme_order_ue")
		assert(tg, "target")
		local _, a = XmlEdit.plan(UE, tg, "status", "NOTSCHEDULED")
		expect(a).toContain("not a status")
		local _, b = XmlEdit.plan(UE, tg, "loglevel", "SYSTEM")
		expect(b).toContain("not a log level")
	end)

	it("refuses a no-op and an element the deployment lacks", function()
		local tg = XmlEdit.locate(UE, "customdeploy_acme_order_ue_po")
		assert(tg, "target")
		local _, same = XmlEdit.plan(UE, tg, "status", "TESTING")
		expect(same).toContain("already TESTING")
		local _, absent = XmlEdit.plan(UE, tg, "loglevel", "AUDIT")
		expect(absent).toContain("no <loglevel> element")
	end)
end)

describe("allowed values", function()
	it("offers the UI's log levels for every script type", function()
		expect((Values.allowed("restlet", "loglevel", false))).toEqual({ "DEBUG", "AUDIT", "ERROR", "EMERGENCY" })
	end)

	it("offers queued statuses to scheduled and map/reduce scripts and release states to the rest", function()
		expect((Values.allowed("scheduledscript", "status", false))).toEqual({ "NOTSCHEDULED", "TESTING" })
		expect((Values.allowed("mapreducescript", "status", true))).toEqual({ "NOTSCHEDULED", "SCHEDULED", "TESTING" })
		expect((Values.allowed("suitelet", "status", true))).toEqual({ "TESTING", "RELEASED" })
	end)

	it("refuses objects that are not scripts", function()
		local v, why = Values.allowed("customrecordtype", "status", false)
		expect(v).toBeNil()
		expect(why).toContain("not a script object")
	end)
end)

return nil
