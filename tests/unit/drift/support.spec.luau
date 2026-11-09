--!strict
local Cache = require("../../../plugin/lib/drift/cache")
local Compare = require("../../../plugin/lib/drift/compare")
local Scope = require("../../../plugin/lib/drift/scope")
local Scratch = require("../../../plugin/lib/drift/scratch")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local function file(): Compare.Entry
	return Compare.pending("file", "/SuiteScripts/acme/a.js", nil, "src/FileCabinet/SuiteScripts/acme/a.js")
end

describe("drift compare", function()
	it("reports line-ending-only differences without a wall of diff, since every line would differ", function()
		local e = Compare.file(file(), "a\nb\n", "a\r\nb\r\n")
		expect(e.status).toBe("changed")
		expect(e.note).toBe("only line endings differ (CRLF in the account)")
		expect(e.diff).toBeNil()
	end)

	it("does not diff binary files", function()
		local e = Compare.file(file(), "PNG\0a", "PNG\0b")
		expect(e.status).toBe("changed")
		expect(e.note).toContain("binary file differs")
	end)

	it("refuses to compare files past the size cap instead of reporting them identical", function()
		local big = string.rep("x", Compare.MAX_FILE_BYTES + 1)
		local e = Compare.file(file(), big, big)
		expect(e.status).toBe("error")
		expect(e.note).toContain("not compared")
	end)

	it("diffs changed files with the project path as the label", function()
		local e = Compare.file(file(), "a\n", "b\n")
		expect(e.diff).toContain("--- project/src/FileCabinet/SuiteScripts/acme/a.js")
	end)
end)

describe("drift scope", function()
	it("derives prefixes from the type word and the next one, so one project's objects define its namespace", function()
		expect(Scope.prefixes({
			"customscript_acme_orders_ue",
			"customlist_acme_sizes",
			"customscript_acme_x",
			"customlist7",
		})).toEqual({
			"customlist7",
			"customlist_acme_",
			"customscript_acme_",
		})
	end)

	it("leaves out objects the project has and objects outside its prefixes", function()
		local listed = {
			{ type = "customlist", scriptId = "customlist_acme_sizes" },
			{ type = "customlist", scriptId = "CUSTOMLIST_ACME_REGIONS" },
			{ type = "customlist", scriptId = "customlist_globex_sizes" },
		}
		local only = Scope.accountOnly(listed, { "customlist_acme_" }, { customlist_acme_sizes = true })
		expect(#only).toBe(1)
		expect(only[1].scriptId).toBe("CUSTOMLIST_ACME_REGIONS")
	end)
end)

describe("drift scratch", function()
	it("refuses an auth ID that would break project.json", function()
		local plan, why = Scratch.plan({ ["suitecloud.config.js"] = "x", ["src/manifest.xml"] = "<m/>" }, "src", 'a"b')
		expect(plan).toBeNil()
		expect(why).toContain("auth ID")
	end)

	it("refuses a project folder that leaves the scratch directory", function()
		local _, why = Scratch.plan({ ["suitecloud.config.js"] = "x", ["../manifest.xml"] = "<m/>" }, "..", "demo-sb")
		expect(why).toContain("leaves the project")
	end)

	it("needs the manifest, without which the CLI cannot import", function()
		local _, why = Scratch.plan({ ["suitecloud.config.js"] = "x" }, "src", "demo-sb")
		expect(why).toContain("manifest.xml")
	end)
end)

describe("drift cache", function()
	local result: Cache.Result = {
		root = "/work/acme/billing",
		authId = "demo-sb",
		account = "1234567_SB1",
		production = false,
		at = 1700000000,
		objects = {
			Compare.pending("object", "customlist_acme_sizes", "customlist", "src/Objects/customlist_acme_sizes.xml"),
		},
		files = {},
		accountOnly = nil,
		problems = { "note" },
	}

	it("round-trips a result for the same project and auth ID", function()
		local back = Cache.decode(Cache.encode(result), result.root, result.authId)
		expect(back and back.objects[1].id).toBe("customlist_acme_sizes")
		expect(back and back.production).toBe(false)
	end)

	it("never shows one target's result for another", function()
		expect(Cache.decode(Cache.encode(result), result.root, "demo-prod")).toBeNil()
		expect(Cache.decode(Cache.encode(result), "/work/acme/storefront", "demo-sb")).toBeNil()
		expect(Cache.fileName(result.root, "demo-sb") ~= Cache.fileName(result.root, "demo-prod")).toBe(true)
	end)

	it("drops malformed cache files", function()
		local v = Cache.encode(result)
		v.objects = { { kind = "object", id = "x", status = "bogus" } }
		expect(Cache.decode(v, result.root, result.authId)).toBeNil()
		expect(Cache.decode("junk", result.root, result.authId)).toBeNil()
	end)

	it("keys one project the same whether reached through /tmp or /private/tmp", function()
		local files = {
			{ path = "project.json", size = 1, real = "/private/tmp/acme/billing/project.json" },
			{ path = "src/manifest.xml", size = 1, real = "/private/tmp/acme/billing/src/manifest.xml" },
			-- Symlinked in from a shared folder that happens to end the same way.
			{ path = "src/FileCabinet/lib.js", size = 1, real = "/work/shared/src/FileCabinet/lib.js" },
		}
		expect(Cache.resolvedRoot("/tmp/acme/billing", files)).toBe("/private/tmp/acme/billing")
		expect(Cache.resolvedRoot("/private/tmp/acme/billing", { { path = "project.json", size = 1 } })).toBe(
			"/private/tmp/acme/billing"
		)
	end)
end)

return nil
