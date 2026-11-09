--!strict
local Catalog = require("../../../plugin/lib/inspector/catalog")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local function kind(name: string): Catalog.Kind
	local k = Catalog.find(name)
	if k == nil then
		error("unknown " .. name)
	end
	return k
end

describe("record type catalog", function()
	it("maps the pages people paste from the NetSuite UI to the table that holds the record", function()
		local so = Catalog.fromPath("/app/accounting/transactions/salesord.nl") :: Catalog.Kind
		expect(so.record).toBe("salesorder")
		expect(so.table).toBe("transaction")
		expect((Catalog.fromPath("/app/common/entity/custjob.nl") :: Catalog.Kind).table).toBe("customer")
		expect((Catalog.fromPath("/app/common/entity/vendor.nl") :: Catalog.Kind).table).toBe("vendor")
		expect((Catalog.fromPath("/APP/Accounting/Transactions/CustInvc.nl") :: Catalog.Kind).record).toBe("invoice")
	end)

	it("reads every item page as the generic item, whatever item type the first entry is", function()
		local item = Catalog.fromPath("/app/common/item/item.nl") :: Catalog.Kind
		expect(item.record).toBe("item")
		expect(item.table).toBe("item")
	end)

	it("knows nothing about pages it has no mapping for, so it never guesses a table", function()
		expect(Catalog.fromPath("/app/center/card.nl")).toBeNil()
		expect(Catalog.find("nosuchtype")).toBeNil()
	end)

	it("accepts record types, SuiteQL tables, common aliases and custom record script ids", function()
		expect(kind("SalesOrder").record).toBe("salesorder")
		expect(kind("so").record).toBe("salesorder")
		expect(kind("transaction").record).toBe("transaction")
		expect(kind("class").table).toBe("classification")
		local box = kind("customrecord_acme_box")
		expect(box.family).toBe("customrecord")
		expect(box.table).toBe("customrecord_acme_box")
		expect(Catalog.find("customrecord_x; drop")).toBeNil()
	end)

	it("refines a generic transaction or item row to its specific type by its code", function()
		expect((Catalog.fromCode("transaction", "ItemShip") :: Catalog.Kind).record).toBe("itemfulfillment")
		expect((Catalog.fromCode("item", "InvtPart") :: Catalog.Kind).record).toBe("inventoryitem")
		expect(Catalog.fromCode("transaction", "Nope")).toBeNil()
	end)

	it("files transaction system notes under -30 and custom records under their numeric type", function()
		expect(kind("invoice").notes).toEqual({ -30 })
		expect(Catalog.customRecord("customrecord_acme_box", "Acme box", 12).notes).toEqual({ 12 })
		expect(Catalog.customRecord("customrecord_acme_box").notes).toEqual({})
	end)

	it("builds the record's UI URL on the account's own host", function()
		expect((Catalog.uiUrl(kind("salesorder"), "123", "1234567_SB1"))).toBe(
			"https://1234567-sb1.app.netsuite.com/app/accounting/transactions/salesord.nl?id=123"
		)
		expect((Catalog.uiUrl(kind("customer"), "42", "1234567"))).toBe(
			"https://1234567.app.netsuite.com/app/common/entity/custjob.nl?id=42"
		)
		expect((Catalog.uiUrl(Catalog.customRecord("customrecord_acme_box", nil, 12), "5", "1234567_SB1"))).toBe(
			"https://1234567-sb1.app.netsuite.com/app/common/custom/custrecordentry.nl?rectype=12&id=5"
		)
	end)

	it("cannot open a custom record before its numeric type is known, nor build a host from a bad id", function()
		local url, why = Catalog.uiUrl(Catalog.customRecord("customrecord_acme_box"), "5", "1234567_SB1")
		expect(url).toBeNil()
		expect(why).toContain("internal id")
		expect((Catalog.uiUrl(kind("invoice"), "1", "evil.example/x"))).toBeNil()
	end)

	it("reads the account back from a UI host so a pasted URL selects its connection", function()
		expect(Catalog.accountOfHost("1234567-sb1.app.netsuite.com")).toBe("1234567_SB1")
		expect(Catalog.accountOfHost("1234567.APP.netsuite.com")).toBe("1234567")
		expect(Catalog.accountOfHost("1234567.app.netsuite.com.evil.example")).toBeNil()
		expect(Catalog.accountOfHost("system.netsuite.com")).toBeNil()
	end)

	it("names the REST record type whose metadata labels a record's standard fields", function()
		expect(Catalog.restType(kind("salesorder"))).toBe("salesorder")
		expect(Catalog.restType(kind("customer"))).toBe("customer")
		expect(Catalog.restType(kind("class"))).toBe("classification")
		expect(Catalog.restType(kind("inventoryitem"))).toBe("inventoryitem")
		expect(Catalog.restType(kind("customrecord_acme_box"))).toBe("customrecord_acme_box")
	end)

	it("names no REST record type for generic kinds or items REST splits by sale and purchase", function()
		for _, name in { "transaction", "entity", "item", "noninventoryitem", "otherchargeitem", "serviceitem" } do
			expect(Catalog.restType(kind(name))).toBeNil()
		end
	end)
end)

return nil
