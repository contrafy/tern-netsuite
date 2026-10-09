--!strict
-- Synthetic SDF projects for the explorer specs: two projects sharing a
-- symlinked library file, one script object with a deployment and a missing
-- script file, and a third project with no project.json.

local Snapshot = require("../../../plugin/lib/sdf/snapshot")

type SnapshotFile = Snapshot.SnapshotFile

local M = {}

M.REPO = "/repo"
M.SHARED = "/repo/netsuite/lib/http.js"

local CONFIG = "module.exports = { defaultProjectFolder: 'src', commands: {} };"
local DEPLOY = [[<deploy>
    <configuration>
        <path>~/AccountConfiguration/*</path>
    </configuration>
    <files>
        <path>~/FileCabinet/SuiteScripts/*</path>
    </files>
    <objects>
        <path>~/Objects/*</path>
    </objects>
</deploy>]]

local function manifest(name: string): string
	return '<manifest projecttype="ACCOUNTCUSTOMIZATION">\n    <projectname>'
		.. name
		.. '</projectname>\n    <frameworkversion>1.0</frameworkversion>\n    <dependencies>\n        <features>\n            <feature required="true">SERVERSIDESCRIPTING</feature>\n        </features>\n    </dependencies>\n</manifest>'
end

local function script(id: string, file: string, deploy: string): string
	return '<usereventscript scriptid="'
		.. id
		.. '">\n    <name>'
		.. id
		.. "</name>\n    <scriptfile>["
		.. file
		.. ']</scriptfile>\n    <scriptdeployments>\n        <scriptdeployment scriptid="'
		.. deploy
		.. '">\n            <isdeployed>T</isdeployed>\n            <loglevel>DEBUG</loglevel>\n            <recordtype>SALESORDER</recordtype>\n            <status>RELEASED</status>\n        </scriptdeployment>\n    </scriptdeployments>\n</usereventscript>'
end

local function text(path: string, body: string, real: string?): SnapshotFile
	return { path = path, size = #body, text = body, real = real }
end

local function file(path: string, real: string?): SnapshotFile
	return { path = path, size = 10, real = real }
end

local function base(name: string, authId: string?): { SnapshotFile }
	local files = {
		text("suitecloud.config.js", CONFIG),
		text("src/manifest.xml", manifest(name)),
		text("src/deploy.xml", DEPLOY),
	}
	if authId then
		table.insert(files, 2, text("project.json", '{"defaultAuthId": "' .. authId .. '"}'))
	end
	return files
end

function M.snapshot(name: string): Snapshot.Snapshot
	local root = M.REPO .. "/sdf/" .. name
	local files: { SnapshotFile }
	if name == "billing" then
		files = base("billing", "demo-sb")
		table.insert(files, file("src/FileCabinet/SuiteScripts/billing/ue.js"))
		table.insert(files, file("src/FileCabinet/SuiteScripts/lib/http.js", M.SHARED))
		table.insert(
			files,
			text(
				"src/Objects/customscript_billing_ue.xml",
				script("customscript_billing_ue", "/SuiteScripts/billing/ue.js", "customdeploy_billing_ue")
			)
		)
		table.insert(
			files,
			text(
				"src/Objects/customscript_billing_gone.xml",
				script("customscript_billing_gone", "/SuiteScripts/billing/gone.js", "customdeploy_billing_gone")
			)
		)
	elseif name == "storefront" then
		files = base("storefront", "PRODUCTION")
		table.insert(files, file("src/FileCabinet/SuiteScripts/storefront/app.js"))
		table.insert(files, file("src/FileCabinet/SuiteScripts/storefront/lib/http.js", M.SHARED))
	else
		files = base(name, nil)
		table.insert(files, file("src/FileCabinet/SuiteScripts/" .. name .. "/only.js"))
		-- Same File Cabinet path as billing's shared library, other source.
		table.insert(files, file("src/FileCabinet/SuiteScripts/lib/http.js"))
	end
	return { root = root, files = files }
end

M.ROOTS = { "/repo/sdf/billing", "/repo/sdf/legacy", "/repo/sdf/storefront" }

return M
