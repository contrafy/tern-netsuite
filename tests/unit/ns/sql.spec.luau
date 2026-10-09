--!strict
local Paging = require("../../../plugin/lib/ns/paging")
local Sql = require("../../../plugin/lib/ns/sql")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local function allowed(sql: string): boolean
	local ok = Sql.readOnly(sql)
	return ok
end

describe("the read-only guard, the last check before a query leaves the machine", function()
	it("allows single SELECT and WITH queries", function()
		expect(allowed("SELECT 1 AS ok FROM DUAL")).toBe(true)
		expect(allowed("  select id from scriptnote;  ")).toBe(true)
		expect(allowed("WITH t AS (SELECT id FROM employee) SELECT * FROM t")).toBe(true)
		expect(allowed("(SELECT id FROM a) UNION (SELECT id FROM b)")).toBe(true)
		expect(allowed("-- recent errors\nSELECT id FROM scriptnote /* newest */ ORDER BY id DESC")).toBe(true)
	end)

	it("refuses every data-changing or procedural statement", function()
		for _, sql in
			{
				"INSERT INTO customer (id) VALUES (1)",
				"UPDATE customer SET companyname = 'x'",
				"DELETE FROM customer",
				"MERGE INTO customer c USING x ON (1=1) WHEN MATCHED THEN UPDATE SET c.a = 1",
				"CALL do_something()",
				"EXEC do_something",
				"DROP TABLE customer",
				"TRUNCATE TABLE customer",
			}
		do
			expect(allowed(sql)).toBe(false)
		end
	end)

	it("refuses a write hidden after a SELECT or inside a CTE", function()
		expect(allowed("SELECT 1 FROM DUAL; DELETE FROM customer")).toBe(false)
		expect(allowed("SELECT 1 FROM DUAL;;")).toBe(false)
		expect(allowed("WITH x AS (SELECT 1 FROM DUAL) DELETE FROM customer")).toBe(false)
		expect(allowed("SELECT id FROM customer FOR UPDATE")).toBe(false)
		expect(allowed("SELECT id INTO v FROM customer")).toBe(false)
	end)

	it("is not fooled by comments that hide a statement start", function()
		expect(allowed("/* SELECT */ DELETE FROM customer")).toBe(false)
		expect(allowed("-- SELECT\nUPDATE customer SET x = 1")).toBe(false)
	end)

	it("ignores keywords inside string literals and quoted identifiers", function()
		expect(allowed("SELECT id FROM scriptnote WHERE title = 'DELETE failed; retry'")).toBe(true)
		expect(allowed("SELECT \"update\" FROM t WHERE x = 'it''s; DROP TABLE y'")).toBe(true)
		expect(allowed("SELECT id, lastupdated, deleted_flag FROM t")).toBe(true)
	end)

	it("refuses text it cannot lex the way NetSuite would", function()
		expect(allowed("SELECT 'unterminated FROM t")).toBe(false)
		expect(allowed("SELECT 1 FROM t /* open")).toBe(false)
		expect(allowed("")).toBe(false)
		expect(allowed("   -- only a comment")).toBe(false)
	end)

	it("names the reason so the user can fix the query", function()
		local ok, why = Sql.readOnly("DELETE FROM customer")
		expect(ok).toBe(false)
		expect(why).toContain("DELETE")
		local _, why2 = Sql.readOnly("SELECT 1 FROM DUAL; SELECT 2 FROM DUAL")
		expect(why2).toContain("single statement")
	end)
end)

describe("binding parameters for REST SuiteQL, which has no parameter list", function()
	it("quotes strings with doubled quotes so a value cannot end the literal", function()
		expect((Sql.bind("SELECT id FROM t WHERE name = ? AND n = ?", { "O'Brien'; DROP", 42 }))).toBe(
			"SELECT id FROM t WHERE name = 'O''Brien''; DROP' AND n = 42"
		)
	end)

	it("leaves question marks inside literals and comments alone", function()
		expect((Sql.bind("SELECT '?' AS q FROM t /* ? */ WHERE a = ? -- ?\n", { true }))).toBe(
			"SELECT '?' AS q FROM t /* ? */ WHERE a = 'T' -- ?\n"
		)
	end)

	it("refuses mismatched or non-scalar parameters instead of sending a different query", function()
		local s, err = Sql.bind("SELECT ? FROM t", {})
		expect(s).toBeNil()
		expect(err).toContain("placeholder")
		expect((Sql.bind("SELECT 1 FROM t", { 1 }))).toBeNil()
		expect((Sql.bind("SELECT ? FROM t", { {} }))).toBeNil()
		expect((Sql.bind("SELECT ? FROM t", { 0 / 0 }))).toBeNil()
	end)
end)

describe("IN-list chunking, since NetSuite fails with an opaque 500 above 1000 items", function()
	it("never puts more than 1000 values in one IN list", function()
		local ids = {}
		for i = 1, 2500 do
			ids[i] = i
		end
		local clauses = Paging.inList("id", ids)
		expect(#clauses).toBe(3)
		expect(#clauses[1].params).toBe(1000)
		expect(#clauses[3].params).toBe(500)
		expect(clauses[3].params[1]).toBe(2001)
		local _, placeholders = string.gsub(clauses[1].sql, "%?", "")
		expect(placeholders).toBe(1000)
	end)

	it("clamps a requested chunk size to the safe range", function()
		expect(#Paging.chunks({ 1, 2, 3 }, 2)).toBe(2)
		expect(#Paging.chunks({ 1, 2, 3 }, 5000)[1]).toBe(3)
		expect(#Paging.chunks({}, 10)).toBe(0)
		expect(Paging.inList("LOWER(email)", { "a", "b" })[1].sql).toBe("LOWER(email) IN (?, ?)")
	end)
end)

describe("keyset paging past REST SuiteQL's 100000-row offset cap", function()
	it("pages by ascending id after the last id seen", function()
		local first = Paging.keyset({ sql = "SELECT id, title FROM scriptnote;", id = "id", size = 500 })
		expect(first and first.sql).toBe(
			"SELECT * FROM (SELECT * FROM (SELECT id, title FROM scriptnote) ORDER BY id) WHERE ROWNUM <= 500"
		)
		expect(first and #first.params).toBe(0)
		local second = Paging.keyset({ sql = "SELECT id, title FROM scriptnote", id = "id", after = 900, size = 500 })
		expect(second and second.sql).toContain("WHERE id > ? ORDER BY id")
		expect(second and second.params[1]).toBe(900)
	end)

	it("stops when a page comes back short and continues from the last row otherwise", function()
		expect(Paging.nextAfter({ { id = "1" }, { id = "7" } }, "id", 2)).toBe(7)
		expect(Paging.nextAfter({ { id = "1" } }, "id", 2)).toBeNil()
		expect(Paging.nextAfter({ { id = 3 }, { id = 4 } }, "ID", 2)).toBe(4)
	end)

	it("refuses a key that is not a plain column name", function()
		local k, err = Paging.keyset({ sql = "SELECT 1 FROM t", id = "id; DROP" })
		expect(k).toBeNil()
		expect(err).toContain("column")
	end)
end)

return nil
