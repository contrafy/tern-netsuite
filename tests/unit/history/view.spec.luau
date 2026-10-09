--!strict
local Record = require("../../../plugin/lib/history/record")
local State = require("../../../plugin/lib/history/state")
local View = require("../../../plugin/lib/history/view")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local FMT: View.Format = {
	day = function(at: number): string
		return os.date("!%Y-%m-%d", at) :: string
	end,
	clock = function(at: number): string
		return os.date("!%H:%M", at) :: string
	end,
	rows = 40,
}

local function line(r: { [string]: any }): string
	local base: { [string]: any } = {
		startedAt = r.at - 72,
		command = "project:deploy",
		status = 0,
		tookMs = 72000,
		authId = "demo-sb",
		accountSource = "cli",
	}
	for k, v in r do
		base[k] = v
	end
	return Record.encode(base :: any)
end

local LOCAL = line({
	at = 1791400000,
	cwd = "/work/sdf/billing",
	line = "suitecloud project:deploy --log d.log",
	project = "billing",
	accountId = "1234567_SB1",
	accountLabel = "1234567_SB1",
	production = false,
	branch = "develop",
	head = "74fbe1735dfd1db4fe1faf64bcf5e28849817553",
	dirty = true,
	log = "/work/sdf/billing/d.log",
}) .. line({
	at = 1791400500,
	cwd = "/work/sdf/payroll",
	line = "suitecloud project:deploy",
	project = "payroll",
	status = 1,
	authId = "prod",
	accountId = "1234567",
	accountLabel = "PROD",
	production = true,
	accountSource = "configured",
})

-- Every text the view shows, in order, plus badge texts with their tone.
local function texts(node: any, out: { string }?): { string }
	local acc = out or {}
	if type(node) ~= "table" then
		return acc
	end
	local p = node.p
	if p then
		if node.k == "badge" then
			table.insert(acc, "[" .. p.text .. ":" .. p.tone .. "]")
		end
		for _, field in { "spans", "head", "label" } do
			if type(p[field]) == "table" then
				for _, s in p[field] do
					table.insert(acc, s.t)
				end
			end
		end
		if type(p.items) == "table" then
			for _, kv in p.items do
				for _, s in kv.k do
					table.insert(acc, s.t)
				end
				for _, s in kv.v do
					table.insert(acc, s.t)
				end
			end
		end
	end
	for _, c in node.c or {} do
		texts(c, acc)
	end
	return acc
end

local function joined(v: { main: any, dock: any }): string
	return table.concat(texts(v.main), " | ") .. " || " .. table.concat(texts(v.dock), " | ")
end

local function loaded(): State.State
	local s = State.init({
		cwd = "/work/sdf/billing",
		settings = { max_entries = 500, ci = nil },
		decode = json.decode,
	})
	s = State.update(s, { t = "local", gen = s.gen, text = LOCAL })
	s = State.update(s, { t = "guard", gen = s.gen, text = "" })
	return s
end

describe("the history block", function()
	it("lists deploys by day with project, account, source, status, git ref and duration", function()
		local text = joined(View.view(loaded(), FMT))
		expect(text).toContain("2026-10-07")
		expect(text).toContain("billing")
		expect(text).toContain("[local:neutral]")
		expect(text).toContain("[ok:success]")
		expect(text).toContain("develop@74fbe17*")
		expect(text).toContain("1m 12s")
		expect(text).toContain("billing | deploy")
	end)

	it("flags production deploys in the error tone so they stand out", function()
		local text = joined(View.view(loaded(), FMT))
		expect(text).toContain("[PROD:error]")
		expect(text).toContain("[failed:error]")
	end)

	it("shows the full command, directory and log file in the details", function()
		local s = State.update(loaded(), { t = "key", name = "j" })
		s = State.update(s, { t = "key", name = "enter" })
		local text = joined(View.view(s, FMT))
		expect(text).toContain("suitecloud project:deploy --log d.log")
		expect(text).toContain("/work/sdf/billing")
		expect(text).toContain("/work/sdf/billing/d.log")
		expect(text).toContain("dirty")
	end)

	it("links a CI run's details to its page", function()
		local s = State.init({
			cwd = "/work",
			settings = {
				max_entries = 500,
				ci = { gh = "gh", workflow = "w.yml", limit = 20, timeout_ms = 20000, poll_seconds = 300 },
			},
			decode = json.decode,
		})
		s = State.update(s, { t = "local", gen = s.gen, text = "" })
		s = State.update(
			s,
			{ t = "git", gen = s.gen, stdout = "root=/work\nremote=git@github.com:example-org/example-repo\n" }
		)
		s = State.update(s, {
			t = "ci",
			gen = s.gen,
			status = 0,
			stdout = fixtures.read("history/gh-run-list.json"),
			stderr = "",
			timedOut = false,
		})
		s = State.update(s, { t = "key", name = "enter" })
		local text = joined(View.view(s, FMT))
		expect(text).toContain("https://github.com/example-org/example-repo/actions/runs/1000000107")
		expect(text).toContain("Merge pull request #13 from example-org/feature-c")
	end)

	it("says so when there is nothing recorded yet", function()
		local s = State.init({ cwd = "/w", settings = { max_entries = 500, ci = nil }, decode = json.decode })
		s = State.update(s, { t = "local", gen = s.gen, text = nil })
		s = State.update(s, { t = "guard", gen = s.gen, text = nil })
		expect(joined(View.view(s, FMT))).toContain("No deploys recorded yet")
	end)
end)

return nil
