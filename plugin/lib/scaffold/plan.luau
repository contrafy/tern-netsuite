--!strict
-- What creating a SuiteScript in an SDF project writes: the script file, its
-- script object with one deployment, and the deploy.xml / manifest.xml edits
-- the project needs so the new files deploy and validate. Validates the form
-- (SDF id rules, File Cabinet names, deployment fields) and refuses anything
-- that would overwrite or collide with what the project already has.

local Edits = require("./edits")
local Kinds = require("./kinds")
local Project = require("../sdf/project")
local Skeleton = require("./skeleton")
local Xml = require("../sdf/xml")

type Project = Project.Project
type Kind = Kinds.Kind
type Node = Xml.Node

export type Deploy = {
	status: string,
	logLevel: string,
	-- User event and client scripts: "SALESORDER", "customrecord_x" or
	-- "[scriptid=customrecord_x]".
	recordType: string?,
	-- Every other type; defaults to the name.
	title: string?,
}

export type Form = {
	scriptType: string,
	name: string,
	-- The part after customscript_ / customdeploy_.
	scriptIdSuffix: string,
	fileName: string,
	-- File Cabinet folder, "/SuiteScripts" or below.
	folder: string,
	deploy: Deploy,
}

export type Write = { path: string, content: string, lang: string }

export type Edit = { path: string, from: string, to: string, reason: string }

-- `field` names the Form field ("scriptIdSuffix", "recordType", ...) or
-- "project".
export type Problem = { field: string, message: string }

export type Plan = {
	scriptId: string,
	deploymentId: string,
	fileCabinetPath: string,
	-- Project-relative.
	scriptPath: string,
	objectPath: string,
	writes: { Write },
	edits: { Edit },
	warnings: { string },
}

export type Inputs = {
	deployText: string?,
	manifestText: string?,
	-- Replaces the built-in skeleton ({{scriptId}}, {{name}}).
	template: string?,
}

local M = {}

M.SCRIPT_PREFIX = "customscript_"
M.DEPLOY_PREFIX = "customdeploy_"
-- sdf_metadata.xml: scriptid length="40" for scripts and deployments
-- (project:validate: "The scriptid must not exceed 40 characters.").
M.MAX_SCRIPT_ID = 40
M.MAX_SUFFIX = M.MAX_SCRIPT_ID - #M.SCRIPT_PREFIX
-- sdf_metadata.xml: name length="40".
M.MAX_NAME = 40
M.ROOT_FOLDER = "/SuiteScripts"

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") :: string
end

local function contains(list: { string }, v: string): boolean
	return table.find(list, v) ~= nil
end

-- A script id suffix from a display name: lower case, runs of anything else
-- as one underscore, at most MAX_SUFFIX characters.
function M.suffixFrom(name: string): string
	local s = string.gsub(string.lower(name), "[^a-z0-9]+", "_")
	s = string.gsub(s, "^_+", "")
	s = string.sub(s, 1, M.MAX_SUFFIX)
	return (string.gsub(s, "_+$", ""))
end

-- "SuiteScripts/a//b/" -> "/SuiteScripts/a/b".
function M.normalizeFolder(folder: string): string
	local parts: { string } = {}
	for part in string.gmatch(trim(folder), "[^/]+") do
		table.insert(parts, part)
	end
	return "/" .. table.concat(parts, "/")
end

local function normalizeRecordType(rt: string?): string?
	if rt == nil then
		return nil
	end
	local v = trim(rt)
	if v == "" then
		return nil
	end
	if string.find(v, "^custom[a-z]*[_%d][a-z0-9_]*$") then
		return "[scriptid=" .. v .. "]"
	end
	if string.find(v, "^%[") then
		return v
	end
	return string.upper(v)
end

