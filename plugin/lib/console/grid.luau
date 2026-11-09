--!strict
-- The console's results grid without drawing: how a value shows, the row
-- order for a sort and a filter, column widths, the windows of rows and
-- columns that are drawn, and which cells name a record to inspect.
--
-- Values are shown as NetSuite sent them: REST SuiteQL answers with
-- strings only, RESTlets with JSON types. A member a row lacks is SQL
-- NULL (JSON decoding drops null members); an explicit null (inside a
-- nested value) is the injected `null` sentinel.

local M = {}

export type Kind = "string" | "number" | "boolean" | "null" | "object"

M.MAX_WIDTH = 40
M.MIN_WIDTH = 3
-- Rows measured for column widths.
M.WIDTH_SAMPLE = 1000
M.GAP = 2
M.MAX_RENDER_ROWS = 200
M.SCROLLOFF = 2

local function isNull(v: any, null: any): boolean
	return v == nil or (null ~= nil and v == null)
end

function M.kind(v: any, null: any): Kind
	if isNull(v, null) then
		return "null"
	end
	local tv = type(v)
	if tv == "string" then
		return "string"
	elseif tv == "number" then
		return "number"
	elseif tv == "boolean" then
		return "boolean"
	end
	return "object"
end

function M.number(n: number): string
	if n ~= n then
		return "NaN"
	elseif n == math.huge then
		return "Infinity"
	elseif n == -math.huge then
		return "-Infinity"
	elseif n == math.floor(n) and math.abs(n) < 2 ^ 53 then
		return string.format("%d", n)
	end
	return tostring(n)
end

local function quoteString(s: string): string
	local out = string.gsub(s, '[%c"\\]', function(c: string): string
		if c == '"' then
			return '\\"'
		elseif c == "\\" then
			return "\\\\"
		elseif c == "\n" then
			return "\\n"
		elseif c == "\r" then
			return "\\r"
		elseif c == "\t" then
			return "\\t"
		end
		return string.format("\\u%04x", string.byte(c))
	end)
	return '"' .. out .. '"'
end

M.quote = quoteString

local function isArray(t: { [any]: any }): boolean
	local n = 0
	for k in t do
		if type(k) ~= "number" then
			return false
		end
		n += 1
	end
	return n == #t
end

-- Compact JSON of a nested value (object members sorted by name).
function M.json(v: any, null: any): string
	if isNull(v, null) then
		return "null"
	end
	local tv = type(v)
	if tv == "string" then
		return quoteString(v)
	elseif tv == "number" then
		return M.number(v)
	elseif tv == "boolean" then
		return if v then "true" else "false"
	elseif tv ~= "table" then
		return quoteString(tostring(v))
	end
	local parts: { string } = {}
	if #v > 0 and isArray(v) then
		for _, item in ipairs(v) do
			table.insert(parts, M.json(item, null))
		end
		return "[" .. table.concat(parts, ",") .. "]"
	end
	local keys: { string } = {}
	for k in v do
		table.insert(keys, tostring(k))
	end
	if #keys == 0 then
		return "{}"
	end
	table.sort(keys)
	for _, k in keys do
		table.insert(parts, quoteString(k) .. ":" .. M.json(v[k], null))
	end
	return "{" .. table.concat(parts, ",") .. "}"
end

-- The full text of a value (the inspector, exports): strings as sent,
-- numbers without a forced decimal point, nested values as JSON; nil for
-- NULL.
function M.text(v: any, null: any): string?
	local k = M.kind(v, null)
	if k == "null" then
		return nil
	elseif k == "string" then
		return v
	elseif k == "number" then
		return M.number(v)
	elseif k == "boolean" then
		return if v then "true" else "false"
	end
	return M.json(v, null)
end

-- One line of a value for a grid cell: control characters become visible
-- marks so a row stays one line.
function M.cell(v: any, null: any): string
	local t = M.text(v, null)
	if t == nil then
		return "null"
	end
	if string.find(t, "%c") then
		t = string.gsub(t, "\r?\n", "⏎")
		t = string.gsub(t, "%c", " ")
	end
	return t
