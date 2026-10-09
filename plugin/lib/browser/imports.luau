--!strict
-- `object:import` / `file:import` of one browser entry into the project:
-- the argv (CLI 3.2.0 non-interactive flags), the shell line shown in the
-- split pane, the local paths the import may overwrite and the git check
-- that refuses to overwrite uncommitted work. Imports read the account and
-- write only local files (object:import replaces a local object and, unless
-- --excludefiles, the script files it references).

local Diff = require("./diff")
local Project = require("../sdf/project")

type Project = Project.Project

export type Request = {
	kind: Diff.Kind,
	-- Absolute project root (the directory with suitecloud.config.js); the
	-- CLI takes the auth ID from its project.json.
	root: string,
	-- defaultProjectFolder, relative to root ("src").
	projectFolder: string,
	-- Objects.
	type: string?,
	scriptId: string?,
	-- Relative to the project folder, under /Objects ("/Objects/lists").
	destinationFolder: string?,
	excludeFiles: boolean,
	-- Files: File Cabinet path.
	path: string?,
}

export type DirtyState = "clean" | "dirty" | "nogit" | "error"
export type Dirty = { state: DirtyState, paths: { string }, message: string? }

local M = {}

M.OBJECTS = "/Objects"
M.MAX_PATH = 1024
-- Dirty paths named in a refusal.
M.MAX_NAMED = 3

local function dirname(path: string): string
	local d = string.match(path, "^(.*)/[^/]*$")
	return if d == nil or d == "" then "/" else d
end

local function join(folder: string, rest: string): string
	if folder == "" or folder == "." then
		return (string.gsub(rest, "^/", ""))
	end
	return folder .. rest
end

