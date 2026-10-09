--!strict
-- The model of one SuiteCloud SDF project, built from a Snapshot: config,
-- manifest.xml, deploy.xml, objects with the scriptids and File Cabinet paths
-- they reference, and File Cabinet files. Never raises: unreadable or
-- malformed inputs become diagnostics.

local Snapshot = require("./snapshot")
local Xml = require("./xml")

type Snapshot = Snapshot.Snapshot
type SnapshotFile = Snapshot.SnapshotFile
type Node = Xml.Node

export type Severity = "error" | "warning" | "info"

export type Diagnostic = {
	severity: Severity,
	-- "xml-parse", "missing-manifest", "missing-deploy", "object-scriptid",
	-- "object-filename", "file-unread" or "scan".
	code: string,
	message: string,
	path: string?,
	line: number?,
	col: number?,
}

export type Feature = { name: string, required: boolean }

-- A SuiteApp (applications) or bundle the project depends on.
export type DependencyGroup = { id: string, objects: { string }, files: { string } }

export type Dependencies = {
	features: { Feature },
	objects: { string },
	files: { string },
	applications: { DependencyGroup },
	bundles: { DependencyGroup },
}

export type Manifest = {
	path: string,
	-- "ACCOUNTCUSTOMIZATION" or "SUITEAPP" as written.
	projectType: string?,
	projectName: string?,
	frameworkVersion: string?,
	-- SuiteApps only.
	publisherId: string?,
	projectId: string?,
	projectVersion: string?,
	dependencies: Dependencies,
}

export type DeploySection = "configuration" | "files" | "objects" | "translationimports"

export type DeployPath = {
	section: DeploySection,
	-- As written, e.g. "~/FileCabinet/*".
	pattern: string,
	-- Relative to the project root, "~/" expanded, e.g. "src/FileCabinet/*".
	target: string,
	line: number,
}

export type Deploy = { path: string, paths: { DeployPath } }

export type Reference = {
	-- As written, possibly dotted for a child: "customrecord_x.custrecord_y".
	scriptId: string,
	type: string?,
	line: number,
}

export type FileReference = {
	-- File Cabinet path, e.g. "/SuiteScripts/x.js".
	path: string,
	line: number,
}

export type Deployment = {
	scriptId: string,
	status: string?,
	logLevel: string?,
	-- As written: a record type ("SALESORDER") or a reference ("[scriptid=...]").
	recordType: string?,
	isDeployed: boolean?,
	title: string?,
	line: number,
}

export type SdfObject = {
	scriptId: string,
	-- The root tag, e.g. "usereventscript", "customrecordtype".
	type: string,
	path: string,
	real: string?,
	line: number,
	-- Has a <scriptfile>.
	isScript: boolean,
	-- Scriptids of nested elements (fields, values, deployments), undotted.
	children: { string },
	-- The same, as dotted paths below the object through every ancestor
	-- with a scriptid: "workflowstate_a.workflowaction_b". References
	-- name them as "<scriptId>.<childPath>".
	childPaths: { string },
	references: { Reference },
	fileReferences: { FileReference },
	deployments: { Deployment },
}

export type File = {
	path: string,
	real: string?,
	size: number,
	-- "/SuiteScripts/x.js".
	fileCabinetPath: string,
}

export type Project = {
	-- The root directory's name.
	name: string,
	root: string,
	-- defaultProjectFolder from suitecloud.config.js ("src" by default).
	projectFolder: string,
	defaultAuthId: string?,
	manifest: Manifest?,
	deploy: Deploy?,
	objects: { SdfObject },
	files: { File },
	-- Every snapshot path, for deploy.xml matching.
	paths: { string },
	truncated: boolean,
	diagnostics: { Diagnostic },
}

local M = {}

M.DEFAULT_FOLDER = "src"

local SECTIONS: { DeploySection } = { "configuration", "files", "objects", "translationimports" }

local function trim(s: string): string
	return string.match(s, "^%s*(.-)%s*$") :: string
end

local function basename(path: string): string
	return (string.match(path, "([^/]+)/*$") or path) :: string
end

