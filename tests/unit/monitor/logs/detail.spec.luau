--!strict
local Detail = require("../../../../plugin/lib/monitor/logs/detail")
local fixtures = require("../../../lib/fixtures")
local json = require("../../../lib/json")
local t = require("../../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local rows = json.decode(fixtures.read("monitor/logs/restlet-rows.json"))

local function labelText(node: any): string
	local parts = {}
	for _, s in node.label do
		table.insert(parts, if type(s) == "string" then s else s.t)
	end
	return table.concat(parts)
end

local function find(nodes: { any }, prefix: string): any?
	for _, n in nodes do
		if string.sub(labelText(n), 1, #prefix) == prefix then
			return n
		end
	end
	return nil
end

describe("JSON log details", function()
	it("turns a JSON object detail into an expandable tree with keys in order", function()
		local p = Detail.parse(rows[3].detail, json.decode, json.null)
		expect(p.json).toBe(true)
		local tree = p.tree :: { any }
		expect(labelText(tree[1])).toBe("message: \"Duplicate alias: 'last'\"")
		expect(labelText(tree[2])).toBe('name: "SSS_DUPLICATE_ALIAS"')
		local stack = find(tree, "stack") :: any
		expect(labelText(stack)).toBe("stack [3]")
		expect(#stack.children).toBe(3)
		expect(labelText(stack.children[2])).toBe('[2] "    at /SuiteScripts/restlets/suiteql.js:1491:42"')
	end)

	it("nests objects and keeps every node id unique for stable rendering", function()
		local p = Detail.parse(rows[5].detail, json.decode, json.null)
		local tree = p.tree :: { any }
		local raw = find(tree, "rawParams") :: any
		expect(labelText(raw)).toBe("rawParams {14}")
		local seen: { [string]: boolean } = {}
		local function walk(list: { any })
			for _, n in list do
				expect(seen[n.id]).toBeNil()
				seen[n.id] = true
				walk(n.children or {})
			end
		end
		walk(tree)
	end)

	it("expands a small detail but keeps a big one collapsed so the rows stay in view", function()
		local small = Detail.parse(rows[3].detail, json.decode, json.null)
		expect((find(small.tree :: { any }, "stack") :: any).open).toBe(true)
		local big = Detail.parse(rows[5].detail, json.decode, json.null)
		expect((find(big.tree :: { any }, "rawParams") :: any).open).toBeNil()
	end)

	it("shows numbers, booleans, null and empty containers readably", function()
		local p = Detail.parse('{"a":1,"b":true,"c":null,"d":[],"e":{},"f":[null]}', json.decode, json.null)
		local tree = p.tree :: { any }
		expect(labelText(tree[1])).toBe("a: 1")
		expect(labelText(tree[2])).toBe("b: true")
		expect(labelText(tree[3])).toBe("d: (empty)")
		expect(labelText(tree[4])).toBe("e: (empty)")
		expect(labelText(tree[5].children[1])).toBe("[1] null")
	end)

	it("leaves invalid or truncated JSON (NetSuite cuts details at 3999 chars) as raw text", function()
		local p = Detail.parse(rows[7].detail, json.decode, json.null)
		expect(p.json).toBe(false)
		expect(p.tree).toBeNil()
	end)

	it("does not treat plain text or JSON scalars as a structured detail", function()
		expect(Detail.parse(rows[6].detail, json.decode, json.null).json).toBe(false)
		expect(Detail.parse("42", json.decode, json.null).json).toBe(false)
		expect(Detail.parse('"text"', json.decode, json.null).json).toBe(false)
		expect(Detail.parse("", json.decode, json.null).json).toBe(false)
	end)

	it("refuses to decode a huge detail and caps the nodes of a wide one", function()
		local huge = '{"x":"' .. string.rep("a", Detail.MAX_BYTES) .. '"}'
		local called = false
		local p = Detail.parse(huge, function(s: string): any
			called = true
			return json.decode(s)
		end, json.null)
		expect(p.json).toBe(false)
		expect(called).toBe(false)

		local items = {}
		for i = 1, Detail.MAX_NODES + 50 do
			table.insert(items, tostring(i))
		end
		local wide = Detail.parse("[" .. table.concat(items, ",") .. "]", json.decode, json.null)
		expect(wide.json).toBe(true)
		expect(wide.truncated).toBe(true)
		expect(wide.nodes <= Detail.MAX_NODES + 1).toBe(true)
	end)

	it("shortens long strings in labels so one value cannot flood the view", function()
		local p = Detail.parse('{"s":"' .. string.rep("b", 2000) .. '"}', json.decode, json.null)
		local label = labelText((p.tree :: { any })[1])
		expect(#label < 2000).toBe(true)
		expect(label).toContain("…")
	end)

	it("never raises when the decoder does", function()
		local p = Detail.parse("{bad", function(): any
			error("boom")
		end, json.null)
		expect(p.json).toBe(false)
	end)

	it("previews a detail on one line", function()
		expect(Detail.preview("a\n  b\tc", 100)).toBe("a b c")
		expect(Detail.preview(string.rep("x", 50), 10)).toBe("xxxxxxxxx…")
	end)
end)

return nil
