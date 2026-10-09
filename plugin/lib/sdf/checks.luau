--!strict
-- Static checks over SDF project models, the problems `project:validate`
-- would report late (or not at all, for problems spanning projects):
--
--   missing-dependency       an object references a custom scriptid that is
--                            neither in the project nor in manifest.xml
--                            dependencies: validation and deploy fail.
--   missing-script-file      an object references a File Cabinet file
--                            ([/SuiteScripts/x.js]) the project neither
--                            contains nor declares: validation fails.
--   not-deployed             an object or file is in the project but no
--                            deploy.xml path covers it: it silently never
--                            reaches the account.
--   empty-deploy-path        a deploy.xml path covers nothing: usually a
--                            typo or a moved folder, so something expected
--                            is not deployed.
--   cross-project-collision  two projects deploy the same object scriptid
--                            or File Cabinet path: the last deploy wins.
--   xml-parse and the other project diagnostics, passed through.

local Project = require("./project")

type Project = Project.Project
type Severity = Project.Severity

export type Finding = {
	severity: Severity,
	code: string,
	message: string,
	project: string,
	path: string?,
	line: number?,
	scriptId: string?,
}

local M = {}

-- Custom object ids (customrecord_x, custbody_x, customlist728, cseg_x);
-- standard ids ("customer", "-2", "SALESORDER") are always in the account.
function M.isCustomId(id: string): boolean
	local top = string.match(id, "^[^%.]+") or id
	return string.find(top, "^cust%l*[_%d]") ~= nil or string.find(top, "^cseg[_%w]") ~= nil
end

local function set(lists: { { string } }): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for _, list in lists do
		for _, v in list do
			out[v] = true
		end
	end
	return out
end

local function dependencies(manifest: Project.Manifest): ({ [string]: boolean }, { [string]: boolean })
	local m = manifest
	local objects: { { string } } = { m.dependencies.objects }
	local files: { { string } } = { m.dependencies.files }
	for _, groups in { m.dependencies.applications, m.dependencies.bundles } do
		for _, g in groups do
			table.insert(objects, g.objects)
			table.insert(files, g.files)
		end
	end
	return set(objects), set(files)
end

-- Object scriptids and every nested scriptid, bare and as the dotted
-- "<object>.<path>" references use (workflow actions sit three deep).
local function defined(project: Project): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for _, o in project.objects do
		out[o.scriptId] = true
		for _, child in o.children do
			out[child] = true
		end
		for _, path in o.childPaths do
			out[o.scriptId .. "." .. path] = true
		end
	end
	return out
end

local function checkReferences(project: Project, out: { Finding })
	-- Without the manifest every declared dependency would look missing.
	local manifest = project.manifest
	if manifest == nil then
		return
	end
	local own = defined(project)
	local depObjects, depFiles = dependencies(manifest)
	-- A truncated scan may have left the referenced file unlisted.
	local checkFiles = not project.truncated
	local cabinet: { [string]: boolean } = {}
	for _, f in project.files do
		cabinet[f.fileCabinetPath] = true
	end
	for _, o in project.objects do
		local seen: { [string]: boolean } = {}
		for _, ref in o.references do
			local id = ref.scriptId
			if not seen[id] and M.isCustomId(id) and not own[id] and not depObjects[id] then
				seen[id] = true
				table.insert(out, {
					severity = "error",
					code = "missing-dependency",
					message = string.format(
						"%s references %s, which is neither in the project nor in manifest.xml dependencies",
						o.scriptId,
						id
					),
					project = project.name,
					path = o.path,
					line = ref.line,
					scriptId = o.scriptId,
				})
			end
		end
		local seenFiles: { [string]: boolean } = {}
		for _, ref in o.fileReferences do
			local path = ref.path
			if checkFiles and not seenFiles[path] and not cabinet[path] and not depFiles[path] then
				seenFiles[path] = true
				table.insert(out, {
					severity = "error",
					code = "missing-script-file",
					message = string.format(
						"%s uses %s, which is neither in the project's FileCabinet nor in manifest.xml dependencies",
						o.scriptId,
						path
					),
					project = project.name,
					path = o.path,
					line = ref.line,
					scriptId = o.scriptId,
				})
			end
		end
	end
end

