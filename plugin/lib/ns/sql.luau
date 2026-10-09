--!strict
-- SuiteQL text handling: a lexer that separates code from comments, string
-- literals and quoted identifiers, the read-only guard every query passes
-- before it is sent, and client-side parameter binding for REST SuiteQL
-- (whose request body has no parameter list).

local M = {}

export type SegmentKind = "code" | "comment" | "string" | "ident"
export type Segment = { kind: SegmentKind, text: string }

-- Splits `sql` into segments; nil and a reason when a comment, string or
-- quoted identifier is not terminated (NetSuite's parser and ours could then
-- disagree about what is code).
function M.segments(sql: string): ({ Segment }?, string?)
	local out: { Segment } = {}
	local i, n = 1, #sql
	local codeStart = 1
	local function flush(upto: number)
		if upto >= codeStart then
			table.insert(out, { kind = "code", text = string.sub(sql, codeStart, upto) })
		end
	end
	while i <= n do
		local c = string.sub(sql, i, i)
		local two = string.sub(sql, i, i + 1)
		if two == "--" then
			flush(i - 1)
			local e = string.find(sql, "\n", i, true) or n
			table.insert(out, { kind = "comment", text = string.sub(sql, i, e) })
			i = e + 1
			codeStart = i
		elseif two == "/*" then
			flush(i - 1)
			local _, e = string.find(sql, "*/", i + 2, true)
			if e == nil then
				return nil, "unterminated /* comment"
			end
			table.insert(out, { kind = "comment", text = string.sub(sql, i, e) })
			i = e + 1
			codeStart = i
		elseif c == "'" or c == '"' then
			flush(i - 1)
			local j = i + 1
			while true do
				local q = string.find(sql, c, j, true)
				if q == nil then
					return nil, if c == "'" then "unterminated string literal" else "unterminated quoted identifier"
				end
				if string.sub(sql, q + 1, q + 1) == c then
					j = q + 2
				else
					table.insert(
						out,
						{ kind = if c == "'" then "string" else "ident", text = string.sub(sql, i, q) } :: Segment
					)
					i = q + 1
					break
				end
			end
			codeStart = i
		else
			i += 1
		end
	end
	flush(n)
	return out, nil
end

-- Statements and clauses that change data, schema, sessions or transactions,
-- or call procedures. Matched as whole words outside comments and literals;
-- SELECT ... FOR UPDATE takes row locks, so UPDATE alone refuses it too.
local FORBIDDEN: { [string]: boolean } = {}
for _, w in
	{
		"INSERT",
		"UPDATE",
		"DELETE",
		"MERGE",
		"UPSERT",
		"CALL",
		"EXEC",
		"EXECUTE",
		"CREATE",
		"DROP",
		"ALTER",
		"TRUNCATE",
		"RENAME",
		"GRANT",
		"REVOKE",
		"COMMIT",
		"ROLLBACK",
		"SAVEPOINT",
		"LOCK",
		"BEGIN",
		"DECLARE",
		"INTO",
	}
do
	FORBIDDEN[w] = true
end

-- Whether `sql` is a single SELECT or WITH query; otherwise false and the
-- reason shown to the user. Comments are ignored, literals are opaque.
function M.readOnly(sql: string): (boolean, string?)
	local segs, err = M.segments(sql)
	if segs == nil then
		return false, err
	end
	local parts: { string } = {}
	for _, s in segs do
		if s.kind == "code" then
			table.insert(parts, s.text)
		elseif s.kind == "comment" then
			table.insert(parts, " ")
		else
			table.insert(parts, " x ")
		end
	end
	local code = table.concat(parts)
	code = string.gsub(code, "^%s+", "")
	code = string.gsub(code, "%s*;%s*$", "")
	if string.find(code, ";", 1, true) then
		return false, "only a single statement may be sent (found ';' between statements)"
	end
	local first = string.match(code, "^%(*%s*([%a_]+)")
	if first == nil then
		return false, "the query is empty"
	end
	first = string.upper(first)
	if first ~= "SELECT" and first ~= "WITH" then
		return false, string.format("only SELECT or WITH queries are allowed, not %s", first)
	end
	for word in string.gmatch(code, "[%a_][%w_$#]*") do
		local w = string.upper(word)
		if FORBIDDEN[w] then
			return false, string.format("%s is not allowed in a read-only query", w)
		end
	end
	return true, nil
end

export type Param = string | number | boolean

local function literal(v: any): (string?, string?)
	local tv = type(v)
	if tv == "number" then
		if v ~= v or math.abs(v) == math.huge then
			return nil, "a parameter is not a finite number"
		end
		if v == math.floor(v) and math.abs(v) < 2 ^ 53 then
			return string.format("%d", v), nil
		end
		return string.format("%.17g", v), nil
	elseif tv == "string" then
		return "'" .. string.gsub(v, "'", "''") .. "'", nil
	elseif tv == "boolean" then
		-- NetSuite stores checkboxes as 'T' / 'F'.
		return if v then "'T'" else "'F'", nil
	end
	return nil, "parameters must be strings, numbers or booleans"
end

-- Substitutes each `?` placeholder outside comments and literals with a SQL
-- literal of the matching parameter. REST SuiteQL takes only `q`, so this is
-- the one way to use parameters there; strings are quoted with '' escaping.
function M.bind(sql: string, params: { any }): (string?, string?)
	local segs, err = M.segments(sql)
	if segs == nil then
		return nil, err
	end
	local used = 0
	local parts: { string } = {}
	for _, s in segs do
		if s.kind ~= "code" then
			table.insert(parts, s.text)
			continue
		end
		local failure: string? = nil
		local text = string.gsub(s.text, "%?", function(): string
			used += 1
			if used > #params then
				failure = failure or string.format("the query has more placeholders than the %d parameter(s)", #params)
				return "?"
			end
			local lit, e = literal(params[used])
			if lit == nil then
				failure = failure or string.format("parameter %d: %s", used, e or "invalid")
				return "?"
			end
			return lit
		end)
		if failure then
			return nil, failure
		end
		table.insert(parts, text)
	end
	if used ~= #params then
		return nil, string.format("the query has %d placeholder(s) but %d parameter(s) were given", used, #params)
	end
	return table.concat(parts), nil
end

-- Whether `name` is a plain column identifier (safe to splice into SQL).
function M.isIdentifier(name: string): boolean
	return string.find(name, "^[%a_][%w_]*$") ~= nil and #name <= 128
end

return M
