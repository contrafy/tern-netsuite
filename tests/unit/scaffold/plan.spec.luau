--!strict
local Diff = require("../../../plugin/lib/scaffold/diff")
local Plan = require("../../../plugin/lib/scaffold/plan")
local Project = require("../../../plugin/lib/sdf/project")
local Snapshot = require("../../../plugin/lib/sdf/snapshot")
local Xml = require("../../../plugin/lib/sdf/xml")
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

type Form = Plan.Form
type SnapshotFile = Snapshot.SnapshotFile

-- A fixture project ("projects/orders", "scaffold/acp") as a scan delivers it,
-- plus the deploy.xml / manifest.xml texts the adapter hands the planner.
local function load(prefix: string, extra: { [string]: string }?): (Project.Project, Plan.Inputs)
	local base = prefix .. "/"
	local folder = Project.projectFolder(
		if fixtures.has(base .. "suitecloud.config.js") then fixtures.read(base .. "suitecloud.config.js") else nil
	)
	local texts: { [string]: string } = {}
	for _, key in fixtures.list(base) do
		texts[string.sub(key, #base + 1)] = fixtures.read(key)
	end
	local more: { [string]: string } = extra or {}
	for path, text in more do
		texts[path] = text
	end
	local files: { SnapshotFile } = {}
	for path, text in texts do
		table.insert(
			files,
			{ path = path, size = #text, text = if Snapshot.wantsText(path, folder) then text else nil }
		)
	end
	local project = Project.build({ root = "/work/" .. prefix, files = files })
	return project, { deployText = texts[folder .. "/deploy.xml"], manifestText = texts[folder .. "/manifest.xml"] }
end

local function form(scriptType: string, overrides: { [string]: any }?): Form
	local f: Form = {
		scriptType = scriptType,
		name = "Demo Script",
		scriptIdSuffix = "demo_" .. scriptType,
		fileName = "demo_" .. scriptType .. ".js",
		folder = "/SuiteScripts/demo",
		deploy = { status = "TESTING", logLevel = "DEBUG", recordType = "SALESORDER", title = nil },
	}
	local given: { [string]: any } = overrides or {}
	for k, v in given do
		if k == "deploy" then
			for dk, dv in v do
				(f.deploy :: any)[dk] = dv
			end
		else
			(f :: any)[k] = v
		end
	end
	return f
end

local function plan(project: Project.Project, f: Form, inputs: Plan.Inputs?): Plan.Plan
	local p, problems = Plan.plan(project, f, inputs)
	if p == nil then
		local messages = {}
		for _, pr in problems do
			table.insert(messages, pr.field .. ": " .. pr.message)
		end
		error("unexpected problems: " .. table.concat(messages, "; "), 2)
	end
	return p
end

local function problems(project: Project.Project, f: Form, inputs: Plan.Inputs?): { [string]: string }
	local p, list = Plan.plan(project, f, inputs)
	expect(p).toBeNil()
	local out: { [string]: string } = {}
	for _, pr in list do
		out[pr.field] = pr.message
	end
	return out
end

-- The orders fixture deploys ~/FileCabinet/* and ~/Objects/* and already
-- requires SERVERSIDESCRIPTING, so plans there are writes only.
local orders, ordersInputs = load("projects/orders")

local GOLDEN: { { scriptType: string, why: string, overrides: { [string]: any } } } = {
	{
		scriptType = "userevent",
		why = "user event deployments carry the audience and record type but no <title> (none in SDF metadata)",
		overrides = { name = "Demo User Event" },
	},
	{
		scriptType = "clientscript",
		why = "a custom record type is written as a [scriptid=...] reference, the way NetSuite exports it",
		overrides = {
			name = "Demo Client",
			deploy = { status = "RELEASED", logLevel = "AUDIT", recordType = "customrecord_demo_sprint" },
		},
	},
	{
		scriptType = "suitelet",
		why = "suitelet deployments need a <title>, defaulted from the name",
		overrides = { name = "Demo Suitelet", deploy = { recordType = "" } },
	},
	{
		scriptType = "restlet",
		why = "delete is a reserved word in JS and titles are escaped like NetSuite exports",
		overrides = {
			name = "Demo RESTlet",
			deploy = { status = "RELEASED", logLevel = "ERROR", title = "Demo RESTlet & API" },
		},
	},
	{
		scriptType = "mapreduce",
		why = "getInputData returns [] so a first run does not fail; no <notifyuser> or audience exists for it",
		overrides = { name = "Demo Map/Reduce", deploy = { status = "NOTSCHEDULED", logLevel = "AUDIT" } },
	},
	{
		scriptType = "scheduled",
		why = "scheduled scripts start NOTSCHEDULED and have no audience",
		overrides = { name = "Demo Scheduled", deploy = { status = "NOTSCHEDULED" } },
	},
}

describe("files per script type", function()
	for _, g in GOLDEN do
		it(g.scriptType .. ": " .. g.why, function()
			local p = plan(orders, form(g.scriptType, g.overrides), ordersInputs)
			expect(#p.writes).toBe(2)
			expect(p.writes[1].path).toBe("src/FileCabinet/SuiteScripts/demo/demo_" .. g.scriptType .. ".js")
			expect(p.writes[1].content).toBe(fixtures.read("scaffold/golden/" .. g.scriptType .. ".js"))
			expect(p.writes[2].path).toBe("src/Objects/customscript_demo_" .. g.scriptType .. ".xml")
			expect(p.writes[2].content).toBe(fixtures.read("scaffold/golden/" .. g.scriptType .. ".xml"))
			expect(#p.edits).toBe(0)
		end)
	end

	it("emits object XML that parses and re-emits byte for byte, so it is well-formed and export-shaped", function()
		for _, g in GOLDEN do
			local xml = plan(orders, form(g.scriptType, g.overrides), ordersInputs).writes[2].content
			local node, err = Xml.parse(xml)
			expect(err).toBeNil()
			expect(Xml.emit(node :: Xml.Node)).toBe(xml)
		end
	end)

	it("produces objects the project model reads back as a script with its file and deployment", function()
		local p = plan(orders, form("userevent", { deploy = { logLevel = "AUDIT" } }), ordersInputs)
		local extra = { [p.writes[1].path] = p.writes[1].content, [p.writes[2].path] = p.writes[2].content }
		local after = load("projects/orders", extra)
		local o = Project.object(after, "customscript_demo_userevent")
		expect(o and o.isScript).toBe(true)
		expect(o and o.fileReferences[1].path).toBe("/SuiteScripts/demo/demo_userevent.js")
		local d = if o then o.deployments[1] else nil
		expect(d and d.scriptId).toBe("customdeploy_demo_userevent")
		expect(d and d.recordType).toBe("SALESORDER")
		expect(d and d.logLevel).toBe("AUDIT")
		expect(d and d.status).toBe("TESTING")
		expect(Project.file(after, "/SuiteScripts/demo/demo_userevent.js") ~= nil).toBe(true)
	end)
end)

describe("script ids", function()
	it("accepts the longest id SDF allows (40 characters) and refuses one more", function()
		local ok = string.rep("a", Plan.MAX_SUFFIX)
		expect(#(Plan.SCRIPT_PREFIX .. ok)).toBe(40)
		expect(plan(orders, form("suitelet", { scriptIdSuffix = ok }), ordersInputs).scriptId).toBe(
			"customscript_" .. ok
		)
		local msg = problems(orders, form("suitelet", { scriptIdSuffix = ok .. "b" }), ordersInputs).scriptIdSuffix
		expect(msg).toContain("41 characters; SDF allows 40")
	end)

	it("refuses characters the CLI rejects, since NetSuite ids are lowercase letters, digits and _", function()
		expect(problems(orders, form("suitelet", { scriptIdSuffix = "Demo_X" })).scriptIdSuffix).toContain("lowercase")
		expect(problems(orders, form("suitelet", { scriptIdSuffix = "demo-x" })).scriptIdSuffix).toContain("lowercase")
	end)

	it("drops a pasted customscript_ prefix instead of doubling it", function()
		local p = plan(orders, form("suitelet", { scriptIdSuffix = "customscript_demo_x" }), ordersInputs)
		expect(p.scriptId).toBe("customscript_demo_x")
		expect(p.deploymentId).toBe("customdeploy_demo_x")
	end)

	it("derives a valid suffix from a display name", function()
		expect(Plan.suffixFrom("Demo: Order Stamp (v2)")).toBe("demo_order_stamp_v2")
		expect(Plan.suffixFrom("  ")).toBe("")
		local long = Plan.suffixFrom(string.rep("abc ", 20))
		expect(#long <= Plan.MAX_SUFFIX).toBe(true)
		expect(string.sub(long, -1) ~= "_").toBe(true)
	end)
end)

describe("collisions", function()
	it("refuses a script id the project already has, so its object is never overwritten", function()
		local msg = problems(orders, form("userevent", { scriptIdSuffix = "demo_print_label_button" })).scriptIdSuffix
		expect(msg).toContain("customscript_demo_print_label_button already exists")
	end)

	it(
		"reports a taken script id while other fields are still empty, so the user learns it before filling them",
		function()
			local f = form("userevent", { scriptIdSuffix = "demo_print_label_button", deploy = { recordType = "" } })
			local found = problems(orders, f)
			expect(found.scriptIdSuffix).toContain("already exists")
			expect(found.recordType).toContain("need a record type")
		end
	)

	it("refuses a deployment id another script already uses", function()
		local other = '<suitelet scriptid="customscript_other"><scriptfile>[/SuiteScripts/o.js]</scriptfile>'
			.. '<scriptdeployments><scriptdeployment scriptid="customdeploy_demo_x"><title>o</title>'
			.. "</scriptdeployment></scriptdeployments></suitelet>"
		local project = load("projects/orders", { ["src/Objects/customscript_other.xml"] = other })
		local msg = problems(project, form("suitelet", { scriptIdSuffix = "demo_x" })).scriptIdSuffix
		expect(msg).toBe("customdeploy_demo_x is already used by customscript_other")
	end)

	it("refuses an object file name that exists under another scriptid", function()
		local misnamed = '<suitelet scriptid="customscript_misnamed"><name>m</name></suitelet>'
		local project = load("projects/orders", { ["src/Objects/customscript_demo_x.xml"] = misnamed })
		local msg = problems(project, form("suitelet", { scriptIdSuffix = "demo_x" })).scriptIdSuffix
		expect(msg).toBe("src/Objects/customscript_demo_x.xml already exists")
	end)

	it("refuses an existing File Cabinet file, ignoring case like the File Cabinet does", function()
		local f = form("mapreduce", {
			folder = "/SuiteScripts/map-reduce",
			fileName = "Order_Sync.js",
			deploy = { status = "NOTSCHEDULED" },
		})
		expect(problems(orders, f).fileName).toBe("/SuiteScripts/map-reduce/Order_Sync.js already exists")
	end)
end)

describe("deploy.xml", function()
	it("is left alone when its paths already cover the new files", function()
		local warehouses, inputs = load("projects/warehouses")
		local p = plan(warehouses, form("userevent", { folder = "/SuiteScripts/user-events" }), inputs)
		expect(#p.edits).toBe(0)
	end)

	it("gains exactly the uncovered script path, indented like its neighbours", function()
		local warehouses, inputs = load("projects/warehouses")
		local p = plan(warehouses, form("userevent"), inputs)
		expect(#p.edits).toBe(1)
		local e = p.edits[1]
		expect(e.path).toBe("src/deploy.xml")
		expect(e.from).toBe(inputs.deployText)
		expect(e.reason).toBe("deploy.xml does not deploy ~/FileCabinet/SuiteScripts/demo/demo_userevent.js")
		expect(Diff.unified(e.path, e.from, e.to)).toBe(table.concat({
			"--- a/src/deploy.xml",
			"+++ b/src/deploy.xml",
			"@@ -6,6 +6,7 @@",
			"         <path>~/FileCabinet/SuiteScripts/common/integrations/carriers/*</path>",
			"         <path>~/FileCabinet/SuiteScripts/warehouses/*</path>",
			"         <path>~/FileCabinet/SuiteScripts/user-events/*</path>",
			"+        <path>~/FileCabinet/SuiteScripts/demo/demo_userevent.js</path>",
			"     </files>",
			"     <objects>",
			"         <path>~/Objects/*</path>",
			"",
		}, "\n"))
	end)

	it("creates a missing section, and the edited file then deploys both new paths", function()
		local deploy = "<deploy>\n    <files>\n        <path>~/FileCabinet/*</path>\n    </files>\n</deploy>\n"
		local project, inputs = load("projects/orders", { ["src/deploy.xml"] = deploy })
		local p = plan(project, form("suitelet"), inputs)
		expect(#p.edits).toBe(1)
		expect(p.edits[1].to).toBe(
			"<deploy>\n    <files>\n        <path>~/FileCabinet/*</path>\n    </files>\n"
				.. "    <objects>\n        <path>~/Objects/customscript_demo_suitelet.xml</path>\n    </objects>\n</deploy>\n"
		)
		local after = load("projects/orders", { ["src/deploy.xml"] = p.edits[1].to })
		expect(Project.isDeployed(after, "files", p.scriptPath)).toBe(true)
		expect(Project.isDeployed(after, "objects", p.objectPath)).toBe(true)
	end)

	it("is reported as a project problem when missing, since nothing would deploy", function()
		local project = load("projects/orders")
		local without = Project.build({
			root = "/work/x",
			files = {
				{ path = "suitecloud.config.js", size = 0, text = "" },
				{ path = "src/manifest.xml", size = 0, text = fixtures.read("projects/orders/src/manifest.xml") },
			},
		})
		expect(project.deploy ~= nil).toBe(true)
		expect(problems(without, form("suitelet")).project).toBe("deploy.xml is missing or does not parse")
	end)
end)

describe("manifest.xml", function()
	it(
		"gains a required SERVERSIDESCRIPTING feature in a fresh project:create project, which validate demands",
		function()
			local acp, inputs = load("scaffold/acp")
			local p = plan(acp, form("userevent"), inputs)
			expect(#p.edits).toBe(1)
			expect(p.edits[1].path).toBe("src/manifest.xml")
			expect(p.edits[1].to).toBe(table.concat({
				'<manifest projecttype="ACCOUNTCUSTOMIZATION">',
				"  <projectname>acp</projectname>",
				"  <frameworkversion>1.0</frameworkversion>",
				"  <dependencies>",
				"    <features>",
				'      <feature required="true">SERVERSIDESCRIPTING</feature>',
				"    </features>",
				"  </dependencies>",
				"</manifest>",
			}, "\n"))
		end
	)

	it("adds the feature after the existing ones", function()
		local tables, inputs = load("projects/tables")
		local p = plan(tables, form("scheduled", { deploy = { status = "NOTSCHEDULED" } }), inputs)
		expect(#p.edits).toBe(1)
		expect(p.edits[1].to).toContain(
			'      <feature required="false">CRM</feature>\n      <feature required="true">SERVERSIDESCRIPTING</feature>\n    </features>'
		)
	end)

	it("turns an optional SERVERSIDESCRIPTING into a required one", function()
		local manifest = '<manifest projecttype="ACCOUNTCUSTOMIZATION"><projectname>x</projectname><dependencies>'
			.. '<features><feature required="false">SERVERSIDESCRIPTING</feature></features></dependencies></manifest>'
		local project, inputs = load("projects/orders", { ["src/manifest.xml"] = manifest })
		local p = plan(project, form("restlet"), inputs)
		expect(p.edits[1].to).toBe((string.gsub(manifest, 'required="false"', 'required="true"')))
	end)
end)

describe("templates", function()
	it("replaces {{scriptId}} and {{name}} in the user's template and keeps other braces", function()
		local template = fixtures.read("scaffold/templates/userevent.js")
		local p = plan(orders, form("userevent", { name = "Order Stamp" }), {
			deployText = ordersInputs.deployText,
			manifestText = ordersInputs.manifestText,
			template = template,
		})
		local js = p.writes[1].content
		expect(js).toContain(" * Order Stamp (customscript_demo_userevent): {{unknown}} stays as written.")
		expect(js).toContain("log.audit({ title: 'customscript_demo_userevent'")
		expect((string.find(js, "{{name}}", 1, true))).toBeNil()
		expect(p.writes[2].content).toContain("<name>Order Stamp</name>")
	end)

	it("keeps % in names literal, which pattern replacement would mangle", function()
		local p = plan(orders, form("suitelet", { name = "100% Done" }), { template = "// {{name}}\n" })
		expect(p.writes[1].content).toBe("// 100% Done\n")
	end)
end)

describe("form validation", function()
	it("requires a record type for user event and client deployments", function()
		expect(problems(orders, form("userevent", { deploy = { recordType = " " } })).recordType).toContain(
			"need a record type"
		)
		expect(problems(orders, form("clientscript", { deploy = { recordType = "sales order" } })).recordType).toContain(
			"SALESORDER"
		)
	end)

	it("defaults titles to the name and refuses deployment states a new script cannot start in", function()
		local p = plan(orders, form("suitelet", { name = "Picker" }), ordersInputs)
		expect(p.writes[2].content).toContain("<title>Picker</title>")
		expect(problems(orders, form("scheduled", { deploy = { status = "SCHEDULED" } })).status).toBe(
			"Scheduled deployments start as NOTSCHEDULED or TESTING"
		)
		expect(problems(orders, form("suitelet", { deploy = { logLevel = "LOUD" } })).logLevel).toContain("DEBUG")
	end)

	it("keeps scripts inside /SuiteScripts with File Cabinet-safe names", function()
		expect(problems(orders, form("suitelet", { folder = "/Templates" })).folder).toContain("/SuiteScripts")
		expect(problems(orders, form("suitelet", { folder = "/SuiteScripts/../Web" })).folder).toContain("..")
		expect(problems(orders, form("suitelet", { fileName = "a:b.js" })).fileName).toContain("cannot contain")
		expect(problems(orders, form("suitelet", { fileName = "a.ts" })).fileName).toBe("script files must be .js")
		local p = plan(orders, form("suitelet", { folder = "SuiteScripts//demo/", fileName = "picker" }), ordersInputs)
		expect(p.fileCabinetPath).toBe("/SuiteScripts/demo/picker.js")
	end)

	it("limits names to the 40 characters SDF stores", function()
		expect(problems(orders, form("suitelet", { name = string.rep("n", 41) })).name).toContain("40")
		expect(problems(orders, form("suitelet", { name = "" })).name).toBe("a name is required")
	end)
end)

return nil
