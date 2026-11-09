--!strict
local Sqltext = require("../../../plugin/lib/console/sqltext")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

describe("console column order", function()
	it("shows columns in select-list order, though decoded rows have no member order", function()
		local rows = { { tranid = "SO1", id = "7", entity = "12" } }
		expect(Sqltext.columns("SELECT id, tranid, entity FROM transaction", rows)).toEqual({ "id", "tranid", "entity" })
	end)

	it("names columns by alias, qualified name or bare alias, ignoring comments and literals", function()
		local names, complete = Sqltext.outputNames([[
			-- Open orders, newest first
			SELECT DISTINCT t.id, t.tranid AS "Doc", BUILTIN.DF(t.status) status,
			       COUNT(*) AS lines, 'a, b' label /* , hidden */
			FROM transaction t
		]])
		expect(names).toEqual({ "id", "doc", "status", "lines", "label" })
		expect(complete).toBe(true)
	end)

	it("reads the main query of a WITH and stops at the FROM of the outer query", function()
		local names = Sqltext.outputNames(
			"WITH o AS (SELECT id, total FROM transaction) SELECT o.id, (SELECT 1 FROM dual) one FROM o"
		)
		expect(names).toEqual({ "id", "one" })
	end)

	it("puts columns it cannot place (SELECT *, unnamed expressions) after the named ones, sorted", function()
		local rows = { { zeta = "1", id = "2", alpha = "3" } }
		expect(Sqltext.columns("SELECT id, * FROM customer", rows)).toEqual({ "id", "alpha", "zeta" })
		local _, complete = Sqltext.outputNames("SELECT id, a + b FROM x")
		expect(complete).toBe(false)
	end)

	it("keeps a selected column whose value is NULL in every row, which JSON decoding drops", function()
		local rows = { { id = "1" }, { id = "2" } }
		expect(Sqltext.columns("SELECT id, email FROM customer", rows)).toEqual({ "id", "email" })
		-- Unknown names stay out when the select list is not fully known.
		expect(Sqltext.columns("SELECT id, email, * FROM customer", rows)).toEqual({ "id" })
	end)

	it("matches RESTlet column names whatever their case", function()
		local rows = { { ID = 1, CompanyName = "Acme" } }
		expect(Sqltext.columns("select companyname, id from customer", rows)).toEqual({ "CompanyName", "ID" })
	end)
end)

describe("console record type of a query", function()
	it("names the table of a single-table query, so its id column can be inspected", function()
		expect(Sqltext.fromTable("SELECT id FROM Customer c WHERE c.isinactive = 'F'")).toBe("customer")
		expect(Sqltext.fromTable("select id from transaction order by id")).toBe("transaction")
		expect(Sqltext.fromTable("SELECT id FROM customrecord_acme_box AS b")).toBe("customrecord_acme_box")
	end)

	it("names none when the id could come from several tables", function()
		expect(Sqltext.fromTable("SELECT t.id FROM transaction t JOIN entity e ON e.id = t.entity")).toBeNil()
		expect(Sqltext.fromTable("SELECT id FROM a, b")).toBeNil()
		expect(Sqltext.fromTable("SELECT id FROM (SELECT id FROM a)")).toBeNil()
		expect(Sqltext.fromTable("SELECT id FROM a UNION SELECT id FROM b")).toBeNil()
	end)
end)

describe("console query titles", function()
	it("titles a saved query by its leading comment", function()
		expect(Sqltext.title("-- Open sales orders\nSELECT id FROM transaction")).toBe("Open sales orders")
		expect(Sqltext.title("\n/* Customers by balance */\nSELECT 1")).toBe("Customers by balance")
		expect(Sqltext.title("SELECT 1 -- not a title")).toBeNil()
	end)
end)

return nil
