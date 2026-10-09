--!strict
local Dates = require("../../../../plugin/lib/monitor/health/dates")
local t = require("../../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local function at(v: any): number?
	local s = Dates.parse(v)
	return if s then s.t else nil
end

describe("NetSuite timestamps", function()
	it("reads TO_CHAR(..., 'YYYY-MM-DD HH24:MI:SS'), the precise form the built-in checks ask for", function()
		local s = Dates.parse("2026-10-08 22:27:20")
		expect(s ~= nil).toBe(true)
		expect((s :: Dates.Stamp).dateOnly).toBe(false)
		expect(Dates.format((s :: Dates.Stamp).t)).toBe("2026-10-08 22:27:20")
	end)

	it("reads the date-only M/D/YYYY that SuiteQL returns for an unformatted date column", function()
		local s = Dates.parse("10/8/2026") :: Dates.Stamp
		expect(s.dateOnly).toBe(true)
		expect(Dates.format(s.t)).toBe("2026-10-08 00:00:00")
		expect(at("12/11/2026")).toBe(at("2026-12-11 00:00:00"))
	end)

	it("reads M/D/YYYY with a 12-hour time, as user date preferences may format it", function()
		expect(at("10/8/2026 10:26 pm")).toBe(at("2026-10-08 22:26:00"))
		expect(at("10/8/2026 12:05 am")).toBe(at("2026-10-08 00:05:00"))
		expect(at("10/8/2026 12:05:09 PM")).toBe(at("2026-10-08 12:05:09"))
		expect(at("10/8/2026 13:05")).toBe(at("2026-10-08 13:05:00"))
	end)

	it("reads ISO 8601 and hour-only buckets", function()
		expect(at("2026-10-08T22:27:20Z")).toBe(at("2026-10-08 22:27:20"))
		expect(at("2026-10-08T22:27:20.123")).toBe(at("2026-10-08 22:27:20"))
		expect(at("2026-10-08 22")).toBe(at("2026-10-08 22:00:00"))
		expect(at("2026-10-08")).toBe(at("2026-10-08 00:00:00"))
	end)

	it("counts days across months, leap years and years correctly", function()
		local a = at("2024-02-28 00:00:00") :: number
		expect((at("2024-03-01 00:00:00") :: number) - a).toBe(2 * 86400)
		expect((at("2027-01-01 00:00:00") :: number) - (at("2026-12-31 23:00:00") :: number)).toBe(3600)
		expect(at("1970-01-01 00:00:00")).toBe(0)
	end)

	it("rejects anything that is not a real date instead of guessing", function()
		expect(at("")).toBeNil()
		expect(at("yesterday")).toBeNil()
		expect(at("13/1/2026")).toBeNil()
		expect(at("2/30/2026")).toBeNil()
		expect(at("2026-10-08 24:00:00")).toBeNil()
		expect(at("10/8/2026 13:05 pm")).toBeNil()
		expect(at(1700000000)).toBeNil()
		expect(at(nil)).toBeNil()
	end)
end)

return nil
