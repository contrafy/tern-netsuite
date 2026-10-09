--!strict
local Audit = require("../../../plugin/lib/guard/audit")
local Record = require("../../../plugin/lib/history/record")
local Settings = require("../../../plugin/lib/history/settings")
local State = require("../../../plugin/lib/history/state")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local CI: Settings.Ci = { gh = "gh", workflow = "sdf-deploy.yml", limit = 20, timeout_ms = 20000, poll_seconds = 300 }

local function settings(ci: boolean): Settings.Settings
	return { max_entries = 500, ci = if ci then CI else nil }
end

local function record(at: number, project: string, status: number): string
	return Record.encode({
		at = at,
		startedAt = at - 30,
		cwd = "/work/sdf/" .. project,
		command = "project:deploy",
		line = "suitecloud project:deploy --log d.log",
		status = status,
		tookMs = 30000,
		project = project,
		root = "/work/sdf/" .. project,
		authId = "demo-sb",
		accountId = "1234567_SB1",
		accountLabel = "1234567_SB1",
		production = false,
		accountSource = "cli",
		log = "/work/sdf/" .. project .. "/d.log",
	})
end

local LOCAL = record(1791400000, "billing", 0) .. record(1791400100, "payroll", 1) .. record(1791400200, "billing", 0)

local GUARD = Audit.line({
	decision = "denied",
	decidedAt = 1791300000,
	command = "project:deploy",
	argv = { "suitecloud", "project:deploy" },
	cwd = "/work/sdf/hr",
	folder = "/work/sdf/hr/src",
	accountLabel = "PROD",
	accountId = "1234567",
	production = true,
	fingerprint = string.rep("ab", 32),
	files = 1,
})

type Effect = State.Effect

local function find(effects: { Effect }, kind: string): Effect?
	for _, e in effects do
		if e.t == kind then
			return e
		end
	end
	return nil
end

local function key(s: State.State, name: string): (State.State, { Effect })
	return State.update(s, { t = "key", name = name })
end

local function loaded(ci: boolean): State.State
	local s, effects = State.init({ cwd = "/work/sdf/billing", settings = settings(ci), decode = json.decode })
	s = State.update(s, { t = "local", gen = s.gen, text = LOCAL })
	s = State.update(s, { t = "guard", gen = s.gen, text = GUARD })
	if ci then
		local git = find(effects, "git") :: Effect
		s = State.update(s, {
			t = "git",
			gen = git.gen,
			stdout = "root=/work\nbranch=develop\nhead=74fbe1735dfd1db4fe1faf64bcf5e28849817553\nremote=git@github.com:example-org/example-repo\n",
		})
		s = State.update(s, {
			t = "ci",
			gen = s.gen,
			status = 0,
			stdout = fixtures.read("history/gh-run-list.json"),
			stderr = "",
			timedOut = false,
		})
	end
	return s
end

