--!strict
-- Object XML fixtures under tests/fixtures/drift/: `account/` follows the
-- format `object:import` wrote in a sandbox scratch project with CLI 3.2.0
-- (two-space indent, empty elements as <x></x>, no prolog, no trailing
-- newline, &quot; escaped), with synthetic Acme content; `local/` holds the
-- same objects as a developer might keep them in git.
local Canon = require("../../../plugin/lib/drift/canon")
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local function pair(name: string): (string, string)
	return fixtures.read("drift/local/" .. name .. ".xml"), fixtures.read("drift/account/" .. name .. ".xml")
end

describe("drift canon", function()
	it(
		"treats an export that differs only in formatting as identical, so reformatted repos do not report drift",
		function()
			local mine, theirs = pair("customlist_acme_sizes")
			local v = Canon.compare(mine, theirs)
			expect(v.same).toBe(true)
			expect(v.exact).toBe(false)
			expect(v.parseError).toBeNil()
		end
	)

	it("reports a changed value as drift", function()
		local mine, theirs = pair("customlist_acme_colors")
		local v = Canon.compare(mine, theirs)
		expect(v.same).toBe(false)
	end)

	it("treats Windows line endings as formatting, as XML parsers do", function()
		local a = '<customlist scriptid="x">\r\n  <name>A</name>\r\n</customlist>\r\n'
		local b = '<customlist scriptid="x">\n  <name>A</name>\n</customlist>'
		expect(Canon.compare(a, b).same).toBe(true)
	end)

	it("keeps a carriage return written as a character reference, since NetSuite stores it in the value", function()
		local a = '<x scriptid="a"><name>A&#xd;</name></x>'
		local b = '<x scriptid="a"><name>A</name></x>'
		expect(Canon.compare(a, b).same).toBe(false)
	end)

	it("ignores attribute order, which carries no meaning in XML", function()
		local a = '<x scriptid="a" b="1"><y/></x>'
		local b = '<x b="1" scriptid="a"><y></y></x>'
		expect(Canon.compare(a, b).same).toBe(true)
	end)

	it("keeps whitespace inside a value, which NetSuite stores as written", function()
		local a = '<x scriptid="a"><name>Acme </name></x>'
		local b = '<x scriptid="a"><name>Acme</name></x>'
		expect(Canon.compare(a, b).same).toBe(false)
	end)

	it("compares bytes when a side is malformed, and says which side, so a broken local file is not hidden", function()
		local v = Canon.compare("<x scriptid='a'>", "<x scriptid='a'/>")
		expect(v.same).toBe(false)
		expect(v.parseError).toContain("project copy")
		local same = Canon.compare("<x", "<x")
		expect(same.same).toBe(true)
		expect(same.exact).toBe(true)
	end)

	it("emits one canonical text for every formatting of the same tree", function()
		local mine, theirs = pair("customlist_acme_sizes")
		local a = Canon.canonical(mine)
		local b = Canon.canonical(theirs)
		expect(a).toBe(b :: string)
	end)
end)

return nil
