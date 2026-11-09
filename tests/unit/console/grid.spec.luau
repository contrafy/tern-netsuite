--!strict
local Grid = require("../../../plugin/lib/console/grid")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect
local null = json.null

describe("console values", function()
	it("shows REST strings as sent and RESTlet numbers and booleans as values", function()
		expect(Grid.cell("0012.50", null)).toBe("0012.50")
		expect(Grid.kind("0012.50", null)).toBe("string")
		expect(Grid.cell(12.5, null)).toBe("12.5")
		expect(Grid.cell(101, null)).toBe("101")
		expect(Grid.kind(101, null)).toBe("number")
		expect(Grid.cell(false, null)).toBe("false")
		expect(Grid.kind(false, null)).toBe("boolean")
	end)

	it("shows a missing member as NULL, since JSON decoding drops null members", function()
		local row = json.decode('{"id": 1, "email": null}')
		expect(Grid.kind(row.email, null)).toBe("null")
		expect(Grid.cell(row.email, null)).toBe("null")
		expect(Grid.text(row.email, null)).toBeNil()
	end)

	it("keeps a cell on one line and shows nested values as JSON", function()
		expect(Grid.cell("line 1\nline 2", null)).toBe("line 1⏎line 2")
		expect(Grid.cell({ b = 1, a = { true, null } :: { any } }, null)).toBe('{"a":[true,null],"b":1}')
	end)

	it("fits text to a column, cutting with an ellipsis and padding numbers on the left", function()
		expect(Grid.fit("Acme Corporation", 6)).toBe("Acme …")
		expect(Grid.fit("12", 5, true)).toBe("   12")
		expect(Grid.fit("é", 3)).toBe("é  ")
	end)

	it("sizes columns by header and widest sampled cell, within bounds", function()
		local rows: { any } = { { id = "1", memo = string.rep("x", 90) }, { id = "12345" } }
		expect(Grid.widths({ "id", "memo" }, rows, null)).toEqual({ 5, Grid.MAX_WIDTH })
	end)
end)

describe("console sorting and filtering", function()
	local rows: { any } = {
		{ id = "10", name = "beta" },
		{ id = "9", name = "Alpha" },
		{ name = "gamma" },
		{ id = "100", name = "alpha" },
	}

	it("sorts numeric strings as numbers, since REST sends every number as text", function()
		expect(Grid.order(rows, "id", "asc", nil, null)).toEqual({ 2, 1, 4, 3 })
		expect(Grid.order(rows, "id", "desc", nil, null)).toEqual({ 4, 1, 2, 3 })
	end)

	it("sorts text case-insensitively and stably, NULLs last both ways", function()
		expect(Grid.order(rows, "name", "asc", nil, null)).toEqual({ 2, 4, 1, 3 })
		expect(Grid.order(rows, "nothing", "desc", nil, null)).toEqual({ 1, 2, 3, 4 })
	end)

	it("keeps NetSuite's order without a sort column", function()
		expect(Grid.order(rows, nil, "asc", nil, null)).toEqual({ 1, 2, 3, 4 })
	end)

	it("filters on every word, in any cell, ignoring case", function()
		local cols = { "id", "name" }
		local words = Grid.words("ALPHA 10")
		local keep = function(i: number): boolean
			return Grid.matches(Grid.haystack(rows[i], cols, null), words)
		end
		expect(Grid.order(rows, nil, "asc", keep, null)).toEqual({ 4 })
	end)
end)

describe("console windows", function()
	it("draws at most a window of rows around the selection", function()
		expect({ Grid.window(1, 1000, 1, 200) }).toEqual({ 1, 200 })
		expect({ Grid.window(500, 1000, 1, 200) }).toEqual({ 303, 502 })
		expect({ Grid.window(1000, 1000, 303, 200) }).toEqual({ 801, 1000 })
	end)

	it("scrolls columns sideways so the current column shows", function()
		local widths = { 10, 10, 10, 10 }
		expect({ Grid.columnWindow(widths, 1, 1, 28) }).toEqual({ 1, 3 })
		expect({ Grid.columnWindow(widths, 4, 1, 28) }).toEqual({ 3, 4 })
		expect({ Grid.columnWindow(widths, 2, 3, 28) }).toEqual({ 2, 4 })
		expect({ Grid.columnWindow(widths, 1, 1, 25) }).toEqual({ 1, 2 })
	end)
end)

describe("console record ids", function()
	it("offers ids of the id column and *id columns, not text ids like tranid", function()
		local row = { id = "42", entityid = "ACME-1", tranid = "SO100", parentid = 7, createdbyid = "x" }
		expect(Grid.idCells(row, { "tranid", "parentid", "id", "entityid", "createdbyid" })).toEqual({
			{ column = "id", id = "42" },
			{ column = "parentid", id = "7" },
		})
	end)

	it("reads ids from the REST fixture rows", function()
		local doc = json.decode(fixtures.read("ns/rest/page1.json"))
		expect(Grid.idCells(doc.items[1], { "id", "title" })).toEqual({ { column = "id", id = "101" } })
	end)
end)

return nil
