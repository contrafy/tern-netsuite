--!strict
-- What the console reads from the SuiteQL text it runs. NetSuite answers
-- with one JSON object per row, and object members have no order once
-- decoded, so the column order comes from the query's select list; the
-- table of a single-table query names the record type of its `id` column
-- (for "Inspect record"); a leading comment titles a saved query.

local Sql = require("../ns/sql")

local M = {}

-- The query's code with comments blanked and literals replaced by a
-- placeholder of the same kind (quoted identifiers stay: they can be
-- aliases). nil when the text does not lex.
local function code(sql: string): string?
	local segs = Sql.segments(sql)
	if segs == nil then
		return nil
	end
	local parts: { string } = {}
	for _, s in segs do
		if s.kind == "code" or s.kind == "ident" then
			table.insert(parts, s.text)
		elseif s.kind == "comment" then
			table.insert(parts, " ")
		else
			table.insert(parts, "''")
		end
	end
	return table.concat(parts)
end

-- Byte ranges of the depth-0 words of `text`: { word (upper), from, to }.
type Word = { w: string, from: number, to: number }

local function topWords(text: string): { Word }
	local out: { Word } = {}
	local depth = 0
	local i, n = 1, #text
	while i <= n do
		local c = string.sub(text, i, i)
		if c == "(" then
			depth += 1
			i += 1
		elseif c == ")" then
			depth = math.max(depth - 1, 0)
			i += 1
		elseif c == '"' then
			local q = string.find(text, '"', i + 1, true) or n
			i = q + 1
		elseif c == "'" then
			i += 2
		else
			local from, to = string.find(text, "^[%a_][%w_$#]*", i)
			if from and to then
				if depth == 0 then
					table.insert(out, { w = string.upper(string.sub(text, from, to)), from = from, to = to })
				end
				i = to + 1
			else
				i += 1
			end
		end
	end
	return out
end

-- The main query's SELECT word index in `words` (after any WITH clauses,
-- whose bodies are parenthesized and so not at depth 0).
local function mainSelect(words: { Word }): number?
	for i, w in words do
		if w.w == "SELECT" then
			return i
		end
	end
	return nil
end

-- Splits `text` at depth-0 commas.
local function splitTop(text: string): { string }
	local out: { string } = {}
	local depth, start = 0, 1
	local i, n = 1, #text
	while i <= n do
		local c = string.sub(text, i, i)
		if c == "(" then
			depth += 1
		elseif c == ")" then
			depth = math.max(depth - 1, 0)
		elseif c == '"' then
			i = string.find(text, '"', i + 1, true) or n
		elseif c == "," and depth == 0 then
			table.insert(out, string.sub(text, start, i - 1))
			start = i + 1
		end
		i += 1
	end
	table.insert(out, string.sub(text, start))
	return out
end

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") :: string
end

local function unquote(name: string): string
	local inner = string.match(name, '^"(.*)"$')
	return if inner then (string.gsub(inner, '""', '"')) else name
end

local IDENT = "[%a_][%w_$#]*"
local QUOTED = '"[^"]*"'

-- The output name of one select item, lower-cased; nil for `*`, `t.*` and
-- expressions without an alias (NetSuite names those itself).
local function itemName(item: string): string?
	local s = trim(item)
	local alias = string.match(s, "%s[Aa][Ss]%s+(" .. IDENT .. ")$")
		or string.match(s, "%s[Aa][Ss]%s*(" .. QUOTED .. ")$")
	if alias then
		return string.lower(unquote(alias))
	end
	-- A plain column reference: `id`, `t.id`, `"Name"`.
	local last = string.match(s, '^[%w_$#%."]*%.(' .. IDENT .. ")$") or string.match(s, "^(" .. IDENT .. ")$")
	if last then
		return string.lower(last)
	end
	-- `expr alias` without AS: the last word after a closing parenthesis, a
	-- literal or an identifier.
	local before, bare = string.match(s, "^(.-[%w_%)'\"])%s+(" .. IDENT .. ")$")
	if before and bare then
		local upper = string.upper(bare)
		if upper ~= "END" and upper ~= "NULL" and not string.find(before, "[%+%-%*/|=<>]$") then
			return string.lower(bare)
		end
	end
	return nil
end

