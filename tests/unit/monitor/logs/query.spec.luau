--!strict
local Query = require("../../../../plugin/lib/monitor/logs/query")
local Sql = require("../../../../plugin/lib/ns/sql")
local t = require("../../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local function count(s: string, needle: string): number
	local n = 0
	local i = 1
	while true do
		local a, b = string.find(s, needle, i, true)
		if a == nil then
			return n
		end
		n += 1
		i = (b :: number) + 1
	end
end

describe("execution log queries", function()
	it("loads the newest rows first, ordered by time (internal ids are not time-ordered)", function()
		local q = Query.first({ scripts = {} }, 200)
		expect(q.sql).toContain("FROM scriptnote n LEFT JOIN script s ON s.id = n.scripttype")
		expect(q.sql).toContain("ORDER BY n.date DESC, n.internalid DESC")
		expect(q.sql).toContain("WHERE ROWNUM <= 200")
		expect(q.params).toEqual({})
		expect((Sql.readOnly(q.sql))).toBe(true)
	end)

	it("polls from a timestamp watermark with parameters only, oldest first", function()
		local q = Query.poll({ scripts = {} }, "2026-10-08 22:13:40", 1000)
		expect(q.sql).toContain("n.date >= TO_DATE(?, 'YYYY-MM-DD HH24:MI:SS')")
		expect(q.sql).toContain("ORDER BY n.date, n.internalid")
		expect(q.params).toEqual({ "2026-10-08 22:13:40" })
		expect((Sql.readOnly(q.sql))).toBe(true)
	end)

	it("scopes to scripts by script id or numeric id through placeholders", function()
		local q = Query.poll({ scripts = { "customscript_a", "123", "customscript_b" } }, "2026-10-08 22:13:40", 50)
		expect(q.sql).toContain("(LOWER(s.scriptid) IN (?, ?) OR n.scripttype IN (?))")
		expect(q.params).toEqual({ "customscript_a", "customscript_b", 123, "2026-10-08 22:13:40" } :: { any })
		expect(count(q.sql, "?")).toBe(#q.params)
		expect((string.find(q.sql, "customscript_a", 1, true))).toBeNil()
	end)

	it("starts at an absolute or relative `since` and reads forward from it", function()
		local abs = Query.first({ scripts = {}, since = { at = "2026-10-08 22:00:00" } }, 200)
		expect(abs.sql).toContain("n.date >= TO_DATE(?, 'YYYY-MM-DD HH24:MI:SS')")
		expect(abs.sql).toContain("ORDER BY n.date, n.internalid")
		expect(abs.params).toEqual({ "2026-10-08 22:00:00" })
		local rel = Query.first({ scripts = { "customscript_a" }, since = { minutes = 90 } }, 200)
		expect(rel.sql).toContain("n.date >= SYSDATE - (? / 1440)")
		expect(rel.params).toEqual({ "customscript_a", 90 } :: { any })
	end)

	it("clamps the row limit so a bad value never reaches the SQL text", function()
		expect(Query.first({ scripts = {} }, 0).sql).toContain("ROWNUM <= 1")
		expect(Query.first({ scripts = {} }, 1e9).sql).toContain("ROWNUM <= 1000")
		expect(Query.first({ scripts = {} }, 12.7).sql).toContain("ROWNUM <= 12")
	end)

	it("shifts NetSuite timestamps across minute, day, month and leap-year boundaries", function()
		expect(Query.shift("2026-10-08 22:15:40", -120)).toBe("2026-10-08 22:13:40")
		expect(Query.shift("2026-10-09 00:01:00", -120)).toBe("2026-10-08 23:59:00")
		expect(Query.shift("2026-03-01 00:00:30", -60)).toBe("2026-02-28 23:59:30")
		expect(Query.shift("2024-03-01 00:00:30", -60)).toBe("2024-02-29 23:59:30")
		expect(Query.shift("2026-12-31 23:59:59", 1)).toBe("2027-01-01 00:00:00")
		expect(Query.shift("garbage", 1)).toBeNil()
	end)

	it("re-reads an overlap window after a complete poll and none after a full page", function()
		expect(Query.nextFrom("2026-10-08 22:15:40", false)).toBe("2026-10-08 22:13:40")
		expect(Query.nextFrom("2026-10-08 22:15:40", true)).toBe("2026-10-08 22:15:40")
	end)
end)

return nil
