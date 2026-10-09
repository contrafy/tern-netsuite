--!strict
local Argv = require("../../../plugin/lib/sdf/argv")
local Config = require("../../../plugin/lib/config")
local ManageauthView = require("../../../plugin/lib/lens/manageauth")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

type Node = any

local DEFAULTS = Config.defaults()

local function inv(line: string): Argv.Invocation
	local words = Argv.words(line)
	local program = table.remove(words, 1) :: string
	return Argv.parse({ program = program, args = words, line = line }) :: Argv.Invocation
end

local function badges(node: Node): { [string]: { text: string, tone: string } }
	local out: { [string]: { text: string, tone: string } } = {}
	local function walk(n: Node, row: string?)
		local key = n.p and n.p.key
		local here = if type(key) == "string" and string.sub(key, 1, 2) == "r:" then string.sub(key, 3) else row
		if n.k == "badge" and here then
			out[here] = { text = n.p.text, tone = n.p.tone }
		end
		for _, c in n.c or {} do
			walk(c, here)
		end
	end
	walk(node, nil)
	return out
end

describe("auth ID list", function()
	it("renders a table row per auth ID, the sandbox muted", function()
		local node = ManageauthView.render(
			inv("suitecloud account:manageauth --list"),
			fixtures.lines("suitecloud/manageauth/list.txt"),
			DEFAULTS
		) :: Node
		local b = badges(node)
		expect(b["demo-sb"].text).toBe("1234567_SB1")
		expect(b["demo-sb"].tone).toBe("muted")
	end)

	it("never calls a row without an account id sandbox: it is unknown unless configured", function()
		local lines = fixtures.lines("suitecloud/manageauth/list.txt")
		local b = badges(ManageauthView.render(inv("suitecloud account:manageauth --list"), lines, DEFAULTS) :: Node)
		expect(b["demo-prod"].text).toBe("unknown")
		local cfg = Config.parse(
			[[{"accounts":[{"id":"prod","label":"PROD","account_id":"1234567","auth_ids":["demo-prod"]}]}]],
			json.decode
		)
		local configured =
			badges(ManageauthView.render(inv("suitecloud account:manageauth --list"), lines, cfg) :: Node)
		expect(configured["demo-prod"].text).toBe("PROD")
		expect(configured["demo-prod"].tone).toBe("error")
	end)
end)

describe("auth ID info", function()
	it("shows the account with its sandbox badge", function()
		local node = ManageauthView.render(
			inv("suitecloud account:manageauth --info demo-sb"),
			fixtures.lines("suitecloud/manageauth/info-sandbox.txt"),
			DEFAULTS
		) :: Node
		local badge = node.c and node.c[1].c and node.c[1].c[1]
		expect((badge :: Node).p.text).toBe("1234567_SB1")
		expect((badge :: Node).p.tone).toBe("muted")
	end)

	it("stays raw for an error such as a missing auth ID", function()
		expect(
			ManageauthView.render(
				inv("suitecloud account:manageauth --info demo-missing"),
				fixtures.lines("suitecloud/manageauth/info-missing.txt"),
				DEFAULTS
			)
		).toBeNil()
	end)

	it("stays raw for options that change credentials and for interactive runs", function()
		expect(ManageauthView.render(inv("suitecloud account:manageauth --remove x"), { "done" }, DEFAULTS)).toBeNil()
		expect(ManageauthView.render(inv("suitecloud account:manageauth -i"), { "?" }, DEFAULTS)).toBeNil()
	end)
end)

describe("output the parser does not read", function()
	it("stays visible under Other output, so native and raw show the same lines", function()
		local lines = fixtures.lines("suitecloud/manageauth/list.txt")
		table.insert(lines, 1, "(node:1) DeprecationWarning: something")
		local node = ManageauthView.render(inv("suitecloud account:manageauth --list"), lines, DEFAULTS) :: Node
		local other = node.c[#node.c]
		expect(other.k).toBe("section")
		expect(other.p.key).toBe("unknown")
		expect(other.c[1].p.spans[1].t).toBe("(node:1) DeprecationWarning: something")
		local info = fixtures.lines("suitecloud/manageauth/info-sandbox.txt")
		table.insert(info, "Role ID: 3")
		local infoNode =
			ManageauthView.render(inv("suitecloud account:manageauth --info demo-sb"), info, DEFAULTS) :: Node
		expect(infoNode.c[#infoNode.c].c[1].p.spans[1].t).toBe("Role ID: 3")
	end)

	it("adds no section when every line was read", function()
		local node = ManageauthView.render(
			inv("suitecloud account:manageauth --list"),
			fixtures.lines("suitecloud/manageauth/list.txt"),
			DEFAULTS
		) :: Node
		for _, c in node.c do
			expect(c.p and c.p.key == "unknown").toBe(false)
		end
	end)
end)

return nil
