--!strict
local Pane = require("../../../plugin/lib/pane")
local t = require("../../lib/test")
local ui = require("../../../plugin/lib/ui")

local describe, it, expect = t.describe, t.it, t.expect

describe("the pane size a block can trust", function()
	it("ignores Tern's 80x24 placeholder until the block has been resized", function()
		local cols, rows = Pane.size(80, 24, false)
		expect(cols).toBeNil()
		expect(rows).toBeNil()
	end)

	it("trusts 80x24 once a resize reported it", function()
		local cols, rows = Pane.size(80, 24, true)
		expect(cols).toBe(80)
		expect(rows).toBe(24)
	end)

	it("trusts any other size, which only a Tern that measured the pane reports", function()
		local cols, rows = Pane.size(82, 47, false)
		expect(cols).toBe(82)
		expect(rows).toBe(47)
	end)
end)

describe("the scrolling row list", function()
	local children = { ui.text({ "a" }, { key = "r1" }), ui.text({ "b" }, { key = "r2" }) }

	it("is a list Tern sizes to the pane and scrolls, so the selected row stays in view", function()
		local n = ui.scroll("rows", children, "r2", 200) :: any
		expect(n.k).toBe("list")
		expect(n.p.key).toBe("rows")
		expect(n.p.role).toBe(ui.SCROLL_ROLE)
		expect(n.p.max).toEqual({ lines = 200 })
		expect(n.c).toBe(children)
	end)

	it("selects a child by its node id: the region, the list key and the child key", function()
		local n = ui.scroll("rows", children, "r2", 200) :: any
		expect(n.p.selected).toBe("main.rows.r2")
	end)

	it("selects nothing without a selected key", function()
		local n = ui.scroll("rows", children, nil, 200) :: any
		expect(n.p.selected).toBeNil()
	end)
end)

return nil
