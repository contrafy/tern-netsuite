--!strict
-- The console's multi-line SQL field: text, caret and undo steps the block
-- owns; Tern only draws it (an `editor` node). Plugin blocks get every key,
-- so editing is done here. The caret is a byte offset, always on a
-- character boundary; the node's `cursor` prop is in UTF-16 code units.

export type Snapshot = { text: string, cursor: number }

export type Field = {
	text: string,
	-- Byte offset of the caret, 0..#text.
	cursor: number,
	-- Oldest first; each entry is the field before one change.
	undo: { Snapshot },
	-- The last change typed a character: the next one joins its undo step.
	typing: boolean,
}

export type Key = { name: string, text: string?, ctrl: boolean?, alt: boolean?, shift: boolean?, meta: boolean? }

local M = {}

M.MAX_UNDO = 100
M.INDENT = "  "

local function isCont(b: number?): boolean
	return b ~= nil and b >= 0x80 and b < 0xC0
end

-- UTF-16 code units of the first `bytes` bytes of `text` (all by default).
function M.utf16(text: string, bytes: number?): number
	local n = 0
	for i = 1, bytes or #text do
		local b = string.byte(text, i)
		if b < 0x80 or b >= 0xC0 then
			n += if b >= 0xF0 then 2 else 1
		end
	end
	return n
end

