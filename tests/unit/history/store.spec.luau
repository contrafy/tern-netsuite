--!strict
local Store = require("../../../plugin/lib/history/store")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local function entries(n: number, from: number?): string
	local parts: { string } = {}
	for i = from or 1, (from or 1) + n - 1 do
		table.insert(parts, string.format('{"n":%d}\n', i))
	end
	return table.concat(parts)
end

describe("the history file", function()
	it("starts with the first entry when there is no file yet", function()
		expect(Store.append(nil, { '{"n":1}\n' }, 10)).toBe('{"n":1}\n')
	end)

	it("appends after the existing entries", function()
		expect(Store.append(entries(2), { '{"n":3}\n' }, 10)).toBe(entries(3))
	end)

	it("keeps only the newest entries once it is full, so it never grows without bound", function()
		local out = Store.append(entries(10), { '{"n":11}\n', '{"n":12}\n' }, 10)
		expect(out).toBe(entries(10, 3))
	end)

	it("drops a torn last line instead of gluing the new entry onto it", function()
		local out = Store.append('{"n":1}\n{"n":', { '{"n":2}\n' }, 10)
		expect(out).toBe('{"n":1}\n{"n":2}\n')
	end)

	it("drops blank lines", function()
		expect(Store.append('\n{"n":1}\n\n', { '{"n":2}' }, 10)).toBe('{"n":1}\n{"n":2}\n')
	end)
end)

describe("reading the newest lines", function()
	it("returns complete lines in file order, at most the requested number", function()
		expect(Store.lines(entries(5), 2)).toEqual({ '{"n":4}', '{"n":5}' })
		expect(Store.lines("", 2)).toEqual({})
	end)
end)

return nil
