--!strict
local Config = require("../../../plugin/lib/config")
local Crypto = require("../../../plugin/lib/ns/crypto")
local Project = require("../../../plugin/lib/sdf/project")
local Query = require("../../../plugin/lib/deployments/query")
local State = require("../../../plugin/lib/deployments/state")
local View = require("../../../plugin/lib/deployments/view")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local CONFIG = [[{
	"accounts": [
		{ "id": "sb", "label": "SB1", "account_id": "1234567_SB1", "auth_ids": ["demo-sb"] },
		{ "id": "prod", "label": "PROD", "account_id": "1234567", "production": true, "auth_ids": ["demo-prod"] }
	],
	"connections": [
		{ "id": "sb-rest", "account": "sb", "auth": "tba", "transport": "rest" },
		{ "id": "prod-rest", "account": "prod", "auth": "oauth2_m2m", "transport": "rest" }
	]
}]]

local cfg = Config.parse(CONFIG, json.decode)
local LIST = json.decode(fixtures.read("deployments/list-rest.json")).items
local ACTIVITY = json.decode(fixtures.read("deployments/activity-rest.json")).items
local UE = fixtures.read("deployments/customscript_acme_order_ue.xml")
local ROOT = "/work/acme/fulfillment"

local function key(name: string, text: string?): State.Key
	return { name = name, text = text, ctrl = false, alt = false, shift = false, meta = false }
end

local function find(effects: { State.Effect }, kind: string): State.Effect?
	for _, e in effects do
		if e.t == kind then
			return e
		end
	end
	return nil
end

local function press(s: State.State, name: string, text: string?): (State.State, { State.Effect })
	return State.update(s, { t = "key", key = key(name, text) })
end

