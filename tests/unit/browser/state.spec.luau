--!strict
local Config = require("../../../plugin/lib/config")
local Render = require("../../../plugin/lib/browser/render")
local State = require("../../../plugin/lib/browser/state")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local sample = require("./sample")
local t = require("../../lib/test")
local ui = require("../../../plugin/lib/ui")

local describe, it, expect = t.describe, t.it, t.expect

type S = State.State
-- Effects are read field by field; which optional fields are set is known.
type Effect = any

local CFG = Config.parse(
	[[{
	"suitecloud": { "program": "/opt/bin/suitecloud", "timeout_ms": 90000 },
	"accounts": [
		{ "id": "sandbox", "label": "SB1", "account_id": "1234567_SB1", "auth_ids": ["demo-sb"] },
		{ "id": "prod", "label": "PROD", "account_id": "1234567", "auth_ids": ["demo-prod"], "production": true }
	]
}]],
	json.decode
)

local function fixture(name: string): string
	return fixtures.read("suitecloud/list/" .. name .. ".txt")
end

-- Walks every node and joins visible text.
local function textOf(node: any): string
	local parts: { string } = {}
	local function walk(n: any)
		local p = n.p or {}
		if type(p.text) == "string" then
			table.insert(parts, p.text)
		end
		for _, s in p.spans or {} do
			table.insert(parts, s.t)
		end
		for _, c in n.c or {} do
			walk(c)
		end
	end
	walk(node)
	return table.concat(parts, "\n")
end

local function viewText(s: S): string
	local v = Render.view(s)
	return textOf(v.main) .. "\n" .. textOf(v.dock)
end

local function step(s: S, msg: any): (S, { Effect })
	return State.update(s, msg)
end

local function find(effects: { Effect }, pred: (Effect) -> boolean): Effect?
	for _, e in effects do
		if pred(e) then
			return e
		end
	end
	return nil
end

local function run(effects: { Effect }, stepName: string): Effect?
	return find(effects, function(e)
		return e.t == "run" and e.step == stepName
	end)
end

-- A browser with config and the sample project scanned (auth id `authId`).
local function scanned(authId: string?): (S, { Effect })
	local s = State.init({ cwd = sample.ROOT .. "/src" })
	s = step(s, { t = "config", config = CFG })
	s = step(s, { t = "found", gen = s.gen, root = sample.ROOT })
	return step(s, { t = "scanned", gen = s.gen, project = sample.project(authId) })
end

local function ran(s: S, e: Effect, stdout: string, status: number?, extra: { [string]: any }?): (S, { Effect })
	local msg: any = {
		t = "ran",
		gen = e.gen,
		step = e.step,
		folder = e.folder,
		token = e.token,
		status = status or 0,
		stdout = stdout,
		stderr = "",
		timedOut = false,
		now = 5000,
	}
	for k, v in (extra or {}) :: { [string]: any } do
		msg[k] = v
	end
	return step(s, msg)
end

-- Sample project listed against the object-all / file-folder fixtures; the
-- block runs one CLI process at a time, so each answer starts the next.
local function listed(authId: string?): S
	local s, effects = scanned(authId or "demo-sb")
	s, effects = ran(s, run(effects, "objects") :: Effect, fixture("object-all"))
	s = ran(s, run(effects, "files") :: Effect, fixture("file-folder"))
	return s
end

