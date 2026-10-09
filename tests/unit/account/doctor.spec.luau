--!strict
local Config = require("../../../plugin/lib/config")
local Context = require("../../../plugin/lib/account/context")
local Doctor = require("../../../plugin/lib/account/doctor")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

type State = Doctor.State
type Effect = Doctor.Effect
type Msg = Doctor.Msg

local CFG_TEXT = '{"accounts": [{"id": "sb", "label": "SB1", "account_id": "1234567_SB1", "auth_ids": ["demo-sb"]},'
	.. ' {"id": "prod", "label": "PROD", "account_id": "1234567", "auth_ids": ["demo-prod", "demo-gone"]}]}'
local CFG = Config.parse(CFG_TEXT, json.decode)

local function project(authId: string?, name: string?): Context.Context
	local n = name or "billing"
	return { projectRoot = "/r/sdf/" .. n, projectName = n, authId = authId, problem = nil }
end

local function find(effects: { Effect }, pred: (Effect) -> boolean): Effect?
	for _, e in effects do
		if pred(e) then
			return e
		end
	end
	return nil
end

local function runOf(effects: { Effect }, step: string, authId: string?): Effect?
	return find(effects, function(e: Effect): boolean
		return e.t == "run" and e.step == step and (authId == nil or e.authId == authId)
	end)
end

local function check(s: State, id: string): Doctor.Check
	for _, c in Doctor.checks(s) do
		if c.id == id then
			return c
		end
	end
	error("no check " .. id)
end

local function ran(
	s: State,
	step: Doctor.Step,
	out: { status: number?, stdout: string?, stderr: string?, authId: string? }
): (State, { Effect })
	return Doctor.update(s, {
		t = "ran",
		gen = s.gen,
		step = step,
		authId = out.authId,
		status = out.status or 0,
		stdout = out.stdout or "",
		stderr = out.stderr or "",
		timedOut = false,
	})
end

-- Config loaded, project scanned, program resolved: the state the list and
-- --info answers arrive in.
local function ready(projects: { Context.Context }?, list: string?): (State, { Effect })
	local s = Doctor.init({ cwd = "/r/sdf/billing" })
	s = Doctor.update(
		s,
		{ t = "config", gen = s.gen, config = CFG, diagnostics = {}, path = "/c.json", status = "loaded" }
	)
	s = Doctor.update(s, {
		t = "scanned",
		gen = s.gen,
		context = project("demo-sb"),
		projects = projects or { project("demo-sb") },
	})
	s = ran(s, "which", { stdout = "/usr/local/bin/suitecloud\n" })
	return ran(s, "list", { stdout = list or fixtures.read("suitecloud/manageauth/list.txt") })
end

