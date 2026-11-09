--!strict
-- A synthetic Acme billing project for the drift specs: three custom lists
-- (one formatted differently from the account's export, one changed, one
-- not in the account) and two File Cabinet scripts.

local Config = require("../../../plugin/lib/config")
local Project = require("../../../plugin/lib/sdf/project")
local Snapshot = require("../../../plugin/lib/sdf/snapshot")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")

type SnapshotFile = Snapshot.SnapshotFile

local M = {}

M.ROOT = "/work/acme/billing"
M.DIR = "/data/drift/work/run-1"

M.CONFIG_JS = "module.exports = { defaultProjectFolder: 'src', commands: {} };"

local MANIFEST = [[<manifest projecttype="ACCOUNTCUSTOMIZATION">
  <projectname>billing</projectname>
  <frameworkversion>1.0</frameworkversion>
</manifest>]]

local SUITEAPP = [[<manifest projecttype="SUITEAPP">
  <publisherid>com.acme</publisherid>
  <projectid>billing</projectid>
  <projectname>billing</projectname>
  <projectversion>1.0.0</projectversion>
  <frameworkversion>1.0</frameworkversion>
</manifest>]]

local DEPLOY = [[<deploy>
  <files><path>~/FileCabinet/SuiteScripts/*</path></files>
  <objects><path>~/Objects/*</path></objects>
</deploy>]]

M.MISSING = [[<customlist scriptid="customlist_acme_missing">
  <name>Acme Missing</name>
</customlist>]]

M.FILES = { "/SuiteScripts/acme/acme_orders_ue.js", "/SuiteScripts/acme/acme_missing.js" }

M.CFG = Config.parse(
	[[{
	"suitecloud": { "program": "/opt/bin/suitecloud", "timeout_ms": 90000 },
	"accounts": [
		{ "id": "sandbox", "label": "SB1", "account_id": "1234567_SB1", "auth_ids": ["demo-sb"] },
		{ "id": "prod", "label": "PROD", "account_id": "1234567", "auth_ids": ["demo-prod"], "production": true }
	]
}]],
	json.decode
)

local function text(path: string, body: string): SnapshotFile
	return { path = path, size = #body, text = body }
end

export type Opts = { suiteApp: boolean?, authId: string? }

-- The project and the texts a scan read (paths relative to the root).
function M.project(opts: Opts?): (Project.Project, { [string]: string })
	local o: Opts = opts or {}
	local files: { SnapshotFile } = {
		text("suitecloud.config.js", M.CONFIG_JS),
		text("project.json", '{ "defaultAuthId": "' .. (o.authId or "demo-sb") .. '" }'),
		text("src/manifest.xml", if o.suiteApp then SUITEAPP else MANIFEST),
		text("src/deploy.xml", DEPLOY),
		text("src/Objects/customlist_acme_sizes.xml", fixtures.read("drift/local/customlist_acme_sizes.xml")),
		text("src/Objects/customlist_acme_colors.xml", fixtures.read("drift/local/customlist_acme_colors.xml")),
		text("src/Objects/customlist_acme_missing.xml", M.MISSING),
		{ path = "src/FileCabinet/SuiteScripts/acme/acme_orders_ue.js", size = 10 },
		{ path = "src/FileCabinet/SuiteScripts/acme/acme_missing.js", size = 10 },
	}
	local project = Project.build({ root = M.ROOT, files = files })
	local texts: { [string]: string } = {}
	for _, f in files do
		if f.text then
			texts[f.path] = f.text
		end
	end
	return project, texts
end

return M
