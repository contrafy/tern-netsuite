--!strict
local Cache = require("../../../plugin/lib/drift/cache")
local CliSlot = require("../../../plugin/lib/sdf/cli_slot")
local State = require("../../../plugin/lib/drift/state")
local fixtures = require("../../lib/fixtures")
local sample = require("./sample")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

type S = State.State
type Effect = any

local OBJ = sample.DIR .. "/src/Objects/"
local FC = sample.DIR .. "/src/FileCabinet"
local ORDERS = "/SuiteScripts/acme/acme_orders_ue.js"
local ORDERS_JS = "/** Acme orders */\nfunction afterSubmit() {}\n"

local function step(s: S, msg: any): (S, { Effect })
	return State.update(s, msg)
end

local function find(effects: { Effect }, kind: string, stepName: string?): any
	for _, e in effects do
		if e.t == kind and (stepName == nil or e.step == stepName) then
			return e
		end
	end
	return nil
end

-- Opens the block on the sample project up to the cache read.
local function open(opts: { held: boolean?, cached: any?, suiteApp: boolean?, accountOnly: boolean? }?): (S, { Effect })
	local o: any = opts or {}
	local s, effects = State.init({ cwd = sample.ROOT .. "/src", held = o.held, accountOnly = o.accountOnly })
	expect(find(effects, "find") ~= nil).toBe(true)
	s = step(s, { t = "config", config = sample.CFG, now = 1000, clock = 1700000000 })
	s, effects = step(s, { t = "found", gen = s.gen, root = sample.ROOT })
	local project, texts = sample.project({ suiteApp = o.suiteApp })
	s, effects = step(s, { t = "scanned", gen = s.gen, project = project, texts = texts })
	local load = find(effects, "load")
	expect(load ~= nil).toBe(true)
	expect(load.file).toBe(Cache.fileName(sample.ROOT, "demo-sb"))
	return step(s, { t = "loaded", gen = s.gen, file = load.file, value = o.cached })
end

local function prepared(s: S, effects: { Effect }): (S, { Effect })
	local prep = find(effects, "prepare")
	expect(prep ~= nil).toBe(true)
	return step(s, { t = "prepared", gen = s.gen, run = prep.run, dir = sample.DIR })
end

local function answer(s: S, e: Effect, stdout: string, texts: { [string]: string }?, status: number?): (S, { Effect })
	return step(s, {
		t = "ran",
		gen = e.gen,
		run = e.run,
		dir = e.dir,
		step = e.step,
		argv = e.argv,
		status = status or 0,
		stdout = stdout,
		stderr = "",
		timedOut = false,
		texts = texts or {},
		now = 2000,
		clock = 1700000600,
	})
end

local function entry(s: S, kind: string, id: string): any
	for _, e in State.entries(s, kind :: any) do
		if e.id == id then
			return e
		end
	end
	return nil
end

-- Runs the whole comparison with the account answers of the fixtures.
local function runAll(s: S, effects: { Effect }): (S, { Effect })
	s, effects = prepared(s, effects)
	local imp = find(effects, "run", "objects") :: Effect
	s, effects = answer(s, imp, fixtures.read("drift/object-import-mixed.txt"), {
		[OBJ .. "customlist_acme_sizes.xml"] = fixtures.read("drift/account/customlist_acme_sizes.xml"),
		[OBJ .. "customlist_acme_colors.xml"] = fixtures.read("drift/account/customlist_acme_colors.xml"),
	})
	local files = find(effects, "run", "files") :: Effect
	local out = "The following files were imported:\n"
		.. ORDERS
		.. "\nThe following files were not imported:\n/SuiteScripts/acme/acme_missing.js, INVALID FILE PATH: /SuiteScripts/acme/acme_missing.js\n"
	return answer(s, files, out, {
		[FC .. ORDERS] = ORDERS_JS,
		[sample.ROOT .. "/src/FileCabinet" .. ORDERS] = ORDERS_JS,
	})
end