-- Strips JS comments well enough to ignore a commented-out setting; a "//"
-- inside a string (a URL) is kept because it never follows whitespace.
local function stripComments(js: string): string
	local s = string.gsub(js, "/%*.-%*/", "")
	s = string.gsub(s, "\n[ \t]*//[^\n]*", "\n")
	s = string.gsub(s, "^[ \t]*//[^\n]*", "")
	s = string.gsub(s, "([ \t;,{])//[^\n]*", "%1")
	return s
end

-- `defaultProjectFolder: 'src'` in any quoting; "src" when absent.
function M.projectFolder(configText: string?): string
	if configText == nil then
		return M.DEFAULT_FOLDER
	end
	local js = stripComments(configText)
	local _, value = string.match(js, "defaultProjectFolder[\"']?%s*:%s*([\"'`])(.-)%1")
	if value == nil then
		return M.DEFAULT_FOLDER
	end
	local folder = string.gsub(string.gsub(trim(value), "^%./", ""), "/+$", "")
	return if folder == "" then M.DEFAULT_FOLDER else folder
end

-- project.json is flat JSON; a pattern avoids injecting a decoder for one key.
function M.defaultAuthId(projectJson: string?): string?
	if projectJson == nil then
		return nil
	end
	local id = string.match(projectJson, '"defaultAuthId"%s*:%s*"([^"\\]*)"')
	return if id == nil or id == "" then nil else id
end

local function texts(parent: Node?, group: string, item: string): { string }
	local out: { string } = {}
	local g = if parent then Xml.child(parent, group) else nil
	if g then
		for _, n in Xml.children(g, item) do
			local v = trim(n.text)
			if v ~= "" then
				table.insert(out, v)
			end
		end
	end
	return out
end

local function groups(deps: Node?, group: string, item: string): { DependencyGroup }
	local out: { DependencyGroup } = {}
	local g = if deps then Xml.child(deps, group) else nil
	if g then
		for _, n in Xml.children(g, item) do
			table.insert(out, {
				id = n.attrs.id or n.attrs.applicationid or "",
				objects = texts(n, "objects", "object"),
				files = texts(n, "files", "file"),
			})
		end
	end
	return out
end

local function optionalText(node: Node, tag: string): string?
	local v = Xml.childText(node, tag)
	if v == nil then
		return nil
	end
	v = trim(v)
	return if v == "" then nil else v
end

local function parseManifest(path: string, root: Node): Manifest
	local deps = Xml.child(root, "dependencies")
	local features: { Feature } = {}
	local fg = if deps then Xml.child(deps, "features") else nil
	if fg then
		for _, f in Xml.children(fg, "feature") do
			local name = trim(f.text)
			if name ~= "" then
				table.insert(features, { name = name, required = string.lower(f.attrs.required or "") == "true" })
			end
		end
	end
	return {
		path = path,
		projectType = root.attrs.projecttype,
		projectName = optionalText(root, "projectname"),
		frameworkVersion = optionalText(root, "frameworkversion"),
		publisherId = optionalText(root, "publisherid"),
		projectId = optionalText(root, "projectid"),
		projectVersion = optionalText(root, "projectversion"),
		dependencies = {
			features = features,
			objects = texts(deps, "objects", "object"),
			files = texts(deps, "files", "file"),
			applications = groups(deps, "applications", "application"),
			bundles = groups(deps, "bundles", "bundle"),
		},
	}
end

local function parseDeploy(path: string, root: Node, folder: string): Deploy
	local paths: { DeployPath } = {}
	for _, section: DeploySection in SECTIONS do
		for _, s in Xml.children(root, section) do
			for _, p in Xml.children(s, "path") do
				local pattern = trim(p.text)
				if pattern ~= "" then
					local target = if string.sub(pattern, 1, 2) == "~/"
						then folder .. "/" .. string.sub(pattern, 3)
						else pattern
					table.insert(paths, { section = section, pattern = pattern, target = target, line = p.line })
				end
			end
		end
	end
	return { path = path, paths = paths }
end

local compiled: { [string]: string } = {}

-- deploy.xml paths: "*" matches anything, "/" included (a trailing "*"
-- deploys a folder recursively); a path without "*" names a file or folder.
local function compile(target: string): string
	local cached = compiled[target]
	if cached then
		return cached
	end
	local escaped = string.gsub(target, "[%^%$%(%)%%%.%[%]%+%-%?]", "%%%0")
	local pattern = "^" .. string.gsub(escaped, "%*", ".*")
	if not string.find(target, "*", 1, true) then
		pattern = pattern .. "/"
	end
	compiled[target] = pattern
	return pattern
