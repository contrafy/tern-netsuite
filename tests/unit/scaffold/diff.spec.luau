--!strict
local Diff = require("../../../plugin/lib/scaffold/diff")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local function lines(n: number): { string }
	local out = {}
	for i = 1, n do
		table.insert(out, "line " .. i)
	end
	return out
end

describe("edit preview diff", function()
	it("is empty when nothing changes, so the preview shows no bogus edit", function()
		expect(Diff.unified("x", "a\nb\n", "a\nb\n")).toBe("")
	end)

	it("splits distant insertions into separate hunks with correct line numbers", function()
		local a = lines(20)
		local b = table.clone(a)
		table.insert(b, 3, "new A")
		table.insert(b, 20, "new B")
		local d = Diff.unified("f.xml", table.concat(a, "\n") .. "\n", table.concat(b, "\n") .. "\n")
		expect(d).toBe(table.concat({
			"--- a/f.xml",
			"+++ b/f.xml",
			"@@ -1,5 +1,6 @@",
			" line 1",
			" line 2",
			"+new A",
			" line 3",
			" line 4",
			" line 5",
			"@@ -16,5 +17,6 @@",
			" line 16",
			" line 17",
			" line 18",
			"+new B",
			" line 19",
			" line 20",
			"",
		}, "\n"))
	end)

	it("shows a changed attribute as a removed and an added line", function()
		local d = Diff.unified("m.xml", '<f required="false">X</f>', '<f required="true">X</f>')
		expect(d).toContain('\n-<f required="false">X</f>\n+<f required="true">X</f>\n')
	end)
end)

return nil
