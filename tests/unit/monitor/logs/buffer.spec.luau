--!strict
local Buffer = require("../../../../plugin/lib/monitor/logs/buffer")
local Entry = require("../../../../plugin/lib/monitor/logs/entry")
local fixtures = require("../../../lib/fixtures")
local json = require("../../../lib/json")
local t = require("../../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local function entries(rows: { any }): { Entry.Entry }
	local out = {}
	for _, r in rows do
		local e = Entry.fromRow(r)
		if e then
			table.insert(out, e)
		end
	end
	return out
end

local function fake(id: number, logged: string): Entry.Entry
	return Entry.fromRow({ internalid = id, logged = logged, type = "DEBUG", title = "t", detail = "" }) :: Entry.Entry
end

local function ids(b: Buffer.Buffer): { number }
	local out = {}
	for _, e in b.entries do
		table.insert(out, e.id)
	end
	return out
end

local rows = json.decode(fixtures.read("monitor/logs/restlet-rows.json"))

describe("the log ring buffer", function()
	it("orders rows by time then id, whatever order NetSuite returned them in", function()
		local b, added = Buffer.merge(Buffer.new(100), entries(rows))
		expect(added).toBe(7)
		expect(ids(b)).toEqual({ 5771426, 5771427, 5771328, 5771329, 5771130, 5771027, 5771131 })
		expect(b.watermark).toBe("2026-10-08 22:16:09")
	end)

	it("drops rows it already holds, so the overlap window never duplicates lines", function()
		local b = Buffer.merge(Buffer.new(100), entries(rows))
		local again, added = Buffer.merge(b, entries(rows))
		expect(added).toBe(0)
		expect(#again.entries).toBe(7)
	end)

	it("inserts a late row with a lower internal id at its place in time", function()
		local b = Buffer.merge(Buffer.new(100), { fake(500, "2026-10-08 22:00:05"), fake(400, "2026-10-08 22:00:01") })
		local late = Buffer.merge(b, { fake(300, "2026-10-08 22:00:03") })
		expect(ids(late)).toEqual({ 400, 300, 500 })
	end)

	it("keeps at most `cap` rows, dropping the oldest and counting them for the overflow notice", function()
		local list = {}
		for i = 1, 10 do
			table.insert(list, fake(i, string.format("2026-10-08 22:00:%02d", i)))
		end
		local b = Buffer.merge(Buffer.new(4), list)
		expect(ids(b)).toEqual({ 7, 8, 9, 10 })
		expect(b.dropped).toBe(6)
		local more = Buffer.merge(b, { fake(11, "2026-10-08 22:00:11") })
		expect(ids(more)).toEqual({ 8, 9, 10, 11 })
		expect(more.dropped).toBe(7)
	end)

	it("does not resurrect a dropped row that the overlap window returns again", function()
		local list = {}
		for i = 1, 5 do
			table.insert(list, fake(i, string.format("2026-10-08 22:00:%02d", i)))
		end
		local b = Buffer.merge(Buffer.new(3), list)
		local again, added = Buffer.merge(b, { fake(2, "2026-10-08 22:00:02") })
		expect(added).toBe(0)
		expect(ids(again)).toEqual({ 3, 4, 5 })
	end)

	it("forgets dedupe ids older than the next poll window to stay bounded", function()
		local b = Buffer.merge(Buffer.new(100), { fake(1, "2026-10-08 22:00:01"), fake(2, "2026-10-08 22:05:00") })
		local pruned = Buffer.prune(b, "2026-10-08 22:03:00")
		expect(pruned.seen[1]).toBeNil()
		expect(pruned.seen[2]).toBe("2026-10-08 22:05:00")
		expect(#pruned.entries).toBe(2)
	end)

	it("never mutates the buffer it was given", function()
		local b = Buffer.merge(Buffer.new(100), { fake(1, "2026-10-08 22:00:01") })
		Buffer.merge(b, { fake(2, "2026-10-08 22:00:02") })
		expect(#b.entries).toBe(1)
		expect(b.seen[2]).toBeNil()
	end)
end)

return nil
