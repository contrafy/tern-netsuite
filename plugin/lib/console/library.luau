--!strict
-- The queries the console can pick from: saved queries (plugin data, see
-- store.luau) and `.sql` files in the read-only folders of config
-- `console.saved_dirs`. A folder path starting with `~/` is under the home
-- directory, an absolute one is used as is, a relative one is resolved
-- against the repository root of the pane the console was opened from
-- (its working directory when that is not in a repository). Folders are
-- read recursively with `find -H`: a configured folder may itself be a
-- symlink, symlinks below it (folders and files) are not followed, so the
-- walk never leaves the folder or loops; hidden folders and node_modules
-- (and so .git) are skipped. At most MAX_FILES files are listed in all.
-- Files are titled by their leading comment (sqltext.title), else by name,
-- and located by their path relative to the configured folder; the console
-- never writes to these folders.

local Context = require("../account/context")
local Sqltext = require("./sqltext")
local Store = require("./store")

local M = {}

M.MAX_FILES = 500
-- A larger .sql file is listed but not loaded.
M.MAX_SQL_FILE_BYTES = 262144
-- Bytes read to find a file's title.
M.TITLE_BYTES = 4096
-- How long one folder's walk may take.
M.FIND_TIMEOUT_MS = 10000

-- What a finished process gave (tern.process.run's ProcessResult).
export type Run = { status: number, stdout: string, stderr: string, timed_out: boolean }

-- File and process access the adapter provides. `list` and `read` give nil
-- when the path cannot be listed or read (missing, not a folder, larger
-- than `max`); `run` calls `cb` once, also when the process cannot start.
export type Io = {
	list: (dir: string) -> { string }?,
	read: (path: string, max: number) -> string?,
	run: (argv: { string }, timeoutMs: number, cb: (result: Run) -> ()) -> (),
}

export type Folder = { configured: string, path: string }

export type FileEntry = {
	path: string,
	-- The file name.
	name: string,
	-- The path relative to the configured folder ("reports/open.sql").
	rel: string,
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
	-- A file's configured folder, set only when files come from more than
	-- one folder.
	folder: string?,
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

-- The argv listing the regular `.sql` files under `dir` (absolute, NUL
-- separated), skipping hidden folders and node_modules.
function M.findArgv(dir: string): { string }
	return {
		"find",
		"-H",
		dir,
		"-mindepth",
		"1",
		"(",
		"-type",
		"d",
		"(",
		"-name",
		".*",
		"-o",
		"-name",
		"node_modules",
		")",
		")",
		"-prune",
		"-o",
		"-type",
		"f",
		"-iname",
		"*.sql",
		"-print0",
	}
end

-- The paths relative to `dir` of the `.sql` files in find's output, sorted.
-- An unterminated last record (a killed find) is dropped.
function M.parseFound(dir: string, stdout: string): { string }
	local prefix = if dir == "/" then "/" else dir .. "/"
	local out: { string } = {}
	for record in string.gmatch(stdout, "([^%z]*)%z") do
		if string.sub(record, 1, #prefix) == prefix then
			local rel = string.sub(record, #prefix + 1)
			if rel ~= "" and isSql(string.match(rel, "[^/]*$") :: string) then
				table.insert(out, rel)
			end
		end
	end
	table.sort(out)
	return out
end

-- The entries for the relative paths found in each folder (`found[i]` for
-- `folders[i]`, nil when it could not be read): folder order, each folder
-- sorted, a file once, at most MAX_FILES in all, titled by their leading
-- comment. Also how many more files were found but not listed.
function M.entries(
	read: (path: string, max: number) -> string?,
	folders: { Folder },
	found: { [number]: { string }? }
): ({ FileEntry }, number)
	local out: { FileEntry } = {}
	local seen: { [string]: boolean } = {}
	local omitted = 0
	for i, f in folders do
		local rels: { string } = found[i] or {}
		for _, rel in rels do
			local path = (if f.path == "/" then "" else f.path) .. "/" .. rel
			if seen[path] then
				continue
			end
			seen[path] = true
			if #out >= M.MAX_FILES then
				omitted += 1
				continue
			end
			local head = read(path, M.MAX_SQL_FILE_BYTES)
			table.insert(out, {
				path = path,
				name = string.match(rel, "[^/]*$") :: string,
				rel = rel,
				title = if head then Sqltext.title(string.sub(head, 1, M.TITLE_BYTES)) else nil,
				folder = f.configured,
			})
		end
	end
	return out, omitted
end

-- The picker line for files found beyond MAX_FILES.
function M.omittedText(omitted: number): string
	return string.format(
		"%d more .sql file%s not listed: only the first %d are",
		omitted,
		if omitted == 1 then "" else "s",
		M.MAX_FILES
	)
end

-- An Io over `list`, `read` and a tern.process.run-like `spawn`, whose
-- callback gets the result then extra values (the window's fresh context),
-- handed to `answered` before the result is used.
function M.io(
	list: (dir: string) -> { string }?,
	read: (path: string, max: number) -> string?,
	spawn: (argv: { string }, opts: { timeout_ms: number }, cb: (r: Run, ...any) -> ()) -> (),
	answered: ((...any) -> ())?
): Io
	return {
		list = list,
		read = read,
		run = function(argv: { string }, timeoutMs: number, cb: (result: Run) -> ())
			local ok, err = pcall(function()
				spawn(argv, { timeout_ms = timeoutMs }, function(r: Run, ...: any)
					if answered then
						answered(...)
					end
					cb({ status = r.status, stdout = r.stdout, stderr = r.stderr, timed_out = r.timed_out })
				end)
			end)
			if not ok then
				cb({ status = -1, stdout = "", stderr = tostring(err), timed_out = false })
			end
		end,
	}
end

local function firstText(text: string): string?
	for line in string.gmatch(text, "[^\n]+") do
		local l = string.match(line, "^%s*(.-)%s*$") :: string
		if l ~= "" then
			return l
		end
	end
	return nil
end

-- Walks each folder of `folders` in turn, then calls `cb` with the files
-- (see entries), the problems and the number of files not listed.
function M.collect(io: Io, folders: { Folder }, cb: (files: { FileEntry }, problems: { string }, omitted: number) -> ())
	local problems: { string } = {}
	local found: { [number]: { string }? } = {}
	local i = 0
	local function step()
		i += 1
		local f = folders[i]
		if f == nil then
			local files, omitted = M.entries(io.read, folders, found)
			if omitted > 0 then
				table.insert(problems, M.omittedText(omitted))
			end
			cb(files, problems, omitted)
			return
		end
		if io.list(f.path) == nil then
			table.insert(problems, string.format("console.saved_dirs: cannot list %s", f.path))
			step()
			return
		end
		io.run(M.findArgv(f.path), M.FIND_TIMEOUT_MS, function(r: Run)
			if r.timed_out then
				table.insert(
					problems,
					string.format(
						"console.saved_dirs: reading %s took over %d s; listing what was found by then",
						f.path,
						M.FIND_TIMEOUT_MS // 1000
					)
				)
			elseif r.status ~= 0 then
				local why = firstText(r.stderr)
				table.insert(
					problems,
					string.format(
						"console.saved_dirs: could not read all of %s%s",
						f.path,
						if why then " (" .. why .. ")" else ""
					)
				)
			end
			found[i] = M.parseFound(f.path, r.stdout)
			step()
		end)
	end
	step()
end

-- The .sql files of config `dirs` for a console opened in `cwd` (relative
-- folders resolve in its repository, else in `cwd` itself); `cb` gets the
-- files, the problems and the number of files not listed.
function M.gather(
	io: Io,
	exists: (string) -> boolean,
	dirs: { string },
	cwd: string?,
	home: string?,
	cb: (files: { FileEntry }, problems: { string }, omitted: number) -> ()
)
	local base = if cwd then (Context.repoRoot(cwd, exists) or cwd) else nil
	local folders, problems = M.folders(dirs, base, home)
	M.collect(io, folders, function(files: { FileEntry }, more: { string }, omitted: number)
		for _, p in more do
			table.insert(problems, p)
		end
		cb(files, problems, omitted)
	end)
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
	local several = false
	for _, f in files do
		if f.folder ~= files[1].folder then
			several = true
			break
		end
	end
	for _, f in files do
		table.insert(out, {
			kind = "file",
			label = f.title or f.name,
			detail = f.rel,
			path = f.path,
			folder = if several then f.folder else nil,
		})
	end
	return out
end

-- The window's `cx:pick` choices for `items`, ending with a line that
-- runs nothing when `omitted` files were not listed.
function M.choices(items: { Item }, omitted: number): { { [string]: any } }
	local out: { { [string]: any } } = {}
	for _, it in items do
		table.insert(out, {
			label = it.label,
			detail = it.detail,
			group = if it.kind == "saved"
				then "Saved queries"
				elseif it.folder then "Query folder " .. it.folder
				else "Query folders",
			icon = if it.kind == "saved" then "database" else "code",
			name = it.name,
			path = it.path,
		})
	end
	if omitted > 0 then
		table.insert(out, {
			label = M.omittedText(omitted),
			detail = "narrow console.saved_dirs to list them",
			group = "Not listed",
			icon = "info",
		})
	end
	return out
end

-- Items whose label, detail or folder holds every word of `text` (any case).
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
		local hay = string.lower(it.label .. "\t" .. it.detail .. "\t" .. (it.folder or ""))
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
