--!strict
local Config = require("../../../plugin/lib/config")
local Render = require("../../../plugin/lib/explorer/render")
local Rows = require("../../../plugin/lib/explorer/rows")
local Sample = require("./sample")
local Snapshot = require("../../../plugin/lib/sdf/snapshot")
local State = require("../../../plugin/lib/explorer/state")
local json = require("../../lib/json")
local t = require("../../lib/test")
local ui = require("../../../plugin/lib/ui")

local describe, it, expect = t.describe, t.it, t.expect

type State = State.State
type Effect = State.Effect
type Row = State.Row

local NOW = 5000000

local function config(text: string?): Config.Config
	local cfg = Config.parse(text or '{"projects":{"roots":["sdf"]}}', json.decode)
	return cfg
end

local function basename(path: string): string
	return string.match(path, "([^/]+)$") or path
end

local function find(effects: { Effect }, kind: string): Effect?
	for _, e in effects do
		if e.t == kind then
			return e
		end
	end
	return nil
end

local function all(effects: { Effect }, kind: string): { Effect }
	local out = {}
	for _, e in effects do
		if e.t == kind then
			table.insert(out, e)
		end
	end
	return out
end

-- Every text the view shows, one string per node line.
local function texts(node: any, out: { string }?): { string }
	local acc = out or {}
	if type(node) ~= "table" then
		return acc
	end
	local p = node.p or {}
	local line: { string } = {}
	if p.spans then
		for _, s in p.spans do
			table.insert(line, s.t)
		end
	end
	if node.k == "badge" then
		table.insert(line, "[" .. p.text .. "]")
	end
	if node.k == "row" then
		for _, c in node.c or {} do
			local inner = texts(c, {})
			table.insert(line, table.concat(inner, " "))
		end
		table.insert(acc, table.concat(line, ""))
		return acc
	end
	if #line > 0 then
		table.insert(acc, table.concat(line, ""))
	end
	for _, c in node.c or {} do
		texts(c, acc)
	end
	return acc
end

local function screen(s: State): string
	local v = Render.view(s)
	local lines = texts(v.main)
	return table.concat(lines, "\n")
end

local function key(s: State, name: string, text: string?): (State, { Effect })
	local s2, effects = State.update(s, { t = "key", key = { name = name, text = text } })
	return s2, effects
end

local function typeText(s: State, str: string): State
	for i = 1, #str do
		local ch = string.sub(str, i, i)
		s = key(s, ch, ch)
	end
	return s
end

local function scanAll(s: State, effects: { Effect }, snapshot: ((string) -> Snapshot.Snapshot)?): (State, { Effect })
	local make = snapshot or function(root: string): Snapshot.Snapshot
		return Sample.snapshot(basename(root))
	end
	local e = find(effects, "scan")
	while e do
		s, effects =
			State.update(s, { t = "scanned", gen = e.gen, root = e.root :: string, snapshot = make(e.root :: string) })
		e = find(effects, "scan")
	end
	return s, effects
end

local function boot(args: { string }?, cfg: Config.Config?, roots: { string }?): (State, { Effect })
	local s, effects = State.init(args or { "/repo/sdf/billing" }, { cwd = nil, height = 40 })
	local c = find(effects, "config") :: Effect
	s, effects = State.update(s, { t = "config", gen = c.gen, config = cfg or config(), now = NOW })
	s, effects = State.update(s, { t = "located", gen = c.gen, repoRoot = "/repo", projectRoot = "/repo/sdf/billing" })
	s, effects = State.update(s, { t = "discovered", gen = c.gen, roots = roots or Sample.ROOTS })
	return scanAll(s, effects)
end

