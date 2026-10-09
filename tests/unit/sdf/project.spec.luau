--!strict
local Project = require("../../../plugin/lib/sdf/project")
local Snapshot = require("../../../plugin/lib/sdf/snapshot")
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

type Snapshot = Snapshot.Snapshot
type SnapshotFile = Snapshot.SnapshotFile

-- A fixture project as a scan would deliver it from /repo/sdf/<name>.
local function fromFixture(name: string): Snapshot
	local prefix = "projects/" .. name .. "/"
	local folder = Project.projectFolder(
		if fixtures.has(prefix .. "suitecloud.config.js") then fixtures.read(prefix .. "suitecloud.config.js") else nil
	)
	local files: { SnapshotFile } = {}
	for _, key in fixtures.list(prefix) do
		local path = string.sub(key, #prefix + 1)
		local text = fixtures.read(key)
		table.insert(files, {
			path = path,
			size = #text,
			text = if Snapshot.wantsText(path, folder) then text else nil,
		})
	end
	return { root = "/repo/sdf/" .. name, files = files }
end

-- Inline snapshot: string values are file contents, numbers are sizes of
-- files whose contents are not read.
local function snap(files: { [string]: string | number }): Snapshot
	local list: { SnapshotFile } = {}
	for path, v in files do
		if type(v) == "string" then
			table.insert(list, { path = path, size = #v, text = v })
		else
			table.insert(list, { path = path, size = v :: number })
		end
	end
	return { root = "/work/demo", files = list }
end

local DEPLOY = "<deploy><files><path>~/FileCabinet/*</path></files><objects><path>~/Objects/*</path></objects></deploy>"
local MANIFEST = '<manifest projecttype="ACCOUNTCUSTOMIZATION"><projectname>demo</projectname></manifest>'

describe("project settings", function()
	it("reads defaultProjectFolder however the config quotes it", function()
		expect(Project.projectFolder("module.exports = {\n\tdefaultProjectFolder: 'src',\n};")).toBe("src")
		expect(Project.projectFolder('module.exports = { "defaultProjectFolder": "source/" }')).toBe("source")
		expect(Project.projectFolder("module.exports = { defaultProjectFolder: `./app` }")).toBe("app")
	end)

	it("ignores a commented-out folder and falls back to src, as the CLI does", function()
		local js = "module.exports = {\n\t// defaultProjectFolder: 'old',\n\t/* defaultProjectFolder: 'older' */\n};"
		expect(Project.projectFolder(js)).toBe("src")
		expect(Project.projectFolder(nil)).toBe("src")
	end)

	it("reads the folder from a real config that also wires a Jest runner", function()
		expect(Project.build(fromFixture("orders")).projectFolder).toBe("src")
	end)

	it("reads the default auth ID so commands can show which account they target", function()
		expect(Project.build(fromFixture("orders")).defaultAuthId).toBe("demo-sb")
		expect(Project.build(fromFixture("tables")).defaultAuthId).toBeNil()
	end)

	it("names a project after its directory", function()
		expect(Project.build(fromFixture("orders")).name).toBe("orders")
		expect(Project.build(fromFixture("orders")).root).toBe("/repo/sdf/orders")
	end)
end)

describe("manifest.xml", function()
	it("reads project type, name and features with their required flag", function()
		local m = Project.build(fromFixture("orders")).manifest :: Project.Manifest
		expect(m.projectType).toBe("ACCOUNTCUSTOMIZATION")
		expect(m.projectName).toBe("orders")
		expect(m.frameworkVersion).toBe("1.0")
		expect(m.dependencies.features[1]).toEqual({ name = "SERVERSIDESCRIPTING", required = true })
		expect(m.dependencies.features[2]).toEqual({ name = "MARKETING", required = false })
	end)

	it("reads object dependencies, dotted child ids included", function()
		local m = Project.build(fromFixture("tables")).manifest :: Project.Manifest
		expect(m.dependencies.objects).toContain("customrecord_cseg_acme_warehouse.custrecord_acme_cs_zip")
		expect(m.dependencies.objects).toContain("customrecord_cseg_acme_warehouse")
	end)

	it("reads SuiteApp identity and application, bundle and file dependencies", function()
		local p = Project.build(snap({
			["suitecloud.config.js"] = "module.exports = { defaultProjectFolder: 'src' };",
			["src/manifest.xml"] = [[<manifest projecttype="SUITEAPP">
  <publisherid>com.example</publisherid>
  <projectid>demo</projectid>
  <projectname>Demo</projectname>
  <projectversion>1.2.0</projectversion>
  <dependencies>
    <files><file>/SuiteScripts/lib/shared.js</file></files>
    <applications>
      <application id="com.example.base">
        <objects><object>customrecord_base</object></objects>
        <files><file>/SuiteApps/com.example.base/x.js</file></files>
      </application>
    </applications>
    <bundles>
      <bundle id="123456"><objects><object>customlist_bundled</object></objects></bundle>
    </bundles>
  </dependencies>
</manifest>]],
			["src/deploy.xml"] = DEPLOY,
		}))
		local m = p.manifest :: Project.Manifest
		expect(m.projectType).toBe("SUITEAPP")
		expect(m.publisherId).toBe("com.example")
		expect(m.projectId).toBe("demo")
		expect(m.projectVersion).toBe("1.2.0")
		expect(m.dependencies.files).toEqual({ "/SuiteScripts/lib/shared.js" })
		expect(m.dependencies.applications).toEqual({
			{
				id = "com.example.base",
				objects = { "customrecord_base" },
				files = { "/SuiteApps/com.example.base/x.js" },
			},
		})
		expect(m.dependencies.bundles).toEqual({ { id = "123456", objects = { "customlist_bundled" }, files = {} } })
	end)
end)

describe("deploy.xml", function()
	it("reads every section's paths with their lines", function()
		local d = Project.build(fromFixture("warehouses")).deploy :: Project.Deploy
		expect(d.paths[1]).toEqual({
			section = "configuration",
			pattern = "~/AccountConfiguration/*",
			target = "src/AccountConfiguration/*",
			line = 3,
		})
		local sections = {}
		for _, p in d.paths do
			sections[p.section] = (sections[p.section] or 0) + 1
		end
		expect(sections).toEqual({ configuration = 1, files = 3, objects = 1, translationimports = 1 })
	end)

	it("treats a trailing * as the whole folder, subfolders included", function()
		local p = Project.build(fromFixture("orders"))
		expect(
			Project.isDeployed(p, "files", "src/FileCabinet/SuiteScripts/user-events/shipping/print_label_button.js")
		).toBe(true)
		expect(Project.isDeployed(p, "objects", "src/FileCabinet/SuiteScripts/map-reduce/order_sync.js")).toBe(false)
	end)

	it("matches exact file paths and folder paths without a wildcard", function()
		local p = Project.build(snap({
			["src/manifest.xml"] = MANIFEST,
			["src/deploy.xml"] = "<deploy><files><path>~/FileCabinet/SuiteScripts/a.js</path>"
				.. "<path>~/FileCabinet/SuiteScripts/lib</path></files></deploy>",
		}))
		expect(Project.isDeployed(p, "files", "src/FileCabinet/SuiteScripts/a.js")).toBe(true)
		expect(Project.isDeployed(p, "files", "src/FileCabinet/SuiteScripts/a.jsx")).toBe(false)
		expect(Project.isDeployed(p, "files", "src/FileCabinet/SuiteScripts/lib/b.js")).toBe(true)
		expect(Project.isDeployed(p, "files", "src/FileCabinet/SuiteScripts/library.js")).toBe(false)
	end)

	it("expands ~/ to a custom project folder", function()
		local p = Project.build({
			root = "/w/x",
			files = {
				{ path = "suitecloud.config.js", size = 1, text = 'module.exports = { defaultProjectFolder: "app" }' },
				{ path = "app/manifest.xml", size = 1, text = MANIFEST },
				{ path = "app/deploy.xml", size = 1, text = DEPLOY },
				{ path = "app/Objects/customlist_x.xml", size = 1, text = '<customlist scriptid="customlist_x"/>' },
			},
		})
		expect(#p.objects).toBe(1)
		expect(Project.isDeployed(p, "objects", "app/Objects/customlist_x.xml")).toBe(true)
	end)
end)

describe("objects", function()
	it("reads a script's type, script file and deployments", function()
		local p = Project.build(fromFixture("orders"))
		local o = Project.object(p, "customscript_demo_order_sync") :: Project.SdfObject
		expect(o.type).toBe("mapreducescript")
		expect(o.isScript).toBe(true)
		expect(o.path).toBe("src/Objects/customscript_demo_order_sync.xml")
		expect(o.fileReferences).toEqual({ { path = "/SuiteScripts/map-reduce/order_sync.js", line = 8 } })
		expect(o.deployments).toEqual({
			{
				scriptId = "customdeploy_demo_order_sync",
				status = "NOTSCHEDULED",
				logLevel = "AUDIT",
				recordType = nil,
				isDeployed = true,
				title = "Order Sync",
				line = 66,
			},
		})
		expect(o.children).toContain("custscript_demo_os_dry_run")
	end)

	it("reads the record a user event is deployed to", function()
		local p = Project.build(fromFixture("orders"))
		local o = Project.object(p, "customscript_demo_print_label_button") :: Project.SdfObject
		expect(o.deployments[1].recordType).toBe("SALESORDER")
		expect(o.deployments[1].status).toBe("RELEASED")
		expect(o.deployments[1].logLevel).toBe("ERROR")
	end)

	it("collects scriptid references wherever they appear, with their line", function()
		local p = Project.build(fromFixture("warehouses"))
		local o = Project.object(p, "customscript_demo_warehouse_stock_subtab") :: Project.SdfObject
		expect(o.references).toEqual({ { scriptId = "customrecord_cseg_acme_warehouse", line = 19 } })
		local field =
			Project.object(Project.build(fromFixture("orders")), "custbody_demo_order_channel") :: Project.SdfObject
		expect(field.type).toBe("transactionbodycustomfield")
		expect(field.isScript).toBe(false)
		expect(field.references[1].scriptId).toBe("customlist_demo_order_channel")
	end)

	it("reads typed and dotted references", function()
		local p = Project.build(snap({
			["src/manifest.xml"] = MANIFEST,
			["src/deploy.xml"] = DEPLOY,
			["src/Objects/customsearch_x.xml"] = [[<savedsearch scriptid="customsearch_x">
  <definition><f>[type=itemcustomfield, scriptid=cseg_demo_product]</f>
  <g>[scriptid=customlist_demo.val_1]|[scriptid=customlist_other]</g></definition>
</savedsearch>]],
		}))
		local o = p.objects[1]
		local expected: { Project.Reference } = {
			{ scriptId = "cseg_demo_product", type = "itemcustomfield", line = 2 },
			{ scriptId = "customlist_demo.val_1", line = 3 },
			{ scriptId = "customlist_other", line = 3 },
		}
		expect(o.references).toEqual(expected)
	end)

	it("reports an object file without a scriptid or named differently, which SDF rejects", function()
		local p = Project.build(snap({
			["src/manifest.xml"] = MANIFEST,
			["src/deploy.xml"] = DEPLOY,
			["src/Objects/a.xml"] = "<customlist><name>x</name></customlist>",
			["src/Objects/b.xml"] = '<customlist scriptid="customlist_b"/>',
		}))
		local codes = {}
		for _, d in p.diagnostics do
			table.insert(codes, d.code)
		end
		table.sort(codes)
		expect(codes).toEqual({ "object-filename", "object-scriptid" })
		expect(#p.objects).toBe(1)
	end)

	it("records nested scriptids with their dotted path, as references name them", function()
		local p = Project.build(snap({
			["src/manifest.xml"] = MANIFEST,
			["src/deploy.xml"] = DEPLOY,
			["src/Objects/customworkflow_w.xml"] = '<workflow scriptid="customworkflow_w"><workflowstates>'
				.. '<workflowstate scriptid="workflowstate_a"><workflowactions>'
				.. '<sendemailaction scriptid="workflowaction_mail"/></workflowactions></workflowstate>'
				.. "</workflowstates></workflow>",
		}))
		local o = p.objects[1]
		expect(o.children).toEqual({ "workflowstate_a", "workflowaction_mail" })
		expect(o.childPaths).toEqual({ "workflowstate_a", "workflowstate_a.workflowaction_mail" })
	end)
end)

describe("scan limits", function()
	it("keeps config, manifest, deploy and object XML however many other files a project has", function()
		local paths = { "suitecloud.config.js", "src/deploy.xml", "src/manifest.xml", "src/Objects/customlist_a.xml" }
		for i = 1, 20 do
			table.insert(paths, string.format("src/FileCabinet/SuiteScripts/f%02d.js", i))
		end
		local kept, truncated = Snapshot.limit(paths, "src", 6)
		expect(truncated).toBe(true)
		expect(kept).toEqual({
			"src/FileCabinet/SuiteScripts/f01.js",
			"src/FileCabinet/SuiteScripts/f02.js",
			"src/Objects/customlist_a.xml",
			"src/deploy.xml",
			"src/manifest.xml",
			"suitecloud.config.js",
		})
	end)

	it("keeps everything under the limit", function()
		local kept, truncated = Snapshot.limit({ "src/b.js", "src/a.js" }, "src", 2)
		expect(truncated).toBe(false)
		expect(kept).toEqual({ "src/a.js", "src/b.js" })
	end)
end)

describe("File Cabinet files", function()
	it("maps project files to their File Cabinet path and keeps symlink targets", function()
		local s = fromFixture("orders")
		local files = table.clone(s.files)
		table.insert(files, {
			path = "src/FileCabinet/SuiteScripts/common/x.js",
			real = "/repo/netsuite/common/x.js",
			size = 10,
		})
		local p = Project.build({ root = s.root, files = files })
		local f = Project.file(p, "/SuiteScripts/common/x.js") :: Project.File
		expect(f.path).toBe("src/FileCabinet/SuiteScripts/common/x.js")
		expect(f.real).toBe("/repo/netsuite/common/x.js")
		expect(f.size).toBe(10)
		expect(Project.file(p, "/SuiteScripts/map-reduce/order_sync.js") ~= nil).toBe(true)
	end)

	it("leaves out hidden files such as .attributes metadata and .gitkeep", function()
		local p = Project.build(snap({
			["src/manifest.xml"] = MANIFEST,
			["src/deploy.xml"] = DEPLOY,
			["src/FileCabinet/SuiteScripts/.attributes/folder.attr.xml"] = 10,
			["src/FileCabinet/SuiteScripts/lib/.gitkeep"] = 0,
			["src/FileCabinet/SuiteScripts/lib/a.js"] = 5,
		}))
		expect(#p.files).toBe(1)
		expect(p.files[1].fileCabinetPath).toBe("/SuiteScripts/lib/a.js")
	end)
end)

describe("problems become diagnostics instead of errors", function()
	it("reports malformed XML with its position and still models the rest", function()
		local p = Project.build(snap({
			["src/manifest.xml"] = MANIFEST,
			["src/deploy.xml"] = DEPLOY,
			["src/Objects/customlist_bad.xml"] = '<customlist scriptid="customlist_bad">\n  <name>x</nam>\n</customlist>',
			["src/Objects/customlist_ok.xml"] = '<customlist scriptid="customlist_ok"/>',
		}))
		expect(#p.objects).toBe(1)
		local d = p.diagnostics[1]
		expect(d.code).toBe("xml-parse")
		expect(d.severity).toBe("error")
		expect(d.path).toBe("src/Objects/customlist_bad.xml")
		expect(d.line).toBe(2)
	end)

	it("reports a missing manifest.xml and deploy.xml", function()
		local p = Project.build(snap({ ["suitecloud.config.js"] = "module.exports = {};" }))
		local codes = {}
		for _, d in p.diagnostics do
			table.insert(codes, d.code)
		end
		expect(codes).toEqual({ "missing-manifest", "missing-deploy" })
		expect(p.manifest).toBeNil()
		expect(p.deploy).toBeNil()
	end)

	it("carries scan problems and truncation through", function()
		local s =
			snap({ ["src/manifest.xml"] = MANIFEST, ["src/deploy.xml"] = DEPLOY, ["src/Objects/big.xml"] = 9999999 })
		local p = Project.build({
			root = s.root,
			files = s.files,
			truncated = true,
			problems = { { path = "src/Objects/big.xml", message = "too large" } },
		})
		expect(p.truncated).toBe(true)
		expect(p.diagnostics[1].code).toBe("scan")
		expect(p.diagnostics[2].code).toBe("file-unread")
	end)

	it("returns a frozen model so shared projects cannot be altered by one view", function()
		local p = Project.build(fromFixture("orders"))
		expect(table.isfrozen(p)).toBe(true)
		expect(table.isfrozen(p.objects[1].references)).toBe(true)
	end)
end)

return nil
