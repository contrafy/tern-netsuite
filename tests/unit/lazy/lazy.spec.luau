--!strict
local lazy = require("../../../plugin/lib/lazy")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

describe("a lazily required module", function()
	it("is not loaded until first used, so it adds nothing to the window's 50 ms load", function()
		local loads = 0
		local _ = lazy(function()
			loads += 1
			return {}
		end)
		expect(loads).toBe(0)
	end)

	it("is loaded once and then reused, since every Tern require call costs a lookup", function()
		local loads = 0
		local get = lazy(function()
			loads += 1
			return { answer = 42 }
		end)
		local first = get()
		expect(get()).toBe(first)
		expect(get().answer).toBe(42)
		expect(loads).toBe(1)
	end)

	it("is loaded again after a failed load, so one error does not disable a feature until reload", function()
		local attempts = 0
		local get = lazy(function(): { ok: boolean }
			attempts += 1
			if attempts == 1 then
				error("module failed to compile")
			end
			return { ok = true }
		end)
		expect(function()
			get()
		end).toThrow()
		expect(get().ok).toBe(true)
		expect(attempts).toBe(2)
	end)
end)

return nil
