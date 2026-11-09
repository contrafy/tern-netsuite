--!strict
local Catalog = require("../../../plugin/lib/inspector/catalog")
local Ref = require("../../../plugin/lib/inspector/ref")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local function parsed(text: string, kind: Catalog.Kind?): Ref.Ref
	local r, err = Ref.parse(text, kind)
	if r == nil then
		error("rejected: " .. tostring(err))
	end
	return r
end

local function rejected(text: string, kind: Catalog.Kind?): string
	local r, err = Ref.parse(text, kind)
	expect(r).toBeNil()
	return err or ""
end

describe("record references", function()
	it("opens a transaction URL pasted from the browser, remembering its account", function()
		local r =
			parsed("  https://1234567-sb1.app.netsuite.com/app/accounting/transactions/salesord.nl?id=123&whence=  ")
		expect((r.kind :: Catalog.Kind).record).toBe("salesorder")
		expect(r.id).toBe("123")
		expect(r.account).toBe("1234567_SB1")
	end)

	it("opens customer and custom record URLs; a custom record names its type by number", function()
		local c = parsed("https://1234567.app.netsuite.com/app/common/entity/custjob.nl?id=42&e=T")
		expect((c.kind :: Catalog.Kind).table).toBe("customer")
		expect(c.account).toBe("1234567")
		local box = parsed("https://1234567-sb1.app.netsuite.com/app/common/custom/custrecordentry.nl?rectype=12&id=5")
		expect(box.kind).toBeNil()
		expect(box.rectype).toBe(12)
		expect(box.id).toBe("5")
	end)

	it("accepts type:id for record types, tables and custom records", function()
		expect((parsed("salesorder:123").kind :: Catalog.Kind).record).toBe("salesorder")
		expect((parsed("Customer : 42").kind :: Catalog.Kind).table).toBe("customer")
		expect((parsed("customrecord_acme_box:5").kind :: Catalog.Kind).family).toBe("customrecord")
	end)

	it("types a bare id only when the caller knows the type", function()
		expect(rejected("123")).toContain("salesorder:123")
		expect((parsed("123", Catalog.find("invoice")).kind :: Catalog.Kind).record).toBe("invoice")
	end)

	it("refuses hosts that are not NetSuite UI hosts, so a look-alike URL selects no account", function()
		expect(rejected("https://1234567.app.netsuite.com.evil.example/app/accounting/transactions/salesord.nl?id=1")).toContain(
			"not a NetSuite UI host"
		)
		expect(rejected("https://example.com/app/accounting/transactions/salesord.nl?id=1")).toContain(
			"not a NetSuite UI host"
		)
	end)

	it("explains what is missing instead of guessing", function()
		expect(rejected("https://1234567.app.netsuite.com/app/accounting/transactions/salesord.nl")).toContain(
			"no record id"
		)
		expect(rejected("https://1234567.app.netsuite.com/app/common/custom/custrecordentry.nl?id=5")).toContain(
			"rectype"
		)
		expect(rejected("https://1234567.app.netsuite.com/app/center/card.nl?id=5")).toContain("type:id")
		expect(rejected("salesorder:abc")).toContain("internal id")
		expect(rejected("salesorder:0")).toContain("internal id")
		expect(rejected("widget:5")).toContain("unknown record type")
		expect(rejected("")).toContain("type:id")
		expect(rejected("so:1\tx")).toContain("control character")
	end)

	it("prints a reference back as text the input can parse again", function()
		expect(Ref.text(parsed("so:9"))).toBe("salesorder:9")
		local box = parsed("https://1234567-sb1.app.netsuite.com/app/common/custom/custrecordentry.nl?rectype=12&id=5")
		local again = parsed(Ref.text(box))
		expect(again.rectype).toBe(12)
		expect(again.account).toBe("1234567_SB1")
	end)
end)

return nil
