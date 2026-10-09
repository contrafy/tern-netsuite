--!strict
-- The SDF project a directory belongs to: the nearest ancestor holding
-- suitecloud.config.js, searched no higher than the repository root (a
-- directory with .git) so a config file above the repo cannot claim it.
-- The project's default auth id comes from project.json, which the
-- SuiteCloud CLI writes on account:setup and reads for every account call.

export type Lookup = {
	exists: (path: string) -> boolean,
	-- nil when the file cannot be read.
	read: (path: string) -> string?,
	decode: (text: string) -> any,
	-- Entry names of a directory; only projectsUnder needs it.
	list: ((path: string) -> { string })?,
}

export type Context = {
	projectRoot: string,
	projectName: string,
	authId: string?,
	-- Why authId is nil.
	problem: string?,
}

local M = {}

M.CONFIG_FILE = "suitecloud.config.js"
M.PROJECT_FILE = "project.json"
M.REPO_MARKER = ".git"

-- Deeper than any real path; bounds the walk on a malformed cwd.
local MAX_DEPTH = 128

local function normalize(path: string): string?
	if string.sub(path, 1, 1) ~= "/" then
		return nil
	end
	local p = string.gsub(path, "/+", "/")
	if #p > 1 then
		p = string.gsub(p, "/$", "")
	end
	return p
end

local function parent(path: string): string?
	if path == "/" then
		return nil
	end
	local up = string.match(path, "^(.*)/[^/]+$")
	if up == nil then
		return nil
	end
	return if up == "" then "/" else up
end

local function join(dir: string, name: string): string
	return if dir == "/" then "/" .. name else dir .. "/" .. name
end

local function basename(path: string): string
	return string.match(path, "([^/]+)$") or path
end

-- The first of `dir` and its ancestors that `accept` takes; the walk ends
-- after a directory `halt` takes.
local function ancestor(dir: string, accept: (string) -> boolean, halt: ((string) -> boolean)?): string?
	local d: string? = dir
	for _ = 1, MAX_DEPTH do
		if d == nil then
			return nil
		end
		local here = d :: string
		if accept(here) then
			return here
		end
		if halt and halt(here) then
			return nil
		end
		d = parent(here)
	end
	return nil
end

function M.findRoot(cwd: string, exists: (string) -> boolean): string?
	local dir = normalize(cwd)
	if dir == nil then
		return nil
	end
	return ancestor(dir, function(d: string): boolean
		return exists(join(d, M.CONFIG_FILE))
	end, function(d: string): boolean
		return exists(join(d, M.REPO_MARKER))
	end)
end

function M.repoRoot(cwd: string, exists: (string) -> boolean): string?
	local dir = normalize(cwd)
	if dir == nil then
		return nil
	end
	return ancestor(dir, function(d: string): boolean
		return exists(join(d, M.REPO_MARKER))
	end)
end

-- The defaultAuthId of a project.json text, or why there is none.
function M.authIdFrom(text: string, decode: (string) -> any): (string?, string?)
	local ok, doc = pcall(decode, text)
	if not ok or type(doc) ~= "table" then
		return nil, "project.json is not valid JSON"
	end
	local id = doc.defaultAuthId
	if type(id) ~= "string" or string.find(id, "^%s*$") then
		return nil, "project.json has no defaultAuthId string"
	end
	return id, nil
end

function M.at(root: string, lookup: Lookup): Context
	local file = join(root, M.PROJECT_FILE)
	local ctx: Context = { projectRoot = root, projectName = basename(root), authId = nil, problem = nil }
	if not lookup.exists(file) then
		ctx.problem = "no project.json (the CLI asks for an auth id)"
		return ctx
	end
	local text = lookup.read(file)
	if text == nil then
		ctx.problem = "project.json could not be read"
		return ctx
	end
	ctx.authId, ctx.problem = M.authIdFrom(text, lookup.decode)
	return ctx
end

function M.forCwd(cwd: string, lookup: Lookup): Context?
	local root = M.findRoot(cwd, lookup.exists)
	if root == nil then
		return nil
	end
	return M.at(root, lookup)
end

-- Projects directly under `<base>/<root>` for each configured root, at most `max`.
function M.projectsUnder(base: string, roots: { string }, lookup: Lookup, max: number): { Context }
	local out: { Context } = {}
	local list = lookup.list
	local dirBase = normalize(base)
	if list == nil or dirBase == nil then
		return out
	end
	for _, root in roots do
		local dir = if string.sub(root, 1, 1) == "/" then normalize(root) else normalize(join(dirBase, root))
		if dir and lookup.exists(dir) then
			local ok, names = pcall(list, dir)
			local entries: { string } = if ok then names else {}
			for _, name in entries do
				if #out >= max then
					return out
				end
				local candidate = join(dir, name)
				if lookup.exists(join(candidate, M.CONFIG_FILE)) then
					table.insert(out, M.at(candidate, lookup))
				end
			end
		end
	end
	return out
end

return M
