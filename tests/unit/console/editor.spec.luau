--!strict
local Editor = require("../../../plugin/lib/console/editor")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local function key(name: string, text: string?, mods: { [string]: boolean }?): Editor.Key
	local k: { [string]: any } = { name = name, text = text, ctrl = false, alt = false, shift = false, meta = false }
	for m, v in (mods or {}) :: { [string]: boolean } do
		k[m] = v
	end
	return k :: any
end

local function typed(f: Editor.Field, text: string): Editor.Field
	for ch in string.gmatch(text, utf8.charpattern) do
		f = Editor.key(f, key(ch, ch)) :: Editor.Field
	end
	return f
end

local function at(text: string, cursor: number): Editor.Field
	return { text = text, cursor = cursor, undo = {}, typing = false }
end

describe("console editor", function()
	it("writes multi-line SQL: Enter breaks the line and keeps the indentation", function()
		local f = typed(Editor.new(), "SELECT id")
		f = Editor.key(f, key("enter")) :: Editor.Field
		f = typed(f, "  FROM customer")
		f = Editor.key(f, key("enter")) :: Editor.Field
		f = typed(f, "WHERE 1 = 1")
		expect(f.text).toBe("SELECT id\n  FROM customer\n  WHERE 1 = 1")
	end)

	it("leaves Ctrl+Enter to the console so it can run the query", function()
		expect(Editor.key(Editor.new("SELECT 1"), key("enter", nil, { ctrl = true }))).toBeNil()
		expect(Editor.key(Editor.new("SELECT 1"), key("enter", nil, { meta = true }))).toBeNil()
	end)

	it("moves between lines keeping the column, clamped to shorter lines", function()
		local f = at("SELECT id,\n  x\nFROM customer", 8)
		f = Editor.key(f, key("down")) :: Editor.Field
		expect(f.cursor).toBe(14)
		f = Editor.key(f, key("down")) :: Editor.Field
		expect(f.cursor).toBe(18)
		f = Editor.key(f, key("up")) :: Editor.Field
		f = Editor.key(f, key("up")) :: Editor.Field
		expect(f.cursor).toBe(3)
	end)

	it("says when the caret is on the first or last line, where up/down recall history", function()
		local f = at("SELECT id\nFROM customer", 3)
		expect(Editor.onFirstLine(f)).toBe(true)
		expect(Editor.onLastLine(f)).toBe(false)
		f = at("SELECT id\nFROM customer", 12)
		expect(Editor.onFirstLine(f)).toBe(false)
		expect(Editor.onLastLine(f)).toBe(true)
		expect(Editor.onFirstLine(Editor.new(""))).toBe(true)
		expect(Editor.onLastLine(Editor.new(""))).toBe(true)
	end)

	it("keeps pasted line breaks and drops other control characters", function()
		local f = Editor.key(Editor.new(""), key("paste", "SELECT id\r\nFROM\tcustomer\27")) :: Editor.Field
		expect(f.text).toBe("SELECT id\nFROM\tcustomer")
	end)

	it("undoes a typed word in one step and a paste in another", function()
		local f = typed(Editor.new(""), "SELECT ")
		f = Editor.key(f, key("paste", "id")) :: Editor.Field
		f = Editor.key(f, key("z", "z", { meta = true })) :: Editor.Field
		expect(f.text).toBe("SELECT ")
		f = Editor.key(f, key("z", "z", { ctrl = true })) :: Editor.Field
		expect(f.text).toBe("")
	end)

	it("edits by word and by line like other Tern fields", function()
		local f = at("SELECT id FROM customer", 23)
		f = Editor.key(f, key("backspace", nil, { alt = true })) :: Editor.Field
		expect(f.text).toBe("SELECT id FROM ")
		f = Editor.key(f, key("u", "u", { ctrl = true })) :: Editor.Field
		expect(f.text).toBe("")
		f = at("a\nbc", 4)
		f = Editor.key(f, key("home")) :: Editor.Field
		expect(f.cursor).toBe(2)
		f = Editor.key(f, key("end")) :: Editor.Field
		expect(f.cursor).toBe(4)
	end)

	it("reports the caret to Tern in UTF-16 units so it lands after non-ASCII text", function()
		local f = typed(Editor.new(""), "'é😀'")
		expect(f.cursor).toBe(#"'é😀'")
		expect(Editor.caret(f)).toBe(5)
		f = Editor.key(f, key("left")) :: Editor.Field
		f = Editor.key(f, key("backspace")) :: Editor.Field
		expect(f.text).toBe("'é'")
	end)

	it("ignores keys it does not own so the console can bind them", function()
		expect(Editor.key(Editor.new(""), key("tab"))).toBeNil()
		expect(Editor.key(Editor.new(""), key("escape"))).toBeNil()
		expect(Editor.key(Editor.new(""), key("o", "o", { ctrl = true }))).toBeNil()
	end)
end)

return nil
