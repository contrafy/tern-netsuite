--!strict
-- tests/fixtures/drift/*-import-*.txt: stdout of `object:import` /
-- `file:import` (CLI 3.2.0) run in a sandbox scratch project, escape bytes
-- kept; script ids and paths replaced by synthetic Acme ones.
local Cli = require("../../../plugin/lib/drift/cli")
local CliSlot = require("../../../plugin/lib/sdf/cli_slot")
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local function fixture(name: string): string
	return fixtures.read("drift/" .. name .. ".txt")
end

describe("drift cli", function()
	it(
		"groups objects by type in batches of at most 8, because the CLI runs larger imports as parallel SDK calls",
		function()
			local objects = {}
			for i = 1, 10 do
				table.insert(objects, { type = "customlist", scriptId = "customlist_acme_" .. i })
			end
			table.insert(objects, { type = "restlet", scriptId = "customscript_acme_rl" })
			local batches = Cli.objectBatches(objects)
			expect(#batches).toBe(3)
			expect(batches[1].type).toBe("customlist")
			expect(#batches[1].scriptIds).toBe(8)
			expect(#batches[2].scriptIds).toBe(2)
			expect(batches[3].type).toBe("restlet")
		end
	)

	it("imports objects without their script files, which the file step compares on its own", function()
		local argv = Cli.objectArgv("suitecloud", { type = "customlist", scriptIds = { "a", "b" } }, nil)
		expect(argv).toEqual({
			"suitecloud",
			"object:import",
			"--type",
			"customlist",
			"--scriptid",
			"a",
			"b",
			"--destinationfolder",
			"/Objects",
			"--excludefiles",
		})
	end)

	it(
		"asks for a SuiteApp's own objects with --appid, since the CLI otherwise only sees objects without one",
		function()
			local argv = Cli.objectArgv("suitecloud", { type = "customlist", scriptIds = { "a" } }, "com.acme.billing")
			expect(table.concat(argv, " ")).toBe(
				"suitecloud object:import --type customlist --scriptid a --destinationfolder /Objects --appid com.acme.billing"
			)
			expect(table.concat(Cli.listArgv("suitecloud", "com.acme.billing"), " ")).toBe(
				"suitecloud object:list --appid com.acme.billing"
			)
		end
	)

	it("imports files without their .attributes, which only hold File Cabinet properties", function()
		expect(Cli.fileArgv("suitecloud", { "/SuiteScripts/a.js", "/SuiteScripts/b c.js" })).toEqual({
			"suitecloud",
			"file:import",
			"--paths",
			"/SuiteScripts/a.js",
			"/SuiteScripts/b c.js",
			"--excludeproperties",
		})
	end)

	it("reads imported and missing objects from a mixed import", function()
		local r = Cli.parseObjectImport(fixture("object-import-mixed"), "")
		expect(r.recognized).toBe(true)
		expect(r.imported.customlist_acme_sizes).toBe(true)
		expect(r.imported.customlist_acme_colors).toBe(true)
		expect(r.failed.customlist_acme_missing).toBe("Record does not exist")
		expect(Cli.isMissing(r.failed.customlist_acme_missing)).toBe(true)
	end)

	it("keeps the reason of objects the account refuses to export, which are not missing", function()
		local r = Cli.parseObjectImport(fixture("object-import-locked"), "")
		local why = r.failed.customscript_acme_bank_rl
		expect(why).toBe("You cannot download the XML file for this object because it is locked.")
		expect(Cli.isMissing(why)).toBe(false)
	end)

	it("reads batch-level failures the CLI prints per reason", function()
		local out =
			'The following objects failed with reason "An unexpected error has occurred.":\n    - customlist_acme_a\n    - customlist_acme_b\n'
		local r = Cli.parseObjectImport("", out)
		expect(r.failed.customlist_acme_a).toBe("An unexpected error has occurred.")
		expect(r.failed.customlist_acme_b).toBe("An unexpected error has occurred.")
	end)

	it("reads imported and missing files, paths with spaces included", function()
		local asked = {
			"/SuiteScripts/acme/acme_orders_ue.js",
			"/SuiteScripts/acme/Acme Shared/acme_lib.js",
			"/SuiteScripts/acme/acme_missing.js",
		}
		local r = Cli.parseFileImport(fixture("file-import-mixed"), "", asked)
		expect(r.imported["/SuiteScripts/acme/Acme Shared/acme_lib.js"]).toBe(true)
		expect(r.imported["/SuiteScripts/acme/acme_orders_ue.js"]).toBe(true)
		local why = r.failed["/SuiteScripts/acme/acme_missing.js"]
		expect(why).toBe("INVALID FILE PATH: /SuiteScripts/acme/acme_missing.js")
		expect(Cli.isMissing(why)).toBe(true)
	end)

	it("recognizes an import where nothing was found", function()
		local asked = { "/SuiteScripts/acme/acme_missing.js", "/SuiteScripts/acme/acme_gone.js" }
		local r = Cli.parseFileImport(fixture("file-import-none"), "", asked)
		expect(r.recognized).toBe(true)
		expect(Cli.isMissing(r.failed["/SuiteScripts/acme/acme_gone.js"])).toBe(true)
	end)

	it("explains failures: browser login, busy slot, timeout, else the CLI's first line", function()
		expect(Cli.failure(1, "Starting the browser-based authentication", "", false, 60000, "demo-sb")).toContain(
			"browser login for auth ID demo-sb"
		)
		expect(
			Cli.failure(
				CliSlot.BUSY_STATUS,
				"",
				"tern-netsuite: project:deploy (pid 4) still holds this auth ID",
				false,
				60000,
				"demo-sb"
			)
		).toContain("still holds this auth ID")
		expect(Cli.failure(-1, "", "", true, 60000, "demo-sb")).toBe("timed out after 60 s (suitecloud.timeout_ms)")
		expect(Cli.failure(1, "", "\n  The project.json file is missing.\n", false, 60000, "demo-sb")).toBe(
			"The project.json file is missing."
		)
	end)

	it("refuses script ids and paths the CLI would split or misread", function()
		expect(Cli.unsafeScriptId("customlist_acme_sizes")).toBeNil()
		expect(Cli.unsafeScriptId("bad id")).toContain("script ID")
		expect(Cli.unsafePath("/SuiteScripts/a b.js")).toBeNil()
		expect(Cli.unsafePath('/SuiteScripts/a".js')).toContain("quote")
		expect(Cli.unsafePath("/SuiteScripts/../x.js")).toContain("plain")
	end)
end)

return nil