local function keys(s: S, names: { string }): (S, { Effect })
	local all: { Effect } = {}
	local effects: { Effect }
	for _, n in names do
		local shifted = n ~= string.lower(n) and #n == 1
		s, effects = step(s, { t = "key", name = n, text = if #n == 1 then n else nil, shift = shifted })
		table.move(effects, 1, #effects, #all + 1, all)
	end
	return s, all
end

local function typeText(s: S, text: string): S
	for i = 1, #text do
		local c = string.sub(text, i, i)
		s = step(s, { t = "key", name = c, text = c, shift = false })
	end
	return s
end

describe("starting", function()
	it("loads the config and looks for the SDF project around the directory it was opened for", function()
		local s, effects = State.init({ cwd = "/work/proj/demo/src" })
		expect(effects[1].t).toBe("config")
		expect(effects[2].t).toBe("find")
		expect(effects[2].cwd).toBe("/work/proj/demo/src")
		expect(s.gen).toBe(1)
	end)

	it("explains instead of listing when the directory is not in an SDF project", function()
		local s = State.init({ cwd = "/tmp/elsewhere" })
		s = step(s, { t = "config", config = CFG })
		local effects
		s, effects = step(s, { t = "found", gen = s.gen, root = nil })
		expect(#effects).toBe(0)
		expect(viewText(s)).toContain("not inside an SDF project")
	end)

	it(
		"lists objects, then the project's File Cabinet folders, in the project directory with the configured CLI and timeout",
		function()
			local s, effects = scanned("demo-sb")
			local objects = run(effects, "objects") :: Effect
			expect(objects.argv).toEqual({ "/opt/bin/suitecloud", "object:list" })
			expect(objects.cwd).toBe(sample.ROOT)
			expect(objects.timeoutMs).toBe(90000)
			local _, after = ran(s, objects, fixture("object-all"))
			local files = run(after, "files") :: Effect
			expect(files.argv).toEqual({ "/opt/bin/suitecloud", "file:list", "--folder", "/SuiteScripts" })
			expect(files.cwd).toBe(sample.ROOT)
		end
	)

	it("runs one CLI process at a time: concurrent runs race on the auth ID's token refresh", function()
		local s, effects = scanned("other-sb")
		expect(#effects).toBe(1)
		expect(effects[1].step).toBe("info")
		local after
		s, after = ran(s, effects[1], fixtures.read("suitecloud/manageauth/info-sandbox.txt"))
		expect(#after).toBe(1)
		expect(after[1].step).toBe("objects")
	end)

	it("does not start a refreshed listing while the previous one is still running", function()
		local s, effects = scanned("demo-sb")
		local old = run(effects, "objects") :: Effect
		local refreshed
		s, refreshed = keys(s, { "r" })
		s, refreshed = step(s, { t = "scanned", gen = s.gen, project = sample.project("demo-sb") })
		expect(#refreshed).toBe(0)
		local after
		s, after = ran(s, old, fixture("object-all"))
		expect(#State.visible(s)).toBe(0)
		expect((run(after, "objects") :: Effect).gen).toBe(s.gen)
	end)

	it("asks the CLI which account an unconfigured auth ID points at, and skips that for configured ones", function()
		local _, effects = scanned("other-sb")
		local info = run(effects, "info") :: Effect
		expect(info.argv).toEqual({ "/opt/bin/suitecloud", "account:manageauth", "--info", "other-sb" })
		local _, configured = scanned("demo-sb")
		expect(run(configured, "info")).toBeNil()
	end)

	it("runs nothing against an account when project.json names no auth ID, and says how to fix it", function()
		local s, effects = scanned(nil)
		expect(run(effects, "objects")).toBeNil()
		expect(viewText(s)).toContain("defaultAuthId")
	end)

	it("explains a CLI that stopped for a browser login instead of showing a bare timeout", function()
		local s, effects = scanned("demo-sb")
		s = ran(
			s,
			run(effects, "objects") :: Effect,
			State.REAUTH_MARKER .. " for refreshing them.",
			-1,
			{ timedOut = true }
		)
		expect(viewText(s)).toContain("browser login for auth ID demo-sb")
	end)
end)

describe("the target account", function()
	it("shows a sandbox by its label", function()
		local s = listed("demo-sb")
		local v = Render.view(s)
		expect(textOf(v.main)).toContain("SB1")
	end)

	it("marks a production account PROD but still lists it: listing and import only read the account", function()
		local s, effects = scanned("demo-prod")
		expect(run(effects, "objects") ~= nil).toBe(true)
		expect(viewText(s)).toContain("PROD")
	end)

	it("resolves an unconfigured auth ID from the CLI's --info answer", function()
		local s, effects = scanned("other-sb")
		expect(viewText(s)).toContain("other-sb?")
		s = ran(s, run(effects, "info") :: Effect, fixtures.read("suitecloud/manageauth/info-sandbox.txt"))
		expect(viewText(s)).toContain("1234567_SB1")
	end)
end)

describe("the listing", function()
	it("diffs the account against the project and counts each side", function()
		local s = listed()
		local text = viewText(s)
		expect(text).toContain("135 account only")
		expect(text).toContain("1 in both")
		expect(text).toContain("1 local only")
	end)

	it("shows the CLI's own error when a listing fails", function()
		local s, effects = scanned("demo-sb")
		s = ran(s, run(effects, "objects") :: Effect, fixture("object-unknown-auth"), 1)
		expect(viewText(s)).toContain("authentication ID is not available")
	end)

	it("says how long it waited when the CLI timed out", function()
		local s, effects = scanned("demo-sb")
		s = ran(s, run(effects, "objects") :: Effect, "", -1, { timedOut = true })
		expect(viewText(s)).toContain("timed out after 90 s")
	end)

	it("drops answers from before a refresh", function()
		local s, effects = scanned("demo-sb")
		local old = run(effects, "objects") :: Effect
		s = keys(s, { "r" })
		s = ran(s, old, fixture("object-all"))
		expect(#State.visible(s)).toBe(0)
	end)

	it("switches between objects and files", function()
		local s = listed()
		s = keys(s, { "tab" })
		expect(s.kind).toBe("file")
		expect(#State.visible(s)).toBe(5)
	end)
end)

describe("filters", function()
	it("cycles the side filter with a", function()
		local s = keys(listed(), { "a", "a", "a" })
		expect(s.filter.where).toBe("local")
		expect(#State.visible(s)).toBe(1)
	end)

	it("cycles types with t and back with T", function()
		local s = keys(listed(), { "t" })
		expect(s.filter.type).toBe("addressForm")
		s = keys(s, { "T" })
		expect(s.filter.type).toBeNil()
	end)

	it("searches as you type after /, and escape keeps the query", function()
		local s = keys(listed(), { "/" })
		expect(s.editing).toBe(true)
		s = typeText(s, "restlet")
		expect(#State.visible(s)).toBe(3)
		s = keys(s, { "backspace" })
		expect(s.filter.query).toBe("restle")
		s = keys(s, { "escape" })
		expect(s.editing).toBe(false)
		expect(s.filter.query).toBe("restle")
	end)

	it("treats letters typed into the search as text, not commands", function()
		local s = keys(listed(), { "/" })
		local effects
		s, effects = keys(s, { "q", "i", "r" })
		expect(#effects).toBe(0)
		expect(s.filter.query).toBe("qir")
	end)

	it("clears the query with escape before closing", function()
		local s = typeText(keys(listed(), { "/" }), "x")
		s = keys(s, { "enter" })
		local effects
		s, effects = keys(s, { "escape" })
		expect(s.filter.query).toBe("")
		expect(#effects).toBe(0)
		local _, closing = keys(s, { "escape" })
		expect(closing[1].t).toBe("exit")
	end)

	it("keeps the selection inside the filtered list", function()
		local s = keys(listed(), { "end" })
		expect(s.selected).toBe(137)
		s = keys(s, { "a", "a", "a" })
		expect(s.selected).toBe(1)
		s = keys(s, { "down", "down" })
		expect(s.selected).toBe(1)
	end)
end)

-- Selects the entry with id `id` through the search box.
local function select(s: S, id: string): S
	s = keys(s, { "/" })
	s = typeText(s, id)
	return keys(s, { "enter" })
end

describe("importing", function()
	it("checks git for uncommitted changes where the import writes before importing", function()
		local s = select(listed(), "customscript_demo_90")
		local effects
		s, effects = keys(s, { "i" })
		local dirty = run(effects, "dirty") :: Effect
		expect(dirty.argv).toEqual({
			"git",
			"-C",
			sample.ROOT,
			"status",
			"--porcelain=v1",
			"-z",
			"--untracked-files=all",
			"--",
			"src/Objects/customscript_demo_90.xml",
			"src/FileCabinet",
		})
		expect(find(effects, function(e)
			return e.t == "import"
		end)).toBeNil()
		local after
		s, after = ran(s, dirty, "")
		local imp = after[1]
		expect(imp.t).toBe("import")
		expect(imp.request.scriptId).toBe("customscript_demo_90")
		expect(imp.request.type).toBe("restlet")
		expect(imp.request.root).toBe(sample.ROOT)
		expect(viewText(s)).toContain("split")
	end)

	it("refuses when the destination has uncommitted changes and says how to force it", function()
		local s = select(listed(), "customscript_demo_90")
		local effects
		s, effects = keys(s, { "i" })
		local after
		s, after = ran(s, run(effects, "dirty") :: Effect, "?? src/FileCabinet/SuiteScripts/x.js\0")
		expect(#after).toBe(0)
		local text = viewText(s)
		expect(text).toContain("src/FileCabinet/SuiteScripts/x.js")
		expect(text).toContain("press I")
	end)

	it("imports without the check when forced with I", function()
		local s = select(listed(), "customscript_demo_90")
		local _, effects = keys(s, { "I" })
		expect(run(effects, "dirty")).toBeNil()
		expect(effects[1].t).toBe("import")
	end)

	it("passes --excludefiles after x, and then only the object file is checked", function()
		local s = select(listed(), "customscript_demo_90")
		local effects
		s, effects = keys(s, { "x", "i" })
		local dirty = run(effects, "dirty") :: Effect
		expect(dirty.argv[#dirty.argv]).toBe("src/Objects/customscript_demo_90.xml")
		local _, after = ran(s, dirty, "")
		expect(after[1].request.excludeFiles).toBe(true)
	end)

	it("ignores a git answer for an import the user already replaced", function()
		local s = select(listed(), "customscript_demo_90")
		local first
		s, first = keys(s, { "i" })
		s = keys(s, { "i" })
		local _, after = ran(s, run(first, "dirty") :: Effect, "")
		expect(#after).toBe(0)
	end)

	it("has nothing to import for a local-only object", function()
		local s = select(listed(), "customlist_local_only")
		local effects
		s, effects = keys(s, { "i" })
		expect(#effects).toBe(0)
		expect(viewText(s)).toContain("only in this project")
	end)

	it("imports files with file:import", function()
		local s = keys(listed(), { "tab" })
		s = select(s, "tns_demo_suitelet")
		local _, effects = keys(s, { "I" })
		expect(effects[1].request.kind).toBe("file")
		expect(effects[1].request.path).toBe("/SuiteScripts/tns_demo_suitelet.js")
	end)
end)

describe("clicks", function()
	it("switch tabs, sides and rows like the keys do", function()
		local s = listed()
		s = step(s, { t = "action", act = "kind", value = "file" })
		expect(s.kind).toBe("file")
		s = step(s, { t = "action", act = "where", value = "account" })
		expect(s.filter.where).toBe("account")
		s = step(s, { t = "action", act = "sel", value = "2" })
		expect(s.selected).toBe(2)
	end)
end)

describe("rendering", function()
	local function rowList(s: S): any
		for _, n in (Render.view(s).main :: any).c do
			if n.p and n.p.key == "rows" then
				return n
			end
		end
		return nil
	end

	it("fills the pane whatever size Tern reports: the rows go in a list that scrolls to the selection", function()
		local s = keys(listed(), { "end" })
		local list = rowList(s)
		expect(list.k).toBe("list")
		expect(list.p.role).toBe(ui.SCROLL_ROLE)
		-- Every row of a listing below the cap, the first and the selected last.
		expect(#list.c).toBe(#State.visible(s))
		local text = textOf(list)
		expect(text).toContain("addressForm")
		expect(text).toContain("customscript_demo_136")
		local selected = State.selectedEntry(s) :: any
		expect(list.p.selected).toBe("main.rows.r:" .. selected.kind .. ":" .. selected.id)
	end)

	it("draws only a window around the selection of a listing past MAX_ROWS", function()
		local s = listed()
		local many = {}
		for i = 1, Render.MAX_ROWS + 50 do
			table.insert(many, { kind = "object", id = string.format("customlist_many_%03d", i), where = "account" })
		end
		s.entries.object = many :: any
		s = keys(s, { "end" })
		local list = rowList(s)
		expect(#list.c).toBe(Render.MAX_ROWS)
		local text = textOf(Render.view(s).main)
		expect(text).toContain("customlist_many_350")
		expect(text).toContain("50 above")
		expect((string.find(text, "customlist_many_001", 1, true))).toBeNil()
	end)

	it("titles the pane with the project", function()
		expect(Render.title(listed())).toContain("demo")
	end)
end)

return nil
