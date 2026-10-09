--!strict
-- Helpers for queries over many ids or many rows. NetSuite answers an IN
-- list above 1000 items with an opaque HTTP 500, and
-- REST SuiteQL cannot page past offset 100000; keyset paging on the internal
-- id has neither limit.

local Sql = require("./sql")

local M = {}

M.MAX_IN = 1000
M.MAX_PAGE = 1000

-- `values` split into consecutive chunks of at most `size` (default and
-- maximum 1000) items.
function M.chunks<T>(values: { T }, size: number?): { { T } }
	local n = math.clamp(math.floor(size or M.MAX_IN), 1, M.MAX_IN)
	local out: { { T } } = {}
	for i = 1, #values, n do
		table.insert(out, table.move(values, i, math.min(i + n - 1, #values), 1, {}))
	end
	return out
end

export type Clause = { sql: string, params: { any } }

-- One `<column> IN (?, ...)` clause with its parameters per chunk of
-- `values`. `column` is SQL written by the caller (it may be an expression
-- such as `LOWER(email)`), never user input.
function M.inList(column: string, values: { any }, size: number?): { Clause }
	local out: { Clause } = {}
	for _, chunk in M.chunks(values, size) do
		table.insert(out, {
			sql = string.format("%s IN (%s)", column, table.concat(table.create(#chunk, "?"), ", ")),
			params = chunk,
		})
	end
	return out
end

export type Keyset = {
	-- The query to page; it must select `id`.
	sql: string,
	-- The unique, numeric, ascending key column (normally `id`).
	id: string,
	-- The last key of the previous page; nil for the first page.
	after: number?,
	size: number?,
}

-- One keyset page of `k.sql`: rows with `id` above `after`, ascending, at
-- most `size` (default and maximum 1000). Returns the SQL and parameters,
-- or nil and a reason.
function M.keyset(k: Keyset): (Clause?, string?)
	if not Sql.isIdentifier(k.id) then
		return nil, string.format("%q is not a column name", k.id)
	end
	local size = math.clamp(math.floor(k.size or M.MAX_PAGE), 1, M.MAX_PAGE)
	local inner = string.gsub(string.gsub(k.sql, "%s*;%s*$", ""), "^%s+", "")
	local where = if k.after == nil then "" else string.format(" WHERE %s > ?", k.id)
	return {
		sql = string.format(
			"SELECT * FROM (SELECT * FROM (%s)%s ORDER BY %s) WHERE ROWNUM <= %d",
			inner,
			where,
			k.id,
			size
		),
		params = if k.after == nil then {} else { k.after },
	},
		nil
end

-- The `after` value for the page following `rows`, or nil when `rows` was
-- the last page (fewer rows than `size`). SuiteQL returns column names in
-- lower case.
function M.nextAfter(rows: { any }, id: string, size: number?): number?
	local n = math.clamp(math.floor(size or M.MAX_PAGE), 1, M.MAX_PAGE)
	if #rows < n then
		return nil
	end
	local last = rows[#rows]
	local v = if type(last) == "table" then last[string.lower(id)] else nil
	return tonumber(v)
end

return M