-- The form as planned: trimmed, the customscript_ prefix dropped from a
-- pasted id, ".js" added to a bare file name, folder and record type in SDF
-- form, title defaulted to the name.
function M.normalize(form: Form): Form
	local suffix = trim(form.scriptIdSuffix)
	if string.sub(suffix, 1, #M.SCRIPT_PREFIX) == M.SCRIPT_PREFIX then
		suffix = string.sub(suffix, #M.SCRIPT_PREFIX + 1)
	end
	local fileName = trim(form.fileName)
	if fileName ~= "" and not string.find(fileName, "%.[^%.]*$") then
		fileName ..= ".js"
	end
	local name = trim(form.name)
	local title = if form.deploy.title then trim(form.deploy.title) else ""
	return {
		scriptType = form.scriptType,
		name = name,
		scriptIdSuffix = suffix,
		fileName = fileName,
		folder = M.normalizeFolder(form.folder),
		deploy = {
			status = form.deploy.status,
			logLevel = form.deploy.logLevel,
			recordType = normalizeRecordType(form.deploy.recordType),
			title = if title == "" then name else title,
		},
	}
end

-- CLI validateFileName: \ / : * ? " < > | and a trailing period.
local function badFileName(name: string): string?
	if string.find(name, '[\\/:%*%?"<>|]') then
		return 'cannot contain any of \\ / : * ? " < > |'
	elseif string.find(name, "%.$") then
		return "cannot end with a period"
	elseif string.find(name, "%c") then
		return "cannot contain control characters"
	end
	return nil
end

local function validateForm(f: Form, kind: Kind, problems: { Problem })
	local function problem(field: string, message: string)
		table.insert(problems, { field = field, message = message })
	end

	if f.name == "" then
		problem("name", "a name is required")
	elseif utf8.len(f.name) == nil or (utf8.len(f.name) :: number) > M.MAX_NAME then
		problem("name", string.format("names are at most %d characters", M.MAX_NAME))
	elseif string.find(f.name, "%c") then
		problem("name", "names cannot contain control characters")
	end

	local suffix = f.scriptIdSuffix
	if suffix == "" then
		problem("scriptIdSuffix", "a script id is required")
	elseif not string.find(suffix, "^[a-z0-9_]+$") then
		problem("scriptIdSuffix", "script ids use only lowercase letters, numbers and underscores")
	elseif #M.SCRIPT_PREFIX + #suffix > M.MAX_SCRIPT_ID then
		problem(
			"scriptIdSuffix",
			string.format(
				"%s%s is %d characters; SDF allows %d",
				M.SCRIPT_PREFIX,
				suffix,
				#M.SCRIPT_PREFIX + #suffix,
				M.MAX_SCRIPT_ID
			)
		)
	end

	if f.fileName == "" then
		problem("fileName", "a file name is required")
	else
		local bad = badFileName(f.fileName)
		if bad then
			problem("fileName", "file names " .. bad)
		elseif string.lower(string.sub(f.fileName, -3)) ~= ".js" then
			problem("fileName", "script files must be .js")
		end
	end

	local folder = f.folder
	if folder ~= M.ROOT_FOLDER and string.sub(folder, 1, #M.ROOT_FOLDER + 1) ~= M.ROOT_FOLDER .. "/" then
		problem("folder", "scripts live in " .. M.ROOT_FOLDER .. " or a folder below it")
	else
		for part in string.gmatch(folder, "[^/]+") do
			local bad = if part == "." or part == ".." then "cannot be . or .." else badFileName(part)
			if bad then
				problem("folder", string.format("folder %q %s", part, bad))
				break
			end
		end
	end

	if not contains(kind.statuses, f.deploy.status) then
		problem("status", string.format("%s deployments start as %s", kind.label, table.concat(kind.statuses, " or ")))
	end
	if not contains(Kinds.LOG_LEVELS, f.deploy.logLevel) then
		problem("logLevel", "log level is one of " .. table.concat(Kinds.LOG_LEVELS, ", "))
	end
	if kind.recordType then
		local rt = f.deploy.recordType
		if rt == nil then
			problem("recordType", kind.label .. " deployments need a record type")
		elseif not (string.find(rt, "^[A-Z][A-Z0-9_]*$") or string.find(rt, "^%[scriptid=[a-z0-9_]+%]$")) then
			problem("recordType", "use a record type such as SALESORDER, or a custom record's script id")
		end
	end
	if kind.title and (f.deploy.title == nil or f.deploy.title == "") then
		problem("title", kind.label .. " deployments need a title")
	end
end

local function lowerSet(list: { string }): { [string]: boolean }
	local out: { [string]: boolean } = {}
	for _, v in list do
		out[string.lower(v)] = true
	end
	return out
end

local function deploymentOwner(project: Project, id: string): string?
	for _, o in project.objects do
		for _, d in o.deployments do
			if d.scriptId == id then
				return o.scriptId
			end
		end
		if contains(o.children, id) then
			return o.scriptId
		end
	end
	return nil
end

local function checkCollisions(project: Project, p: Plan, problems: { Problem })
	local existing = Project.object(project, p.scriptId)
	if existing then
		table.insert(
			problems,
			{ field = "scriptIdSuffix", message = string.format("%s already exists (%s)", p.scriptId, existing.path) }
		)
	else
		local owner = deploymentOwner(project, p.deploymentId)
		if owner then
			table.insert(
				problems,
				{ field = "scriptIdSuffix", message = string.format("%s is already used by %s", p.deploymentId, owner) }
			)
		end
	end
	-- macOS file systems and the File Cabinet both ignore case.
	local paths = lowerSet(project.paths)
	if existing == nil and paths[string.lower(p.objectPath)] then
		table.insert(problems, { field = "scriptIdSuffix", message = p.objectPath .. " already exists" })
	end
	local cabinet = string.lower(p.fileCabinetPath)
	for _, f in project.files do
		if string.lower(f.fileCabinetPath) == cabinet then
			table.insert(problems, { field = "fileName", message = p.fileCabinetPath .. " already exists" })
			return
		end
	end
	if paths[string.lower(p.scriptPath)] then
		table.insert(problems, { field = "fileName", message = p.scriptPath .. " already exists" })
	end
end

local function el(tag: string, text: string): Node
	return Xml.element(tag, { text = text })
end

-- The script object as NetSuite exports it (element order, no trailing
-- newline), with only what a new script needs: fields at their SDF default
-- are left out, and so is executioncontext, whose exported value lists
-- account-specific contexts.
function M.objectXml(kind: Kind, f: Form, scriptId: string, deploymentId: string, fileCabinetPath: string): string
	local d: { Node } = {}
	if kind.audience then
		table.insert(d, el("allroles", "T"))
	end
	table.insert(d, el("isdeployed", "T"))
	table.insert(d, el("loglevel", f.deploy.logLevel))
	if kind.recordType then
		table.insert(d, el("recordtype", f.deploy.recordType or ""))
	end
	table.insert(d, el("status", f.deploy.status))
	if kind.title then
		table.insert(d, el("title", f.deploy.title or f.name))
	end
	local deployment =
		Xml.element("scriptdeployment", { attrs = { { name = "scriptid", value = deploymentId } }, children = d })

	local c: { Node } = {
		el("description", ""),
		el("isinactive", "F"),
		el("name", f.name),
		el("notifyadmins", "F"),
		el("notifyemails", ""),
		el("notifyowner", "T"),
	}
	if kind.notifyUser then
		table.insert(c, el("notifyuser", "F"))
	end
	table.insert(c, el("scriptfile", "[" .. fileCabinetPath .. "]"))
	table.insert(c, Xml.element("scriptdeployments", { children = { deployment } }))
	return Xml.emit(Xml.element(kind.tag, { attrs = { { name = "scriptid", value = scriptId } }, children = c }))
end

local function hasRequiredFeature(project: Project, name: string): boolean
	local manifest = project.manifest
	if manifest == nil then
		return false
	end
	for _, feature in manifest.dependencies.features do
		if feature.name == name and feature.required then
			return true
		end
	end
	return false
end

local function planEdits(project: Project, p: Plan, inputs: Inputs, problems: { Problem })
	local deploy = project.deploy
	if deploy == nil then
		table.insert(problems, { field = "project", message = "deploy.xml is missing or does not parse" })
	else
		local adds: { Edits.DeployAdd } = {}
		if not Project.isDeployed(project, "files", p.scriptPath) then
			table.insert(adds, { section = "files", pattern = "~/FileCabinet" .. p.fileCabinetPath })
		end
		if not Project.isDeployed(project, "objects", p.objectPath) then
			table.insert(adds, { section = "objects", pattern = "~/Objects/" .. p.scriptId .. ".xml" })
		end
		if #adds > 0 then
			local text = inputs.deployText
			local to, err = if text then Edits.addDeployPaths(text, adds) else nil, "deploy.xml was not read"
			if text and to then
				local what = {}
				for _, a in adds do
					table.insert(what, a.pattern)
				end
				table.insert(p.edits, {
					path = deploy.path,
					from = text,
					to = to,
					reason = "deploy.xml does not deploy " .. table.concat(what, " or "),
				})
			else
				table.insert(problems, { field = "project", message = err or "deploy.xml cannot be edited" })
			end
		end
	end

	local manifest = project.manifest
	if manifest == nil then
		table.insert(problems, { field = "project", message = "manifest.xml is missing or does not parse" })
	elseif not hasRequiredFeature(project, Kinds.FEATURE) then
		local text = inputs.manifestText
		local to, err = if text then Edits.requireFeature(text, Kinds.FEATURE) else nil, "manifest.xml was not read"
		if text and to then
			table.insert(p.edits, {
				path = manifest.path,
				from = text,
				to = to,
				reason = "script objects need the " .. Kinds.FEATURE .. " feature as required",
			})
		else
			table.insert(problems, { field = "project", message = err or "manifest.xml cannot be edited" })
		end
	end
end

-- The plan for `form` in `project`, or nil and every problem found. A plan
-- never overwrites: writes are new paths, edits carry the text they expect.
function M.plan(project: Project, form: Form, inputs: Inputs?): (Plan?, { Problem })
	local problems: { Problem } = {}
	local kind = Kinds.get(form.scriptType)
	if kind == nil then
		return nil, { { field = "scriptType", message = "unknown script type " .. form.scriptType } }
	end
	local f = M.normalize(form)
	validateForm(f, kind, problems)
	for _, pr in problems do
		if pr.field == "scriptIdSuffix" or pr.field == "fileName" or pr.field == "folder" then
			return nil, problems
		end
	end
	local scriptId = M.SCRIPT_PREFIX .. f.scriptIdSuffix
	local deploymentId = M.DEPLOY_PREFIX .. f.scriptIdSuffix
	local fileCabinetPath = f.folder .. "/" .. f.fileName
	local folder = project.projectFolder
	local p: Plan = {
		scriptId = scriptId,
		deploymentId = deploymentId,
		fileCabinetPath = fileCabinetPath,
		scriptPath = folder .. "/FileCabinet" .. fileCabinetPath,
		objectPath = folder .. "/Objects/" .. scriptId .. ".xml",
		writes = {},
		edits = {},
		warnings = {},
	}
	-- Collisions are reported even while other fields are incomplete.
	checkCollisions(project, p, problems)
	if #problems > 0 then
		return nil, problems
	end
	local i: Inputs = inputs or {}
	planEdits(project, p, i, problems)
	if #problems > 0 then
		return nil, problems
	end
	if project.truncated then
		table.insert(p.warnings, "the project scan was truncated, so collisions with unlisted files were not checked")
	end
	local script = if i.template
		then Skeleton.render(i.template, { scriptId = scriptId, name = f.name })
		else Skeleton.builtin(kind)
	table.insert(p.writes, { path = p.scriptPath, content = script, lang = "javascript" })
	table.insert(p.writes, {
		path = p.objectPath,
		content = M.objectXml(kind, f, scriptId, deploymentId, fileCabinetPath),
		lang = "xml",
	})
	return p, {}
end

return table.freeze(M)