local function checkDeploy(project: Project, out: { Finding })
	local deploy = project.deploy
	if deploy == nil then
		return
	end
	for _, o in project.objects do
		if not Project.isDeployed(project, "objects", o.path) then
			table.insert(out, {
				severity = "warning",
				code = "not-deployed",
				message = string.format("%s is not covered by any <objects> path in deploy.xml", o.scriptId),
				project = project.name,
				path = o.path,
				line = nil,
				scriptId = o.scriptId,
			})
		end
	end
	-- Info only: projects deliberately keep tests and fixtures out of the
	-- File Cabinet by listing deployable paths one by one.
	for _, f in project.files do
		if not Project.isDeployed(project, "files", f.path) then
			table.insert(out, {
				severity = "info",
				code = "not-deployed",
				message = string.format("%s is not covered by any <files> path in deploy.xml", f.fileCabinetPath),
				project = project.name,
				path = f.path,
				line = nil,
				scriptId = nil,
			})
		end
	end
	if project.truncated then
		return
	end
	for _, p in deploy.paths do
		local hit = false
		for _, path in project.paths do
			if Project.covers(p, path) then
				hit = true
				break
			end
		end
		if not hit then
			-- `project:create` writes configuration, translationimports and
			-- whole-folder FileCabinet/Objects paths whatever the project
			-- holds, and git drops the empty folders.
			local boilerplate = p.section == "configuration"
				or p.section == "translationimports"
				or p.pattern == "~/FileCabinet/*"
				or p.pattern == "~/Objects/*"
			table.insert(out, {
				severity = if boilerplate then "info" else "warning",
				code = "empty-deploy-path",
				message = string.format("<%s> path %s matches nothing in the project", p.section, p.pattern),
				project = project.name,
				path = deploy.path,
				line = p.line,
				scriptId = nil,
			})
		end
	end
end

type Owner = { project: Project, path: string, source: string }

local function checkCollisions(projects: { Project }, out: { Finding })
	local objects: { [string]: { Owner } } = {}
	local files: { [string]: { Owner } } = {}
	local function add(index: { [string]: { Owner } }, key: string, owner: Owner)
		local list = index[key]
		if list == nil then
			list = {}
			index[key] = list
		end
		for _, o in list do
			if o.project.root == owner.project.root then
				return
			end
		end
		table.insert(list, owner)
	end
	for _, p in projects do
		for _, o in p.objects do
			if Project.isDeployed(p, "objects", o.path) then
				add(objects, o.scriptId, { project = p, path = o.path, source = o.real or p.root .. "/" .. o.path })
			end
		end
		for _, f in p.files do
			if Project.isDeployed(p, "files", f.path) then
				add(
					files,
					f.fileCabinetPath,
					{ project = p, path = f.path, source = f.real or p.root .. "/" .. f.path }
				)
			end
		end
	end
	local function report(index: { [string]: { Owner } }, isObject: boolean)
		for key, owners in index do
			if #owners < 2 then
				continue
			end
			for _, mine in owners do
				local same: { string } = {}
				local different: { string } = {}
				for _, o in owners do
					if o ~= mine then
						table.insert(if o.source == mine.source then same else different, o.project.name)
					end
				end
				table.sort(same)
				table.sort(different)
				local parts: { string } = {}
				if #same > 0 then
					table.insert(parts, table.concat(same, ", ") .. " from the same source file")
				end
				if #different > 0 then
					table.insert(parts, table.concat(different, ", ") .. " from a different source file")
				end
				table.insert(out, {
					severity = if #different > 0 then "warning" else "info",
					code = "cross-project-collision",
					message = string.format(
						"%s is also deployed by %s%s",
						key,
						table.concat(parts, " and by "),
						if #different > 0 then "; whichever deploys last wins" else ""
					),
					project = mine.project.name,
					path = mine.path,
					line = nil,
					scriptId = if isObject then key else nil,
				})
			end
		end
	end
	report(objects, true)
	report(files, false)
end

local SEVERITY_RANK: { [Severity]: number } = { error = 1, warning = 2, info = 3 }

-- Findings for each project and across them, ordered by project, severity,
-- path and line.
function M.run(projects: { Project }): { Finding }
	local out: { Finding } = {}
	for _, p in projects do
		for _, d in p.diagnostics do
			table.insert(out, {
				severity = d.severity,
				code = d.code,
				message = d.message,
				project = p.name,
				path = d.path,
				line = d.line,
				scriptId = nil,
			})
		end
		checkReferences(p, out)
		checkDeploy(p, out)
	end
	checkCollisions(projects, out)
	table.sort(out, function(a: Finding, b: Finding): boolean
		if a.project ~= b.project then
			return a.project < b.project
		end
		if a.severity ~= b.severity then
			return SEVERITY_RANK[a.severity] < SEVERITY_RANK[b.severity]
		end
		if (a.path or "") ~= (b.path or "") then
			return (a.path or "") < (b.path or "")
		end
		if (a.line or 0) ~= (b.line or 0) then
			return (a.line or 0) < (b.line or 0)
		end
		if a.code ~= b.code then
			return a.code < b.code
		end
		return a.message < b.message
	end)
	for i, f in out do
		out[i] = table.freeze(f)
	end
	return table.freeze(out)
end

return table.freeze(M)
