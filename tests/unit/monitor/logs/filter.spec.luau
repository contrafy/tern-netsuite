--!strict
local Entry = require("../../../../plugin/lib/monitor/logs/entry")
local Filter = require("../../../../plugin/lib/monitor/logs/filter")
local fixtures = require("../../../lib/fixtures")
local json = require("../../../lib/json")
local t = require("../../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local all: { Entry.Entry } = {}
for _, r in json.decode(fixtures.read("monitor/logs/restlet-rows.json")) do
	table.insert(all, Entry.fromRow(r) :: Entry.Entry)
end

local function matching(text: string, minRank: number?): { number }
	local f = Filter.parse(text)
	local out = {}
	for _, e in all do
		if Filter.matches(e, f, minRank or 1) then
			table.insert(out, e.id)
		end
	end
	table.sort(out)
	return out
end

describe("log filters", function()
	it("shows everything with an empty filter at the debug level", function()
		expect(#matching("")).toBe(#all)
	end)

	it("hides rows below the chosen level", function()
		expect(matching("", Entry.rank("ERROR"))).toEqual({ 5771027, 5771131, 5771329 })
		expect(matching("", Entry.rank("EMERGENCY"))).toEqual({})
	end)

	it("matches every word, case-insensitively, in the title or the detail", function()
		expect(matching("duplicate ALIAS")).toEqual({ 5771329 })
		expect(matching("exec.start")).toEqual({ 5771328, 5771426 })
		expect(matching("duplicate exec.start")).toEqual({})
	end)

	it("matches a title namespace by prefix", function()
		expect(matching("ns:suiteql")).toEqual({ 5771328, 5771426, 5771427 })
		expect(matching("ns:storefront")).toEqual({ 5771130 })
		expect(matching("ns:storefront:order")).toEqual({ 5771130 })
		expect(matching("ns:order")).toEqual({})
	end)

	it("matches a script by script id, name or numeric id", function()
		expect(matching("script:customscript_demo_storefront_api")).toEqual({ 5771130 })
		expect(matching("script:bank")).toEqual({ 5771027 })
		expect(matching("script:4902")).toEqual({ 5771131 })
	end)

	it("treats literal pattern characters as text, never as Lua patterns", function()
		expect(matching("%d+")).toEqual({})
		expect(matching("(")).toEqual({ 5771027, 5771131, 5771329 })
	end)

	it("reports whether anything is filtered so the view can say so", function()
		expect(Filter.isEmpty(Filter.parse("   "))).toBe(true)
		expect(Filter.isEmpty(Filter.parse("ns:x"))).toBe(false)
	end)
end)

return nil