describe("starting the doctor", function()
	it("loads the config and scans the project first; everything else waits for them", function()
		local s, effects = Doctor.init({ cwd = "/r" })
		expect(find(effects, function(e)
			return e.t == "config"
		end) ~= nil).toBe(true)
		expect((find(effects, function(e)
			return e.t == "scan"
		end) :: Effect).cwd).toBe("/r")
		expect(check(s, "program").severity).toBe("pending")
	end)

	it("looks the configured program up on PATH and checks Java once the config is in", function()
		local s = Doctor.init({ cwd = nil })
		local cfg = Config.parse('{"suitecloud": {"program": "/opt/sc"}}', json.decode)
		local _, effects = Doctor.update(
			s,
			{ t = "config", gen = s.gen, config = cfg, diagnostics = {}, path = nil, status = "loaded" }
		)
		local which = runOf(effects, "which") :: Effect
		expect(which.argv[#which.argv]).toBe("/opt/sc")
		expect(runOf(effects, "java") ~= nil).toBe(true)
	end)
end)

describe("the SuiteCloud CLI and Java", function()
	it("asks for the version and the auth id list through the resolved path", function()
		local s = Doctor.init({ cwd = nil })
		s = Doctor.update(
			s,
			{ t = "config", gen = s.gen, config = CFG, diagnostics = {}, path = nil, status = "missing" }
		)
		local s2, effects = ran(s, "which", { stdout = "/usr/local/bin/suitecloud\n" })
		expect((runOf(effects, "version") :: Effect).argv).toEqual({ "/usr/local/bin/suitecloud", "--version" })
		expect((runOf(effects, "list") :: Effect).argv).toEqual({
			"/usr/local/bin/suitecloud",
			"account:manageauth",
			"--list",
		})
		expect(check(s2, "program").severity).toBe("ok")
	end)

	it("reports a missing CLI with how to fix it, and runs nothing else through it", function()
		local s = Doctor.init({ cwd = nil })
		s = Doctor.update(
			s,
			{ t = "config", gen = s.gen, config = CFG, diagnostics = {}, path = nil, status = "missing" }
		)
		local s2, effects = ran(s, "which", { status = 1 })
		expect(#effects).toBe(0)
		local c = check(s2, "program")
		expect(c.severity).toBe("error")
		expect(c.hint).toContain("suitecloud.program")
		expect(check(s2, "list").severity).toBe("error")
	end)

	it("accepts the Java versions the CLI's SDK supports", function()
		local s = ran(Doctor.init({ cwd = nil }), "java", { stderr = 'openjdk version "21.0.11" 2026-04-21\n' })
		expect(check(s, "java").severity).toBe("ok")
		expect(check(s, "java").detail).toContain("21.0.11")
	end)

	it("flags an unsupported or missing Java, which breaks every account command", function()
		local old = ran(Doctor.init({ cwd = nil }), "java", { stderr = 'java version "1.8.0_202"\n' })
		expect(check(old, "java").severity).toBe("error")
		expect(check(old, "java").hint).toContain("17")
		local none = ran(Doctor.init({ cwd = nil }), "java", { status = 127, stderr = "sh: java: not found" })
		expect(check(none, "java").severity).toBe("error")
	end)
end)

describe("auth ids", function()
	it("checks --info for configured and project auth ids the CLI lists, never for missing ones", function()
		local _, effects = ready()
		expect(runOf(effects, "info", "demo-sb") ~= nil).toBe(true)
		expect(runOf(effects, "info", "demo-prod") ~= nil).toBe(true)
		expect(runOf(effects, "info", "demo-gone")).toBeNil()
	end)

	it("reports a configured auth id that is not set up on this machine", function()
		local s = ready()
		local c = check(s, "auth:demo-gone")
		expect(c.severity).toBe("error")
		expect(c.hint).toContain("account:setup")
	end)

	it("confirms an auth id that points at its configured account", function()
		local s = ready()
		s = ran(s, "info", { authId = "demo-sb", stdout = fixtures.read("suitecloud/manageauth/info-sandbox.txt") })
		local c = check(s, "auth:demo-sb")
		expect(c.severity).toBe("ok")
		expect(c.production).toBe(false)
	end)

	it("flags a production account so it stands out", function()
		local s = ready()
		s = ran(s, "info", {
			authId = "demo-prod",
			stdout = "Authentication ID: demo-prod\nAccount ID: 1234567\nAccount Type: Production\n",
		})
		local c = check(s, "auth:demo-prod")
		expect(c.severity).toBe("ok")
		expect(c.production).toBe(true)
	end)

	it("catches an auth id re-pointed at another account than the config says", function()
		local s = ready()
		s = ran(s, "info", { authId = "demo-sb", stdout = "Authentication ID: demo-sb\nAccount ID: 9999999_SB1\n" })
		local c = check(s, "auth:demo-sb")
		expect(c.severity).toBe("error")
		expect(c.detail).toContain("9999999_SB1")
	end)

	it("shows the CLI's reason when --info fails", function()
		local s = ready()
		s = ran(s, "info", {
			authId = "demo-sb",
			status = 1,
			stdout = fixtures.read("suitecloud/manageauth/info-missing.txt"),
		})
		expect(check(s, "auth:demo-sb").detail).toContain("is not available")
	end)

	it("warns about project auth ids missing from the config: they resolve through the CLI only", function()
		local list = fixtures.read("suitecloud/manageauth/list.txt")
			.. "loose | Administrator @ Example Corp | 1234567-sb1.app.netsuite.com\n"
		local s, effects = ready({ project("demo-sb"), project("demo-prod", "a"), project("loose", "b") }, list)
		local c = check(s, "auth:loose")
		expect(c.severity).toBe("warning")
		expect(c.detail).toContain("b")
		expect(c.hint).toContain("auth_ids")
		expect(runOf(effects, "info", "loose") ~= nil).toBe(true)
	end)

	it("reports a project auth id that is not set up at all, since that project cannot deploy", function()
		local s, effects = ready({ project("demo-sb"), project("loose", "b") })
		expect(check(s, "auth:loose").severity).toBe("error")
		expect(runOf(effects, "info", "loose")).toBeNil()
	end)
end)

describe("config and project", function()
	it("lists config diagnostics with their key path", function()
		local s = Doctor.init({ cwd = nil })
		s = Doctor.update(s, {
			t = "config",
			gen = s.gen,
			config = CFG,
			diagnostics = { { level = "error", path = "guard.timeout_s", message = "must be an integer" } },
			path = "/c.json",
			status = "loaded",
		})
		local c = check(s, "config:1")
		expect(c.severity).toBe("error")
		expect(c.detail).toContain("guard.timeout_s")
	end)

	it("explains a project without a default auth id", function()
		local s = Doctor.init({ cwd = "/r/sdf/x" })
		local ctx = project(nil)
		ctx.problem = "no project.json (the CLI asks for an auth id)"
		s = Doctor.update(s, { t = "scanned", gen = s.gen, context = ctx, projects = { ctx } })
		expect(check(s, "project").severity).toBe("warning")
	end)
end)

describe("keys and reruns", function()
	it("reruns every check on r and ignores answers from the previous run", function()
		local s = ready()
		local oldGen = s.gen
		local s2, effects = Doctor.update(s, { t = "key", name = "r" })
		expect(s2.gen).toBe(oldGen + 1)
		expect(find(effects, function(e)
			return e.t == "config"
		end) ~= nil).toBe(true)
		local stale = Doctor.update(s2, {
			t = "ran",
			gen = oldGen,
			step = "java",
			status = 0,
			stdout = "",
			stderr = 'openjdk version "21"',
			timedOut = false,
		})
		expect(stale).toBe(s2)
	end)

	it("closes on escape", function()
		local _, effects = Doctor.update(Doctor.init({ cwd = nil }), { t = "key", name = "escape" })
		expect(effects[1].t).toBe("exit")
	end)

	it("ignores other keys so the view does not re-render", function()
		local s = Doctor.init({ cwd = nil })
		local s2, effects = Doctor.update(s, { t = "key", name = "x" })
		expect(s2).toBe(s)
		expect(#effects).toBe(0)
	end)

	it("reports a timed-out command as such", function()
		local s = Doctor.update(Doctor.init({ cwd = nil }), {
			t = "ran",
			gen = 1,
			step = "java",
			status = -1,
			stdout = "",
			stderr = "",
			timedOut = true,
		})
		expect(check(s, "java").detail).toContain("timed out")
	end)
end)

describe("rendering", function()
	it("renders every state without raising", function()
		local s = ready()
		local v = Doctor.view(s)
		expect(v.main ~= nil).toBe(true)
		expect(Doctor.title(s)).toContain("Doctor")
	end)
end)

return nil