end

-- Whether a deploy.xml path covers `path` (relative to the project root).
function M.covers(deployPath: DeployPath, path: string): boolean
	local target = deployPath.target
	if path == target then
		return true
	end
	local pattern = compile(target)
	if string.find(target, "*", 1, true) then
		return string.find(path, pattern .. "$") ~= nil
	end
	return string.find(path, pattern) ~= nil
end

-- Whether deploy.xml deploys `path` (relative to the project root) through
-- one of the section's paths. False without a deploy.xml.
function M.isDeployed(project: Project, section: DeploySection, path: string): boolean
	local deploy = project.deploy
	if deploy == nil then
		return false
	end
	for _, p in deploy.paths do
		if p.section == section and M.covers(p, path) then
			return true
		end
	end
	return false
end

-- "[scriptid=x]", "[type=t, scriptid=x]" and "[/SuiteScripts/x.js]".
local function scanReferences(node: Node, refs: { Reference }, files: { FileReference })
	for inner in string.gmatch(node.text, "%[([^%[%]\n]+)%]") do
		if string.sub(inner, 1, 1) == "/" then
			table.insert(files, { path = inner, line = node.line })
		else
			local fields: { [string]: string } = {}
			for part in string.gmatch(inner, "[^,]+") do
				local k, v = string.match(part, "^%s*([%w_]+)%s*=%s*(.-)%s*$")
				if k and v then
					fields[string.lower(k)] = v
				end
			end
			local id = fields.scriptid
			if id and id ~= "" then
				table.insert(refs, { scriptId = id, type = fields.type, line = node.line })
			end
		end
	end
	for _, c in node.children do
		scanReferences(c, refs, files)
	end
end

local function deployments(root: Node): { Deployment }
	local out: { Deployment } = {}
	for _, d in Xml.descendants(root, "scriptdeployment") do
		local deployed = optionalText(d, "isdeployed")
		table.insert(out, {
			scriptId = d.attrs.scriptid or "",
			status = optionalText(d, "status"),
			logLevel = optionalText(d, "loglevel"),
			recordType = optionalText(d, "recordtype"),
			isDeployed = if deployed == "T" then true elseif deployed == "F" then false else nil,
			title = optionalText(d, "title"),
			line = d.line,
		})
	end
	return out
end

-- Nested scriptids, bare and as dotted paths through scriptid ancestors.
local function nestedIds(root: Node): ({ string }, { string })
	local ids: { string } = {}
	local paths: { string } = {}
	local function walk(n: Node, prefix: string)
		for _, c in n.children do
			local id = c.attrs.scriptid
			local inner = prefix
			if id and id ~= "" then
				table.insert(ids, id)
				inner = prefix .. id
				table.insert(paths, inner)
				inner ..= "."
			end
			walk(c, inner)
		end
	end
	walk(root, "")
	return ids, paths
end

local function parseObject(file: SnapshotFile, root: Node): SdfObject
	local refs: { Reference } = {}
	local fileRefs: { FileReference } = {}
	scanReferences(root, refs, fileRefs)
	local children, childPaths = nestedIds(root)
	return {
		scriptId = root.attrs.scriptid or "",
		type = root.tag,
		path = file.path,
		real = file.real,
		line = root.line,
		isScript = Xml.child(root, "scriptfile") ~= nil,
		children = children,
		childPaths = childPaths,
		references = refs,
		fileReferences = fileRefs,
		deployments = deployments(root),
	}
end

local function hidden(rel: string): boolean
	return string.find("/" .. rel, "/%.") ~= nil
end

local function deepFreeze(v: any): any
	if type(v) == "table" and not table.isfrozen(v) then
		for _, x in v do
			deepFreeze(x)
		end
		table.freeze(v)
	end
	return v
end

