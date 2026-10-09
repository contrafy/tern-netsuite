--!strict
local Form = require("../../../plugin/lib/scaffold/form")
local Snapshot = require("../../../plugin/lib/sdf/snapshot")
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

type State = Form.State
type Effect = Form.Effect
type SnapshotFile = Snapshot.SnapshotFile

local ROOT = "/work/sdf/orders"

local function snapshot(prefix: string, extra: { [string]: string }?): Snapshot.Snapshot
	local base = prefix .. "/"
	local texts: { [string]: string } = {}
	for _, key in fixtures.list(base) do
		texts[string.sub(key, #base + 1)] = fixtures.read(key)
	end
	local more: { [string]: string } = extra or {}
	for path, text in more do
		texts[path] = text
	end
	local files: { SnapshotFile } = {}
	for path, text in texts do
		table.insert(files, { path = path, size = #text, text = if Snapshot.wantsText(path, "src") then text else nil })
	end
	return { root = ROOT, files = files }
end

local function send(s: State, msg: Form.Msg): (State, { Effect })
	return Form.update(s, msg)
end

local function key(s: State, name: string, mods: { [string]: any }?): (State, { Effect })
	local k: Form.Key = { name = name }
	local given: { [string]: any } = mods or {}
	for m, v in given do
		(k :: any)[m] = v
	end
	return send(s, { t = "key", key = k })
end

local function typeText(s: State, text: string): State
	local n = s
	for ch in string.gmatch(text, ".") do
		n = key(n, if ch == " " then "space" else ch, { text = ch })
	end
	return n
end

-- A block whose project (the orders fixture) is found and scanned.
local function ready(extra: { [string]: string }?): State
	local s = Form.init({ cwd = ROOT .. "/src", program = "suitecloud" })
	local effects
	s, effects = send(s, { t = "found", root = ROOT })
	expect(effects[1].t).toBe("scan")
	s = send(s, { t = "scanned", gen = effects[1].gen, snapshot = snapshot("projects/orders", extra) })
	return s
end

local function find(effects: { Effect }, kind: string): Effect?
	for _, e in effects do
		if e.t == kind then
			return e
		end
	end
	return nil
end

describe("opening the block", function()
	it("looks for the project of the pane's directory, loads templates and focuses the name input", function()
		local s, effects = Form.init({ cwd = "/work/sdf/orders/src", program = "suitecloud" })
		expect(s.phase).toBe("loading")
		local expected: { any } = {
			{ t = "find", cwd = "/work/sdf/orders/src" },
			{ t = "templates" },
			{ t = "focus", id = "main.name" },
		}
		expect(effects).toEqual(expected)
	end)

	it("explains where it looked when there is no SuiteCloud project", function()
		local s = Form.init({ cwd = "/tmp/x" })
		s = send(s, { t = "found", root = nil })
		expect(s.phase).toBe("failed")
		expect((s.notice :: Form.Notice).text).toContain("no suitecloud.config.js in /tmp/x or above it")
	end)

	it("ignores a scan result from an older generation", function()
		local s = Form.init({ cwd = ROOT })
		s = send(s, { t = "found", root = ROOT })
		local stale = send(s, { t = "scanned", gen = s.gen - 1, snapshot = snapshot("projects/orders") })
		expect(stale.project).toBeNil()
	end)
end)

describe("typing the form", function()
	it("derives the script id and file name from the name until the user edits them", function()
		local s = typeText(ready(), "Order Stamp")
		expect(s.values.scriptIdSuffix).toBe("order_stamp")
		expect(s.values.fileName).toBe("order_stamp.js")
		s = key(s, "tab")
		s = typeText(s, "_ue")
		expect(s.values.scriptIdSuffix).toBe("order_stamp_ue")
		expect(s.values.fileName).toBe("order_stamp_ue.js")
		s = key(s, "tab", { shift = true })
		s = typeText(s, "s")
		expect(s.values.name).toBe("Order Stamps")
		expect(s.values.scriptIdSuffix).toBe("order_stamp_ue")
	end)

	it("lowercases typed script ids, which SDF requires", function()
		local s = key(ready(), "tab")
		s = typeText(s, "AB")
		expect(s.values.scriptIdSuffix).toBe("ab")
	end)

	it("focuses the next input on Tab and skips fields the script type does not have", function()
		local s = ready()
		local effects
		for _ = 1, 3 do
			s = key(s, "tab")
		end
		expect(s.field).toBe("folder")
		s, effects = key(s, "tab")
		expect(s.field).toBe("recordType")
		expect(effects).toEqual({ { t = "focus", id = "main.recordType" } })
		s = send(s, { t = "action", act = "type", value = "suitelet" })
		s = send(s, { t = "action", act = "field", value = "folder" })
		s = key(s, "tab")
		expect(s.field).toBe("title")
	end)

	it("gives a new type its own default status unless the user picked one it allows", function()
		local s = send(ready(), { t = "action", act = "type", value = "scheduled" })
		expect(s.values.status).toBe("NOTSCHEDULED")
		s = send(ready(), { t = "action", act = "status", value = "RELEASED" })
		s = send(s, { t = "action", act = "type", value = "mapreduce" })
		expect(s.values.status).toBe("NOTSCHEDULED")
		s = send(s, { t = "action", act = "status", value = "TESTING" })
		s = send(s, { t = "action", act = "type", value = "suitelet" })
		expect(s.values.status).toBe("TESTING")
	end)

	it("cycles choice fields with the arrow keys", function()
		local s = send(ready(), { t = "action", act = "field", value = "logLevel" })
		s = key(s, "right")
		expect(s.values.logLevel).toBe("AUDIT")
		s = key(s, "left")
		s = key(s, "left")
		expect(s.values.logLevel).toBe("EMERGENCY")
	end)

	it("edits by whole characters and clears with Ctrl+U", function()
		local s = typeText(ready(), "Café")
		s = key(s, "backspace")
		expect(s.values.name).toBe("Caf")
		s = key(s, "u", { ctrl = true })
		expect(s.values.name).toBe("")
		s = key(s, "paste", { text = "Line one\nline two" })
		expect(s.values.name).toBe("Line one line two")
	end)
end)

describe("creating", function()
	local function filled(): State
		local s = typeText(ready(), "Order Stamp")
		s = send(s, { t = "action", act = "field", value = "recordType" })
		return typeText(s, "salesorder")
	end

	it("writes the planned files on Ctrl+Enter and rescans once they are written", function()
		local s, effects = key(filled(), "enter", { ctrl = true })
		local w = find(effects, "write") :: Effect
		expect(s.phase).toBe("writing")
		expect(w.root).toBe(ROOT)
		local writes = w.writes :: { any }
		expect(writes[1].path).toBe("src/FileCabinet/SuiteScripts/order_stamp.js")
		expect(writes[2].path).toBe("src/Objects/customscript_order_stamp.xml")
		expect(writes[2].content).toContain("<recordtype>SALESORDER</recordtype>")

		local done, after = send(s, { t = "written", gen = w.gen, written = { writes[1].path, writes[2].path } })
		expect(done.phase).toBe("done")
		local scan = find(after, "scan") :: Effect
		expect(scan.root).toBe(ROOT)

		local extra = { [writes[1].path] = writes[1].content, [writes[2].path] = writes[2].content }
		local verified = send(done, { t = "scanned", gen = scan.gen, snapshot = snapshot("projects/orders", extra) })
		local v = verified.verify :: Form.Verify
		expect(v.found).toBe(true)
		expect(v.deployed).toBe(true)
		expect(v.findings).toEqual({})
	end)

	it("creates only from the last field on Enter, so Enter elsewhere just moves on", function()
		local s, effects = key(filled(), "enter")
		expect(find(effects, "write")).toBeNil()
		expect(s.field).toBe("status")
		s = key(s, "enter")
		s, effects = key(s, "enter")
		expect(find(effects, "write") ~= nil).toBe(true)
	end)

	it("refuses to create while the form has problems and says why", function()
		local s = typeText(ready(), "Order Stamp")
		local n, effects = key(s, "enter", { ctrl = true })
		expect(find(effects, "write")).toBeNil()
		expect((n.notice :: Form.Notice).text).toBe("Cannot create yet: User Event deployments need a record type")
	end)

	it(
		"returns to the form with the error when writing fails and rescans so a retry plans from the new files",
		function()
			local s, effects = key(filled(), "enter", { ctrl = true })
			local w = find(effects, "write") :: Effect
			s, effects =
				send(s, { t = "written", gen = w.gen, written = {}, err = "src/deploy.xml changed since the scan" })
			expect(s.phase).toBe("edit")
			expect((s.notice :: Form.Notice).text).toBe("src/deploy.xml changed since the scan")
			local scan = find(effects, "scan") :: Effect
			expect(scan.gen).toBe(s.gen)
		end
	)

	it("copies a validate command that survives quotes in the project path", function()
		expect(Form.validateCommand("/work/it's here", "suitecloud")).toBe(
			"cd '/work/it'\\''s here' && suitecloud project:validate"
		)
	end)
end)

describe("view", function()
	local function collect(node: any, out: { any })
		table.insert(out, node)
		local children: { any } = node.c or {}
		for _, c in children do
			collect(c, out)
		end
	end

	it("puts each input directly under the main column so main.<key> focus reaches it", function()
		local v = Form.view(ready())
		local keys = {}
		local children: { any } = (v.main :: any).c or {}
		for _, c in children do
			if c.k == "input" then
				table.insert(keys, (c.p :: any).key)
			end
		end
		expect(keys).toEqual({ "name", "scriptIdSuffix", "fileName", "folder", "recordType" })
	end)

	it("previews new files as code and edits as a diff before anything is written", function()
		local deploy = "<deploy>\n    <objects>\n        <path>~/Objects/*</path>\n    </objects>\n</deploy>\n"
		local s = typeText(ready({ ["src/deploy.xml"] = deploy }), "Picker")
		s = send(s, { t = "action", act = "type", value = "suitelet" })
		local nodes = {}
		collect(Form.view(s).main, nodes)
		local kinds: { [string]: number } = {}
		for _, n in nodes do
			kinds[n.k] = (kinds[n.k] or 0) + 1
		end
		expect(kinds.code).toBe(2)
		expect(kinds.diff).toBe(1)
	end)
end)

return nil
