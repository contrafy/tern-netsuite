--!strict
local Argv = require("../../../plugin/lib/sdf/argv")
local Output = require("../../../plugin/lib/sdf/output")
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

type Result = Output.Result

local function inv(line: string): Argv.Invocation
	local words = Argv.words(line)
	local program = table.remove(words, 1) :: string
	return Argv.parse({ program = program, args = words, line = line }) :: Argv.Invocation
end

local function capture(name: string, line: string): Result
	local status = tonumber((string.gsub(fixtures.read("suitecloud/" .. name .. ".exit"), "%s", ""))) :: number
	return Output.parse(inv(line), fixtures.lines("suitecloud/" .. name .. ".txt"), status) :: Result
end

local function understood(r: Result): boolean
	return #r.lines > 0 and r.outcome ~= "unknown"
end

describe("local validation", function()
	it("reports a clean project as ok with nothing to show", function()
		local r = capture("validate/ok", "suitecloud project:validate")
		expect(r.outcome).toBe("ok")
		expect(#r.diagnostics).toBe(0)
		expect(r.server).toBe(false)
		expect(r.target).toBeNil()
		expect(r.summary).toBe("The validation process has finished.")
		expect(#r.unknown).toBe(0)
	end)

	it("keeps warnings with their file, line and object so they can be opened", function()
		local r = capture("validate/warnings", "suitecloud project:validate")
		expect(r.outcome).toBe("warnings")
		expect(r.counts.warnings).toBe(1)
		local d = r.diagnostics[1]
		expect(d.severity).toBe("warning")
		expect(d.path).toBe("/work/proj/warnings/src/Objects/customscript_tns_demo.xml")
		expect(d.line).toBe(13)
		expect(d.objectScriptId).toBe("customscript_tns_demo")
		expect(d.message).toContain('The "allpartners" field depends on the "CRM" feature')
		expect(#r.unknown).toBe(0)
	end)

	it("reports a malformed object XML as a failed run pointing at the broken file", function()
		local r = capture("validate/malformed-xml", "suitecloud project:validate")
		expect(r.outcome).toBe("failed")
		expect(r.counts.errors).toBe(1)
		local d = r.diagnostics[1]
		expect(d.path).toBe("/work/proj/malformed/src/Objects/customscript_tns_broken.xml")
		expect(d.objectScriptId).toBe("customscript_tns_broken")
		expect(d.line).toBe(1)
		expect(d.message).toBe('The element type "restlet" must be terminated by the matching end-tag "</restlet>".')
	end)

	it("groups a missing manifest dependency by the file that needs fixing", function()
		local r = capture("validate/missing-dependency", "suitecloud project:validate")
		expect(r.outcome).toBe("failed")
		expect(r.counts.errors).toBe(2)
		expect(#r.groups).toBe(2)
		expect(r.groups[1].objectScriptId).toBe("customscript_tns_demo")
		expect(r.groups[2].path).toBe("/work/proj/nodep/src/manifest.xml")
		expect(r.groups[2].diagnostics[1].message).toContain("[Feature - SERVERSIDESCRIPTING:required]")
	end)

	it("points a deploy.xml path that does not exist at deploy.xml", function()
		local r = capture("validate/deploy-path-missing", "suitecloud project:validate")
		expect(r.outcome).toBe("failed")
		expect(r.diagnostics[1].path).toBe("/work/proj/deploypath/src/deploy.xml")
		expect(r.diagnostics[1].line).toBe(3)
	end)

	it("keeps an SDK crash message instead of dropping it, as an error the user can read", function()
		local r = capture("validate/deploy-path-crash", "suitecloud project:validate")
		expect(r.outcome).toBe("failed")
		expect(#r.unknown).toBe(1)
		expect(r.unknown[1].text).toContain("java.util.Collection.iterator()")
	end)

	it("reports a script whose file is missing on the script object", function()
		local r = capture("validate/missing-file", "suitecloud project:validate")
		expect(r.outcome).toBe("failed")
		local d = r.groups[1].diagnostics[1]
		expect(r.groups[1].objectScriptId).toBe("customscript_tns_demo")
		expect(d.line).toBe(9)
		expect(d.message).toContain('"scriptfile" is missing')
	end)

	it("remembers the --log file, which the CLI itself never mentions", function()
		local r = capture("validate/log", "suitecloud project:validate --log /work/validate.log")
		expect(r.outcome).toBe("ok")
		expect(r.logFile).toBe("/work/validate.log")
	end)

	it("recognizes the setup error of a project without an account", function()
		local r = capture("validate/no-account", "suitecloud project:validate")
		expect(r.outcome).toBe("failed")
		expect(r.diagnostics[1].message).toContain("No account has been set up")
	end)
end)

describe("server validation", function()
	it("names the account it validated against and lists the steps", function()
		local r = capture("validate/server-ok", "suitecloud project:validate --server")
		expect(r.outcome).toBe("ok")
		expect(r.server).toBe(true)
		local target = r.target :: Output.Target
		expect(target.accountId).toBe("1234567_SB1")
		expect(target.accountName).toBe("Example Co")
		expect(target.role).toBe("Administrator")
		expect(#r.steps).toBe(15)
		expect(r.counts.failedSteps).toBe(0)
		expect(#r.unknown).toBe(0)
	end)

	it("reads a WARNING block into a warning on its object and file", function()
		local r = capture("validate/server-warnings", "suitecloud project:validate --server")
		expect(r.outcome).toBe("warnings")
		local d = r.diagnostics[1]
		expect(d.severity).toBe("warning")
		expect(d.objectScriptId).toBe("customscript_tns_demo")
		expect(d.path).toBe("~/Objects/customscript_tns_demo.xml")
		expect(d.message).toContain("The allpartners field depends on the CRM feature")
		expect(#r.unknown).toBe(0)
	end)

	it("reads an ERROR block into an error on the failing object", function()
		local r = capture("validate/server-missing-file", "suitecloud project:validate --server")
		expect(r.outcome).toBe("failed")
		expect(r.counts.failedSteps).toBe(1)
		expect(r.counts.errors).toBe(1)
		local d = r.diagnostics[1]
		expect(d.objectScriptId).toBe("customscript_tns_demo")
		expect(d.title).toBe("An error occurred during custom object validation.")
		expect(d.message).toContain("/SuiteScripts/tns_missing.js is missing")
		expect(d.path).toBe("~/Objects/customscript_tns_demo.xml")
		expect(d.details).toContain("Validation failed.")
		expect(#r.unknown).toBe(0)
	end)

	it("reads an error block without a script id, keeping its file", function()
		local r = capture("validate/server-malformed-xml", "suitecloud project:validate --server")
		expect(r.outcome).toBe("failed")
		local d = r.diagnostics[1]
		expect(d.path).toBe("~/Objects/customscript_tns_broken.xml")
		expect(d.objectScriptId).toBe("customscript_tns_broken")
		expect(d.message).toContain("must be terminated")
		expect(#r.unknown).toBe(0)
	end)

	it("reports a dependency the account lacks against manifest.xml", function()
		local r = capture("validate/server-account-dependency", "suitecloud project:validate --server")
		expect(r.outcome).toBe("failed")
		local d = r.diagnostics[1]
		expect(d.title).toBe("An unexpected error has occurred.")
		expect(d.path).toBe("~/manifest.xml")
		expect(d.message).toContain("customrecord_tns_does_not_exist")
		expect(#r.unknown).toBe(0)
	end)
end)

describe("deploy preview (--dryrun)", function()
	it("marks a dry run as a preview, so nothing reads as deployed", function()
		local r = capture("deploy/preview", "suitecloud project:deploy --dryrun")
		expect(r.preview).toBe(true)
		expect(r.outcome).toBe("ok")
		expect(r.counts.objects).toBe(3)
		expect((r.target :: Output.Target).accountId).toBe("1234567_SB1")
		expect(#r.unknown).toBe(0)
	end)

	it("recognizes a preview by its header even when the flag came through a wrapper", function()
		local r = Output.parse(inv("suitecloud project:deploy"), fixtures.lines("suitecloud/deploy/preview.txt"), 0)
		expect((r :: Result).preview).toBe(true)
	end)

	it("does not mark a real deploy as a preview", function()
		expect(capture("deploy/ok", "suitecloud project:deploy").preview).toBe(false)
		expect(capture("validate/server-ok", "suitecloud project:validate --server").preview).toBe(false)
	end)
end)

describe("deploy (synthetic fixtures)", function()
	it("lists what was deployed with its duration and the target account kind", function()
		local r = capture("deploy/ok", "suitecloud project:deploy")
		expect(r.outcome).toBe("ok")
		expect(r.server).toBe(true)
		local target = r.target :: Output.Target
		expect(target.accountId).toBe("1234567_SB1")
		expect(target.kind).toBe("SANDBOX")
		expect(r.counts.objects).toBe(3)
		expect(r.counts.files).toBe(1)
		expect(r.items[2].name).toBe("customscript_tns_demo")
		expect(r.items[2].objectType).toBe("restlet")
		expect(r.items[2].action).toBe("Update")
		expect(r.seconds).toBe(18)
		expect(r.duration).toBe("18s")
		expect(r.project).toBe("tns-demo")
		expect(#r.unknown).toBe(0)
	end)

	it("keeps the production account id the log names", function()
		local r = capture("deploy/ok-production", "suitecloud project:deploy")
		expect((r.target :: Output.Target).accountId).toBe("1234567")
		expect((r.target :: Output.Target).kind).toBe("PRODUCTION")
	end)

	it("fails when server validation stops the deploy, showing the object error", function()
		local r = capture("deploy/validation-failed", "suitecloud project:deploy")
		expect(r.outcome).toBe("failed")
		expect(r.counts.objects).toBe(0)
		expect(r.diagnostics[1].objectScriptId).toBe("customscript_tns_demo")
		expect(#r.unknown).toBe(0)
	end)

	it("fails on an error during deployment and names the object", function()
		local r = capture("deploy/failed", "suitecloud project:deploy")
		expect(r.outcome).toBe("failed")
		expect(r.counts.objects).toBe(1)
		local d = r.diagnostics[1]
		expect(d.objectScriptId).toBe("customrecord_tns_demo")
		expect(d.message).toContain("is locked")
		expect(#r.unknown).toBe(0)
	end)
end)

describe("file upload (synthetic fixtures)", function()
	it("lists the uploaded files", function()
		local r = capture("upload/ok", 'suitecloud file:upload --paths "/SuiteScripts/tns_demo.js"')
		expect(r.outcome).toBe("ok")
		expect(r.counts.files).toBe(2)
		expect(r.items[1].action).toBe("Uploaded")
	end)

	it("fails a partial upload even though the CLI exits 0, so a skipped file is not missed", function()
		local r = capture("upload/partial", "suitecloud file:upload --paths /SuiteScripts/a.js")
		expect(r.status).toBe(0)
		expect(r.outcome).toBe("failed")
		expect(r.diagnostics[1].path).toBe("/SuiteScripts/tns_locked.js")
		expect(r.diagnostics[1].message).toContain("inactive")
	end)

	it("reports an upload with nothing to upload as failed", function()
		local r = capture("upload/failed", "suitecloud file:upload --paths /SuiteScripts/a.js")
		expect(r.outcome).toBe("failed")
		expect(r.counts.errors).toBe(1)
	end)
end)

describe("package and dependencies", function()
	it("reports the package file and the reminder that packaging does not validate", function()
		local r = capture("package/ok", "suitecloud project:package")
		expect(r.outcome).toBe("ok")
		expect(r.packageFile).toBe("/work/proj/clean/build/tns-demo-2026-10-09_00-00-42.zip")
		expect(#r.notes).toBe(1)
		expect(#r.unknown).toBe(0)
	end)

	it("lists the dependencies written to the manifest", function()
		local r = capture("adddependencies/added", "suitecloud project:adddependencies")
		expect(r.outcome).toBe("ok")
		expect(r.counts.dependencies).toBe(2)
		expect(r.items[1].name).toBe("Feature - SERVERSIDESCRIPTING:required")
	end)

	it("reports that nothing was missing", function()
		local r = capture("adddependencies/none", "suitecloud project:adddependencies")
		expect(r.outcome).toBe("ok")
		expect(r.counts.dependencies).toBe(0)
		expect(r.summary).toBe("There are no dependencies to add to the manifest.xml file.")
	end)
end)

describe("output the parser does not understand", function()
	it("is unknown, so the lens shows it raw", function()
		local r = Output.parse(inv("suitecloud project:validate"), { "Something entirely different", "x" }, 0) :: Result
		expect(r.outcome).toBe("unknown")
		expect(#r.unknown).toBe(2)
	end)

	it("is unknown when empty", function()
		expect((Output.parse(inv("suitecloud project:deploy"), {}, 0) :: Result).outcome).toBe("unknown")
	end)

	it("keeps unexpected lines between known ones", function()
		local r = Output.parse(
			inv("suitecloud project:validate"),
			{ "Surprise line", "The validation process has finished." },
			0
		) :: Result
		expect(r.outcome).toBe("ok")
		expect(r.unknown[1].text).toBe("Surprise line")
		expect(r.unknown[1].line).toBe(1)
	end)

	it("does not model commands without a result view", function()
		expect(Output.parse(inv("suitecloud object:list"), { "x" }, 0)).toBeNil()
	end)

	it("treats a non-zero exit as failed even when every line looked fine", function()
		local r = Output.parse(inv("suitecloud project:validate"), { "The validation process has finished." }, 1)
		expect((r :: Result).outcome).toBe("failed")
	end)
end)

describe("terminal residue", function()
	it("drops spinner frames and escape sequences the way the terminal shows them", function()
		expect(Output.clean("\27[2K\27[1GThe validation process has finished.")).toBe(
			"The validation process has finished."
		)
		expect(Output.clean("| Validating...\rThe deployment process has finished successfully.  ")).toBe(
			"The deployment process has finished successfully."
		)
		expect(Output.clean("\27[31mred\27[39m")).toBe("red")
		expect(Output.clean("ends with cr\r")).toBe("ends with cr")
	end)

	it("reads the auth id from a spinner line the terminal kept", function()
		local r = Output.parse(inv("suitecloud project:deploy"), {
			'Deploying project "tns-demo" with auth ID "demo-sb"...',
			"The deployment process has finished successfully.",
		}, 0) :: Result
		expect((r.target :: Output.Target).authId).toBe("demo-sb")
	end)
end)

describe("copying errors", function()
	it("copies each error as the CLI printed it", function()
		local r = capture("validate/server-missing-file", "suitecloud project:validate --server")
		local text = Output.copyText(r, "error")
		expect(text).toContain("Details: The file reference /SuiteScripts/tns_missing.js")
		expect(text).toContain("File: ~/Objects/customscript_tns_demo.xml")
	end)
end)

describe("every captured fixture", function()
	it("is understood: none falls back to raw", function()
		for _, path in fixtures.list("suitecloud/") do
			local name = string.match(path, "^suitecloud/(.+)%.txt$")
			if
				name == nil
				or string.find(name, "^help/")
				or string.find(name, "^list/")
				or string.find(name, "^manageauth/")
			then
				continue
			end
			local family = string.match(name, "^(%a+)/")
			local command = ({
				validate = "project:validate",
				deploy = "project:deploy",
				upload = "file:upload",
				package = "project:package",
				adddependencies = "project:adddependencies",
			})[family :: string]
			local r = capture(name, "suitecloud " .. command)
			if not understood(r) then
				error(name .. " was not understood")
			end
		end
	end)
end)

return nil
