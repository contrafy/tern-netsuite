--!strict
local Export = require("../../../plugin/lib/console/export")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect
local null = json.null

local columns = { "id", "companyname", "balance", "memo" }
local rows: { any } = {
	{ id = "101", companyname = "Acme, Inc", balance = 12.5, memo = 'says "hi"\nthen\tleaves' },
	{ id = "102", companyname = " Globex" },
}

describe("console exports", function()
	it("writes CSV that spreadsheets read back: quoted commas, quotes, line breaks and edge spaces", function()
		expect(Export.csv(columns, rows, { 1, 2 }, null)).toBe(
			'id,companyname,balance,memo\n101,"Acme, Inc",12.5,"says ""hi""\nthen\tleaves"\n102," Globex",,\n'
		)
	end)

	it("writes TSV with one line per row, escaping tabs and line breaks", function()
		expect(Export.tsv(columns, rows, { 2, 1 }, null)).toBe(
			'id\tcompanyname\tbalance\tmemo\n102\t Globex\t\t\n101\tAcme, Inc\t12.5\tsays "hi"\\nthen\\tleaves\n'
		)
	end)

	it("writes JSON in column order with values as NetSuite sent them and NULL as null", function()
		local text = Export.json(columns, rows, { 1, 2 }, null)
		expect(text).toBe(
			'[\n  {"id":"101","companyname":"Acme, Inc","balance":12.5,"memo":"says \\"hi\\"\\nthen\\tleaves"},\n'
				.. '  {"id":"102","companyname":" Globex","balance":null,"memo":null}\n]\n'
		)
		local back = json.decode(text)
		expect(back[1].balance).toBe(12.5)
		expect(back[2].companyname).toBe(" Globex")
	end)

	it("exports only the rows the grid shows, in its order", function()
		expect(Export.csv({ "id" }, rows, { 2 }, null)).toBe("id\n102\n")
		expect(Export.json({ "id" }, rows, {}, null)).toBe("[]\n")
	end)

	it("names files by connection and time, never reusing a taken name", function()
		expect(Export.fileName("sb-rest", "20261109-101500", "csv")).toBe("suiteql-sb-rest-20261109-101500.csv")
		expect(Export.fileName("sb/rest", "20261109-101500", "json", 2)).toBe("suiteql-sb_rest-20261109-101500-2.json")
	end)

	it("opens only absolute paths without control characters or parent steps", function()
		expect(Export.safePath("/tmp/acme/suiteql.csv")).toBe(true)
		expect(Export.safePath("tmp/suiteql.csv")).toBe(false)
		expect(Export.safePath("/tmp/../etc/x.csv")).toBe(false)
		expect(Export.safePath("/tmp/a\nb.csv")).toBe(false)
	end)
end)

return nil
