--!strict
-- A synthetic SDF project for the browser specs: one restlet that is also
-- in the account fixture (customscript_demo_89), one local-only list in a
-- subfolder of Objects, a File Cabinet file the file:list fixture also has
-- and one that exists only locally.

local Project = require("../../../plugin/lib/sdf/project")
local Snapshot = require("../../../plugin/lib/sdf/snapshot")

type SnapshotFile = Snapshot.SnapshotFile

local M = {}

M.ROOT = "/work/proj/demo"

local CONFIG = "module.exports = { defaultProjectFolder: 'src', commands: {} };"
local MANIFEST = [[<manifest projecttype="ACCOUNTCUSTOMIZATION">
    <projectname>demo</projectname>
    <frameworkversion>1.0</frameworkversion>
</manifest>]]
local DEPLOY = [[<deploy>
    <files>
        <path>~/FileCabinet/SuiteScripts/*</path>
    </files>
    <objects>
        <path>~/Objects/*</path>
    </objects>
</deploy>]]

local RESTLET = [[<restlet scriptid="customscript_demo_89">
    <name>Demo</name>
    <scriptfile>[/SuiteScripts/tns_demo/tns_demo_restlet.js]</scriptfile>
</restlet>]]

local LIST = [[<customlist scriptid="customlist_local_only">
    <name>Local</name>
</customlist>]]

local function text(path: string, body: string): SnapshotFile
	return { path = path, size = #body, text = body }
end

function M.snapshot(authId: string?): Snapshot.Snapshot
	local files: { SnapshotFile } = {
		text("suitecloud.config.js", CONFIG),
		text("src/manifest.xml", MANIFEST),
		text("src/deploy.xml", DEPLOY),
		text("src/Objects/customscript_demo_89.xml", RESTLET),
		text("src/Objects/lists/customlist_local_only.xml", LIST),
		{ path = "src/FileCabinet/SuiteScripts/tns_demo/tns_demo_restlet.js", size = 10 },
		{ path = "src/FileCabinet/SuiteScripts/local_only.js", size = 10 },
	}
	if authId then
		table.insert(files, text("project.json", '{ "defaultAuthId": "' .. authId .. '" }'))
	end
	return { root = M.ROOT, files = files }
end

function M.project(authId: string?): Project.Project
	return Project.build(M.snapshot(authId))
end

return M