-- Moves down to the first selectable row containing `needle` (and whose
-- key starts with `prefix`, when given).
local function select(s: State, needle: string, prefix: string?): State
	for _ = 1, 400 do
		local row = State.selected(s)
		if
			row
			and string.find(row.text, needle, 1, true)
			and (prefix == nil or string.sub(row.key, 1, #prefix) == prefix)
		then
			return s
		end
		s = key(s, "j")
	end
	error("no selectable row contains " .. needle)
end

describe("finding the projects to show", function()
	it("searches the configured roots under the git repository", function()
		local s, effects = State.init({ "/repo/sdf/billing/src" }, { height = 40 })
		s, effects = State.update(s, { t = "config", gen = 1, config = config(), now = NOW })
		local locate = find(effects, "locate") :: Effect
		expect(locate.cwd).toBe("/repo/sdf/billing/src")
		s, effects = State.update(s, { t = "located", gen = 1, repoRoot = "/repo", projectRoot = "/repo/sdf/billing" })
		local d = find(effects, "discover") :: Effect
		expect(d.base).toBe("/repo")
		expect(d.roots).toEqual({ "sdf" })
	end)

	it("outside a git repository searches the parent of the project the block was opened in", function()
		local s, effects = State.init({ "/work/sdf/billing" }, { height = 40 })
		s, effects = State.update(s, { t = "config", gen = 1, config = config(), now = NOW })
		s, effects = State.update(s, { t = "located", gen = 1, repoRoot = nil, projectRoot = "/work/sdf/billing" })
		local d = find(effects, "discover") :: Effect
		expect(d.base).toBe("/work/sdf")
		expect(d.roots).toEqual({})
	end)

	it("keeps the project it was opened in even when the configured roots miss it", function()
		local s, effects = State.init({ "/repo/other/app" }, { height = 40 })
		s, effects = State.update(s, { t = "config", gen = 1, config = config(), now = NOW })
		s, effects = State.update(s, { t = "located", gen = 1, repoRoot = "/repo", projectRoot = "/repo/other/app" })
		s, effects = State.update(s, { t = "discovered", gen = 1, roots = { "/repo/sdf/billing" } })
		local scans = all(effects, "scan")
		expect(#scans).toBe(1)
		expect(State.progress(s).total).toBe(2)
	end)

	it("shows scanning progress, one project at a time", function()
		local s, effects = State.init({ "/repo/sdf/billing" }, { height = 40 })
		s, effects = State.update(s, { t = "config", gen = 1, config = config(), now = NOW })
		s, effects = State.update(s, { t = "located", gen = 1, repoRoot = "/repo", projectRoot = "/repo/sdf/billing" })
		s, effects = State.update(s, { t = "discovered", gen = 1, roots = Sample.ROOTS })
		expect(#all(effects, "scan")).toBe(1)
		s, effects =
			State.update(s, { t = "scanned", gen = 1, root = Sample.ROOTS[1], snapshot = Sample.snapshot("billing") })
		expect(screen(s)).toContain("Scanning 2/3")
		expect((find(effects, "scan") :: Effect).root).toBe(Sample.ROOTS[2])
	end)

	it("drops the results of a scan that a rescan superseded", function()
		local s, effects = State.init({ "/repo/sdf/billing" }, { height = 40 })
		s, effects = State.update(s, { t = "config", gen = 1, config = config(), now = NOW })
		s, effects = State.update(s, { t = "located", gen = 1, repoRoot = "/repo", projectRoot = "/repo/sdf/billing" })
		s, effects = State.update(s, { t = "discovered", gen = 1, roots = Sample.ROOTS })
		s, effects = key(s, "r")
		local c = find(effects, "config") :: Effect
		expect(c.gen).toBe(2)
		s, effects =
			State.update(s, { t = "scanned", gen = 1, root = Sample.ROOTS[1], snapshot = Sample.snapshot("billing") })
		expect(#effects).toBe(0)
		expect(State.progress(s).done).toBe(0)
	end)

	it("keeps showing the previous projects while a rescan runs", function()
		local s = boot()
		s = key(s, "r")
		expect(screen(s)).toContain("billing")
	end)

	it("says so when the repository has no SDF project", function()
		local s = State.init({ "/repo" }, { height = 40 })
		s = State.update(s, { t = "config", gen = 1, config = config(), now = NOW })
		s = State.update(s, { t = "located", gen = 1, repoRoot = "/repo", projectRoot = nil })
		s = State.update(s, { t = "discovered", gen = 1, roots = {} })
		expect(screen(s)).toContain("No SDF projects")
	end)
end)

describe("the project list", function()
	it("names each project with its counts, findings and target account", function()
		local s = boot()
		local text = screen(s)
		expect(text).toContain("billing")
		expect(text).toContain("2 objects")
		expect(text).toContain("2 files")
		-- billing's second script points at a file that does not exist.
		expect(text).toContain("1 error")
		expect(text).toContain("[no auth id]")
	end)

	it("asks the CLI once per auth id the config does not know, and shows the answer", function()
		local s, effects = boot()
		local lookups = all(effects, "lookup")
		local ids = {}
		for _, e in lookups do
			table.insert(ids, e.authId)
		end
		table.sort(ids)
		expect(ids).toEqual({ "PRODUCTION", "demo-sb" })
		expect(screen(s)).toContain("[demo-sb?]")
		s = State.update(
			s,
			{ t = "resolved", entry = { authId = "demo-sb", accountId = "1234567_SB1", at = NOW }, now = NOW }
		)
		expect(screen(s)).toContain("[1234567_SB1]")
	end)

	it("shows an auth id the CLI could not resolve as production, the way the guard treats it", function()
		local s = boot()
		s = State.update(s, {
			t = "resolved",
			entry = { authId = "demo-sb", at = NOW, error = "not available" },
			now = NOW,
		})
		local row = State.rows(s)[1]
		expect(row.text).toContain("billing")
		local badge = (row.badges :: any)[1]
		expect(badge.text).toBe("demo-sb? PROD")
		expect(badge.tone).toBe("error")
	end)

	it("marks a production account loudly", function()
		local cfg = config(
			'{"projects":{"roots":["sdf"]},"accounts":[{"id":"acme","account_id":"7654321","label":"Acme","auth_ids":["PRODUCTION"]}]}'
		)
		local s, effects = boot(nil, cfg)
		expect(screen(s)).toContain("[Acme PROD]")
		expect(#all(effects, "lookup")).toBe(1)
	end)
end)

describe("navigation", function()
	it("moves with j/k and opens a project's detail with enter, and backspace returns to the same row", function()
		local s = boot()
		expect((State.selected(s) :: any).text).toContain("billing")
		s = key(s, "j")
		expect((State.selected(s) :: any).text).toContain("legacy")
		s = key(s, "j")
		s = key(s, "j")
		expect((State.selected(s) :: any).text).toContain("storefront")
		s = key(s, "k")
		expect((State.selected(s) :: any).text).toContain("legacy")
		s = key(s, "j")
		s = key(s, "enter")
		expect(State.viewKey(s)).toBe("detail:/repo/sdf/storefront")
		s = key(s, "backspace")
		expect(State.viewKey(s)).toBe("projects")
		expect((State.selected(s) :: any).text).toContain("storefront")
	end)

	it("switches between projects and findings with tab", function()
		local s = boot()
		s = key(s, "tab")
		expect(State.viewKey(s)).toBe("findings")
		s = key(s, "tab")
		expect(State.viewKey(s)).toBe("projects")
	end)

	it("closes with escape", function()
		local s = boot()
		local _, effects = key(s, "escape")
		expect(find(effects, "exit") ~= nil).toBe(true)
	end)

	it("activates a clicked row only when the row under the click is still the one rendered", function()
		local s = boot()
		local rows = State.rows(s)
		local value = State.clickValue(rows, 3)
		s = State.update(s, { t = "click", value = value })
		expect(State.viewKey(s)).toBe("detail:/repo/sdf/storefront")
		local s2 = boot()
		s2 = State.update(s2, { t = "click", value = "3:deadbeef" })
		expect(State.viewKey(s2)).toBe("projects")
	end)
end)

describe("project detail", function()
	local function detail(): State
		local s = boot()
		s = key(s, "enter")
		return s
	end

	it("groups objects by type with their script file and deployments", function()
		local text = screen(detail())
		expect(text).toContain("usereventscript (2)")
		expect(text).toContain("customscript_billing_ue")
		expect(text).toContain("/SuiteScripts/billing/ue.js")
		expect(text).toContain("customdeploy_billing_ue")
		expect(text).toContain("RELEASED")
		expect(text).toContain("DEBUG")
	end)

	it("shows the File Cabinet as a tree, manifest dependencies and deploy.xml paths", function()
		local s = detail()
		local text = table.concat(
			(function()
				local out = {}
				for _, r in State.rows(s) do
					table.insert(out, r.text)
				end
				return out
			end)(),
			"\n"
		)
		expect(text).toContain("SuiteScripts/")
		expect(text).toContain("billing/")
		expect(text).toContain("ue.js")
		expect(text).toContain("SERVERSIDESCRIPTING")
		expect(text).toContain("~/FileCabinet/SuiteScripts/*")
	end)

	it("opens an object's XML at its line, and a file by its path", function()
		local s = detail()
		s = select(s, "customscript_billing_ue")
		local _, effects = key(s, "enter")
		expect((find(effects, "open") :: Effect).target).toBe(
			"/repo/sdf/billing/src/Objects/customscript_billing_ue.xml:1"
		)
		s = select(s, "ue.js", "f:")
		_, effects = key(s, "enter")
		expect((find(effects, "open") :: Effect).target).toBe(
			"/repo/sdf/billing/src/FileCabinet/SuiteScripts/billing/ue.js"
		)
	end)

	it("hands the selected File Cabinet file to the upload flow with its account", function()
		local s = detail()
		s = select(s, "http.js")
		local _, effects = key(s, "u")
		local up = find(effects, "upload") :: Effect
		local g = up.grant :: any
		expect(g.root).toBe("/repo/sdf/billing")
		expect(g.fileCabinetPath).toBe("/SuiteScripts/lib/http.js")
		expect(g.authId).toBe("demo-sb")
		expect(g.production).toBe(true)
	end)

	it("does not upload an object, which file:upload cannot send", function()
		local s = detail()
		s = select(s, "customscript_billing_ue")
		local s2, effects = key(s, "u")
		expect(find(effects, "upload")).toBeNil()
		expect(screen(s2)).toContain("File Cabinet file")
	end)

	it("copies a local validate command for the project without running anything", function()
		local s = detail()
		local _, effects = key(s, "v")
		local copy = find(effects, "copy") :: Effect
		expect(copy.text).toBe("cd /repo/sdf/billing && suitecloud project:validate")
		expect(#effects).toBe(1)
	end)
end)

describe("findings", function()
	local function findings(): State
		local s = boot()
		s = key(s, "tab")
		return s
	end

	it("groups findings across all projects by code", function()
		local text = screen(findings())
		expect(text).toContain("missing-script-file")
		expect(text).toContain("cross-project-collision")
	end)

	it("highlights cross-project collisions", function()
		local s = findings()
		local found = false
		for _, r in State.rows(s) do
			if r.kind == "heading" and string.find(r.text, "cross-project-collision", 1, true) then
				found = r.tone == "warning"
			end
		end
		expect(found).toBe(true)
	end)

	it("opens the file and line a finding points at", function()
		local s = findings()
		s = select(s, "gone.js")
		local _, effects = key(s, "enter")
		expect((find(effects, "open") :: Effect).target).toContain(
			"/repo/sdf/billing/src/Objects/customscript_billing_gone.xml:"
		)
	end)
end)

describe("filtering", function()
	it("narrows the list to rows matching what is typed after /", function()
		local s = boot()
		s = key(s, "/", "/")
		s = typeText(s, "store")
		local text = screen(s)
		expect(text).toContain("storefront")
		expect((string.find(text, "legacy", 1, true))).toBeNil()
		expect((State.selected(s) :: any).text).toContain("storefront")
	end)

	it("keeps the headings of matching rows so the grouping stays readable", function()
		local s = boot()
		s = key(s, "enter")
		s = key(s, "/", "/")
		s = typeText(s, "deploy_billing_ue")
		s = key(s, "enter")
		local text = screen(s)
		expect(text).toContain("usereventscript")
		expect((string.find(text, "manifest", 1, true))).toBeNil()
	end)

	it("clears with escape before escape closes the block", function()
		local s = boot()
		s = key(s, "/", "/")
		s = typeText(s, "port")
		s = key(s, "enter")
		local s2, effects = key(s, "escape")
		expect(find(effects, "exit")).toBeNil()
		expect(screen(s2)).toContain("legacy")
	end)
end)

describe("picking the project to upload a shared file from", function()
	it("lists every project that carries the file and uploads from the chosen one", function()
		local s = boot({ "/repo/sdf/billing", "--pick", Sample.SHARED })
		expect(State.viewKey(s)).toBe("pick")
		local text = screen(s)
		expect(text).toContain("/SuiteScripts/lib/http.js")
		expect(text).toContain("/SuiteScripts/storefront/lib/http.js")
		s = select(s, "storefront")
		local _, effects = key(s, "enter")
		local g = (find(effects, "upload") :: Effect).grant :: any
		expect(g.project).toBe("storefront")
		expect(g.fileCabinetPath).toBe("/SuiteScripts/storefront/lib/http.js")
	end)

	it("explains when no project carries the file", function()
		local s = boot({ "/repo/sdf/billing", "--pick", "/elsewhere/x.js" })
		expect(screen(s)).toContain("no scanned SDF project")
	end)
end)

describe("large repositories", function()
	local function big(root: string): Snapshot.Snapshot
		local snap = Sample.snapshot(basename(root))
		if basename(root) == "billing" then
			for i = 1, 600 do
				table.insert(
					snap.files,
					{ path = string.format("src/FileCabinet/SuiteScripts/many/f%04d.js", i), size = 1 }
				)
			end
		end
		return snap
	end

	local function bigBilling(opts: State.InitOpts): State
		local s, effects = State.init({ "/repo/sdf/billing" }, opts)
		s, effects = State.update(s, { t = "config", gen = 1, config = config(), now = NOW })
		s, effects = State.update(s, { t = "located", gen = 1, repoRoot = "/repo", projectRoot = "/repo/sdf/billing" })
		s, effects = State.update(s, { t = "discovered", gen = 1, roots = Sample.ROOTS })
		s = scanAll(s, effects, big)
		return (key(s, "enter"))
	end

	local function rowList(s: State): any
		for _, n in (Render.view(s).main :: any).c do
			if n.p and n.p.key == "rows" then
				return n
			end
		end
		return nil
	end

	it("fills the pane whatever size Tern reports: up to MAX_RENDER_ROWS rows in a scrolling list", function()
		-- Tern 0.7.0 reports no real size: the host passes none.
		local s = bigBilling({})
		expect(#State.rows(s) > 600).toBe(true)
		local list = rowList(s)
		expect(list.k).toBe("list")
		expect(list.p.role).toBe(ui.SCROLL_ROLE)
		expect(#list.c > 100).toBe(true)
		expect(#list.c <= State.MAX_RENDER_ROWS).toBe(true)
		expect(list.p.selected).toBe("main.rows.row:" .. (State.selected(s) :: Row).key)
		expect(screen(s)).toContain("more below")
		s = key(s, "end")
		expect(screen(s)).toContain("more above")
		expect((State.selected(s) :: any).text).toContain("~/Objects/*")
		expect(rowList(s).p.selected).toBe("main.rows.row:" .. (State.selected(s) :: Row).key)
	end)

	it("draws the same rows in a short pane as in a tall one: the list scrolls, not the core", function()
		expect(#rowList(bigBilling({ height = 20, width = 100 })).c).toBe(#rowList(bigBilling({})).c)
	end)

	it("shows the rows above the first selectable one again after going back to the top", function()
		local s = bigBilling({})
		s = key(s, "end")
		s = key(s, "home")
		expect((string.find(screen(s), "more above", 1, true))).toBeNil()
		expect(texts(rowList(s))[1]).toContain("root")
	end)

	it("pages by the height Tern reports, else by a default page", function()
		local function paged(s: State): number
			local rows = State.rows(s)
			local before = State.selectedIndex(s, rows)
			s = key(s, "pagedown")
			return State.selectedIndex(s, rows) - before
		end
		local short = paged(bigBilling({ height = 20, width = 100 }))
		local tall = paged(bigBilling({ height = 80, width = 100 }))
		expect(short >= 1).toBe(true)
		expect(tall > short).toBe(true)
		expect(paged(bigBilling({}))).toBe(paged(bigBilling({ height = State.DEFAULT_HEIGHT })))
		local resized = State.update(bigBilling({}), { t = "resize", rows = 80, cols = 100 })
		expect(paged(resized)).toBe(tall)
	end)

	it("measures the window in wrapped lines, so long findings in a narrow pane stay within the drawn lines", function()
		local s, effects = State.init({ "/repo/sdf/billing" }, { height = 20, width = 30 })
		s, effects = State.update(s, { t = "config", gen = 1, config = config(), now = NOW })
		s, effects = State.update(s, { t = "located", gen = 1, repoRoot = "/repo", projectRoot = "/repo/sdf/billing" })
		s, effects = State.update(s, { t = "discovered", gen = 1, roots = Sample.ROOTS })
		s = scanAll(s, effects)
		s = key(s, "tab")
		for _ = 1, 6 do
			s = key(s, "j")
		end
		local rows = State.rows(s)
		local selected = State.selectedIndex(s, rows)
		local first, last = State.window(s, rows, selected)
		expect(selected >= first and selected <= last).toBe(true)
		local used = 0
		for i = first, last do
			used += Rows.lines(rows[i], 30)
		end
		expect(used <= State.MAX_RENDER_ROWS).toBe(true)
	end)

	it("caps the number of projects scanned", function()
		local roots = {}
		for i = 1, State.MAX_PROJECTS + 7 do
			table.insert(roots, string.format("/repo/sdf/p%03d", i))
		end
		local s = State.init({ "/repo" }, { height = 40 })
		s = State.update(s, { t = "config", gen = 1, config = config(), now = NOW })
		s = State.update(s, { t = "located", gen = 1, repoRoot = "/repo", projectRoot = nil })
		s = State.update(s, { t = "discovered", gen = 1, roots = roots })
		expect(State.progress(s).total).toBe(State.MAX_PROJECTS)
		expect(screen(s)).toContain("7 more projects not scanned")
	end)
end)

return nil
