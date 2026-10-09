--!strict
local Viewstate = require("../../../plugin/lib/lens/viewstate")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

describe("view state carried in action values", function()
	it("round-trips every combination, so a reloaded lens shows what the user had open", function()
		for _, w in { false, true } do
			for _, i in { false, true } do
				for _, s in { false, true } do
					local vs = { warnings = w, items = i, steps = s }
					expect(Viewstate.decode(Viewstate.encode(vs))).toEqual(vs)
				end
			end
		end
	end)

	it("holds no '=' after the action name, which Tern splits on", function()
		local action = Viewstate.action({ warnings = true, items = true, steps = true })
		expect(action).toBe("v=w:1;i:1;s:1")
		local _, count = string.gsub(action, "=", "")
		expect(count).toBe(1)
	end)

	it("ignores unknown and malformed fields from other plugin versions", function()
		expect(Viewstate.decode("w:1;zz:9;garbage;i")).toEqual({ warnings = true, items = false, steps = false })
		expect(Viewstate.decode("")).toEqual(Viewstate.default())
	end)

	it("toggles one field without touching the others", function()
		local vs = Viewstate.toggled(Viewstate.decode("s:1"), "warnings")
		expect(vs).toEqual({ warnings = true, items = false, steps = true })
	end)
end)

return nil
