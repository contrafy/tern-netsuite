--!strict
local Project = require("../../../plugin/lib/sdf/project")
local Snapshot = require("../../../plugin/lib/sdf/snapshot")
local Symlinks = require("../../../plugin/lib/sdf/symlinks")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

type SnapshotFile = Snapshot.SnapshotFile

local MANIFEST = '<manifest projecttype="ACCOUNTCUSTOMIZATION"><projectname>x</projectname></manifest>'
local DEPLOY = "<deploy><files><path>~/FileCabinet/*</path></files><objects><path>~/Objects/*</path></objects></deploy>"

local function project(root: string, extra: { SnapshotFile }): Project.Project
	local files: { SnapshotFile } = {
		{ path = "src/manifest.xml", size = #MANIFEST, text = MANIFEST },
		{ path = "src/deploy.xml", size = #DEPLOY, text = DEPLOY },
	}
	table.move(extra, 1, #extra, #files + 1, files)
	return Project.build({ root = root, files = files })
end

local LIST = '<customlist scriptid="customlist_shared"/>'

local billing = project("/repo/sdf/billing", {
	{
		path = "src/FileCabinet/SuiteScripts/common/utils/http.js",
		real = "/repo/netsuite/common/utils/http.js",
		size = 10,
	},
	{ path = "src/FileCabinet/SuiteScripts/billing/run.js", size = 10 },
	{
		path = "src/Objects/customlist_shared.xml",
		real = "/repo/netsuite/objects/customlist_shared.xml",
		size = #LIST,
		text = LIST,
	},
})
local storefront = project("/repo/sdf/storefront", {
	-- A directory symlink: the file's own path holds no link.
	{
		path = "src/FileCabinet/SuiteScripts/lib/utils/http.js",
		real = "/repo/netsuite/common/utils/http.js",
		size = 10,
	},
	{
		path = "src/Objects/customlist_shared.xml",
		real = "/repo/netsuite/objects/customlist_shared.xml",
		size = #LIST,
		text = LIST,
	},
})
local index = Symlinks.index({ storefront, billing })

describe("finding where a source file is deployed from", function()
	it("lists every project that symlinks a shared file, with its File Cabinet path", function()
		local owners = Symlinks.owners(index, "/repo/netsuite/common/utils/http.js")
		expect(owners).toEqual({
			{
				project = "billing",
				root = "/repo/sdf/billing",
				path = "src/FileCabinet/SuiteScripts/common/utils/http.js",
				fileCabinetPath = "/SuiteScripts/common/utils/http.js",
			},
			{
				project = "storefront",
				root = "/repo/sdf/storefront",
				path = "src/FileCabinet/SuiteScripts/lib/utils/http.js",
				fileCabinetPath = "/SuiteScripts/lib/utils/http.js",
			},
		})
	end)

	it("finds the same owners from any project's view of the file", function()
		local fromLink = Symlinks.owners(index, "/repo/sdf/storefront/src/FileCabinet/SuiteScripts/lib/utils/http.js")
		expect(#fromLink).toBe(2)
		expect(fromLink).toEqual(Symlinks.owners(index, "/repo/netsuite/common/utils/http.js"))
	end)

	it("returns a file living in the project itself", function()
		local owners = Symlinks.owners(index, "/repo/sdf/billing/src/FileCabinet/SuiteScripts/billing/run.js")
		expect(#owners).toBe(1)
		expect(owners[1].fileCabinetPath).toBe("/SuiteScripts/billing/run.js")
	end)

	it("lists shared object XML without a File Cabinet path", function()
		local owners = Symlinks.owners(index, "/repo/netsuite/objects/customlist_shared.xml")
		expect(#owners).toBe(2)
		expect(owners[1].fileCabinetPath).toBeNil()
		expect(owners[2].path).toBe("src/Objects/customlist_shared.xml")
	end)

	it("accepts unnormalized paths such as editors report them", function()
		expect(#Symlinks.owners(index, "/repo/netsuite/./common//utils/../utils/http.js")).toBe(2)
	end)

	it("returns nothing for a file no project deploys", function()
		expect(Symlinks.owners(index, "/repo/netsuite/common/unused.js")).toEqual({})
		expect(Symlinks.owners(index, "/repo/sdf/billing/src/manifest.xml")).toEqual({})
	end)
end)

return nil