describe("drift state", function()
	it("imports into a scratch project naming the chosen auth ID, never into the user's project", function()
		local s, effects = open()
		local prep = find(effects, "prepare") :: Effect
		local paths: { [string]: string } = {}
		for _, w in prep.plan.writes do
			paths[w.path] = w.text
		end
		expect(paths["project.json"]).toContain('"defaultAuthId": "demo-sb"')
		expect(paths["suitecloud.config.js"]).toBe('module.exports = {\n\tdefaultProjectFolder: "src",\n};\n')
		expect(paths["src/manifest.xml"] ~= nil).toBe(true)
		expect(paths["src/deploy.xml"]).toBeNil()
		s, effects = prepared(s, effects)
		local imp = find(effects, "run", "objects") :: Effect
		expect(imp.cwd).toBe(sample.DIR)
		expect(imp.slot).toBe("demo-sb")
		expect(table.concat(imp.argv, " ")).toBe(
			"/opt/bin/suitecloud object:import --type customlist --scriptid customlist_acme_colors customlist_acme_missing customlist_acme_sizes --destinationfolder /Objects --excludefiles"
		)
		expect(s.run and s.run.total).toBe(5)
	end)

	it("classifies formatting-only, changed and missing objects and files, with a diff for real changes", function()
		local s, effects = runAll(open())
		local sizes = entry(s, "object", "customlist_acme_sizes")
		expect(sizes.status).toBe("identical")
		expect(sizes.note).toBe("formatting differs only")
		local colors = entry(s, "object", "customlist_acme_colors")
		expect(colors.status).toBe("changed")
		expect(colors.diff).toContain("-      <isinactive>F</isinactive>")
		expect(colors.diff).toContain("+      <isinactive>T</isinactive>")
		expect(entry(s, "object", "customlist_acme_missing").status).toBe("missing")
		expect(entry(s, "file", ORDERS).status).toBe("identical")
		expect(entry(s, "file", "/SuiteScripts/acme/acme_missing.js").status).toBe("missing")
		expect(s.run and s.run.status).toBe("done")
		local save = find(effects, "save") :: Effect
		expect(save.file).toBe(Cache.fileName(sample.ROOT, "demo-sb"))
		local cached = Cache.decode(save.value, sample.ROOT, "demo-sb")
		expect(cached and cached.at).toBe(1700000600)
		expect(find(effects, "cleanup").dir).toBe(sample.DIR)
	end)

	it("runs account commands one at a time, each in the auth ID's CLI slot", function()
		local s, effects = open()
		s, effects = prepared(s, effects)
		local runs = 0
		for _, e in effects do
			if e.t == "run" then
				runs += 1
			end
		end
		expect(runs).toBe(1)
		expect(s.inflight).toBe(1)
		expect(#s.queue).toBe(1)
		expect((s.queue[1] :: Effect).slot).toBe("demo-sb")
	end)

	it("shows the cached result without running the CLI, and r rescans the project before running again", function()
		local s0, e0 = runAll(open())
		local cachedValue = (find(e0, "save") :: Effect).value
		local s, effects = open({ cached = cachedValue })
		expect(find(effects, "prepare")).toBeNil()
		expect(s.cached).toBe(true)
		expect(entry(s, "object", "customlist_acme_colors").status).toBe("changed")
		expect(s0.result ~= nil).toBe(true)
		s, effects = step(s, { t = "key", name = "r" })
		expect(find(effects, "scan") ~= nil).toBe(true)
		expect(find(effects, "prepare")).toBeNil()
		local project, texts = sample.project()
		s, effects = step(s, { t = "scanned", gen = s.gen, project = project, texts = texts })
		expect(find(effects, "prepare") ~= nil).toBe(true)
		expect(entry(s, "object", "customlist_acme_colors").status).toBe("pending")
	end)

	it("runs nothing from a bare link until Enter", function()
		local s, effects = open({ held = true })
		expect(find(effects, "prepare")).toBeNil()
		expect(find(effects, "run")).toBeNil()
		s, effects = step(s, { t = "key", name = "enter" })
		local project, texts = sample.project()
		s, effects = step(s, { t = "scanned", gen = s.gen, project = project, texts = texts })
		expect(find(effects, "prepare") ~= nil).toBe(true)
		expect(s.held).toBe(false)
	end)

	-- Opens on a project whose project.json names `authId`, up to the cache miss.
	local function openAs(authId: string): (S, { Effect }, Effect?)
		local s = State.init({ cwd = sample.ROOT })
		s = step(s, { t = "config", config = sample.CFG, now = 1000, clock = 1700000000 })
		s = step(s, { t = "found", gen = s.gen, root = sample.ROOT })
		local project, texts = sample.project({ authId = authId })
		local effects
		s, effects = step(s, { t = "scanned", gen = s.gen, project = project, texts = texts })
		local info = find(effects, "run", "info")
		local load = find(effects, "load") :: Effect
		s, effects = step(s, { t = "loaded", gen = s.gen, file = load.file, value = nil })
		return s, effects, info
	end

	it("waits for Enter without a cache when the project's account is production", function()
		local s, effects = openAs("demo-prod")
		expect(find(effects, "prepare")).toBeNil()
		expect(s.held).toBe(true)
		expect(s.heldFor).toBe("target")
		s, effects = step(s, { t = "key", name = "enter" })
		local project, texts = sample.project({ authId = "demo-prod" })
		s, effects = step(s, { t = "scanned", gen = s.gen, project = project, texts = texts })
		expect(find(effects, "prepare") ~= nil).toBe(true)
	end)

	it("classifies an unknown auth ID with --info before running without a cache", function()
		local s, effects, info = openAs("acme-new")
		expect(info ~= nil).toBe(true)
		expect(find(effects, "prepare")).toBeNil()
		expect(s.held).toBe(false)
		local e = info :: Effect
		local stdout = string.gsub(fixtures.read("suitecloud/manageauth/info-sandbox.txt"), "demo%-sb", "acme-new")
		s, effects = step(s, {
			t = "ran",
			gen = e.gen,
			step = "info",
			argv = e.argv,
			status = 0,
			stdout = stdout,
			stderr = "",
			timedOut = false,
			now = 1001,
		})
		expect(find(effects, "prepare") ~= nil).toBe(true)
	end)

	it("waits for Enter when --info cannot classify the auth ID", function()
		local s, effects, info = openAs("demo-missing")
		local e = info :: Effect
		s, effects = step(s, {
			t = "ran",
			gen = e.gen,
			step = "info",
			argv = e.argv,
			status = 1,
			stdout = fixtures.read("suitecloud/manageauth/info-missing.txt"),
			stderr = "",
			timedOut = false,
			now = 1001,
		})
		expect(find(effects, "prepare")).toBeNil()
		expect(s.held).toBe(true)
	end)

	it(
		"cancels: the queue is dropped, the answer in flight ignored and the scratch project removed afterwards",
		function()
			local s, effects = open()
			s, effects = prepared(s, effects)
			local imp = find(effects, "run", "objects") :: Effect
			s, effects = step(s, { t = "key", name = "c" })
			expect(s.run and s.run.status).toBe("cancelled")
			expect(#s.queue).toBe(0)
			expect(find(effects, "cleanup")).toBeNil()
			s, effects = answer(s, imp, fixtures.read("drift/object-import-mixed.txt"))
			expect(entry(s, "object", "customlist_acme_colors").status).toBe("pending")
			expect(find(effects, "run")).toBeNil()
			expect(find(effects, "cleanup").dir).toBe(sample.DIR)
			expect(find(effects, "save")).toBeNil()
		end
	)

	it("stops at an expired login instead of failing every batch the same way", function()
		local s, effects = open()
		s, effects = prepared(s, effects)
		local imp = find(effects, "run", "objects") :: Effect
		s, effects = answer(s, imp, "Starting the browser-based authentication process...\n", {}, 1)
		expect(s.run and s.run.status).toBe("failed")
		expect(s.run and s.run.error).toContain("browser login for auth ID demo-sb")
		expect(find(effects, "run")).toBeNil()
		expect(entry(s, "file", ORDERS).status).toBe("error")
		expect(find(effects, "cleanup") ~= nil).toBe(true)
	end)

	it("stops when another command keeps the auth ID's slot busy", function()
		local s, effects = open()
		s, effects = prepared(s, effects)
		local imp = find(effects, "run", "objects") :: Effect
		s, effects = step(s, {
			t = "ran",
			gen = imp.gen,
			run = imp.run,
			dir = imp.dir,
			step = "objects",
			argv = imp.argv,
			status = CliSlot.BUSY_STATUS,
			stdout = "",
			stderr = "tern-netsuite: project:deploy (pid 42) still holds this auth ID after 45 s; nothing was run, try again when it finishes\n",
			timedOut = false,
			now = 2000,
		})
		expect(s.run and s.run.error).toContain("project:deploy (pid 42) still holds this auth ID")
		expect(entry(s, "object", "customlist_acme_sizes").status).toBe("error")
	end)

	it("keeps an object the account refuses to export apart from missing ones", function()
		local s, effects = open()
		s, effects = prepared(s, effects)
		local imp = find(effects, "run", "objects") :: Effect
		local out = "The following objects have not been imported:\n"
			.. "    - customlist:customlist_acme_sizes failed: You cannot download the XML file for this object because it is locked..\n"
		s, effects = answer(s, imp, out, {}, 1)
		local e = entry(s, "object", "customlist_acme_sizes")
		expect(e.status).toBe("error")
		expect(e.note).toContain("locked")
		expect(entry(s, "object", "customlist_acme_colors").note).toBe("the CLI did not report this object")
	end)

	it("lists account-only objects under the project's prefixes on o, without importing them", function()
		local s, effects = runAll(open())
		s, effects = step(s, { t = "key", name = "o" })
		s, effects = prepared(s, effects)
		local list = find(effects, "run", "list") :: Effect
		expect(table.concat(list.argv, " ")).toBe("/opt/bin/suitecloud object:list")
		expect(find(effects, "run", "objects")).toBeNil()
		local out = "The following objects were found in your account:\n"
			.. "customlist:customlist_acme_sizes\ncustomlist:customlist_acme_regions\ncustomlist:customlist_other_x\nrestlet:customscript_acme_rl\n"
		s, effects = answer(s, list, out)
		expect(entry(s, "object", "customlist_acme_regions").status).toBe("account")
		expect(entry(s, "object", "customlist_other_x")).toBeNil()
		expect(entry(s, "object", "customscript_acme_rl")).toBeNil()
		expect(entry(s, "object", "customlist_acme_colors").status).toBe("changed")
		expect(find(effects, "save") ~= nil).toBe(true)
	end)

	it("offers configured and CLI auth IDs, failing closed to production for accounts it cannot classify", function()
		local s, effects = open({ cached = {} })
		s, effects = step(s, { t = "key", name = "p" })
		local auths = find(effects, "run", "auths") :: Effect
		expect(auths.slot).toBeNil()
		s, effects = step(s, {
			t = "ran",
			gen = auths.gen,
			step = "auths",
			argv = auths.argv,
			status = 0,
			stdout = fixtures.read("suitecloud/manageauth/list.txt") .. "acme-live | Administrator @ Acme Corp\n",
			stderr = "",
			timedOut = false,
			now = 3000,
		})
		local byId: { [string]: any } = {}
		for _, c in State.choices(s) do
			byId[c.authId] = c
		end
		expect(byId["demo-sb"].target.production).toBe(false)
		expect(byId["demo-prod"].target.production).toBe(true)
		expect(byId["acme-live"].target.production).toBe(true)
		expect(byId["acme-live"].target.label).toBe("PROD")
		local ids = {}
		for i, c in State.choices(s) do
			ids[i] = c.authId
		end
		local prodAt = table.find(ids, "demo-prod") :: number
		s, effects = step(s, { t = "action", act = "pick", value = tostring(prodAt) })
		expect(s.authId).toBe("demo-prod")
		local load = find(effects, "load")
		expect(load.file).toBe(Cache.fileName(sample.ROOT, "demo-prod"))
		expect(s.target and s.target.production).toBe(true)
		s, effects = step(s, { t = "loaded", gen = s.gen, file = load.file, value = nil })
		expect(find(effects, "prepare")).toBeNil()
		expect(s.held).toBe(true)
	end)

	it("brings the previous result back when a rerun is cancelled", function()
		local s0, e0 = runAll(open())
		expect(s0.result ~= nil).toBe(true)
		local s = open({ cached = find(e0, "save").value })
		s = step(s, { t = "key", name = "r" })
		local project, texts = sample.project()
		s = step(s, { t = "scanned", gen = s.gen, project = project, texts = texts })
		expect(entry(s, "object", "customlist_acme_colors").status).toBe("pending")
		s = step(s, { t = "key", name = "c" })
		expect(entry(s, "object", "customlist_acme_colors").status).toBe("changed")
		expect(s.cached).toBe(true)
		expect(s.message and s.message.text).toContain("previous result")
	end)

	it("imports a SuiteApp's objects by application ID and explains why its files are skipped", function()
		local s, effects = open({ suiteApp = true })
		s, effects = prepared(s, effects)
		local imp = find(effects, "run", "objects") :: Effect
		expect(table.concat(imp.argv, " ")).toContain("--appid com.acme.billing")
		expect(#State.entries(s, "file")).toBe(0)
		expect((s.result :: any).problems[1]).toContain("SuiteApp")
	end)
end)

return nil
