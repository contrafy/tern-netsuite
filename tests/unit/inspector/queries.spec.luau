--!strict
local Catalog = require("../../../plugin/lib/inspector/catalog")
local Queries = require("../../../plugin/lib/inspector/queries")
local Sql = require("../../../plugin/lib/ns/sql")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local function readOnly(q: Queries.Query?)
	expect(q ~= nil).toBe(true)
	local query = q :: Queries.Query
	local ok, why = Sql.readOnly(query.sql)
	expect(why).toBeNil()
	expect(ok).toBe(true)
	-- Every value travels as a parameter: binding must use them all.
	local bound, err = Sql.bind(query.sql, query.params)
	expect(err).toBeNil()
	expect(type(bound)).toBe("string")
end

describe("inspector SuiteQL", function()
	it("reads the record with its id as a parameter, passing the read-only guard", function()
		local q = Queries.record(Catalog.find("salesorder") :: Catalog.Kind, "123") :: Queries.Query
		expect(q.sql).toBe("SELECT * FROM transaction WHERE id = ?")
		expect(q.params).toEqual({ 123 })
		readOnly(q)
	end)

	it("never splices a table name that is not a plain identifier", function()
		local evil = Catalog.customRecord("customrecord_x")
		evil.table = "customrecord_x; DELETE"
		expect(Queries.record(evil, "1")).toBeNil()
		expect(Queries.display(evil, "1", { "entity" })).toBeNil()
	end)

	it("asks custom field labels only for custom field columns", function()
		local q =
			Queries.labels({ "id", "entity", "custbody_a", "custcol_b", "customform", "custrecord_c" }, true) :: Queries.Query
		expect(q.params).toEqual({ "custbody_a", "custcol_b", "custrecord_c" })
		readOnly(q)
		readOnly(Queries.labels({ "custbody_a" }, false))
		expect(Queries.labels({ "id", "tranid" }, true)).toBeNil()
	end)

	it("caps label lookups so a wide custom record cannot build an unbounded IN list", function()
		local cols: { string } = {}
		for i = 1, Queries.MAX_LABEL_FIELDS + 20 do
			table.insert(cols, "custrecord_f" .. i)
		end
		expect(#(Queries.labels(cols, true) :: Queries.Query).params).toBe(Queries.MAX_LABEL_FIELDS)
	end)

	it("asks display names only for safe column names", function()
		local q =
			Queries.display(Catalog.find("salesorder") :: Catalog.Kind, "1", { "entity", "bad-col" }) :: Queries.Query
		expect(q.sql).toBe("SELECT BUILTIN.DF(entity) AS entity FROM transaction WHERE id = ?")
		readOnly(q)
	end)

	it("filters system notes by record id and every note type of the record type", function()
		local q = Queries.notes("123", { -2, -9 }) :: Queries.Query
		expect(q.params).toEqual({ 123, -2, -9 })
		readOnly(q)
		expect(Queries.notes("1", {})).toBeNil()
	end)

	it("reads the note type raw, since BUILTIN.DF fails on that static field, and the field's label", function()
		local q = Queries.notes("123", { -30 }) :: Queries.Query
		expect(q.sql).toContain("sn.type AS action")
		expect((string.find(q.sql, "DF(sn.type)", 1, true))).toBeNil()
		expect(q.sql).toContain("BUILTIN.DF(sn.field) AS fieldlabel")
	end)

	it("finds transactions created from a record through their lines, where createdfrom lives", function()
		local q = Queries.children("123")
		expect(q.sql).toContain("JOIN transactionline tl ON tl.transaction = t.id")
		expect(q.sql).toContain("tl.createdfrom = ?")
		expect(q.sql).toContain("SELECT DISTINCT")
		expect(q.params).toEqual({ 123 })
	end)

	it("finds what a transaction was created from through its lines, as transaction has no createdfrom", function()
		local q = Queries.createdFrom("130")
		expect(q.sql).toBe(
			"SELECT DISTINCT tl.createdfrom AS createdfrom, BUILTIN.DF(tl.createdfrom) AS name"
				.. " FROM transactionline tl WHERE tl.transaction = ? AND tl.createdfrom IS NOT NULL"
		)
		expect(q.params).toEqual({ 130 })
		readOnly(q)
	end)

	it("keeps the related-record queries read-only and parameterised", function()
		readOnly(Queries.lines("123"))
		readOnly(Queries.children("123"))
		readOnly(Queries.entityTransactions("42"))
		readOnly(Queries.customRecordType(12, nil))
		readOnly(Queries.customRecordType(nil, "customrecord_acme_box"))
	end)
end)

return nil
