--!strict
local Cache = require("../../../plugin/lib/drift/cache")
local Render = require("../../../plugin/lib/drift/render")
local State = require("../../../plugin/lib/drift/state")
local sample = require("./sample")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

type S = State.State

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

local function findKind(node: any, kind: string): any
	if node.k == kind then
		return node
	end
	for _, c in node.c or {} do
		local f = findKind(c, kind)
		if f then
			return f
		end
	end
	return nil
end

local function entry(id: string, status: string, extra: { [string]: any }?): any
	local e: any =
		{ kind = "object", id = id, type = "customlist", localPath = "src/Objects/" .. id .. ".xml", status = status }
	local more: { [string]: any } = extra or {}
	for k, v in more do
		e[k] = v
	end
	return e
end

-- The sample project opened against `authId` with `objects` cached.
local function opened(authId: string, objects: { any }, clock: number?): S
	local s = State.init({ cwd = sample.ROOT, authId = authId })
	s = State.update(s, { t = "config", config = sample.CFG, now = 1000, clock = clock or 1700000000 })
	s = State.update(s, { t = "found", gen = s.gen, root = sample.ROOT })
	local project, texts = sample.project()
	s = State.update(s, { t = "scanned", gen = s.gen, project = project, texts = texts })
	local value = Cache.encode({
		root = sample.ROOT,
		authId = authId,
		account = nil,
		production = false,
		at = 1700000000 - 600,
		objects = objects,
		files = {},
		accountOnly = nil,
		problems = {},
	})
	s = State.update(s, { t = "loaded", gen = s.gen, file = "x", value = value })
	return s
end

describe("drift render", function()
	it("marks a production target with a red PROD badge", function()
		local s = opened("demo-prod", { entry("customlist_acme_sizes", "identical") })
		local badge = findKind(Render.view(s).main, "badge")
		expect(badge.p.text).toBe("PROD")
		expect(badge.p.tone).toBe("error")
		expect(Render.title(s)).toContain("vs PROD")
	end)

	it("shows an unresolved auth ID as unknown rather than guessing the account", function()
		local s = opened("demo-other", { entry("customlist_acme_sizes", "identical") })
		local badge = findKind(Render.view(s).main, "badge")
		expect(badge.p.text).toBe("demo-other?")
		expect(badge.p.tone).toBe("warning")
	end)

	it("says when a cached result was taken, so stale drift is recognizable", function()
		local s = opened("demo-sb", { entry("customlist_acme_sizes", "identical") })
		local text = viewText(s)
		expect(text).toContain("compared 10 min ago")
		expect(text).toContain("cached; r runs again")
	end)

	it("shows the unified diff of the selected change", function()
		local diff = "--- project/x\n+++ account/x\n@@ -1 +1 @@\n-a\n+b\n"
		local s = opened("demo-sb", { entry("customlist_acme_colors", "changed", { diff = diff }) })
		s = State.update(s, { t = "key", name = "enter" })
		local node = findKind(Render.view(s).main, "diff")
		expect(node.p.text).toBe(diff)
		expect(node.p.path).toBe("src/Objects/customlist_acme_colors.xml")
	end)

	it("draws at most 200 rows however many entries there are", function()
		local many = {}
		for i = 1, 450 do
			table.insert(many, entry("customlist_acme_" .. i, "identical"))
		end
		local s = opened("demo-sb", many)
		s = State.update(s, { t = "action", act = "sel", value = "300" })
		local list = findKind(Render.view(s).main, "list")
		expect(#list.c <= Render.MAX_ROWS).toBe(true)
		expect(list.p.selected).toBe("main.rows.r:object:customlist_acme_300")
	end)

	it("shows progress while a run is going and how to cancel it", function()
		local s = opened("demo-sb", {})
		s = State.update(s, { t = "key", name = "r" })
		local project, texts = sample.project()
		s = State.update(s, { t = "scanned", gen = s.gen, project = project, texts = texts })
		s = State.update(s, { t = "prepared", gen = s.gen, run = (s.run :: any).n, dir = sample.DIR })
		local text = viewText(s)
		expect(text).toContain("comparing 0/5")
		expect(text).toContain("object:import customlist (3)")
		expect(text).toContain("cancel")
	end)
end)

return nil
