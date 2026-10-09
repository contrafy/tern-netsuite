--!strict
local Diff = require("../../../plugin/lib/browser/diff")
local Listing = require("../../../plugin/lib/sdf/listing")
local fixtures = require("../../lib/fixtures")
local sample = require("./sample")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

type Entry = Diff.Entry

local function accountObjects(): { Listing.Object }
	local r = Listing.objects(fixtures.lines("suitecloud/list/object-all.txt"), 0) :: Listing.ObjectList
	return r.objects
end

local function accountFiles(): { string }
	local r = Listing.files(fixtures.lines("suitecloud/list/file-folder.txt"), 0) :: Listing.FileList
	return r.files
end

local function find(entries: { Entry }, id: string): Entry?
	for _, e in entries do
		if e.id == id then
			return e
		end
	end
	return nil
end

describe("object diff", function()
	local entries = Diff.objects(accountObjects(), sample.project())

	it("marks an object present in the account and the project as in both, with its local file", function()
		local e = find(entries, "customscript_demo_89") :: Entry
		expect(e.where).toBe("both")
		expect(e.type).toBe("restlet")
		expect(e.localPath).toBe("src/Objects/customscript_demo_89.xml")
	end)

	it("marks objects only the account has as importable", function()
		local e = find(entries, "custtmpl_demo_2") :: Entry
		expect(e.where).toBe("account")
		expect(e.localPath).toBeNil()
	end)

	it("lists objects the account does not have as local only, so a deploy would create them", function()
		local e = find(entries, "customlist_local_only") :: Entry
		expect(e.where).toBe("local")
		expect(e.type).toBe("customlist")
		expect(e.localPath).toBe("src/Objects/lists/customlist_local_only.xml")
	end)

	it("matches scriptids case-insensitively, as NetSuite does", function()
		local out = Diff.objects({ { type = "restlet", scriptId = "CUSTOMSCRIPT_DEMO_89" } }, sample.project())
		expect((find(out, "CUSTOMSCRIPT_DEMO_89") :: Entry).where).toBe("both")
	end)

	it("counts each side for the header", function()
		local c = Diff.counts(entries)
		expect(c.all).toBe(137)
		expect(c.both).toBe(1)
		expect(c["local"]).toBe(1)
		expect(c.account).toBe(135)
	end)
end)

describe("file diff", function()
	local project = sample.project()
	local folders = Diff.folders(project)

	it("lists the File Cabinet top folders the project ships files to", function()
		expect(folders).toEqual({ "/SuiteScripts" })
	end)

	it("falls back to /SuiteScripts for a project without files", function()
		local p = table.clone(project)
		p.files = {}
		expect(Diff.folders(p)).toEqual({ "/SuiteScripts" })
	end)

	it("classifies account and local files by File Cabinet path", function()
		local entries = Diff.files(accountFiles(), folders, project)
		expect((find(entries, "/SuiteScripts/tns_demo/tns_demo_restlet.js") :: Entry).where).toBe("both")
		expect((find(entries, "/SuiteScripts/tns_demo_suitelet.js") :: Entry).where).toBe("account")
		local only = find(entries, "/SuiteScripts/local_only.js") :: Entry
		expect(only.where).toBe("local")
		expect(only.localPath).toBe("src/FileCabinet/SuiteScripts/local_only.js")
	end)

	it("ignores local files outside the listed folders instead of calling them local only", function()
		local entries = Diff.files({}, { "/Templates" }, project)
		expect(#entries).toBe(0)
	end)
end)

describe("filters", function()
	local entries = Diff.objects(accountObjects(), sample.project())

	it("narrows to one side", function()
		local out = Diff.apply(entries, { where = "local", type = nil, query = "" })
		expect(#out).toBe(1)
		expect(out[1].id).toBe("customlist_local_only")
	end)

	it("narrows to one type", function()
		local out = Diff.apply(entries, { where = "all", type = "restlet", query = "" })
		expect(#out).toBe(3)
	end)

	it("searches ids and types case-insensitively, every word must match", function()
		expect(#Diff.apply(entries, { where = "all", type = nil, query = "CUSTTMPL" })).toBe(3)
		expect(#Diff.apply(entries, { where = "all", type = nil, query = "restlet demo" })).toBe(3)
		expect(#Diff.apply(entries, { where = "all", type = nil, query = "restlet nothing" })).toBe(0)
	end)

	it("treats search text literally, so ids with dots or dashes are searchable", function()
		local out = Diff.apply({
			{ kind = "file", id = "/SuiteScripts/a.b-c.js", where = "account" },
			{ kind = "file", id = "/SuiteScripts/abxc.js", where = "account" },
		}, { where = "all", type = nil, query = "a.b-" })
		expect(#out).toBe(1)
	end)

	it("offers every type present, alphabetically, for the type filter", function()
		local types = Diff.types(entries)
		expect(types[1]).toBe("addressForm")
		expect(table.find(types, "customlist") ~= nil).toBe(true)
	end)

	it("cycles the side filter and the type filter, wrapping back to all", function()
		expect(Diff.nextWhere("all")).toBe("account")
		expect(Diff.nextWhere("account")).toBe("both")
		expect(Diff.nextWhere("both")).toBe("local")
		expect(Diff.nextWhere("local")).toBe("all")
		local types = { "a", "b" }
		expect(Diff.nextType(types, nil, 1)).toBe("a")
		expect(Diff.nextType(types, "b", 1)).toBeNil()
		expect(Diff.nextType(types, nil, -1)).toBe("b")
		expect(Diff.nextType(types, "gone", 1)).toBeNil()
	end)
end)

return nil
