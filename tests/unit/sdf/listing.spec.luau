--!strict
local Listing = require("../../../plugin/lib/sdf/listing")
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local function status(name: string): number
	return tonumber((string.gsub(fixtures.read("suitecloud/list/" .. name .. ".exit"), "%s", ""))) :: number
end

local function objects(name: string): Listing.ObjectList?
	return Listing.objects(fixtures.lines("suitecloud/list/" .. name .. ".txt"), status(name))
end

local function files(name: string): Listing.FileList?
	return Listing.files(fixtures.lines("suitecloud/list/" .. name .. ".txt"), status(name))
end

describe("object:list output", function()
	it("reads every type:scriptid line of a real account listing", function()
		local r = objects("object-all") :: Listing.ObjectList
		expect(#r.objects).toBe(136)
		expect(r.objects[1]).toEqual({ type = "addressForm", scriptId = "custform_demo_1" })
		expect(r.empty).toBe(false)
		expect(#r.unknown).toBe(0)
	end)

	it("keeps the CLI's order so the listing reads like the raw output", function()
		local r = objects("object-type") :: Listing.ObjectList
		local types: { string } = {}
		for _, o in r.objects do
			table.insert(types, o.type)
		end
		expect(types).toEqual({ "restlet", "restlet", "restlet", "suitelet", "suitelet", "suitelet" })
	end)

	it("treats the no-match sentence as an empty listing, not as unknown output", function()
		for _, name in { "object-none", "object-unknown-type" } do
			local r = objects(name) :: Listing.ObjectList
			expect(#r.objects).toBe(0)
			expect(r.empty).toBe(true)
			expect(#r.unknown).toBe(0)
		end
	end)

	it("returns nil for a failed run so callers show the CLI's own error", function()
		expect(objects("object-unknown-auth")).toBeNil()
		expect(objects("object-no-account")).toBeNil()
	end)

	it("cleans the spinner's escape codes that tern.process.run leaves in stdout", function()
		local lines =
			Listing.split("\27[2K\27[1GThe following objects were found in your account:\nrestlet:customscript_x\n")
		local r = Listing.objects(lines, 0) :: Listing.ObjectList
		expect(r.objects).toEqual({ { type = "restlet", scriptId = "customscript_x" } })
	end)

	it("keeps lines it cannot place so nothing the CLI printed is hidden", function()
		local r = Listing.objects({
			"The following objects were found in your account:",
			"restlet:customscript_x",
			"Some new notice from the SDK",
		}, 0) :: Listing.ObjectList
		expect(#r.objects).toBe(1)
		expect(r.unknown).toEqual({ { line = 3, text = "Some new notice from the SDK" } })
	end)

	it("does not mistake a colon-bearing message before the header for an object", function()
		local r =
			Listing.objects({ "Warning:deprecated", "There are no objects matching your search criteria." }, 0) :: Listing.ObjectList
		expect(#r.objects).toBe(0)
		expect(r.unknown[1].text).toBe("Warning:deprecated")
	end)
end)

describe("file:list output", function()
	it("reads one File Cabinet path per line, spaces included", function()
		local r = files("file-folder") :: Listing.FileList
		expect(r.files).toEqual({
			"/SuiteScripts/tns_demo/lib/tns_util.js",
			"/SuiteScripts/tns_demo/tns_demo_restlet.js",
			"/SuiteScripts/tns_demo_suitelet.js",
			"/SuiteScripts/tns demo/report template.html",
		})
		expect(r.empty).toBe(false)
	end)

	it("treats 'No files found.' as an empty folder", function()
		local r = files("file-missing-folder") :: Listing.FileList
		expect(#r.files).toBe(0)
		expect(r.empty).toBe(true)
	end)

	it("returns nil when the CLI refused the options", function()
		expect(files("file-no-folder")).toBeNil()
	end)
end)

describe("errors and summaries", function()
	it("names the first thing the CLI said when a run fails", function()
		local text = Listing.errorText(fixtures.lines("suitecloud/list/object-unknown-auth.txt"))
		expect(text).toBe(
			'The "demo-missing" authentication ID is not available. Check your authentication credentials and try again.'
		)
		expect(Listing.errorText({ "", "  " })).toBeNil()
	end)

	it("counts objects per type, largest first, for a quick overview of the account", function()
		local counts = Listing.byType({
			{ type = "suitelet", scriptId = "a" },
			{ type = "restlet", scriptId = "b" },
			{ type = "suitelet", scriptId = "c" },
			{ type = "clientscript", scriptId = "d" },
		})
		expect(counts).toEqual({
			{ type = "suitelet", count = 2 },
			{ type = "clientscript", count = 1 },
			{ type = "restlet", count = 1 },
		})
	end)

	it("groups files by folder for the same overview", function()
		local counts = Listing.byFolder({ "/SuiteScripts/a/x.js", "/SuiteScripts/a/y.js", "/SuiteScripts/z.js" })
		expect(counts).toEqual({
			{ folder = "/SuiteScripts/a", count = 2 },
			{ folder = "/SuiteScripts", count = 1 },
		})
	end)
end)

return nil
