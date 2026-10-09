--!strict
-- Which project files a source file is deployed as. Monorepos keep shared
-- SuiteScripts and objects outside the SDF projects and symlink them in, so
-- "upload this file" must find every project (and File Cabinet path) that
-- carries the file being edited.

local Project = require("./project")

type Project = Project.Project

export type Owner = {
	project: string,
	root: string,
	-- Relative to the project root.
	path: string,
	-- Set for File Cabinet files.
	fileCabinetPath: string?,
}

export type Index = {
	-- Real (symlink-resolved) absolute path -> owners.
	byReal: { [string]: { Owner } },
	-- Absolute in-project path -> its real path.
	alias: { [string]: string },
}

local M = {}

-- Lexical normalization: collapses "//", "." and "..", drops a trailing "/".
function M.normalize(path: string): string
	local parts: { string } = {}
	for part in string.gmatch(path, "[^/]+") do
		if part == ".." then
			table.remove(parts)
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	return "/" .. table.concat(parts, "/")
end

function M.index(projects: { Project }): Index
	local byReal: { [string]: { Owner } } = {}
	local alias: { [string]: string } = {}
	local function add(p: Project, path: string, real: string?, fileCabinetPath: string?)
		local abs = M.normalize(p.root .. "/" .. path)
		local key = if real then M.normalize(real) else abs
		alias[abs] = key
		local list = byReal[key]
		if list == nil then
			list = {}
			byReal[key] = list
		end
		table.insert(
			list,
			table.freeze({ project = p.name, root = p.root, path = path, fileCabinetPath = fileCabinetPath })
		)
	end
	for _, p in projects do
		for _, f in p.files do
			add(p, f.path, f.real, f.fileCabinetPath)
		end
		for _, o in p.objects do
			add(p, o.path, o.real, nil)
		end
	end
	for _, list in byReal do
		table.sort(list, function(a: Owner, b: Owner): boolean
			if a.project ~= b.project then
				return a.project < b.project
			end
			if a.root ~= b.root then
				return a.root < b.root
			end
			return a.path < b.path
		end)
		table.freeze(list)
	end
	return table.freeze({ byReal = table.freeze(byReal), alias = table.freeze(alias) })
end

-- Every project file that is `absolutePath` or a symlink to it. The path may
-- be the real source file or any project's view of it.
function M.owners(index: Index, absolutePath: string): { Owner }
	local abs = M.normalize(absolutePath)
	local real = index.alias[abs] or abs
	return index.byReal[real] or table.freeze({})
end

return table.freeze(M)
