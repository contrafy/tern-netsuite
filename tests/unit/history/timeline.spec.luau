--!strict
local Ci = require("../../../plugin/lib/history/ci")
local GuardLog = require("../../../plugin/lib/history/guardlog")
local Record = require("../../../plugin/lib/history/record")
local Timeline = require("../../../plugin/lib/history/timeline")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local DAY = 86400
-- 2026-10-08 00:00:00 UTC
local D0 = 1791417600

local function rec(at: number, extra: { [string]: any }): Record.Record
	local r: { [string]: any } = {
		at = at,
		startedAt = at - 60,
		cwd = "/tmp/work/billing",
		command = "project:deploy",
		line = "suitecloud project:deploy",
		status = 0,
		tookMs = 60000,
		project = "billing",
		authId = "demo-sb",
		accountId = "1234567_SB1",
		accountLabel = "1234567_SB1",
		production = false,
		accountSource = "cli",
	}
	for k, v in extra do
		r[k] = v
	end
	if extra.accountSource == "unknown" then
		r.accountId, r.accountLabel, r.production = nil, nil, nil
	end
	return r :: any
end

local function guard(at: number, decision: string, extra: { [string]: any }?): GuardLog.Entry
	local g: { [string]: any } = {
		at = at,
		decision = decision,
		command = "project:deploy",
		cwd = "/private/tmp/work/payroll",
		line = "suitecloud project:deploy",
		accountId = "1234567",
		accountLabel = "PROD",
		production = true,
		authId = "prod",
	}
	for k, v in (extra or {}) :: { [string]: any } do
		g[k] = v
	end
	return g :: any
end

local function ciRuns(): { Ci.Run }
	return (Ci.parse(fixtures.read("history/gh-run-list.json"), json.decode)) :: { Ci.Run }
end

local function utcDay(at: number): string
	return os.date("!%Y-%m-%d", at) :: string
end

local function sample(): { Timeline.Item }
	return Timeline.build({
		records = {
			rec(D0 + 3600, {}),
			rec(D0 + 7200, {
				cwd = "/tmp/work/payroll",
				project = "payroll",
				status = 1,
				authId = "prod",
				accountId = "1234567",
				accountLabel = "PROD",
				production = true,
				accountSource = "configured",
			}),
			rec(D0 - DAY + 100, { authId = "x-sb", accountSource = "unknown" }),
		},
		guards = {
			-- Decided while the payroll deploy ran: the same event.
			guard(D0 + 7200 - 30, "denied", { reason = "fingerprint mismatch" }),
			-- A decision whose command line Tern never saw (another shell).
			guard(D0 + 5000, "approved", { cwd = "/work/hr" }),
		},
		runs = ciRuns(),
		repo = "example-org/example-repo",
	})
end

describe("the deploy timeline", function()
	it("puts local deploys, guard decisions and CI runs on one newest-first timeline", function()
		local items = sample()
		expect(#items).toBe(3 + 1 + 6)
		for i = 2, #items do
			expect(items[i - 1].at >= items[i].at).toBe(true)
		end
		local sources: { [string]: number } = {}
		for _, item in items do
			sources[item.source] = (sources[item.source] or 0) + 1
		end
		expect(sources).toEqual({ ["local"] = 3, guard = 1, ci = 6 })
	end)

	it("folds a guard decision into the deploy it was made for instead of listing it twice", function()
		local payroll: Timeline.Item? = nil
		for _, item in sample() do
			if item.project == "payroll" then
				payroll = item
			end
		end
		local p = payroll :: Timeline.Item
		expect(p.source).toBe("local")
		expect(p.guard).toBe("denied")
		expect(p.status).toBe("denied")
		expect(p.reason).toBe("fingerprint mismatch")
	end)

	it("marks production accounts and says when the account was unknown", function()
		local byProject: { [string]: Timeline.Item } = {}
		for _, item in sample() do
			if item.source == "local" and item.project then
				byProject[item.project .. (if item.status == "ok" and item.at < D0 then "-old" else "")] = item
			end
		end
		expect(byProject.payroll.account).toEqual({ label = "PROD", production = true })
		expect(byProject.billing.account).toEqual({ label = "1234567_SB1", production = false })
		expect(byProject["billing-old"].account).toEqual({ label = "x-sb?", production = nil })
	end)

	it("links CI runs to their page and keeps their commit and duration", function()
		local run: Timeline.Item? = nil
		for _, item in sample() do
			if item.runId == 1000000105 then
				run = item
			end
		end
		local r = run :: Timeline.Item
		expect(r.source).toBe("ci")
		expect(r.status).toBe("ok")
		expect(r.branch).toBe("develop")
		expect(r.head).toBe("74fbe1735dfd1db4fe1faf64bcf5e28849817553")
		expect(r.url).toBe("https://github.com/example-org/example-repo/actions/runs/1000000105")
		expect(r.repo).toBe("example-org/example-repo")
		expect(r.tookMs).toBe(430000)
	end)
end)

describe("timeline filters", function()
	it("narrow by project, account and source together", function()
		local items = sample()
		expect(#Timeline.filter(items, { source = "ci" })).toBe(6)
		expect(#Timeline.filter(items, { project = "billing" })).toBe(2)
		expect(#Timeline.filter(items, { account = "PROD" })).toBe(2)
		expect(#Timeline.filter(items, { account = "PROD", source = "guard" })).toBe(1)
		expect(#Timeline.filter(items, {})).toBe(#items)
	end)

	it("offer each value present, sorted, to cycle through", function()
		local items = sample()
		expect(Timeline.values(items, "project")).toEqual({ "billing", "hr", "payroll" })
		expect(Timeline.values(items, "source")).toEqual({ "ci", "guard", "local" })
		expect(Timeline.values(items, "account")).toEqual({ "1234567_SB1", "PROD", "x-sb?" })
	end)

	it("cycle from all through each value back to all", function()
		local values = { "a", "b" }
		expect(Timeline.cycle(values, nil)).toBe("a")
		expect(Timeline.cycle(values, "a")).toBe("b")
		expect(Timeline.cycle(values, "b")).toBeNil()
		expect(Timeline.cycle({}, nil)).toBeNil()
	end)
end)

describe("timeline days", function()
	it("group consecutive items by their day, newest day first", function()
		local items = Timeline.filter(sample(), { source = "local" })
		local days = Timeline.group(items, utcDay)
		expect(#days).toBe(2)
		expect(days[1].day).toBe("2026-10-08")
		expect(#days[1].items).toBe(2)
		expect(days[2].day).toBe("2026-10-07")
	end)
end)

return nil