function M.new(text: string?): Field
	local t = text or ""
	return { text = t, cursor = #t, undo = {}, typing = false }
end

-- The `cursor` prop of the editor node.
function M.caret(f: Field): number
	return M.utf16(f.text, f.cursor)
end

local function prevChar(text: string, c: number): number
	local p = math.max(c - 1, 0)
	while p > 0 and isCont(string.byte(text, p + 1)) do
		p -= 1
	end
	return p
end

local function nextChar(text: string, c: number): number
	local n = math.min(c + 1, #text)
	while n < #text and isCont(string.byte(text, n + 1)) do
		n += 1
	end
	return n
end

local function isSpaceAt(text: string, i: number): boolean
	return string.find(string.sub(text, i, i), "^%s") ~= nil
end

local function wordLeft(text: string, c: number): number
	local p = c
	while p > 0 and isSpaceAt(text, p) do
		p -= 1
	end
	while p > 0 and not isSpaceAt(text, p) do
		p -= 1
	end
	return p
end

local function wordRight(text: string, c: number): number
	local n = c
	while n < #text and isSpaceAt(text, n + 1) do
		n += 1
	end
	while n < #text and not isSpaceAt(text, n + 1) do
		n += 1
	end
	return n
end

-- Byte offset where the line holding offset `c` starts.
local function lineStart(text: string, c: number): number
	local p = c
	while p > 0 and string.sub(text, p, p) ~= "\n" do
		p -= 1
	end
	return p
end

-- Byte offset where the line holding offset `c` ends (before its "\n").
local function lineEnd(text: string, c: number): number
	local e = string.find(text, "\n", c + 1, true)
	return if e then e - 1 else #text
end

-- Characters between `from` and `to` (byte offsets on one line).
local function chars(text: string, from: number, to: number): number
	return utf8.len(string.sub(text, from + 1, to)) or (to - from)
end

-- The byte offset `n` characters after `from`, at most `limit`.
local function advance(text: string, from: number, n: number, limit: number): number
	local c = from
	for _ = 1, n do
		if c >= limit then
			break
		end
		c = nextChar(text, c)
	end
	return math.min(c, limit)
end

-- 1-based line of the caret and the number of lines.
function M.line(f: Field): (number, number)
	local line, total = 1, 1
	for i = 1, #f.text do
		if string.byte(f.text, i) == 10 then
			total += 1
			if i <= f.cursor then
				line += 1
			end
		end
	end
	return line, total
end

function M.onFirstLine(f: Field): boolean
	return string.find(string.sub(f.text, 1, f.cursor), "\n", 1, true) == nil
end

function M.onLastLine(f: Field): boolean
	return string.find(f.text, "\n", f.cursor + 1, true) == nil
end

-- Line breaks become "\n"; tabs stay; other control characters go.
local function clean(text: string): string
	local t = string.gsub(text, "\r\n?", "\n")
	return (string.gsub(t, "[%z\1-\8\11-\31\127]", ""))
end

local function moved(f: Field, cursor: number): Field
	if cursor == f.cursor then
		return f
	end
	return { text = f.text, cursor = cursor, undo = f.undo, typing = false }
end

local function changed(f: Field, text: string, cursor: number, typing: boolean, join: boolean): Field
	if text == f.text then
		return moved(f, cursor)
	end
	local undo = f.undo
	if not join then
		undo = table.clone(undo)
		table.insert(undo, { text = f.text, cursor = f.cursor })
		if #undo > M.MAX_UNDO then
			table.remove(undo, 1)
		end
	end
	return { text = text, cursor = cursor, undo = undo, typing = typing }
end

local function replace(f: Field, from: number, to: number, insert: string): Field
	local text = string.sub(f.text, 1, from) .. insert .. string.sub(f.text, to + 1)
	return changed(f, text, from + #insert, false, false)
end

local function typeText(f: Field, ch: string): Field
	local c = f.cursor
	-- A word typed after a space starts a new undo step.
	local join = f.typing and not (c > 0 and isSpaceAt(f.text, c) and not string.find(ch, "^%s"))
	local text = string.sub(f.text, 1, c) .. ch .. string.sub(f.text, c + 1)
	return changed(f, text, c + #ch, true, join)
end

-- Replaces the whole text (history recall, a loaded query) as one undo step.
function M.set(f: Field, text: string): Field
	return changed(f, text, #text, false, false)
end

-- The text a key types, if any (paste aside).
function M.printable(key: Key): string?
	if key.ctrl or key.meta or key.alt then
		return nil
	end
	local text = key.text
	if text and #text >= 1 and not string.find(text, "%c") then
		return text
	end
	if #key.name == 1 then
		return if key.shift then string.upper(key.name) else key.name
	end
	if key.name == "space" then
		return " "
	end
	return nil
end

local function vertical(f: Field, down: boolean): Field
	local text, c = f.text, f.cursor
	local start = lineStart(text, c)
	local col = chars(text, start, c)
	if down then
		local e = lineEnd(text, c)
		if e >= #text then
			return moved(f, #text)
		end
		local nextStart = e + 1
		return moved(f, advance(text, nextStart, col, lineEnd(text, nextStart)))
	end
	if start == 0 then
		return moved(f, 0)
	end
	local prevStart = lineStart(text, start - 1)
	return moved(f, advance(text, prevStart, col, start - 1))
end

-- Applies an editing key; nil when the key is not the field's (ctrl+enter,
-- escape, tab, function keys, ...). A key that changes nothing returns `f`.
function M.key(f: Field, key: Key): Field?
	local name = key.name
	local text, c = f.text, f.cursor
	local word = key.alt or key.ctrl
	if name == "paste" then
		local insert = clean(key.text or "")
		return if insert == "" then f else replace(f, c, c, insert)
	elseif name == "enter" or name == "return" then
		if key.ctrl or key.meta or key.alt then
			return nil
		end
		-- The new line keeps the current line's indentation.
		local indent = string.match(string.sub(text, lineStart(text, c) + 1, c), "^[ \t]*") or ""
		return replace(f, c, c, "\n" .. indent)
	elseif name == "backspace" then
		local from = if key.meta then lineStart(text, c) elseif word then wordLeft(text, c) else prevChar(text, c)
		return replace(f, from, c, "")
	elseif name == "delete" then
		local to = if key.meta then lineEnd(text, c) elseif word then wordRight(text, c) else nextChar(text, c)
		return replace(f, c, to, "")
	elseif name == "left" then
		return moved(f, if key.meta then lineStart(text, c) elseif word then wordLeft(text, c) else prevChar(text, c))
	elseif name == "right" then
		return moved(f, if key.meta then lineEnd(text, c) elseif word then wordRight(text, c) else nextChar(text, c))
	elseif name == "up" then
		return if key.meta then moved(f, 0) else vertical(f, false)
	elseif name == "down" then
		return if key.meta then moved(f, #text) else vertical(f, true)
	elseif name == "home" then
		return moved(f, if key.ctrl or key.meta then 0 else lineStart(text, c))
	elseif name == "end" then
		return moved(f, if key.ctrl or key.meta then #text else lineEnd(text, c))
	elseif (key.ctrl or key.meta) and name == "z" then
		return M.undo(f) or f
	elseif key.ctrl and not key.meta and not key.alt then
		if name == "a" then
			return moved(f, lineStart(text, c))
		elseif name == "e" then
			return moved(f, lineEnd(text, c))
		elseif name == "u" then
			return replace(f, lineStart(text, c), c, "")
		elseif name == "k" then
			return replace(f, c, lineEnd(text, c), "")
		elseif name == "w" then
			return replace(f, wordLeft(text, c), c, "")
		end
		return nil
	end
	local ch = M.printable(key)
	return if ch then typeText(f, ch) else nil
end

-- Steps back one change; nil when there is none.
function M.undo(f: Field): Field?
	local n = #f.undo
	if n == 0 then
		return nil
	end
	local snap = f.undo[n]
	local undo = table.clone(f.undo)
	undo[n] = nil
	return { text = snap.text, cursor = snap.cursor, undo = undo, typing = false }
end

return M