-- The folder under the project folder an object file is in, when it is
-- under Objects ("src/Objects/lists/x.xml" -> "/Objects/lists").
local function objectFolder(projectFolder: string, localPath: string): string?
	local prefix = if projectFolder == "" or projectFolder == "." then "" else projectFolder .. "/"
	if string.sub(localPath, 1, #prefix) ~= prefix then
		return nil
	end
	local folder = dirname("/" .. string.sub(localPath, #prefix + 1))
	if folder == M.OBJECTS or string.sub(folder, 1, #M.OBJECTS + 1) == M.OBJECTS .. "/" then
		return folder
	end
	return nil
end

function M.forEntry(project: Project, e: Diff.Entry, excludeFiles: boolean): (Request?, string?)
	if e.where == "local" then
		return nil, e.id .. " exists only in this project; there is nothing to import"
	end
	if e.kind == "object" then
		local folder = if e.localPath then objectFolder(project.projectFolder, e.localPath) else nil
		return {
			kind = "object",
			root = project.root,
			projectFolder = project.projectFolder,
			type = e.type,
			scriptId = e.id,
			destinationFolder = folder or M.OBJECTS,
			excludeFiles = excludeFiles,
		},
			nil
	end
	return {
		kind = "file",
		root = project.root,
		projectFolder = project.projectFolder,
		path = e.id,
		excludeFiles = false,
	},
		nil
end

local function clean(s: string): boolean
	return not string.find(s, "%c") and #s <= M.MAX_PATH
end

-- No `.`/`..` components and no empty ones.
local function plainPath(p: string): boolean
	if string.sub(p, 1, 1) ~= "/" or not clean(p) or string.find(p, "//", 1, true) then
		return false
	end
	for part in string.gmatch(p, "[^/]+") do
		if part == "." or part == ".." then
			return false
		end
	end
	return true
end

-- Why the request cannot run, or nil.
function M.validate(r: Request): string?
	if string.sub(r.root, 1, 1) ~= "/" or not plainPath(r.root) then
		return "the project root must be an absolute path"
	end
	if not clean(r.projectFolder) or string.find(r.projectFolder, "..", 1, true) then
		return "the project folder is not a plain folder name"
	end
	if r.kind == "object" then
		local ty, id, dest = r.type, r.scriptId, r.destinationFolder
		if ty == nil or not string.match(ty, "^%a%w*$") then
			return "the object type is missing or malformed"
		end
		if id == nil or not string.match(id, "^[%w_][%w_%.%-]*$") then
			return "the script ID is missing or malformed"
		end
		if dest == nil or not plainPath(dest) or not (dest == M.OBJECTS or string.sub(dest, 1, 9) == "/Objects/") then
			return "the destination must be a folder under /Objects"
		end
		return nil
	end
	local path = r.path
	if path == nil or not plainPath(path) or string.sub(path, -1) == "/" then
		return "the File Cabinet path must be absolute, like /SuiteScripts/x.js"
	end
	return nil
end

function M.argv(program: string, r: Request): ({ string }?, string?)
	local err = M.validate(r)
	if err then
		return nil, err
	end
	if r.kind == "object" then
		local argv = {
			program,
			"object:import",
			"--type",
			r.type :: string,
			"--scriptid",
			r.scriptId :: string,
			"--destinationfolder",
			r.destinationFolder :: string,
		}
		if r.excludeFiles then
			table.insert(argv, "--excludefiles")
		end
		return argv, nil
	end
	return { program, "file:import", "--paths", r.path :: string }, nil
end

function M.quote(s: string): string
	if s ~= "" and string.match(s, "^[%w%._/:@%-=+,]+$") then
		return s
	end
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

function M.commandLine(argv: { string }): string
	local words: { string } = table.create(#argv)
	for i, w in argv do
		words[i] = M.quote(w)
	end
	return table.concat(words, " ")
end

-- Project paths (relative to root) the import may write. An account-only
-- object's script files are unknown until it is imported, so the whole
-- File Cabinet counts unless --excludefiles.
function M.destinations(r: Request, references: { string }?): { string }
	local pf = r.projectFolder
	if r.kind == "object" then
		local out = { join(pf, (r.destinationFolder :: string) .. "/" .. (r.scriptId :: string) .. ".xml") }
		if not r.excludeFiles then
			if references then
				for _, ref in references do
					table.insert(out, join(pf, "/FileCabinet" .. ref))
				end
			else
				table.insert(out, join(pf, "/FileCabinet"))
			end
		end
		return out
	end
	local path = r.path :: string
	return { join(pf, "/FileCabinet" .. path), join(pf, "/FileCabinet" .. dirname(path) .. "/.attributes") }
end

function M.dirtyArgv(r: Request, destinations: { string }): { string }
	local argv = { "git", "-C", r.root, "status", "--porcelain=v1", "-z", "--untracked-files=all", "--" }
	table.move(destinations, 1, #destinations, #argv + 1, argv)
	return argv
end

local function firstLine(text: string): string
	return string.match(text, "^%s*([^\n]*)") or ""
end

-- `git status --porcelain=v1 -z` as a verdict input.
function M.dirty(status: number, stdout: string, stderr: string, timedOut: boolean): Dirty
	if timedOut then
		return { state = "error", paths = {}, message = "git status timed out" }
	end
	if status ~= 0 then
		if string.find(stderr, "not a git repository", 1, true) then
			return { state = "nogit", paths = {}, message = nil }
		end
		local why = firstLine(stderr)
		return { state = "error", paths = {}, message = if why ~= "" then why else "git status exited " .. status }
	end
	local paths: { string } = {}
	local tokens = string.split(stdout, "\0")
	local i = 1
	while i <= #tokens do
		local tok = tokens[i]
		if #tok > 3 then
			local xy = string.sub(tok, 1, 2)
			table.insert(paths, string.sub(tok, 4))
			if string.find(xy, "[RC]") and tokens[i + 1] and tokens[i + 1] ~= "" then
				i += 1
				table.insert(paths, tokens[i])
			end
		end
		i += 1
	end
	return { state = if #paths > 0 then "dirty" else "clean", paths = paths, message = nil }
end

local FORCE_HINT = "press I to import anyway"

-- Whether the import may run, and what to tell the user.
function M.verdict(d: Dirty, force: boolean): (boolean, string)
	if force then
		return true, "forced: the import may overwrite local changes"
	end
	if d.state == "clean" then
		return true, "no uncommitted changes in the destination"
	end
	if d.state == "dirty" then
		local named = table.move(d.paths, 1, math.min(#d.paths, M.MAX_NAMED), 1, {})
		local more = if #d.paths > M.MAX_NAMED then string.format(" and %d more", #d.paths - M.MAX_NAMED) else ""
		return false,
			string.format(
				"%d uncommitted change%s where the import writes (%s%s); commit or stash them, or %s",
				#d.paths,
				if #d.paths == 1 then "" else "s",
				table.concat(named, ", "),
				more,
				FORCE_HINT
			)
	end
	if d.state == "nogit" then
		return false,
			"the project is not in a git repository, so overwritten files could not be recovered; " .. FORCE_HINT
	end
	return false, "could not check for uncommitted changes (" .. (d.message or "unknown error") .. "); " .. FORCE_HINT
end

return table.freeze(M)
