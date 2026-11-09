--!strict
-- The temporary SDF project a drift run imports into. The CLI reads
-- ./suitecloud.config.js and ./project.json, writes imports under the
-- project folder and takes the auth ID from project.json, so the scratch
-- project is a generated suitecloud.config.js naming only the project
-- folder (never the user's file: its hooks must not run during drift), a
-- project.json naming the chosen auth ID, the user's manifest.xml (it names
-- a SuiteApp's application ID) and empty Objects/ and FileCabinet/
-- folders. object:import and file:import need no deploy.xml. The user's
-- project is never written: imports land only in the scratch directory,
-- which the host creates under the plugin's data directory and removes
-- after the run.

local CliSlot = require("../sdf/cli_slot")

export type Write = {
	-- Relative to the scratch root.
	path: string,
	text: string,
}

export type Plan = {
	-- Relative to the scratch root, created before the writes.
	dirs: { string },
	writes: { Write },
}

-- Project texts the scan read (paths relative to the project root).
export type Texts = { [string]: string }

local M = {}

M.CONFIG = "suitecloud.config.js"
M.PROJECT_JSON = "project.json"
M.DIR = "drift/work"

-- Why `folder` (defaultProjectFolder) cannot hold the scratch copies.
local function badFolder(folder: string): string?
	if folder == "" or string.sub(folder, 1, 1) == "/" or string.find(folder, "[%c\"'\\]") then
		return "the project folder " .. CliSlot.printable(folder) .. " is not a relative folder name"
	end
	for part in string.gmatch(folder, "[^/]+") do
		if part == "." or part == ".." then
			return "the project folder " .. folder .. " leaves the project"
		end
	end
	return nil
end

function M.unsafeAuthId(authId: string): string?
	if #authId > 128 or not string.find(authId, "^[%w_][%w_%.%-]*$") then
		return "the auth ID " .. CliSlot.printable(authId) .. " has characters project.json cannot carry safely"
	end
	return nil
end

function M.projectJson(authId: string): string
	return '{\n  "defaultAuthId": "' .. authId .. '"\n}\n'
end

-- The generated config: `folder` passed badFolder, so it needs no escaping.
function M.config(folder: string): string
	return 'module.exports = {\n\tdefaultProjectFolder: "' .. folder .. '",\n};\n'
end

function M.plan(texts: Texts, projectFolder: string, authId: string): (Plan?, string?)
	local why = badFolder(projectFolder) or M.unsafeAuthId(authId)
	if why then
		return nil, why
	end
	local manifest = texts[projectFolder .. "/manifest.xml"]
	if manifest == nil then
		return nil, projectFolder .. "/manifest.xml could not be read"
	end
	local writes: { Write } = {
		{ path = M.CONFIG, text = M.config(projectFolder) },
		{ path = M.PROJECT_JSON, text = M.projectJson(authId) },
		{ path = projectFolder .. "/manifest.xml", text = manifest },
	}
	return { dirs = { projectFolder .. "/Objects", projectFolder .. "/FileCabinet" }, writes = writes }, nil
end

-- Where object:import writes `scriptId` (relative to the scratch root).
function M.objectPath(projectFolder: string, scriptId: string): string
	return projectFolder .. "/Objects/" .. scriptId .. ".xml"
end

-- Where file:import writes File Cabinet `path` ("/SuiteScripts/x.js").
function M.filePath(projectFolder: string, path: string): string
	return projectFolder .. "/FileCabinet" .. path
end

return table.freeze(M)
