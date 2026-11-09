--!strict
local TextDiff = require("../../../plugin/lib/drift/textdiff")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local function lines(n: number, f: (number) -> string): string
	local out: { string } = table.create(n)
	for i = 1, n do
		out[i] = f(i)
	end
	return table.concat(out, "\n") .. "\n"
end

-- Applies a unified diff to `from`, so specs check the diff is correct
-- rather than one particular rendering of it.
local function apply(from: string, diff: string): string
	local src = string.split(from, "\n")
	if src[#src] == "" then
		table.remove(src)
	end
	local out: { string } = {}
	local pos = 1
	local inHunk = false
	for _, l in string.split(diff, "\n") do
		local start = string.match(l, "^@@ %-(%d+)")
		if start then
			local s = tonumber(start) :: number
			-- "-0,0" hunks insert before line 1.
			local upto = if string.find(l, "^@@ %-%d+,0 ") then s else s - 1
			while pos <= upto do
				table.insert(out, src[pos])
				pos += 1
			end
			inHunk = true
		elseif inHunk and string.sub(l, 1, 1) == " " then
			table.insert(out, string.sub(l, 2))
			pos += 1
		elseif inHunk and string.sub(l, 1, 1) == "-" and string.sub(l, 1, 4) ~= "--- " then
			pos += 1
		elseif inHunk and string.sub(l, 1, 1) == "+" and string.sub(l, 1, 4) ~= "+++ " then
			table.insert(out, string.sub(l, 2))
		end
	end
	while pos <= #src do
		table.insert(out, src[pos])
		pos += 1
	end
	return table.concat(out, "\n") .. "\n"
end

describe("drift textdiff", function()
	it("is empty for equal texts, so identical entries carry no diff", function()
		expect(TextDiff.unified("a.xml", "x\ny\n", "x\ny\n").text).toBe("")
	end)

	it("labels the project side and the account side so the reader knows which is which", function()
		local d = TextDiff.unified("Objects/a.xml", "a\nb\nc\n", "a\nB\nc\n")
		expect(d.text).toContain("--- project/Objects/a.xml")
		expect(d.text).toContain("+++ account/Objects/a.xml")
		expect(d.text).toContain("-b\n+B")
		expect(d.text).toContain("@@ -1,3 +1,3 @@")
	end)

	it("produces a diff that turns the project copy into the account copy", function()
		local a = lines(300, function(i)
			return "line " .. i
		end)
		local b = lines(305, function(i)
			if i == 7 then
				return "inserted"
			elseif i % 50 == 0 then
				return "changed " .. i
			end
			return "line " .. (if i > 7 then i - 1 else i)
		end)
		local d = TextDiff.unified("x.js", a, b)
		expect(d.truncated).toBe(false)
		expect(apply(a, d.text)).toBe(b)
	end)

	it("keeps hunks small around a change deep inside a large file, so a one-line drift reads as one line", function()
		local a = lines(5000, function(i)
			return "row " .. i
		end)
		local b = string.gsub(a, "row 2500\n", "row 2500 edited\n")
		local d = TextDiff.unified("big.js", a, b)
		expect(d.text).toContain("@@ -2497,7 +2497,7 @@")
		expect(apply(a, d.text)).toBe(b)
	end)

	it("handles a completely rewritten file without running away, still producing a correct diff", function()
		local a = lines(3000, function(i)
			return "a" .. i
		end)
		local b = lines(3000, function(i)
			return "b" .. i
		end)
		local d = TextDiff.unified("x.js", a, b, { maxBytes = 10000000 })
		expect(apply(a, d.text)).toBe(b)
	end)

	it("truncates very large diffs and says so, so a block never ships megabytes of text", function()
		local a = lines(2000, function(i)
			return string.rep("a", 100) .. i
		end)
		local b = lines(2000, function(i)
			return string.rep("b", 100) .. i
		end)
		local d = TextDiff.unified("x.js", a, b, { maxBytes = 5000 })
		expect(d.truncated).toBe(true)
		expect(#d.text <= 5000 + 200).toBe(true)
	end)

	it("diffs texts without a trailing newline like NetSuite exports", function()
		local d = TextDiff.unified("a.xml", "<a>\n  <b>1</b>\n</a>\n", "<a>\n  <b>2</b>\n</a>")
		expect(d.text).toContain("-  <b>1</b>\n+  <b>2</b>")
	end)

	it("adds lines to an empty side", function()
		local d = TextDiff.unified("a.js", "", "x\ny\n")
		expect(d.text).toContain("@@ -0,0 +1,2 @@")
		expect(apply("", d.text)).toBe("x\ny\n")
	end)
end)

return nil
