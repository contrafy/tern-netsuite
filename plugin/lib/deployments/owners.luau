--!strict
-- Which local SDF project owns a script deployment: the projects the
-- deployments block scanned (lib/sdf/project.luau) indexed by deployment
-- scriptid, the owner an edit applies to, and the deploy command the user
-- runs afterwards (never the block: deploys go through the guard).

local Project = require("../sdf/project")

local M = {}

export type Owner = {
	-- Project root (the directory with suitecloud.config.js).
	root: string,
	name: string,
	authId: string?,
	-- The script object owning the deployment.
	object: string,
	tag: string,
	-- The object file relative to the root, as shown.
	rel: string,
	-- The file to read and write: its real path when it is a symlink, so an
	-- edit never replaces the link with a copy.
	path: string,
	line: number,
}

export type Index = { [string]: { Owner } }

function M.index(projects: { Project.Project }): Index
	local out: Index = {}
	for _, p in projects do
		for _, o in p.objects do
			for _, d in o.deployments do
				local key = string.lower(d.scriptId)
				if key ~= "" then
					local list = out[key]
					if list == nil then
						list = {}
						out[key] = list
					end
					table.insert(list, {
						root = p.root,
						name = p.name,
						authId = p.defaultAuthId,
						object = o.scriptId,
						tag = o.type,
						rel = o.path,
						path = o.real or (p.root .. "/" .. o.path),
						line = d.line,
					})
				end
			end
		end
	end
	return out
end

local function inside(path: string, root: string): boolean
	return path == root or string.sub(path, 1, #root + 1) == root .. "/"
end

-- The owner an edit of deployment `id` applies to, or nil and why: the
-- only owner, or the one containing `cwd` when several projects ship it.
function M.pick(index: Index, id: string, cwd: string?): (Owner?, string?)
	local list = index[string.lower(id)]
	if list == nil or #list == 0 then
		return nil, "no local SDF project defines this deployment"
	end
	if #list == 1 then
		return list[1], nil
	end
	if cwd then
		local best: Owner? = nil
		for _, o in list do
			if inside(cwd, o.root) and (best == nil or #o.root > #best.root) then
				best = o
			end
		end
		if best then
			return best, nil
		end
	end
	local names: { string } = {}
	for _, o in list do
		table.insert(names, o.name)
	end
	return nil,
		string.format(
			"%d local projects define this deployment (%s); open the block from inside the one to edit",
			#list,
			table.concat(names, ", ")
		)
end

-- `cd <root> && suitecloud project:deploy`, or nil and why when the root
-- cannot be put in a shell line safely.
function M.deployCommand(root: string): (string?, string?)
	if string.find(root, "[%c'\"\\]") then
		return nil, "the project path has quotes, backslashes or control characters; deploy from a shell by hand"
	end
	local quoted = if string.find(root, "^[%w%-%._/@+,]+$") then root else "'" .. root .. "'"
	return "cd " .. quoted .. " && suitecloud project:deploy", nil
end

return table.freeze(M)
