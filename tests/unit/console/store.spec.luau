--!strict
local Store = require("../../../plugin/lib/console/store")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

-- Enough of an encoder for the store's flat objects.
local function encode(v: any): string
	local keys: { string } = {}
	for k in v do
		table.insert(keys, k)
	end
	table.sort(keys)
	local parts: { string } = {}
	for _, k in keys do
		local x = v[k]
		local s = if type(x) == "string"
			then '"' .. string.gsub(string.gsub(x, "\\", "\\\\"), '[\n"]', { ["\n"] = "\\n", ['"'] = '\\"' }) .. '"'
			else tostring(x)
		table.insert(parts, '"' .. k .. '":' .. s)
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

describe("console history", function()
	it("survives a restart: what is written reads back in order", function()
		local list = Store.addHistory({}, { sql = "SELECT 1", connection = "sb-rest", at = 10 })
		list = Store.addHistory(list, { sql = "SELECT id\nFROM customer", connection = "sb-rest", at = 20 })
		local back = Store.parseHistory(Store.encodeHistory(list, encode), json.decode)
		expect(back).toEqual(list)
		expect(back[2].sql).toBe("SELECT id\nFROM customer")
	end)

	it("moves a repeated query to the end instead of keeping duplicates", function()
		local list = Store.addHistory({}, { sql = "SELECT 1", at = 1 })
		list = Store.addHistory(list, { sql = "SELECT 2", at = 2 })
		list = Store.addHistory(list, { sql = "SELECT 1", at = 3 })
		expect(#list).toBe(2)
		expect(list[2]).toEqual({ sql = "SELECT 1", at = 3 })
	end)

	it("keeps the newest MAX_HISTORY entries and skips queries too long to keep", function()
		local list = {}
		for i = 1, Store.MAX_HISTORY + 5 do
			list = Store.addHistory(list, { sql = "SELECT " .. i, at = i })
		end
		expect(#list).toBe(Store.MAX_HISTORY)
		expect(list[1].sql).toBe("SELECT 6")
		local long = string.rep("x", Store.MAX_SQL_BYTES + 1)
		expect(Store.addHistory(list, { sql = long, at = 0 })).toBe(list)
	end)

	it("loses only a damaged line, such as one cut short by a crash", function()
		local text = '{"sql":"SELECT 1","at":1}\n{"sql":"SELECT 2","a\n{"sql":"SELECT 3","at":3}\n'
		local back = Store.parseHistory(text, json.decode)
		expect(#back).toBe(2)
		expect(back[2].sql).toBe("SELECT 3")
	end)
end)

describe("console saved queries", function()
	it("replaces a query saved under the same name in place", function()
		local list = Store.save({}, "Open orders", "SELECT 1", 1) :: { Store.Saved }
		list = Store.save(list, "Customers", "SELECT 2", 2) :: { Store.Saved }
		list = Store.save(list, "  Open orders ", "SELECT 3", 3) :: { Store.Saved }
		expect(list).toEqual({
			{ name = "Open orders", sql = "SELECT 3", at = 3 },
			{ name = "Customers", sql = "SELECT 2", at = 2 },
		})
		expect(Store.parseSaved(Store.encodeSaved(list, encode), json.decode)).toEqual(list)
	end)

	it("refuses names and queries that cannot be saved, saying why", function()
		local _, why = Store.save({}, "  ", "SELECT 1", 1)
		expect(why).toBe("give the query a name")
		_, why = Store.save({}, "a\nb", "SELECT 1", 1)
		expect(why).toBe("a name is one line without control characters")
		_, why = Store.save({}, "x", "   ", 1)
		expect(why).toBe("the query is empty")
	end)

	it("deletes a saved query by name", function()
		local list = Store.save({}, "a", "SELECT 1", 1) :: { Store.Saved }
		expect(Store.remove(list, "a")).toEqual({})
		expect(Store.find(list, "a")).toEqual({ name = "a", sql = "SELECT 1", at = 1 })
	end)
end)

return nil