function M.build(snapshot: Snapshot): Project
	local diags: { Diagnostic } = {}
	local function diag(d: Diagnostic)
		table.insert(diags, d)
	end
	local problems: { Snapshot.Problem } = snapshot.problems or {}
	for _, p in problems do
		diag({ severity = "warning", code = "scan", message = p.message, path = p.path })
	end

	local byPath: { [string]: SnapshotFile } = {}
	local paths: { string } = {}
	for _, f in snapshot.files do
		byPath[f.path] = f
		table.insert(paths, f.path)
	end
	table.sort(paths)

	local config = byPath["suitecloud.config.js"]
	local folder = M.projectFolder(if config then config.text else nil)
	local pj = byPath["project.json"]
	local prefix = folder .. "/"

	local function parse(file: SnapshotFile): Node?
		if file.text == nil then
			diag({
				severity = "warning",
				code = "file-unread",
				message = string.format("%s was not read (%d bytes)", file.path, file.size),
				path = file.path,
			})
			return nil
		end
		local node, err = Xml.parse(file.text)
		if node == nil and err then
			diag({
				severity = "error",
				code = "xml-parse",
				message = err.message,
				path = file.path,
				line = err.line,
				col = err.col,
			})
		end
		return node
	end

	local manifest: Manifest? = nil
	local manifestFile = byPath[prefix .. "manifest.xml"]
	if manifestFile == nil then
		diag({
			severity = "error",
			code = "missing-manifest",
			message = string.format("%smanifest.xml not found; the project cannot be validated or deployed", prefix),
		})
	else
		local node = parse(manifestFile)
		if node then
			manifest = parseManifest(manifestFile.path, node)
		end
	end

	local deploy: Deploy? = nil
	local deployFile = byPath[prefix .. "deploy.xml"]
	if deployFile == nil then
		diag({
			severity = "error",
			code = "missing-deploy",
			message = string.format("%sdeploy.xml not found; nothing would be deployed", prefix),
		})
	else
		local node = parse(deployFile)
		if node then
			deploy = parseDeploy(deployFile.path, node, folder)
		end
	end

	local objects: { SdfObject } = {}
	local files: { File } = {}
	local objectsPrefix = prefix .. "Objects/"
	local cabinetPrefix = prefix .. "FileCabinet/"
	for _, path in paths do
		local f = byPath[path]
		if string.sub(path, 1, #objectsPrefix) == objectsPrefix then
			if string.lower(string.sub(path, -4)) == ".xml" and not hidden(string.sub(path, #objectsPrefix + 1)) then
				local node = parse(f)
				if node then
					local object = parseObject(f, node)
					if object.scriptId == "" then
						diag({
							severity = "error",
							code = "object-scriptid",
							message = string.format("<%s> has no scriptid attribute", node.tag),
							path = path,
							line = node.line,
						})
					else
						table.insert(objects, object)
						local stem = string.sub(basename(path), 1, -5)
						if stem ~= object.scriptId then
							diag({
								severity = "warning",
								code = "object-filename",
								message = string.format(
									"file name %s does not match scriptid %s; SDF expects %s.xml",
									basename(path),
									object.scriptId,
									object.scriptId
								),
								path = path,
								line = node.line,
							})
						end
					end
				end
			end
		elseif string.sub(path, 1, #cabinetPrefix) == cabinetPrefix then
			local rest = string.sub(path, #cabinetPrefix + 1)
			if not hidden(rest) then
				table.insert(files, { path = path, real = f.real, size = f.size, fileCabinetPath = "/" .. rest })
			end
		end
	end

	return deepFreeze({
		name = basename(snapshot.root),
		root = snapshot.root,
		projectFolder = folder,
		defaultAuthId = M.defaultAuthId(if pj then pj.text else nil),
		manifest = manifest,
		deploy = deploy,
		objects = objects,
		files = files,
		paths = paths,
		truncated = snapshot.truncated == true,
		diagnostics = diags,
	})
end

-- The object with a scriptid, or nil.
function M.object(project: Project, scriptId: string): SdfObject?
	for _, o in project.objects do
		if o.scriptId == scriptId then
			return o
		end
	end
	return nil
end

-- The File Cabinet file at a File Cabinet path ("/SuiteScripts/x.js"), or nil.
function M.file(project: Project, fileCabinetPath: string): File?
	for _, f in project.files do
		if f.fileCabinetPath == fileCabinetPath then
			return f
		end
	end
	return nil
end

return table.freeze(M)