end

function M.width(text: string): number
	return utf8.len(text) or #text
end

-- `text` cut or padded to `width` characters; `right` pads on the left.
function M.fit(text: string, width: number, right: boolean?): string
	local n = M.width(text)
	if n > width then
		if width <= 1 then
			return string.sub("…", 1, if width == 1 then #"…" else 0)
		end
		local cut = utf8.offset(text, width) or width
		return string.sub(text, 1, cut - 1) .. "…"
	end
	local pad = string.rep(" ", width - n)
	return if right then pad .. text else text .. pad
end

-- Display width of each column: its header or its widest cell among the
-- first WIDTH_SAMPLE rows, within MIN_WIDTH..MAX_WIDTH.
function M.widths(columns: { string }, rows: { any }, null: any): { number }
	local out: { number } = table.create(#columns)
	for j, c in columns do
		out[j] = M.width(c)
	end
	for i = 1, math.min(#rows, M.WIDTH_SAMPLE) do
		local row = rows[i]
		if type(row) == "table" then
			for j, c in columns do
				local w = M.width(M.cell(row[c], null))
				if w > out[j] then
					out[j] = w
				end
			end
		end
	end
	for j, w in out do
		out[j] = math.clamp(w, M.MIN_WIDTH, M.MAX_WIDTH)
	end
	return out
end

-- Sorting ---------------------------------------------------------------------

export type Dir = "asc" | "desc"

-- Sort key: numbers (and strings that are numbers: REST sends numbers as
-- strings) compare as numbers before text; NULLs sort last either way.
type SortKey = { rank: number, n: number, s: string }

local function sortKey(v: any, null: any): SortKey
	local k = M.kind(v, null)
	if k == "null" then
		return { rank = 3, n = 0, s = "" }
	elseif k == "number" then
		return { rank = 1, n = v, s = "" }
	elseif k == "boolean" then
		return { rank = 2, n = 0, s = if v then "true" else "false" }
	elseif k == "string" then
		if string.find(v, "^%s*[-+]?%d+%.?%d*[eE]?[-+]?%d*%s*$") or string.find(v, "^%s*[-+]?%.%d+%s*$") then
			local n = tonumber(v)
			if n then
				return { rank = 1, n = n, s = "" }
			end
		end
		return { rank = 2, n = 0, s = string.lower(v) }
	end
	return { rank = 2, n = 0, s = string.lower(M.json(v, null)) }
end

-- Indices of `rows` in display order: sorted by column `col` (stable; nil
-- keeps NetSuite's order) and kept when `keep(i)` is true.
function M.order(rows: { any }, col: string?, dir: Dir, keep: ((number) -> boolean)?, null: any): { number }
	local idx: { number } = {}
	for i = 1, #rows do
		if keep == nil or keep(i) then
			table.insert(idx, i)
		end
	end
	if col == nil then
		return idx
	end
	local keys: { [number]: SortKey } = {}
	for _, i in idx do
		local row = rows[i]
		keys[i] = sortKey(if type(row) == "table" then row[col] else nil, null)
	end
	local desc = dir == "desc"
	table.sort(idx, function(a: number, b: number): boolean
		local ka, kb = keys[a], keys[b]
		if ka.rank ~= kb.rank then
			-- NULLs last in both directions.
			if ka.rank == 3 or kb.rank == 3 then
				return kb.rank == 3
			end
			if desc then
				return ka.rank > kb.rank
			end
			return ka.rank < kb.rank
		end
		if ka.rank == 1 and ka.n ~= kb.n then
			if desc then
				return ka.n > kb.n
			end
			return ka.n < kb.n
		elseif ka.rank == 2 and ka.s ~= kb.s then
			if desc then
				return ka.s > kb.s
			end
			return ka.s < kb.s
		end
		return a < b
	end)
	return idx
end

-- Filtering -------------------------------------------------------------------

-- Lower-cased text of every cell of `row`, tab-separated, for filtering.
function M.haystack(row: any, columns: { string }, null: any): string
	if type(row) ~= "table" then
		return ""
	end
	local parts: { string } = table.create(#columns)
	for j, c in columns do
		parts[j] = M.cell(row[c], null)
	end
	return string.lower(table.concat(parts, "\t"))
end

-- Filter words: every word must appear in some cell (case-insensitive).
function M.words(filter: string): { string }
	local out: { string } = {}
	for w in string.gmatch(string.lower(filter), "%S+") do
		table.insert(out, w)
	end
	return out
end

function M.matches(hay: string, words: { string }): boolean
	for _, w in words do
		if not string.find(hay, w, 1, true) then
			return false
		end
	end
	return true
end

-- Windows ---------------------------------------------------------------------

-- Rows `[first, last]` of a `size`-row window over `total` rows keeping
-- `selected` SCROLLOFF rows from either edge, moving `offset` minimally.
function M.window(selected: number, total: number, offset: number, size: number): (number, number)
	if total <= size then
		return 1, total
	end
	local so = math.min(M.SCROLLOFF, (size - 1) // 2)
	local sel = math.clamp(selected, 1, total)
	local first = offset
	if sel < first + so then
		first = sel - so
	elseif sel > first + size - 1 - so then
		first = sel - size + 1 + so
	end
	first = math.clamp(first, 1, total - size + 1)
	return first, first + size - 1
end

-- Columns `[first, last]` that fit `room` characters (with GAP between
-- them), starting at `first` moved minimally so column `cur` shows. The
-- last one may be cut.
function M.columnWindow(widths: { number }, cur: number, first: number, room: number): (number, number)
	local n = #widths
	if n == 0 then
		return 1, 0
	end
	cur = math.clamp(cur, 1, n)
	first = math.clamp(first, 1, cur)
	-- Move right until `cur` fits whole.
	while first < cur do
		local used = 0
		for j = first, cur do
			used += widths[j] + (if j > first then M.GAP else 0)
		end
		if used <= room then
			break
		end
		first += 1
	end
	local used, last = 0, first - 1
	for j = first, n do
		local need = widths[j] + (if j > first then M.GAP else 0)
		if used + need > room and j > first then
			-- A part of the next column when at least a few characters fit.
			if room - used - M.GAP >= M.MIN_WIDTH then
				last = j
			end
			break
		end
		used += need
		last = j
	end
	return first, last
end

-- Record ids --------------------------------------------------------------------

-- Columns named *id whose values are text, not internal ids.
local TEXT_IDS: { [string]: boolean } = {
	tranid = true,
	entityid = true,
	externalid = true,
	scriptid = true,
	itemid = true,
	acctnumber = true,
	otherrefnum = true,
	transactionnumber = true,
}

-- Whether column `name` may hold internal ids (`id` or `<field>id`).
function M.isIdColumn(name: string): boolean
	local n = string.lower(name)
	if TEXT_IDS[n] then
		return false
	end
	return n == "id" or (string.find(n, "id$") ~= nil and string.find(n, "^[%a_][%w_]*$") ~= nil)
end

-- The internal id in a cell (a positive integer, as text or a number), or
-- nil.
function M.internalId(v: any): string?
	local s: string? = nil
	if type(v) == "number" and v == math.floor(v) and v > 0 and v < 1e12 then
		s = string.format("%d", v)
	elseif type(v) == "string" then
		s = v
	end
	if s and string.find(s, "^[1-9]%d?%d?%d?%d?%d?%d?%d?%d?%d?%d?%d?$") then
		return s
	end
	return nil
end

export type IdCell = { column: string, id: string }

-- Cells of `row` that name a record: the `id` column first, then the
-- others in column order.
function M.idCells(row: any, columns: { string }): { IdCell }
	local out: { IdCell } = {}
	if type(row) ~= "table" then
		return out
	end
	for _, c in columns do
		if M.isIdColumn(c) then
			local id = M.internalId(row[c])
			if id then
				local cell = { column = c, id = id }
				if string.lower(c) == "id" then
					table.insert(out, 1, cell)
				else
					table.insert(out, cell)
				end
			end
		end
	end
	return out
end

return M
