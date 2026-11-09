--!strict
-- Query history and saved queries, kept in the plugin data directory as
-- JSON Lines: `console/history.jsonl` and `console/saved.jsonl`, one JSON
-- object per line, oldest first.
--
-- Why JSONL and not SQLite: consoles are host blocks and SQLite is only
-- reachable from the window half (`cx.db`), so every history write would
-- need a host -> window round trip; the files are small (capped below),
-- read whole and rewritten whole with `tern.fs`, readable with any tool,
-- and a line cut short by a crash costs that one entry, not the file
-- (unreadable lines are skipped).

local M = {}

M.VERSION = 1
M.DIR = "console"
M.HISTORY_FILE = "history.jsonl"
M.SAVED_FILE = "saved.jsonl"
M.MAX_HISTORY = 500
M.MAX_SAVED = 500
-- Longer queries are run but not kept.
M.MAX_SQL_BYTES = 65536
M.MAX_NAME = 80
-- The files are read at most this large; a bigger one is a stranger's.
M.MAX_FILE_BYTES = 4 * 1024 * 1024

export type HistoryEntry = { sql: string, connection: string?, at: number }
export type Saved = { name: string, sql: string, at: number }

local function lines(text: string?, decode: (string) -> any): { any }
	local out: { any } = {}
	for line in string.gmatch(text or "", "[^\n]+") do
		local ok, doc = pcall(decode, line)
		if ok and type(doc) == "table" then
			table.insert(out, doc)
		end
	end
	return out
end

local function validSql(sql: any): boolean
	return type(sql) == "string" and string.find(sql, "%S") ~= nil and #sql <= M.MAX_SQL_BYTES
end

function M.parseHistory(text: string?, decode: (string) -> any): { HistoryEntry }
	local out: { HistoryEntry } = {}
	for _, doc in lines(text, decode) do
		if validSql(doc.sql) then
			table.insert(out, {
				sql = doc.sql,
				connection = if type(doc.connection) == "string" then doc.connection else nil,
				at = if type(doc.at) == "number" then doc.at else 0,
			})
		end
	end
	while #out > M.MAX_HISTORY do
		table.remove(out, 1)
	end
	return out
end

-- A saved query's name: trimmed, one line, 1..MAX_NAME characters; nil
-- and why when it cannot be one.
function M.name(raw: string): (string?, string?)
	local n = string.match(raw, "^%s*(.-)%s*$") :: string
	if n == "" then
		return nil, "give the query a name"
	elseif string.find(n, "%c") then
		return nil, "a name is one line without control characters"
	elseif (utf8.len(n) or #n) > M.MAX_NAME then
		return nil, string.format("a name has at most %d characters", M.MAX_NAME)
	end
	return n, nil
end

function M.parseSaved(text: string?, decode: (string) -> any): { Saved }
	local out: { Saved } = {}
	local seen: { [string]: number } = {}
	for _, doc in lines(text, decode) do
		local name = if type(doc.name) == "string" then M.name(doc.name) else nil
		if name and validSql(doc.sql) then
			local entry = { name = name, sql = doc.sql, at = if type(doc.at) == "number" then doc.at else 0 }
			-- A later line with the same name wins (an edited copy).
			if seen[name] then
				out[seen[name]] = entry
			else
				table.insert(out, entry)
				seen[name] = #out
			end
		end
	end
	return out
end

local function encodeAll(list: { any }, encode: (any) -> string): string
	local out: { string } = table.create(#list)
	for i, e in list do
		out[i] = encode(e)
	end
	return if #out == 0 then "" else table.concat(out, "\n") .. "\n"
end

function M.encodeHistory(list: { HistoryEntry }, encode: (any) -> string): string
	local docs: { any } = table.create(#list)
	for i, e in list do
		docs[i] = { v = M.VERSION, sql = e.sql, connection = e.connection, at = e.at }
	end
	return encodeAll(docs, encode)
end

function M.encodeSaved(list: { Saved }, encode: (any) -> string): string
	local docs: { any } = table.create(#list)
	for i, e in list do
		docs[i] = { v = M.VERSION, name = e.name, sql = e.sql, at = e.at }
	end
	return encodeAll(docs, encode)
end

-- `list` with `entry` last: an earlier identical query moves to the end
-- (recalling it once finds it), the oldest go past MAX_HISTORY; `list`
-- itself when the query is too long to keep.
function M.addHistory(list: { HistoryEntry }, entry: HistoryEntry): { HistoryEntry }
	if not validSql(entry.sql) then
		return list
	end
	local out: { HistoryEntry } = {}
	for _, e in list do
		if e.sql ~= entry.sql then
			table.insert(out, e)
		end
	end
	table.insert(out, entry)
	while #out > M.MAX_HISTORY do
		table.remove(out, 1)
	end
	return out
end

-- `list` with query `name` set to `sql` (replacing one of that name in
-- place); nil and why when it cannot be saved.
function M.save(list: { Saved }, rawName: string, sql: string, at: number): ({ Saved }?, string?)
	local name, why = M.name(rawName)
	if name == nil then
		return nil, why
	end
	if not validSql(sql) then
		return nil,
			if string.find(sql, "%S")
				then string.format("queries over %d KB are not saved", M.MAX_SQL_BYTES // 1024)
				else "the query is empty"
	end
	local out = table.clone(list)
	for i, e in out do
		if e.name == name then
			out[i] = { name = name, sql = sql, at = at }
			return out, nil
		end
	end
	if #out >= M.MAX_SAVED then
		return nil, string.format("at most %d queries are saved; delete some first", M.MAX_SAVED)
	end
	table.insert(out, { name = name, sql = sql, at = at })
	return out, nil
end

function M.remove(list: { Saved }, name: string): { Saved }
	local out: { Saved } = {}
	for _, e in list do
		if e.name ~= name then
			table.insert(out, e)
		end
	end
	return out
end

function M.find(list: { Saved }, name: string): Saved?
	for _, e in list do
		if e.name == name then
			return e
		end
	end
	return nil
end

return M
