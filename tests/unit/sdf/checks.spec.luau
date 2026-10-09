--!strict
local Checks = require("../../../plugin/lib/sdf/checks")
local Project = require("../../../plugin/lib/sdf/project")
local Snapshot = require("../../../plugin/lib/sdf/snapshot")
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

type Finding = Checks.Finding
type SnapshotFile = Snapshot.SnapshotFile

local DEPLOY = "<deploy><files><path>~/FileCabinet/*</path></files><objects><path>~/Objects/*</path></objects></deploy>"

local function manifest(objects: { string }?, files: { string }?): string
	local parts = { '<manifest projecttype="ACCOUNTCUSTOMIZATION"><projectname>x</projectname><dependencies>' }
	table.insert(parts, "<objects>")
	local objectList: { string } = objects or {}
	for _, o in objectList do
		table.insert(parts, "<object>" .. o .. "</object>")
	end
	table.insert(parts, "</objects><files>")
	local fileList: { string } = files or {}
	for _, f in fileList do
		table.insert(parts, "<file>" .. f .. "</file>")
	end
	table.insert(parts, "</files></dependencies></manifest>")
	return table.concat(parts)
end

-- string values are contents, numbers sizes; `reals` maps paths to
-- symlink targets.
local function project(
	root: string,
	files: { [string]: string | number },
	reals: { [string]: string }?
): Project.Project
	local list: { SnapshotFile } = {}
	for path, v in files do
		local real = if reals then reals[path] else nil
		if type(v) == "string" then
			table.insert(list, { path = path, size = #v, text = v, real = real })
		else
			table.insert(list, { path = path, size = v :: number, real = real })
		end
	end
	return Project.build({ root = root, files = list })
end

local function fromFixture(name: string): Project.Project
	local prefix = "projects/" .. name .. "/"
	local list: { SnapshotFile } = {}
	for _, key in fixtures.list(prefix) do
		local path = string.sub(key, #prefix + 1)
		local text = fixtures.read(key)
		table.insert(list, { path = path, size = #text, text = if Snapshot.wantsText(path, "src") then text else nil })
	end
	return Project.build({ root = "/repo/sdf/" .. name, files = list })
end

local function only(findings: { Finding }, code: string): { Finding }
	local out: { Finding } = {}
	for _, f in findings do
		if f.code == code then
			table.insert(out, f)
		end
	end
	return out
end

local function script(id: string, file: string, extra: string?): string
	return string.format(
		'<suitelet scriptid="%s">\n  <scriptfile>[%s]</scriptfile>\n%s</suitelet>',
		id,
		file,
		extra or ""
	)
end

describe("missing-dependency: references that would fail validation", function()
	it("flags a custom scriptid that is neither in the project nor a declared dependency", function()
		local p = project("/w/a", {
			["src/manifest.xml"] = manifest(),
			["src/deploy.xml"] = DEPLOY,
			["src/Objects/custentity_a.xml"] = '<entitycustomfield scriptid="custentity_a">\n'
				.. "  <selectrecordtype>[scriptid=customlist_absent]</selectrecordtype>\n"
				.. "</entitycustomfield>",
		})
		local found = only(Checks.run({ p }), "missing-dependency")
		expect(#found).toBe(1)
		expect(found[1].severity).toBe("error")
		expect(found[1].scriptId).toBe("custentity_a")
		expect(found[1].path).toBe("src/Objects/custentity_a.xml")
		expect(found[1].line).toBe(2)
		expect(found[1].message).toContain("customlist_absent")
	end)

	it("accepts ids defined in the project, its nested children and declared dependencies", function()
		local p = project("/w/a", {
			["src/manifest.xml"] = manifest({ "customrecord_site", "customrecord_site.custrecord_zip" }),
			["src/deploy.xml"] = DEPLOY,
			["src/Objects/customlist_dir.xml"] = '<customlist scriptid="customlist_dir"><customvalues>'
				.. '<customvalue scriptid="val_in"/></customvalues></customlist>',
			["src/Objects/custentity_a.xml"] = '<entitycustomfield scriptid="custentity_a">'
				.. "<a>[scriptid=customlist_dir]</a><b>[scriptid=customlist_dir.val_in]</b>"
				.. "<c>[scriptid=customrecord_site]</c><d>[type=x, scriptid=customrecord_site.custrecord_zip]</d>"
				.. "</entitycustomfield>",
		})
		expect(#only(Checks.run({ p }), "missing-dependency")).toBe(0)
	end)

	it("accepts workflow action references three levels deep, which Oracle's examples use", function()
		local p = project("/w/a", {
			["src/manifest.xml"] = manifest(),
			["src/deploy.xml"] = DEPLOY,
			["src/Objects/customworkflow_approvals.xml"] = '<workflow scriptid="customworkflow_approvals">'
				.. '<workflowstates><workflowstate scriptid="workflowstate_pending">'
				.. '<workflowactions triggertype="ONENTRY"><setfieldvalueaction scriptid="workflowaction_approve"/>'
				.. "</workflowactions>"
				.. "<x>[scriptid=customworkflow_approvals.workflowstate_pending.workflowaction_approve]</x>"
				.. "</workflowstate></workflowstates></workflow>",
			["src/Objects/custentity_a.xml"] = '<entitycustomfield scriptid="custentity_a">'
				.. "<a>[scriptid=customworkflow_approvals.workflowstate_pending.workflowaction_approve]</a>"
				.. "<b>[scriptid=customworkflow_approvals.workflowstate_pending]</b>"
				.. "</entitycustomfield>",
		})
		expect(only(Checks.run({ p }), "missing-dependency")).toEqual({})
	end)

	it("still flags a deep reference to a state the workflow does not have", function()
		local p = project("/w/a", {
			["src/manifest.xml"] = manifest(),
			["src/deploy.xml"] = DEPLOY,
			["src/Objects/customworkflow_approvals.xml"] = '<workflow scriptid="customworkflow_approvals">'
				.. '<workflowstate scriptid="workflowstate_pending"><a scriptid="workflowaction_approve"/></workflowstate>'
				.. "<x>[scriptid=customworkflow_approvals.workflowstate_gone.workflowaction_approve]</x>"
				.. "</workflow>",
		})
		expect(#only(Checks.run({ p }), "missing-dependency")).toBe(1)
	end)

	it("skips dependency checks when manifest.xml cannot be read, instead of one false error per reference", function()
		local p = project("/w/a", {
			["src/manifest.xml"] = "<manifest><dependencies></manifest>",
			["src/deploy.xml"] = DEPLOY,
			["src/Objects/customscript_a.xml"] = script(
				"customscript_a",
				"/SuiteScripts/shared.js",
				"  <x>[scriptid=customrecord_declared]</x>\n"
			),
		})
		local all = Checks.run({ p })
		expect(#only(all, "xml-parse")).toBe(1)
		expect(only(all, "missing-dependency")).toEqual({})
		expect(only(all, "missing-script-file")).toEqual({})
	end)

	it("ignores standard records and fields, which every account has", function()
		expect(Checks.isCustomId("customer")).toBe(false)
		expect(Checks.isCustomId("-119")).toBe(false)
		expect(Checks.isCustomId("SALESORDER")).toBe(false)
		expect(Checks.isCustomId("customrecord_x")).toBe(true)
		expect(Checks.isCustomId("customlist728.val_1")).toBe(true)
		expect(Checks.isCustomId("custbody_x")).toBe(true)
		expect(Checks.isCustomId("cseg_region")).toBe(true)
	end)

	it("finds nothing missing in the real fixture projects", function()
		local all = Checks.run({ fromFixture("orders"), fromFixture("warehouses"), fromFixture("tables") })
		expect(only(all, "missing-dependency")).toEqual({})
	end)
end)

describe("missing-script-file: scripts whose code would not be deployed", function()
	it("flags a script file absent from the FileCabinet and undeclared", function()
		local p = project("/w/a", {
			["src/manifest.xml"] = manifest(),
			["src/deploy.xml"] = DEPLOY,
			["src/Objects/customscript_a.xml"] = script("customscript_a", "/SuiteScripts/a.js"),
		})
		local found = only(Checks.run({ p }), "missing-script-file")
		expect(#found).toBe(1)
		expect(found[1].line).toBe(2)
		expect(found[1].message).toContain("/SuiteScripts/a.js")
	end)

	it("accepts a file in the project or declared as a file dependency", function()
		local p = project("/w/a", {
			["src/manifest.xml"] = manifest(nil, { "/SuiteScripts/lib/shared.js" }),
			["src/deploy.xml"] = DEPLOY,
			["src/FileCabinet/SuiteScripts/a.js"] = 10,
			["src/Objects/customscript_a.xml"] = script(
				"customscript_a",
				"/SuiteScripts/a.js",
				"  <libraryscripts><libraryscript><scriptfile>[/SuiteScripts/lib/shared.js]</scriptfile>"
					.. "</libraryscript></libraryscripts>\n"
			),
		})
		expect(#only(Checks.run({ p }), "missing-script-file")).toBe(0)
	end)

	it("flags a bundle file an exported object still points at", function()
		local found = only(Checks.run({ fromFixture("backup") }), "missing-script-file")
		expect(#found).toBe(1)
		expect(found[1].scriptId).toBe("customscript_demo_util_filedetection")
	end)
end)

describe("not-deployed: project content deploy.xml leaves out", function()
	local p = project("/w/a", {
		["src/manifest.xml"] = manifest(),
		["src/deploy.xml"] = "<deploy><files><path>~/FileCabinet/SuiteScripts/app/*</path></files>"
			.. "<objects><path>~/Objects/customscript_a.xml</path></objects></deploy>",
		["src/FileCabinet/SuiteScripts/app/a.js"] = 1,
		["src/FileCabinet/SuiteScripts/tests/a.test.js"] = 1,
		["src/Objects/customscript_a.xml"] = script("customscript_a", "/SuiteScripts/app/a.js"),
		["src/Objects/customlist_b.xml"] = '<customlist scriptid="customlist_b"/>',
	})
	local found = only(Checks.run({ p }), "not-deployed")

	it("warns about an object no <objects> path covers", function()
		expect(found[1].scriptId).toBe("customlist_b")
		expect(found[1].severity).toBe("warning")
	end)

	it("notes a file no <files> path covers without alarming, as tests are left out on purpose", function()
		expect(#found).toBe(2)
		expect(found[2].path).toBe("src/FileCabinet/SuiteScripts/tests/a.test.js")
		expect(found[2].severity).toBe("info")
	end)

	it("finds everything deployed in a project that deploys whole folders", function()
		expect(only(Checks.run({ fromFixture("orders") }), "not-deployed")).toEqual({})
	end)
end)

describe("empty-deploy-path: deploy.xml paths that cover nothing", function()
	it("warns about a files path matching nothing, with its deploy.xml line", function()
		local p = project("/w/a", {
			["src/manifest.xml"] = manifest(),
			["src/deploy.xml"] = "<deploy>\n<files>\n<path>~/FileCabinet/SuiteScripts/moved/*</path>\n"
				.. "<path>~/FileCabinet/SuiteScripts/app/*</path>\n</files>\n</deploy>",
			["src/FileCabinet/SuiteScripts/app/a.js"] = 1,
		})
		local found = only(Checks.run({ p }), "empty-deploy-path")
		expect(#found).toBe(1)
		expect(found[1].severity).toBe("warning")
		expect(found[1].path).toBe("src/deploy.xml")
		expect(found[1].line).toBe(3)
		expect(found[1].message).toContain("~/FileCabinet/SuiteScripts/moved/*")
	end)

	it("only notes the configuration and translation paths project:create writes by default", function()
		local found = only(Checks.run({ fromFixture("warehouses") }), "empty-deploy-path")
		expect(#found).toBe(2)
		expect(found[1].severity).toBe("info")
		expect(found[2].severity).toBe("info")
	end)

	it("only notes the ~/FileCabinet/* and ~/Objects/* template paths of an objects-only or fresh project", function()
		local p = project("/w/a", {
			["src/manifest.xml"] = manifest(),
			["src/deploy.xml"] = DEPLOY,
		})
		local found = only(Checks.run({ p }), "empty-deploy-path")
		expect(#found).toBe(2)
		expect(found[1].severity).toBe("info")
		expect(found[2].severity).toBe("info")
	end)
end)

describe("a scan cut short by projects.max_files", function()
	it("does not report files or deploy paths as missing, since unlisted files may exist", function()
		local p = Project.build({
			root = "/w/big",
			truncated = true,
			files = {
				{ path = "src/manifest.xml", size = 1, text = manifest() },
				{
					path = "src/deploy.xml",
					size = 1,
					text = "<deploy><files><path>~/FileCabinet/SuiteScripts/zz/*</path></files></deploy>",
				},
				{
					path = "src/Objects/customscript_a.xml",
					size = 1,
					text = script("customscript_a", "/SuiteScripts/zz/a.js"),
				},
			},
		})
		local all = Checks.run({ p })
		expect(only(all, "missing-script-file")).toEqual({})
		expect(only(all, "empty-deploy-path")).toEqual({})
	end)
end)

describe("cross-project-collision: two projects deploying the same thing", function()
	local function pair(realA: string?, realB: string?): { Finding }
		local a = project("/repo/sdf/alpha", {
			["src/manifest.xml"] = manifest(),
			["src/deploy.xml"] = DEPLOY,
			["src/FileCabinet/SuiteScripts/common/util.js"] = 1,
			["src/Objects/customlist_shared.xml"] = '<customlist scriptid="customlist_shared"/>',
		}, { ["src/FileCabinet/SuiteScripts/common/util.js"] = realA :: string })
		local b = project("/repo/sdf/beta", {
			["src/manifest.xml"] = manifest(),
			["src/deploy.xml"] = DEPLOY,
			["src/FileCabinet/SuiteScripts/common/util.js"] = 1,
			["src/Objects/customlist_other.xml"] = '<customlist scriptid="customlist_other"/>',
		}, { ["src/FileCabinet/SuiteScripts/common/util.js"] = realB :: string })
		local c = project("/repo/sdf/gamma", {
			["src/manifest.xml"] = manifest(),
			["src/deploy.xml"] = DEPLOY,
			["src/Objects/customlist_shared.xml"] = '<customlist scriptid="customlist_shared"/>',
		})
		return only(Checks.run({ a, b, c }), "cross-project-collision")
	end

	it("names both projects when one object scriptid is deployed by two", function()
		local found = pair("/repo/netsuite/common/util.js", "/repo/netsuite/common/util.js")
		local objects: { Finding } = {}
		for _, f in found do
			if f.scriptId == "customlist_shared" then
				table.insert(objects, f)
			end
		end
		expect(#objects).toBe(2)
		expect(objects[1].project).toBe("alpha")
		expect(objects[1].message).toContain("gamma")
		expect(objects[2].project).toBe("gamma")
		expect(objects[2].message).toContain("alpha")
		expect(objects[1].severity).toBe("warning")
	end)

	it("only notes a shared file both projects symlink from one source", function()
		local found = pair("/repo/netsuite/common/util.js", "/repo/netsuite/common/util.js")
		local files: { Finding } = {}
		for _, f in found do
			if f.scriptId == nil then
				table.insert(files, f)
			end
		end
		expect(#files).toBe(2)
		expect(files[1].severity).toBe("info")
		expect(files[1].message).toContain("/SuiteScripts/common/util.js")
		expect(files[1].message).toContain("same source")
	end)

	it("warns when two projects deploy different files to one File Cabinet path", function()
		local found = pair(nil, nil)
		for _, f in found do
			expect(f.severity).toBe("warning")
		end
		expect(#found).toBe(4)
	end)

	it("tells a shared symlinked copy apart from a diverged copy of the same file", function()
		local function withUtil(root: string, real: string?): Project.Project
			return project(root, {
				["src/manifest.xml"] = manifest(),
				["src/deploy.xml"] = DEPLOY,
				["src/FileCabinet/SuiteScripts/util.js"] = 1,
			}, { ["src/FileCabinet/SuiteScripts/util.js"] = real :: string })
		end
		local found = only(
			Checks.run({
				withUtil("/repo/sdf/alpha", "/repo/netsuite/util.js"),
				withUtil("/repo/sdf/beta", "/repo/netsuite/util.js"),
				withUtil("/repo/sdf/backup", nil),
			}),
			"cross-project-collision"
		)
		expect(#found).toBe(3)
		local alpha = found[1]
		expect(alpha.project).toBe("alpha")
		expect(alpha.severity).toBe("warning")
		expect(alpha.message).toBe(
			"/SuiteScripts/util.js is also deployed by beta from the same source file and by backup "
				.. "from a different source file; whichever deploys last wins"
		)
	end)

	it("finds no collision among unrelated projects", function()
		local all = Checks.run({ fromFixture("orders"), fromFixture("warehouses") })
		expect(only(all, "cross-project-collision")).toEqual({})
	end)
end)

describe("project diagnostics become findings", function()
	it("reports malformed object XML as xml-parse with its line", function()
		local p = project("/w/a", {
			["src/manifest.xml"] = manifest(),
			["src/deploy.xml"] = DEPLOY,
			["src/Objects/customlist_a.xml"] = '<customlist scriptid="customlist_a">\n<name>x</customlist>',
		})
		local found = only(Checks.run({ p }), "xml-parse")
		expect(#found).toBe(1)
		expect(found[1].severity).toBe("error")
		expect(found[1].project).toBe("a")
		expect(found[1].line).toBe(2)
	end)

	it("reports nothing for a well-formed project", function()
		expect(only(Checks.run({ fromFixture("orders") }), "xml-parse")).toEqual({})
	end)
end)

return nil
