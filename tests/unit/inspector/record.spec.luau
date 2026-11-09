--!strict
local Catalog = require("../../../plugin/lib/inspector/catalog")
local Record = require("../../../plugin/lib/inspector/record")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local null = json.null
local so = json.decode(fixtures.read("inspector/salesorder-rest.json"))[1]

local function kind(name: string): Catalog.Kind
	return Catalog.find(name) :: Catalog.Kind
end

describe("inspected record", function()
	it("lists id first, then standard and custom fields, leaving out REST's links member", function()
		local fields = Record.fields(so, null)
		expect(fields[1]).toEqual({ column = "id", value = "123" })
		local names: { string } = {}
		for _, f in fields do
			table.insert(names, f.column)
		end
		expect(table.find(names, "links")).toBeNil()
		expect(names[#names]).toBe("custbody_acme_empty")
		local tranAt, boxAt = table.find(names, "tranid") or 0, table.find(names, "custbody_acme_box") or 0
		expect(tranAt > 0 and tranAt < boxAt).toBe(true)
	end)

	it("reads RESTlet typed values and nulls the same way as REST strings", function()
		expect(Record.text(5, null)).toBe("5")
		expect(Record.text(2.5, null)).toBe("2.5")
		expect(Record.text(true, null)).toBe("T")
		expect(Record.text(null, null)).toBeNil()
		expect(Record.text("", null)).toBeNil()
		local fields = Record.fields({ id = 7, memo = null, custbody_x = false }, null)
		expect(Record.value(fields, "id")).toBe("7")
		expect(Record.value(fields, "memo")).toBeNil()
		expect(Record.value(fields, "custbody_x")).toBe("F")
	end)

	it("shows a generic transaction row as its real type so the UI link and label are right", function()
		local fields = Record.fields(so, null)
		expect(Record.refine(kind("transaction"), fields).record).toBe("salesorder")
		expect(Record.refine(kind("invoice"), fields).record).toBe("salesorder")
		expect(Record.title(fields)).toBe("SO-1001")
	end)

	it("links the records a transaction points at, including custom fields pointing at custom records", function()
		local fields = Record.fields(so, null)
		local labels = Record.labels(json.decode(fixtures.read("inspector/labels-rest.json")), null)
		expect(labels.custbody_acme_channel).toEqual({ label = "Sales channel" })
		local refs = Record.references(kind("salesorder"), fields, labels)
		local byKey: { [string]: Record.Related } = {}
		for _, r in refs do
			byKey[r.key] = r
		end
		expect(byKey["f:entity"].record).toBe("entity")
		expect(byKey["f:entity"].id).toBe("42")
		expect(byKey["f:createdfrom"]).toBeNil()
		expect(byKey["f:custbody_acme_box"]).toEqual({
			key = "f:custbody_acme_box",
			label = "Shipping box",
			record = "customrecord_acme_box",
			id = "5",
		})
		local named =
			Record.named(refs, Record.display(json.decode(fixtures.read("inspector/display-rest.json")), null))
		for _, r in named do
			if r.key == "f:entity" then
				expect(r.name).toBe("Acme Retail Co")
			end
		end
	end)

	it("points a custom record's parent at its own type", function()
		local fields = Record.fields(json.decode(fixtures.read("inspector/customrecord-rest.json"))[1], null)
		local refs = Record.references(Catalog.customRecord("customrecord_acme_box", "Acme box", 12), fields, {})
		expect(refs[1]).toEqual({ key = "f:parent", label = "Parent", record = "customrecord_acme_box", id = "2" })
		expect(refs[2].record).toBe("employee")
	end)

	it("reads system notes with who, when and old -> new values", function()
		local notes = Record.notes(json.decode(fixtures.read("inspector/notes-restlet.json")), null)
		expect(notes[1]).toEqual({
			id = "9002",
			noted = "2026-10-08 22:16:02",
			who = "Ada Admin",
			role = "Administrator",
			context = "UI",
			action = "Change",
			field = "TRANDOC.KSTATUS",
			old = "Pending Approval",
			new = "Pending Fulfillment",
		})
		expect(notes[2].field).toBeNil()
	end)

	it("links each distinct line item once and labels linked transactions by type", function()
		local lines = Record.lines(json.decode(fixtures.read("inspector/lines-rest.json")), null)
		expect(#lines).toBe(3)
		local items = Record.lineItems(lines)
		expect(#items).toBe(2)
		expect(items[1]).toEqual({
			key = "item:7",
			label = "Line item",
			record = "item",
			id = "7",
			name = "Acme widget",
		})
		local back =
			Record.transactions(json.decode(fixtures.read("inspector/children-rest.json")), "Created from this", null)
		expect(back[1].record).toBe("itemfulfillment")
		expect(back[1].name).toBe("Item fulfillment IF-2001 (Shipped)")
	end)
end)

return nil
