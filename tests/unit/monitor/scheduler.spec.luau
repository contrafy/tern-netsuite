--!strict
local Scheduler = require("../../../plugin/lib/monitor/scheduler")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

type Job = Scheduler.Job

local function job(key: string, group: string, interval: number?): Job
	return { key = key, group = group, interval = interval or 120 }
end

local function keys(list: { Job }): { string }
	local out = {}
	for i, j in list do
		out[i] = j.key
	end
	return out
end

-- Starts and finishes `j` at `now` with `outcome`, a mid-range jitter draw.
local function run(s: Scheduler.State, j: Job, now: number, outcome: Scheduler.Outcome)
	Scheduler.start(s, j, now)
	Scheduler.finish(s, j, now, outcome, 0.5)
end

describe("polling schedule", function()
	it("runs every new check right away, so a fresh window shows data without waiting a whole interval", function()
		local s = Scheduler.new()
		local jobs = { job("a.errors", "a"), job("b.errors", "b") }
		expect(keys(Scheduler.due(s, jobs, 1000))).toEqual({ "a.errors", "b.errors" })
	end)

	it("keeps at most one query in flight per connection, so NetSuite's concurrency limit is never hit", function()
		local s = Scheduler.new()
		local jobs = { job("a.errors", "a"), job("a.deploy", "a"), job("b.errors", "b") }
		local first = Scheduler.due(s, jobs, 1000)
		expect(keys(first)).toEqual({ "a.errors", "b.errors" })
		Scheduler.start(s, first[1], 1000)
		Scheduler.start(s, first[2], 1000)
		expect(#Scheduler.due(s, jobs, 1001)).toBe(0)
		Scheduler.finish(s, first[1], 1002, "ok", 0.5)
		expect(keys(Scheduler.due(s, jobs, 1002))).toEqual({ "a.deploy" })
	end)

	it("waits the poll interval after a success", function()
		local s = Scheduler.new()
		local j = job("a.errors", "a", 120)
		run(s, j, 1000, "ok")
		expect(#Scheduler.due(s, { j }, 1119)).toBe(0)
		expect(#Scheduler.due(s, { j }, 1120)).toBe(1)
	end)

	it("jitters intervals by at most 10% so windows and connections drift apart", function()
		local low, high = Scheduler.new(), Scheduler.new()
		local j = job("a.errors", "a", 100)
		Scheduler.start(low, j, 0)
		Scheduler.finish(low, j, 0, "ok", 0)
		Scheduler.start(high, j, 0)
		Scheduler.finish(high, j, 0, "ok", 0.999)
		expect(#Scheduler.due(low, { j }, 89)).toBe(0)
		expect(#Scheduler.due(low, { j }, 90)).toBe(1)
		expect(#Scheduler.due(high, { j }, 109)).toBe(0)
		expect(#Scheduler.due(high, { j }, 110)).toBe(1)
	end)

	it("backs off exponentially on rate limits and network errors instead of retrying in a storm", function()
		local s = Scheduler.new()
		local j = job("a.errors", "a", 120)
		run(s, j, 0, "retry")
		expect(#Scheduler.due(s, { j }, 239)).toBe(0)
		expect(#Scheduler.due(s, { j }, 240)).toBe(1)
		run(s, j, 240, "retry")
		expect(#Scheduler.due(s, { j }, 240 + 479)).toBe(0)
		expect(#Scheduler.due(s, { j }, 240 + 480)).toBe(1)
	end)

	it("caps the backoff so a recovered account is noticed within half an hour", function()
		local s = Scheduler.new()
		local j = job("a.errors", "a", 600)
		local now = 0
		for _ = 1, 8 do
			run(s, j, now, "retry")
			now += Scheduler.MAX_BACKOFF_SECONDS
		end
		expect(#Scheduler.due(s, { j }, now)).toBe(1)
	end)

	it("holds every check of a throttled connection, not just the one that hit the limit", function()
		local s = Scheduler.new()
		local a, b = job("a.errors", "a"), job("a.deploy", "a")
		run(s, a, 0, "retry")
		expect(#Scheduler.due(s, { a, b }, 100)).toBe(0)
		expect(#Scheduler.due(s, { a, b }, 240)).toBe(1)
	end)

	it("resets the backoff once a query succeeds", function()
		local s = Scheduler.new()
		local j = job("a.errors", "a", 120)
		run(s, j, 0, "retry")
		run(s, j, 240, "retry")
		run(s, j, 720, "ok")
		run(s, j, 840, "retry")
		expect(#Scheduler.due(s, { j }, 840 + 240)).toBe(1)
	end)

	it("polls a broken query at the normal pace: the server answered, so the connection is fine", function()
		local s = Scheduler.new()
		local j = job("a.custom", "a", 120)
		run(s, j, 0, "fail")
		expect(#Scheduler.due(s, { j }, 120)).toBe(1)
	end)

	it("stops polling a paused connection until it is resumed", function()
		local s = Scheduler.new()
		local j = job("a.errors", "a")
		run(s, j, 0, "ok")
		Scheduler.pause(s, "a")
		expect(#Scheduler.due(s, { j }, 10000)).toBe(0)
		expect(Scheduler.paused(s, "a")).toBe(true)
		Scheduler.resume(s, "a")
		expect(#Scheduler.due(s, { j }, 10000)).toBe(1)
	end)

	it("runs everything now on an explicit refresh, even during a backoff", function()
		local s = Scheduler.new()
		local j = job("a.errors", "a")
		run(s, j, 0, "retry")
		Scheduler.runNow(s, 1)
		expect(#Scheduler.due(s, { j }, 1)).toBe(1)
	end)

	it("forgets a query that never answered so one lost callback cannot stall a connection", function()
		local s = Scheduler.new()
		local j = job("a.errors", "a")
		Scheduler.start(s, j, 0)
		expect(#Scheduler.due(s, { j }, Scheduler.STALE_SECONDS - 1)).toBe(0)
		expect(#Scheduler.due(s, { j }, Scheduler.STALE_SECONDS)).toBe(1)
	end)

	it("ignores the late answer of a query it already gave up on", function()
		local s = Scheduler.new()
		local j = job("a.errors", "a")
		local first = Scheduler.start(s, j, 0)
		local second = Scheduler.start(s, j, Scheduler.STALE_SECONDS)
		expect(Scheduler.finish(s, j, Scheduler.STALE_SECONDS + 1, "ok", 0.5, first)).toBe(false)
		expect(Scheduler.running(s, "a")).toBe(true)
		expect(Scheduler.finish(s, j, Scheduler.STALE_SECONDS + 1, "ok", 0.5, second)).toBe(true)
		expect(Scheduler.running(s, "a")).toBe(false)
	end)

	it("says when to wake next: the earliest due check, never in the past", function()
		local s = Scheduler.new()
		local a, b = job("a.errors", "a", 120), job("b.errors", "b", 300)
		run(s, a, 0, "ok")
		run(s, b, 0, "ok")
		expect(Scheduler.nextWake(s, { a, b }, 10)).toBe(120)
		expect(Scheduler.nextWake(s, { a, b }, 200)).toBe(200)
		expect(Scheduler.nextWake(s, {}, 10)).toBeNil()
	end)
end)

describe("polling lease across windows", function()
	it("lets the first window take the lease and keep it while it renews", function()
		local mine = Scheduler.lease(nil, "w1", 100, 60)
		expect(mine ~= nil).toBe(true)
		local again = Scheduler.lease(mine, "w1", 130, 60)
		expect(again ~= nil).toBe(true)
	end)

	it("keeps a second window from polling the same account twice", function()
		local held = Scheduler.lease(nil, "w1", 100, 60)
		expect(Scheduler.lease(held, "w2", 120, 60)).toBeNil()
	end)

	it("hands the lease over when its holder stopped renewing (window closed)", function()
		local held = Scheduler.lease(nil, "w1", 100, 60)
		local taken = Scheduler.lease(held, "w2", 161, 60)
		expect(taken ~= nil and taken.owner).toBe("w2")
	end)

	it("lets a manual refresh take the lease from another window", function()
		local held = Scheduler.lease(nil, "w1", 100, 60)
		local taken = Scheduler.lease(held, "w2", 101, 60, true)
		expect(taken ~= nil and taken.owner).toBe("w2")
	end)

	it("renews only when half the lease has passed, to keep kv writes rare", function()
		local held = Scheduler.lease(nil, "w1", 100, 60) :: Scheduler.Lease
		expect(Scheduler.needsRenewal(held, 120)).toBe(false)
		expect(Scheduler.needsRenewal(held, 131)).toBe(true)
	end)

	it("treats a malformed stored lease as free", function()
		local taken = Scheduler.lease({ owner = 5 } :: any, "w1", 100, 60)
		expect(taken ~= nil and taken.owner).toBe("w1")
	end)
end)

return nil