-- Output column names of the main query's select list, lower-cased, in
-- order; `complete` is false when some item has no name the query gives
-- (`*`, an expression without an alias) or the text could not be read.
function M.outputNames(sql: string): ({ string }, boolean)
	local text = code(sql)
	if text == nil then
		return {}, false
	end
	local words = topWords(text)
	local sel = mainSelect(words)
	if sel == nil then
		return {}, false
	end
	local startAt = words[sel].to + 1
	local stopAt = #text
	for i = sel + 1, #words do
		local w = words[i].w
		if w == "FROM" or w == "UNION" or w == "INTERSECT" or w == "EXCEPT" or w == "MINUS" then
			stopAt = words[i].from - 1
			break
		end
	end
	local list = string.sub(text, startAt, stopAt)
	list = string.gsub(list, "^%s*[Dd][Ii][Ss][Tt][Ii][Nn][Cc][Tt]%s", " ")
	list = string.gsub(list, "^%s*[Aa][Ll][Ll]%s", " ")
	list = string.gsub(list, "^%s*[Tt][Oo][Pp]%s+%d+%s", " ")
	local names: { string } = {}
	local complete = true
	for _, item in splitTop(list) do
		local name = itemName(item)
		if name then
			if not table.find(names, name) then
				table.insert(names, name)
			end
		else
			complete = false
		end
	end
	return names, complete
end

-- Column order of `rows` for `sql`: the select list's names first (in its
-- order, each only when some row has it or the select list names every
-- column), then any other member names, sorted. Matching ignores case:
-- REST SuiteQL lower-cases column names, RESTlets need not.
function M.columns(sql: string, rows: { any }): { string }
	local present: { [string]: string } = {}
	local extra: { string } = {}
	for _, row in rows do
		if type(row) == "table" then
			for k in row do
				if type(k) == "string" and present[string.lower(k)] == nil then
					present[string.lower(k)] = k
					table.insert(extra, k)
				end
			end
		end
	end
	local names, complete = M.outputNames(sql)
	local out: { string } = {}
	local used: { [string]: boolean } = {}
	for _, n in names do
		local actual = present[n]
		if actual then
			table.insert(out, actual)
			used[actual] = true
		elseif complete and #rows > 0 then
			-- Every row left it out: SQL NULL in each (JSON decoding drops
			-- null members).
			table.insert(out, n)
			used[n] = true
		end
	end
	local rest: { string } = {}
	for _, k in extra do
		if not used[k] then
			table.insert(rest, k)
		end
	end
	table.sort(rest)
	for _, k in rest do
		table.insert(out, k)
	end
	return out
end

-- The table of a query that reads exactly one table (no joins, no second
-- table, no set operator), lower-cased; nil otherwise.
function M.fromTable(sql: string): string?
	local text = code(sql)
	if text == nil then
		return nil
	end
	local words = topWords(text)
	local sel = mainSelect(words)
	if sel == nil then
		return nil
	end
	local from: number? = nil
	for i = sel + 1, #words do
		local w = words[i].w
		if w == "FROM" and from == nil then
			from = i
		elseif w == "JOIN" or w == "UNION" or w == "INTERSECT" or w == "EXCEPT" or w == "MINUS" then
			return nil
		end
	end
	if from == nil then
		return nil
	end
	local rest = string.sub(text, words[from].to + 1)
	local stop = #rest
	for _, kw in { "WHERE", "GROUP", "ORDER", "HAVING", "FETCH", "OFFSET", "CONNECT", "START" } do
		local p = string.find(string.upper(rest), "%f[%w_]" .. kw .. "%f[^%w_]")
		if p and p - 1 < stop then
			stop = p - 1
		end
	end
	local clause = trim(string.sub(rest, 1, stop))
	if string.find(clause, "[,(]") then
		return nil
	end
	local name = string.match(clause, "^(" .. IDENT .. ")%s+[Aa][Ss]%s+" .. IDENT .. "$")
		or string.match(clause, "^(" .. IDENT .. ")%s+" .. IDENT .. "$")
		or string.match(clause, "^(" .. IDENT .. ")$")
	return if name then string.lower(name) else nil
end

M.MAX_TITLE = 80

-- The title a query gives itself: its first non-blank line when that is a
-- comment (`-- Open orders`, `/* Open orders */`), else nil.
function M.title(sql: string): string?
	for line in string.gmatch(sql, "[^\n]+") do
		local l = trim(line)
		if l ~= "" then
			local text = string.match(l, "^%-%-+%s*(.-)$") or string.match(l, "^/%*+%s*(.-)%s*%**/?$")
			if text == nil then
				return nil
			end
			text = trim(text)
			if text == "" then
				continue
			end
			if #text > M.MAX_TITLE then
				text = string.sub(text, 1, (utf8.offset(text, M.MAX_TITLE) or M.MAX_TITLE) - 1) .. "…"
			end
			return text
		end
	end
	return nil
end

return M