describe("opening the history", function()
	it("reads the local history and the guard's audit log, and asks git only when CI is configured", function()
		local _, plain = State.init({ cwd = "/work/sdf/billing", settings = settings(false), decode = json.decode })
		expect(find(plain, "read_local") ~= nil).toBe(true)
		expect(find(plain, "read_guard") ~= nil).toBe(true)
		expect(find(plain, "git")).toBeNil()
		local _, withCi = State.init({ cwd = "/work/sdf/billing", settings = settings(true), decode = json.decode })
		expect((find(withCi, "git") :: Effect).cwd).toBe("/work/sdf/billing")
	end)

	it("asks gh for the workflow's runs of the repository's GitHub remote", function()
		local s, effects = State.init({ cwd = "/work/sdf/billing", settings = settings(true), decode = json.decode })
		local _, next = State.update(s, {
			t = "git",
			gen = (find(effects, "git") :: Effect).gen,
			stdout = "root=/work\nbranch=develop\nremote=https://github.com/example-org/example-repo.git\n",
		})
		local ci = find(next, "ci") :: Effect
		expect((ci.argv :: { string })[5]).toBe("example-org/example-repo")
		expect(ci.timeoutMs).toBe(20000)
	end)

	it("never runs gh for a repository that is not on GitHub", function()
		local s, effects = State.init({ cwd = "/work/sdf/billing", settings = settings(true), decode = json.decode })
		local after, next = State.update(s, {
			t = "git",
			gen = (find(effects, "git") :: Effect).gen,
			stdout = "root=/work\nbranch=develop\nremote=git@gitlab.com:x/y.git\n",
		})
		expect(find(next, "ci")).toBeNil()
		expect(after.ciLoad).toBe("off")
	end)

	it("shows newest first and selects the newest entry", function()
		local s = loaded(false)
		local items = State.visible(s)
		expect(#items).toBe(4)
		expect(items[1].at).toBe(1791400200)
		expect(s.sel).toBe(items[1].key)
	end)
end)

describe("navigating the history", function()
	it("moves with j/k and stays inside the list", function()
		local s = loaded(false)
		local items = State.visible(s)
		s = key(s, "j")
		expect(s.sel).toBe(items[2].key)
		s = key(key(key(key(s, "j"), "j"), "j"), "down")
		expect(s.sel).toBe(items[4].key)
		s = key(s, "k")
		expect(s.sel).toBe(items[3].key)
		s = key(s, "g")
		expect(s.sel).toBe(items[1].key)
		s = key(s, "G")
		expect(s.sel).toBe(items[4].key)
	end)

	it("opens details with enter; escape goes back, then closes the block", function()
		local s = key(loaded(false), "enter")
		expect(s.detail).toBe(true)
		local back, e1 = key(s, "escape")
		expect(back.detail).toBe(false)
		expect(find(e1, "exit")).toBeNil()
		local _, e2 = key(back, "escape")
		expect(find(e2, "exit") ~= nil).toBe(true)
	end)

	it("filters by project, account and source, keeping the selection when it is still shown", function()
		local s = loaded(false)
		s = key(s, "s") -- source: guard
		expect(s.filters.source).toBe("guard")
		expect(#State.visible(s)).toBe(1)
		s = key(s, "s") -- source: local
		expect(#State.visible(s)).toBe(3)
		s = key(s, "p") -- project: billing
		expect(s.filters.project).toBe("billing")
		expect(#State.visible(s)).toBe(2)
		s = key(s, "j")
		local sel = s.sel
		s = key(s, "a") -- account: the only one of the billing deploys
		expect(s.sel).toBe(sel)
		s = key(s, "x")
		expect(s.filters).toEqual({})
		expect(#State.visible(s)).toBe(4)
	end)

	it("reloads everything with r and ignores answers to the previous load", function()
		local s = loaded(false)
		local old = s.gen
		local fresh, effects = key(s, "r")
		expect(fresh.gen > old).toBe(true)
		expect(find(effects, "read_local") ~= nil).toBe(true)
		local stale = State.update(fresh, { t = "local", gen = old, text = "" })
		expect(#State.visible(stale)).toBe(4)
	end)

	it("reloads the local history when a new deploy was recorded", function()
		local _, effects = State.update(loaded(false), { t = "recorded" })
		expect(find(effects, "read_local") ~= nil).toBe(true)
	end)
end)

describe("CI runs in the history", function()
	it("opens the selected run's page and its failed-step log", function()
		local s = key(loaded(true), "s") -- source: ci
		expect(s.filters.source).toBe("ci")
		local _, opened = key(s, "o")
		expect((find(opened, "open") :: Effect).url).toBe(
			"https://github.com/example-org/example-repo/actions/runs/1000000107"
		)
		local _, noLog = key(s, "l")
		expect(find(noLog, "log")).toBeNil()
		s = key(s, "G") -- the oldest run failed
		local _, log = key(s, "l")
		local e = find(log, "log") :: Effect
		expect(e.repo).toBe("example-org/example-repo")
		expect(e.runId).toBe(1000000102)
	end)

	it("reports a gh failure but keeps showing the local history", function()
		local s, effects = State.init({ cwd = "/work/sdf/billing", settings = settings(true), decode = json.decode })
		s = State.update(s, { t = "local", gen = s.gen, text = LOCAL })
		s = State.update(s, {
			t = "git",
			gen = (find(effects, "git") :: Effect).gen,
			stdout = "root=/work\nbranch=develop\nremote=git@github.com:example-org/example-repo\n",
		})
		s = State.update(s, {
			t = "ci",
			gen = s.gen,
			status = 1,
			stdout = "",
			stderr = "HTTP 404: workflow x not found\n",
			timedOut = false,
		})
		expect(s.ciLoad).toBe("error")
		expect(s.ciError).toBe("HTTP 404: workflow x not found")
		expect(#State.visible(s)).toBe(3)
	end)
end)

return nil
