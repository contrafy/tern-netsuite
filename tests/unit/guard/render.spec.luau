--!strict
local Config = require("../../../plugin/lib/config")
local Render = require("../../../plugin/lib/guard/render")
local Session = require("../../../plugin/lib/guard/session")
local encode = require("./encode")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local NONCE = "0123456789abcdef0123456789abcdef"
local SPOOL = "/data/tern-netsuite/spool"
local FP = string.rep("ab", 32)
local SHA = string.rep("0f", 32)
local NOW = 1791476710

local function request(over: { [string]: any }?): string
	local d: { [string]: any } = {
		version = 1,
		nonce = NONCE,
		argv = { "suitecloud", "file:upload", "--paths", "/SuiteScripts/a b.js" },
		command = "file:upload",
		program = "/opt/bin/suitecloud",
		cwd = "/work/sdf/billing",
		folder = "/work/sdf/billing/src",
		auth_id = "prod",
		account_id = "1234567",
		account_name = "Example Co",
		account_type = "Production",
		pane = "7",
		git = {
			root = "/work",
			branch = "feature/x",
			head = "0123456789abcdef0123456789abcdef01234567",
			dirty = true,
			upstream = "origin/feature/x",
			ahead = 0,
			behind = 0,
			default_branch = "main",
		},
		notes = {},
		files = {
			{ path = "/work/sdf/billing/project.json", sha256 = SHA },
			{ path = "/work/sdf/billing/src/FileCabinet/SuiteScripts/a b.js", sha256 = SHA },
			{ path = "/work/sdf/billing/src/Objects/customscript_a.xml", sha256 = SHA },
			{ path = "/work/sdf/billing/src/Objects/customscript_b.xml", sha256 = SHA },
		},
		fingerprint = FP,
		created_at = NOW - 5,
		timeout_s = 600,
	}
	if over then
		for k, v in over do
			d[k] = v
		end
	end
	return encode(d)
end

local function session(over: { [string]: any }?, cfgText: string?): Session.State
	local cfg =
		Config.parse(cfgText or [[{"accounts": [{"id": "p", "label": "PROD", "account_id": "1234567"}]}]], json.decode)
	local s = Session.init({
		args = { SPOOL .. "/req-" .. NONCE .. ".json" },
		now = NOW,
		spool = SPOOL,
		request = { text = request(over) },
		panes = { "7" },
		decode = json.decode,
		config = cfg,
	})
	for _, tag in { "spool", "hash" } do
		Session.update(s, {
			t = "result",
			tag = tag,
			gen = s.gen,
			result = {
				status = 0,
				stdout = if tag == "spool" then SPOOL .. "\n" else FP .. "  -\n",
				stderr = "",
				timed_out = false,
			},
		})
	end
	return s
end

-- Every visible string of a node tree, one per line.
local function strings(node: any, out: { string }?): { string }
	local acc = out or {}
	if type(node) ~= "table" then
		return acc
	end
	local p = node.p
	if p then
		for _, field in { "text", "placeholder" } do
			if type(p[field]) == "string" then
				table.insert(acc, p[field])
			end
		end
		for _, field in { "spans", "head" } do
			if type(p[field]) == "table" then
				local parts: { string } = {}
				for _, span in p[field] do
					table.insert(parts, span.t)
				end
				table.insert(acc, table.concat(parts))
			end
		end
		if type(p.items) == "table" then
			for _, item in p.items do
				local parts: { string } = {}
				for _, span in item.k do
					table.insert(parts, span.t)
				end
				table.insert(parts, ": ")
				for _, span in item.v do
					table.insert(parts, span.t)
				end
				table.insert(acc, table.concat(parts))
			end
		end
	end
	for _, child in node.c or {} do
		strings(child, acc)
	end
	return acc
end

local function text(s: Session.State): string
	local v = Render.view(s)
	return table.concat(strings(v.main), "\n") .. "\n" .. table.concat(strings(v.dock), "\n")
end

local function findAction(node: any, act: string): any
	if type(node) ~= "table" then
		return nil
	end
	if node.p and node.p.actions and node.p.actions.click == act then
		return node
	end
	for _, child in node.c or {} do
		local hit = findAction(child, act)
		if hit then
			return hit
		end
	end
	return nil
end

describe("the approve block view", function()
	it("names the production target prominently, with its account and auth ID", function()
		local out = text(session())
		expect(out).toContain("PRODUCTION")
		expect(out).toContain("PROD")
		expect(out).toContain("1234567")
		expect(out).toContain("Example Co")
		expect(out).toContain("Auth ID: prod")
	end)

	it("shows the exact command, quoting arguments with spaces", function()
		expect(text(session())).toContain("suitecloud file:upload --paths '/SuiteScripts/a b.js'")
	end)

	it("shows the git state and its warnings", function()
		local out = text(session())
		expect(out).toContain("feature/x @ 0123456789ab")
		expect(out).toContain("Uncommitted changes")
		expect(out).toContain("not main")
	end)

	it("summarises what is sent, by kind, and lists the files on demand", function()
		local s = session()
		local out = text(s)
		expect(out).toContain("4 files fingerprinted")
		expect(out).toContain("2 objects")
		expect(out).toContain("1 File Cabinet file")
		Session.update(s, { t = "action", act = "files" })
		out = text(s)
		expect(out).toContain("~/Objects/customscript_a.xml")
		expect(out).toContain("project.json")
	end)

	it("asks to type the label when confirmation is required, with an input to type it in", function()
		local s = session()
		local v = Render.view(s)
		expect(text(s)).toContain("Type PROD to approve")
		local input: any = nil
		for _, child in (v.main :: any).c do
			if child.k == "input" then
				input = child
			end
		end
		assert(input, "input node")
		expect(input.p.key).toBe("typed")
	end)

	it("offers Approve and Deny as clickable actions", function()
		local v = Render.view(session())
		assert(findAction(v.main, "approve"), "approve action")
		assert(findAction(v.main, "deny"), "deny action")
	end)

	it("offers only Close when nothing can be answered", function()
		local s = session({ created_at = NOW - 700 })
		local v = Render.view(s)
		expect(findAction(v.main, "approve")).toBeNil()
		assert(findAction(v.main, "close"), "close action")
		expect(text(s)).toContain("expired")
	end)

	it("marks a non-production target as such and asks for no typing", function()
		local s = session({ account_id = "1234567_SB1" }, "{}")
		local out = text(s)
		expect(out).toContain("NON-PRODUCTION")
		expect((string.find(out, "to approve", 1, true))).toBeNil()
	end)

	it("titles the pane with the account and command", function()
		expect(Render.title(session())).toBe("NetSuite approve · PROD · file:upload")
	end)
end)

return nil
