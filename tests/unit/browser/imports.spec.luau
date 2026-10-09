--!strict
local Diff = require("../../../plugin/lib/browser/diff")
local Imports = require("../../../plugin/lib/browser/imports")
local sample = require("./sample")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

type Request = Imports.Request

local project = sample.project("demo-sb")

local function objectEntry(id: string, where: Diff.Where, localPath: string?, refs: { string }?): Diff.Entry
	return { kind = "object", id = id, type = "restlet", where = where, localPath = localPath, fileReferences = refs }
end

describe("building the import of a selected entry", function()
	it(
		"imports an account-only object into the project's Objects folder with the CLI's non-interactive flags",
		function()
			local req = Imports.forEntry(project, objectEntry("customscript_demo_90", "account"), false) :: Request
			local argv = Imports.argv("suitecloud", req) :: { string }
			expect(argv).toEqual({
				"suitecloud",
				"object:import",
				"--type",
				"restlet",
				"--scriptid",
				"customscript_demo_90",
				"--destinationfolder",
				"/Objects",
			})
			expect(req.root).toBe(sample.ROOT)
		end
	)

	it(
		"re-imports an object into the folder it already lives in, so it replaces that file instead of duplicating it",
		function()
			local e = objectEntry("customlist_x", "both", "src/Objects/lists/customlist_x.xml")
			local req = Imports.forEntry(project, e, false) :: Request
			expect(req.destinationFolder).toBe("/Objects/lists")
		end
	)

	it("adds --excludefiles when the user chose to leave referenced scripts alone", function()
		local req = Imports.forEntry(project, objectEntry("customscript_demo_90", "account"), true) :: Request
		local argv = Imports.argv("suitecloud", req) :: { string }
		expect(argv[#argv]).toBe("--excludefiles")
	end)

	it("imports a file by its File Cabinet path", function()
		local e: Diff.Entry = { kind = "file", id = "/SuiteScripts/tns demo/report template.html", where = "account" }
		local req = Imports.forEntry(project, e, false) :: Request
		expect((Imports.argv("suitecloud", req))).toEqual({
			"suitecloud",
			"file:import",
			"--paths",
			"/SuiteScripts/tns demo/report template.html",
		})
	end)

	it("refuses local-only entries: the account has nothing to import", function()
		local req, err = Imports.forEntry(project, objectEntry("customlist_local_only", "local", "src/x.xml"), false)
		expect(req).toBeNil()
		expect(err).toContain("only in this project")
	end)
end)

describe("validation", function()
	local base: Request = {
		kind = "object",
		root = "/work/p",
		projectFolder = "src",
		type = "restlet",
		scriptId = "customscript_x",
		destinationFolder = "/Objects",
		excludeFiles = false,
	}

	local function with(fields: { [string]: any }): Request
		local r: any = table.clone(base)
		for k, v in fields do
			r[k] = v
		end
		return r
	end

	it("refuses a scriptid that would be read as another option", function()
		local argv, err = Imports.argv("suitecloud", with({ scriptId = "--excludefiles" }))
		expect(argv).toBeNil()
		expect(err).toContain("script ID")
	end)

	it("refuses destinations outside the Objects folder, which the CLI rejects anyway", function()
		expect((Imports.argv("suitecloud", with({ destinationFolder = "/FileCabinet" })))).toBeNil()
		expect((Imports.argv("suitecloud", with({ destinationFolder = "/Objects/../.." })))).toBeNil()
	end)

	it("refuses file paths that climb out of the File Cabinet or carry control characters", function()
		local f = with({ kind = "file", path = "/SuiteScripts/../x.js" })
		expect((Imports.argv("suitecloud", f))).toBeNil()
		expect((Imports.argv("suitecloud", with({ kind = "file", path = "/SuiteScripts/a\nb.js" })))).toBeNil()
		expect((Imports.argv("suitecloud", with({ kind = "file", path = "SuiteScripts/x.js" })))).toBeNil()
	end)

	it("refuses a relative project root", function()
		expect((Imports.argv("suitecloud", with({ root = "work/p" })))).toBeNil()
	end)
end)

describe("the command shown in the split pane", function()
	it("quotes words so a shell runs exactly the argv", function()
		local line = Imports.commandLine({ "suitecloud", "file:import", "--paths", "/SuiteScripts/it's here.js" })
		expect(line).toBe("suitecloud file:import --paths '/SuiteScripts/it'\\''s here.js'")
	end)

	it("leaves plain words bare so the command reads naturally", function()
		expect(Imports.commandLine({ "suitecloud", "object:import", "--type", "restlet" })).toBe(
			"suitecloud object:import --type restlet"
		)
	end)

	it("quotes shell metacharacters", function()
		expect(Imports.quote("a;rm -rf ~")).toBe("'a;rm -rf ~'")
		expect(Imports.quote("$(x)")).toBe("'$(x)'")
	end)
end)

describe("what an import may overwrite", function()
	it(
		"covers the object file and, without --excludefiles, the whole File Cabinet for an account-only object",
		function()
			local req = Imports.forEntry(project, objectEntry("customscript_demo_90", "account"), false) :: Request
			expect(Imports.destinations(req, nil)).toEqual({ "src/Objects/customscript_demo_90.xml", "src/FileCabinet" })
		end
	)

	it("covers only the scripts a local object references when re-importing it", function()
		local e = objectEntry("customscript_demo_89", "both", "src/Objects/customscript_demo_89.xml", {
			"/SuiteScripts/tns_demo/tns_demo_restlet.js",
		})
		local req = Imports.forEntry(project, e, false) :: Request
		expect(Imports.destinations(req, e.fileReferences)).toEqual({
			"src/Objects/customscript_demo_89.xml",
			"src/FileCabinet/SuiteScripts/tns_demo/tns_demo_restlet.js",
		})
	end)

	it("covers only the object file with --excludefiles", function()
		local req = Imports.forEntry(project, objectEntry("customscript_demo_90", "account"), true) :: Request
		expect(Imports.destinations(req, nil)).toEqual({ "src/Objects/customscript_demo_90.xml" })
	end)

	it("covers a file and its .attributes folder", function()
		local e: Diff.Entry = { kind = "file", id = "/SuiteScripts/a/x.js", where = "account" }
		local req = Imports.forEntry(project, e, false) :: Request
		expect(Imports.destinations(req, nil)).toEqual({
			"src/FileCabinet/SuiteScripts/a/x.js",
			"src/FileCabinet/SuiteScripts/a/.attributes",
		})
	end)

	it("asks git about exactly those paths, untracked files included", function()
		local req = Imports.forEntry(project, objectEntry("customscript_demo_90", "account"), true) :: Request
		expect(Imports.dirtyArgv(req, Imports.destinations(req, nil))).toEqual({
			"git",
			"-C",
			sample.ROOT,
			"status",
			"--porcelain=v1",
			"-z",
			"--untracked-files=all",
			"--",
			"src/Objects/customscript_demo_90.xml",
		})
	end)
end)

describe("dirty-tree refusal", function()
	it("allows an import when git reports nothing in the destination", function()
		local d = Imports.dirty(0, "", "", false)
		expect(d.state).toBe("clean")
		local ok = Imports.verdict(d, false)
		expect(ok).toBe(true)
	end)

	it("refuses when the destination has uncommitted changes, naming them, unless forced", function()
		local d = Imports.dirty(0, " M src/Objects/a.xml\0?? src/FileCabinet/SuiteScripts/b.js\0", "", false)
		expect(d.state).toBe("dirty")
		expect(d.paths).toEqual({ "src/Objects/a.xml", "src/FileCabinet/SuiteScripts/b.js" })
		local ok, why = Imports.verdict(d, false)
		expect(ok).toBe(false)
		expect(why).toContain("src/Objects/a.xml")
		expect(why).toContain("I")
		expect((Imports.verdict(d, true))).toBe(true)
	end)

	it("reads both names of a rename", function()
		local d = Imports.dirty(0, "R  src/Objects/new.xml\0src/Objects/old.xml\0", "", false)
		expect(d.paths).toEqual({ "src/Objects/new.xml", "src/Objects/old.xml" })
	end)

	it("refuses outside a git repository, where overwritten files could not be recovered", function()
		local d =
			Imports.dirty(128, "", "fatal: not a git repository (or any of the parent directories): .git\n", false)
		expect(d.state).toBe("nogit")
		local ok, why = Imports.verdict(d, false)
		expect(ok).toBe(false)
		expect(why).toContain("not in a git repository")
	end)

	it("fails closed when git cannot answer", function()
		local timedOut = Imports.dirty(-1, "", "", true)
		expect(timedOut.state).toBe("error")
		expect((Imports.verdict(timedOut, false))).toBe(false)
		local missing = Imports.dirty(-1, "", "could not start git", false)
		expect(missing.state).toBe("error")
		expect(missing.message).toContain("could not start git")
	end)
end)

return nil