local function project(authId: string): Project.Project
	return Project.build({
		root = ROOT,
		files = {
			{ path = "suitecloud.config.js", size = 10, text = "module.exports = { defaultProjectFolder: 'src' };" },
			{ path = "project.json", size = 10, text = '{"defaultAuthId": "' .. authId .. '"}' },
			{ path = "src/manifest.xml", size = 10, text = '<manifest projecttype="ACCOUNTCUSTOMIZATION"></manifest>' },
			{ path = "src/deploy.xml", size = 10, text = "<deploy></deploy>" },
			{ path = "src/Objects/customscript_acme_order_ue.xml", size = #UE, text = UE },
		},
	})
end

-- A palette-opened block on `connection` with the fixture rows, activity
-- and (optionally) the scanned local project.
local function loaded(connection: string?, authId: string?): State.State
	local s, effects = State.init(if connection then { "connection=" .. connection } else {}, nil, cfg, ROOT .. "/src")
	local list = find(effects, "query") :: State.Effect
	s = State.update(s, { t = "result", req = list.req, rows = LIST, at = "10:00:00" })
	local act = s.activityReq
	s = State.update(s, { t = "result", req = act, rows = ACTIVITY })
	s = State.update(s, { t = "scanned", projects = if authId then { project(authId) } else {}, errors = {} })
	return s
end

local function select(s: State.State, id: string): State.State
	return (State.update(s, { t = "action", act = "sel", value = id }))
end

local function viewText(node: any, out: { string }?): string
	local acc = out or {}
	if type(node) == "table" then
		if type(node.t) == "string" then
			table.insert(acc, node.t)
		end
		if type(node.text) == "string" then
			table.insert(acc, node.text)
		end
		for _, v in node do
			if type(v) == "table" then
				viewText(v, acc)
			end
		end
	end
	return table.concat(acc, " ")
end

describe("loading deployments", function()
	it("starts the list query and the local project scan when opened from the palette", function()
		local s, effects = State.init({}, nil, cfg, "/work/acme/fulfillment")
		local q = find(effects, "query")
		assert(q, "query effect")
		expect(q.sql).toBe(Query.LIST_SQL)
		expect(q.connection).toBe("sb-rest")
		expect((find(effects, "scan") :: State.Effect).cwd).toBe("/work/acme/fulfillment")
		expect(s.scan).toBe("scanning")
	end)

	it("queries nothing for a printed link until Enter", function()
		local s, effects = State.init({ "connection=prod-rest", "hold=1" }, nil, cfg, nil)
		expect(#effects).toBe(0)
		local _, started = press(s, "enter")
		expect((find(started, "query") :: State.Effect).connection).toBe("prod-rest")
	end)

	it("counts 24 h activity after the list and keeps the list when counting fails", function()
		local s, effects = State.init({}, nil, cfg, nil)
		local list = find(effects, "query") :: State.Effect
		local s2, after = State.update(s, { t = "result", req = list.req, rows = LIST })
		local act = find(after, "query") :: State.Effect
		expect(act.sql).toBe(Query.ACTIVITY_SQL)
		local s3 = State.update(s2, {
			t = "result",
			req = act.req,
			err = { kind = "permission", message = "no scriptnote access" },
		})
		expect(#State.visible(s3)).toBe(5)
		expect(s3.activityErr ~= nil).toBe(true)
	end)

	it("ignores a late answer from a connection the user switched away from", function()
		local s, effects = State.init({}, nil, cfg, nil)
		local old = find(effects, "query") :: State.Effect
		local switched = press(s, "c", "c")
		local same = State.update(switched, { t = "result", req = old.req, rows = LIST })
		expect(same).toBe(switched)
	end)
end)

describe("browsing", function()
	it("filters by type, status and log level from the keyboard", function()
		local s = loaded()
		s = press(s, "t", "t")
		expect(s.filter.type).toBe("MAPREDUCE")
		expect(#State.visible(s)).toBe(1)
		s = press(s, "x", "x")
		s = press(s, "l", "l")
		expect(s.filter.level).toBe("AUDIT")
		expect(State.visible(s)[1].scriptId).toBe("customdeploy_acme_billing_sync")
	end)

	it("opens the deployment and its script on the account's NetSuite domain", function()
		local s = select(loaded("prod-rest"), "customdeploy_acme_order_ue")
		local _, a = press(s, "o", "o")
		expect((find(a, "open") :: State.Effect).url).toBe(
			"https://1234567.app.netsuite.com/app/common/scripting/scriptrecord.nl?id=203"
		)
		local _, b = press(s, "O", "O")
		expect((find(b, "open") :: State.Effect).url).toBe(
			"https://1234567.app.netsuite.com/app/common/scripting/script.nl?id=103"
		)
	end)

	it("tails the execution logs of the selected deployment's script", function()
		local s = select(loaded(), "customdeploy_acme_nightly_export")
		local _, effects = press(s, "L", "L")
		expect((find(effects, "logs") :: State.Effect).url).toBe(
			"tern-netsuite://logs?connection=sb-rest&script=customscript_acme_nightly_export"
		)
	end)

	it("shows the PROD badge, the rows and the 24 h errors", function()
		local s = loaded("prod-rest")
		local v = View.view(s)
		local text = viewText(v.main)
		expect(text).toContain("PROD")
		expect(text).toContain("customdeploy_acme_billing_sync")
		expect(text).toContain("3 err/24h")
		expect(text).toContain("NOT DEPLOYED")
	end)

	it("keeps every row on one line in narrow and wide blocks, so the list scrolls right", function()
		for _, cols in { 30, 39, 60, 82, 120, 200 } do
			local s = State.update(loaded("sb-rest", "demo-sb"), { t = "resize", height = 30, width = cols })
			local list: any = nil
			for _, c in (View.view(s).main :: any).c do
				if c.k == "list" then
					list = c
				end
			end
			assert(list, "row list")
			for _, row in list.c do
				local n = 0
				for _, span in row.p.spans do
					n += utf8.len(span.t) or #span.t
				end
				expect(n <= math.max(cols - 4, 14)).toBe(true)
			end
		end
	end)

	it("renders at most 200 rows around the selection", function()
		local many = {}
		for i = 1, 450 do
			table.insert(many, { scriptid = string.format("customdeploy_%03d", i), status = "RELEASED" })
		end
		local s, effects = State.init({}, nil, cfg, nil)
		s = State.update(s, { t = "result", req = (find(effects, "query") :: State.Effect).req, rows = many })
		s = select(s, "customdeploy_300")
		local v = View.view(s)
		local list: any = nil
		for _, c in (v.main :: any).c do
			if c.k == "list" then
				list = c
			end
		end
		assert(list, "row list")
		expect(#list.c <= State.MAX_RENDER_ROWS).toBe(true)
		expect(list.p.selected).toBe("main.rows.r-customdeploy_300")
	end)
end)

describe("editing a deployment in its local project", function()
	local function editing(authId: string): (State.State, State.Effect)
		local s = select(loaded("sb-rest", authId), "customdeploy_acme_order_ue")
		local s2, effects = press(s, "e", "e")
		local read = find(effects, "read") :: State.Effect
		expect(read.path).toBe(ROOT .. "/src/Objects/customscript_acme_order_ue.xml")
		return State.update(s2, { t = "read", req = read.req, text = UE }), read
	end

	it("previews the diff before writing, then writes only the previewed file", function()
		local s = editing("demo-sb")
		local e = s.edit :: State.Edit
		expect(e.phase).toBe("choose")
		expect(State.choices(e)[e.index]).toBe("DEBUG")
		s = press(s, "right")
		local _, none = press(s, "right")
		expect(find(none, "write")).toBeNil()
		s = press(s, "enter")
		e = s.edit :: State.Edit
		expect(e.phase).toBe("preview")
		expect((e.plan :: any).after).toBe("\t\t\t<loglevel> AUDIT </loglevel>")
		local text = viewText((View.view(s) :: any).dock)
		expect(text).toContain("-\t\t\t<loglevel> DEBUG </loglevel>")
		expect(text).toContain("Writes the local file only")
		local s2, effects = press(s, "enter")
		local w = find(effects, "write") :: State.Effect
		expect(w.path).toBe(ROOT .. "/src/Objects/customscript_acme_order_ue.xml")
		expect(w.expect).toBe(Crypto.hex(Crypto.sha256(UE)))
		expect(w.text).toBe((string.gsub(UE, "> DEBUG <", "> AUDIT <")))
		local done = State.update(s2, { t = "wrote", req = w.req })
		expect((done.edit :: State.Edit).command).toBe("cd /work/acme/fulfillment && suitecloud project:deploy")
		local _, copy = press(done, "y", "y")
		expect((find(copy, "copy") :: State.Effect).text).toBe("cd /work/acme/fulfillment && suitecloud project:deploy")
	end)

	it("switches to the status field with the values the script type allows", function()
		local s = editing("demo-sb")
		s = press(s, "tab")
		local e = s.edit :: State.Edit
		expect(e.field).toBe("status")
		expect(State.choices(e)).toEqual({ "TESTING", "RELEASED" })
		expect(State.choices(e)[e.index]).toBe("RELEASED")
	end)

	it("reports a file that changed after the preview instead of overwriting it", function()
		local s = editing("demo-sb")
		s = press(s, "right")
		s = press(s, "enter")
		local s2, effects = press(s, "enter")
		local w = find(effects, "write") :: State.Effect
		local failed = State.update(s2, { t = "wrote", req = w.req, error = State.writeError(3, "") })
		expect((failed.edit :: State.Edit).phase).toBe("error")
		expect((failed.edit :: State.Edit).message).toContain("changed since it was read")
	end)

	it("warns when the project deploys to another account than the one shown", function()
		local s = editing("demo-prod")
		expect((s.edit :: State.Edit).warning).toContain("deploys to PROD (auth ID demo-prod), not to SB1")
	end)

	it("offers no edit for a deployment no local project defines", function()
		local s = select(loaded("sb-rest", "demo-sb"), "customdeploy_acme_nightly_export")
		local s2, effects = press(s, "e", "e")
		expect(find(effects, "read")).toBeNil()
		expect(s2.notice).toContain("no local SDF project")
	end)

	it("never lets a launch argument start an edit or a write", function()
		local s, effects = State.init({ "edit=customdeploy_acme_order_ue", "write=1" }, nil, cfg, ROOT)
		expect(find(effects, "read")).toBeNil()
		expect(find(effects, "write")).toBeNil()
		expect(s.notice).toContain("unknown parameter")
	end)
end)

describe("write script errors", function()
	it("explains each refusal of the write script", function()
		expect(State.writeError(0, "")).toBeNil()
		expect(State.writeError(7, "")).toContain("symlink")
		expect(State.writeError(6, "mv: permission denied\n")).toContain("permission denied")
	end)
end)

return nil
