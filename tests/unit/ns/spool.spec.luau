--!strict
local Spool = require("../../../plugin/lib/ns/spool")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

describe("pending request records", function()
	it("keys each record by its request id", function()
		expect(Spool.pendingKey("0123456789abcdef")).toBe("ns.pending.0123456789abcdef")
	end)

	it("authorizes the recorded action until it expires", function()
		local rec = Spool.pending("query", "query", "acme-sb", 1000)
		expect(rec.exp).toBe(1000 + Spool.PENDING_TTL_SECONDS)
		expect(Spool.checkPending(rec, "query", 1000)).toBeNil()
		expect(Spool.checkPending(rec, "query", rec.exp + 1)).toContain("expired")
	end)

	it("refuses a request file nobody recorded, such as one another program dropped", function()
		expect(Spool.checkPending(nil, "query", 1000)).toContain("not created by Tern NetSuite")
		expect(Spool.checkPending("x", "store", 1000)).toContain("not created by Tern NetSuite")
	end)

	it("refuses a record made for another action", function()
		local rec = Spool.pending("query", "query", "acme-sb", 1000)
		expect(Spool.checkPending(rec, "forget", 1000)).toContain("does not match")
	end)

	it("changes credentials only for records the connect block made", function()
		local fromQuery = { action = "store", origin = "query", connection = "acme-sb", exp = 2000 }
		expect(Spool.checkPending(fromQuery, "store", 1000)).toContain("Connect account")
		expect(Spool.checkPending(Spool.pending("store", "connect", "acme-sb", 1000), "store", 1000)).toBeNil()
		expect(Spool.checkPending(Spool.pending("forget", "connect", "acme-sb", 1000), "forget", 1000)).toBeNil()
	end)

	it("refuses malformed records, since kv round-trips JSON", function()
		expect(Spool.checkPending({ action = "query", exp = "soon", connection = "a" }, "query", 1)).toContain(
			"expired"
		)
		expect(Spool.checkPending({ action = "query", exp = 10 }, "query", 1)).toContain("malformed")
	end)
end)

return nil
