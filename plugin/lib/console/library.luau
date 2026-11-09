--!strict
-- The queries the console can pick from: saved queries (plugin data, see
-- store.luau) and `.sql` files in the read-only folders of config
-- `console.saved_dirs`. A folder path starting with `~/` is under the home
-- directory, an absolute one is used as is, a relative one is resolved
-- against the repository root of the pane the console was opened from
-- (its working directory when that is not in a repository). Files are
-- titled by their leading comment (sqltext.title), else by name; the
-- console never writes to these folders.

local Context = require("../account/context")
local Sqltext = require("./sqltext")
local Store = require("./store")

local M = {}

M.MAX_FILES = 500
-- A larger .sql file is listed but not loaded.
M.MAX_SQL_FILE_BYTES = 262144
-- Bytes read to find a file's title.
M.TITLE_BYTES = 4096

-- File access the adapter provides: nil when the path cannot be listed or
-- read (missing, not a folder, larger than `max`).
export type Fs = {
	list: (dir: string) -> { string }?,
	read: (path: string, max: number) -> string?,
}

export type Folder = { configured: string, path: string }

export type FileEntry = {
	path: string,
	name: string,
	title: string?,
	-- The configured folder it was found in.
	folder: string,
}

export type Item = {
	kind: "saved" | "file",
	-- What the picker shows and filters on.
	label: string,
	detail: string,
	name: string?,
	path: string?,
	sql: string?,
}

function M.normalize(path: string): string
	local parts: { string } = {}
	for part in string.gmatch(path, "[^/]+") do
		if part == ".." then
			if #parts > 0 then
				table.remove(parts)
			end
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	return "/" .. table.concat(parts, "/")
end

-- The absolute folder `configured` names, or nil and why.
function M.resolve(configured: string, base: string?, home: string?): (string?, string?)
	if string.find(configured, "%c") then
		return nil, string.format("%q has a control character", configured)
	end
	if configured == "~" or string.sub(configured, 1, 2) == "~/" then
		if home == nil or string.sub(home, 1, 1) ~= "/" then
			return nil, string.format("%q needs HOME", configured)
		end
		return M.normalize(home .. "/" .. string.sub(configured, 3)), nil
	elseif string.sub(configured, 1, 1) == "/" then
		return M.normalize(configured), nil
	elseif string.sub(configured, 1, 1) == "~" then
		return nil, string.format("%q: only ~/ (your home) is expanded", configured)
	end
	if base == nil or string.sub(base, 1, 1) ~= "/" then
		return nil,
			string.format("%q is relative, and the console has no repository or folder to resolve it in", configured)
	end
	return M.normalize(base .. "/" .. configured), nil
end

-- Folders of `dirs` in order (duplicates once), with problems for the
-- entries that name none.
function M.folders(dirs: { string }, base: string?, home: string?): ({ Folder }, { string })
	local out: { Folder } = {}
	local problems: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, d in dirs do
		local path, why = M.resolve(d, base, home)
		if path == nil then
			table.insert(problems, "console.saved_dirs: " .. (why or d))
		elseif not seen[path] then
			seen[path] = true
			table.insert(out, { configured = d, path = path })
		end
	end
	return out, problems
end

local function isSql(name: string): boolean
	return string.lower(string.sub(name, -4)) == ".sql" and #name > 4 and string.sub(name, 1, 1) ~= "."
end

-- The `.sql` files directly in each folder (sorted by name per folder, at
-- most MAX_FILES in all), titled by their leading comment.
function M.collect(fs: Fs, folders: { Folder }): ({ FileEntry }, { string })
	local out: { FileEntry } = {}
	local problems: { string } = {}
	for _, f in folders do
		local names = fs.list(f.path)
		if names == nil then
			table.insert(problems, string.format("console.saved_dirs: cannot list %s", f.path))
			continue
		end
		for _, name in names do
			if not isSql(name) then
				continue
			end
			if #out >= M.MAX_FILES then
				table.insert(problems, string.format("only the first %d .sql files are listed", M.MAX_FILES))
				return out, problems
			end
			local path = f.path .. "/" .. name
			local head = fs.read(path, M.MAX_SQL_FILE_BYTES)
			table.insert(out, {
				path = path,
				name = name,
				title = if head then Sqltext.title(string.sub(head, 1, M.TITLE_BYTES)) else nil,
				folder = f.configured,
			})
		end
	end
	return out, problems
end

-- The .sql files of config `dirs` for a console opened in `cwd` (relative
-- folders resolve in its repository, else in `cwd` itself), and problems.
function M.gather(
	fs: Fs,
	exists: (string) -> boolean,
	dirs: { string },
	cwd: string?,
	home: string?
): ({ FileEntry }, { string })
	local base = if cwd then (Context.repoRoot(cwd, exists) or cwd) else nil
	local folders, problems = M.folders(dirs, base, home)
	local files, more = M.collect(fs, folders)
	for _, p in more do
		table.insert(problems, p)
	end
	return files, problems
end

-- The first line of code (comments name the query already).
local function firstLine(sql: string): string
	for line in string.gmatch(sql, "[^\n]+") do
		local l = string.match(line, "^%s*(.-)%s*$") :: string
		if l ~= "" and string.sub(l, 1, 2) ~= "--" then
			return if #l > 60 then string.sub(l, 1, (utf8.offset(l, 60) or 60) - 1) .. "…" else l
		end
	end
	return ""
end

-- Picker entries: saved queries (newest first), then files in folder order.
function M.items(saved: { Store.Saved }, files: { FileEntry }): { Item }
	local out: { Item } = {}
	local list = table.clone(saved)
	table.sort(list, function(a: Store.Saved, b: Store.Saved): boolean
		if a.at ~= b.at then
			return a.at > b.at
		end
		return a.name < b.name
	end)
	for _, s in list do
		table.insert(out, { kind = "saved", label = s.name, detail = firstLine(s.sql), name = s.name, sql = s.sql })
	end
	for _, f in files do
		table.insert(out, {
			kind = "file",
			label = f.title or f.name,
			detail = f.folder .. "/" .. f.name,
			path = f.path,
		})
	end
	return out
end

-- Items whose label or detail holds every word of `text` (any case).
function M.filter(items: { Item }, text: string): { Item }
	local words: { string } = {}
	for w in string.gmatch(string.lower(text), "%S+") do
		table.insert(words, w)
	end
	if #words == 0 then
		return items
	end
	local out: { Item } = {}
	for _, it in items do
		local hay = string.lower(it.label .. "\t" .. it.detail)
		local ok = true
		for _, w in words do
			if not string.find(hay, w, 1, true) then
				ok = false
				break
			end
		end
		if ok then
			table.insert(out, it)
		end
	end
	return out
end

return M
