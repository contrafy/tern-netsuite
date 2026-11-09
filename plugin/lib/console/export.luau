--!strict
-- Results as CSV, TSV and JSON text, in the grid's column order and row
-- order (its sort and filter), plus the names of exported files.
--
-- CSV follows RFC 4180 (fields with a comma, quote, line break or edge
-- space are quoted, quotes doubled; LF line ends). TSV fields escape
-- backslash, tab and line breaks as \\ \t \n \r so every row stays one
-- line. NULL is an empty field in both. JSON is an array of objects whose
-- members follow the column order, values as NetSuite sent them (REST
-- strings stay strings, RESTlet numbers stay numbers), NULL as null.

local Grid = require("./grid")

local M = {}

export type Format = "csv" | "tsv" | "json"

M.EXTENSIONS = table.freeze({ csv = "csv", tsv = "tsv", json = "json" }) :: { [string]: string }

local function csvField(v: any, null: any): string
	local t = Grid.text(v, null)
	if t == nil then
		return ""
	end
	if string.find(t, '[,"\r\n]') or string.find(t, "^%s") or string.find(t, "%s$") then
		return '"' .. string.gsub(t, '"', '""') .. '"'
	end
	return t
end

local TSV_ESCAPES: { [string]: string } = { ["\\"] = "\\\\", ["\t"] = "\\t", ["\n"] = "\\n", ["\r"] = "\\r" }

local function tsvField(v: any, null: any): string
	local t = Grid.text(v, null)
	if t == nil then
		return ""
	end
	return (string.gsub(t, "[\\\t\n\r]", TSV_ESCAPES))
end

local function delimited(
	columns: { string },
	rows: { any },
	order: { number },
	sep: string,
	field: (any, any) -> string,
	null: any
): string
	local lines: { string } = table.create(#order + 1)
	local head: { string } = table.create(#columns)
	for j, c in columns do
		head[j] = field(c, null)
	end
	table.insert(lines, table.concat(head, sep))
	local cells: { string } = table.create(#columns)
	for _, i in order do
		local row = rows[i]
		local r = if type(row) == "table" then row else {}
		for j, c in columns do
			cells[j] = field(r[c], null)
		end
		table.insert(lines, table.concat(cells, sep))
	end
	return table.concat(lines, "\n") .. "\n"
end

function M.csv(columns: { string }, rows: { any }, order: { number }, null: any): string
	return delimited(columns, rows, order, ",", csvField, null)
end

function M.tsv(columns: { string }, rows: { any }, order: { number }, null: any): string
	return delimited(columns, rows, order, "\t", tsvField, null)
end

-- One object per line, so large results stay readable in an editor.
function M.json(columns: { string }, rows: { any }, order: { number }, null: any): string
	local keys: { string } = table.create(#columns)
	for j, c in columns do
		keys[j] = Grid.quote(c) .. ":"
	end
	local lines: { string } = table.create(#order)
	local members: { string } = table.create(#columns)
	for _, i in order do
		local row = rows[i]
		local r = if type(row) == "table" then row else {}
		for j, c in columns do
			members[j] = keys[j] .. Grid.json(r[c], null)
		end
		table.insert(lines, "  {" .. table.concat(members, ",") .. "}")
	end
	if #lines == 0 then
		return "[]\n"
	end
	return "[\n" .. table.concat(lines, ",\n") .. "\n]\n"
end

function M.text(format: Format, columns: { string }, rows: { any }, order: { number }, null: any): string
	if format == "tsv" then
		return M.tsv(columns, rows, order, null)
	elseif format == "json" then
		return M.json(columns, rows, order, null)
	end
	return M.csv(columns, rows, order, null)
end

-- `suiteql-<connection>-<stamp>[-<n>].<ext>`; `stamp` is the host's
-- `os.date("%Y%m%d-%H%M%S")`, `n` counts names already taken.
function M.fileName(connection: string, stamp: string, format: Format, n: number?): string
	local conn = string.gsub(connection, "[^%w%._%-]", "_")
	local suffix = if n and n > 1 then "-" .. tostring(n) else ""
	return string.format("suiteql-%s-%s%s.%s", conn, stamp, suffix, M.EXTENSIONS[format])
end

-- A path that may be opened as a file: absolute, no control characters,
-- no `..` component.
function M.safePath(path: string): boolean
	return string.sub(path, 1, 1) == "/"
		and not string.find(path, "%c")
		and not string.find(path, "/%.%./")
		and not string.find(path, "/%.%.$")
end

return M
