--!strict
local Filter = require("../../../plugin/lib/deployments/filter")
local Link = require("../../../plugin/lib/deployments/link")
local Owners = require("../../../plugin/lib/deployments/owners")
local Pages = require("../../../plugin/lib/deployments/pages")
local Query = require("../../../plugin/lib/deployments/query")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local function project(root: string, objects: { any }, authId: string?): any
	return {
		name = string.match(root, "([^/]+)$"),
		root = root,
		projectFolder = "src",
		defaultAuthId = authId,
		objects = objects,
		files = {},
		paths = {},
		truncated = false,
		diagnostics = {},
	}
end

local function object(id: string, deploy: string, real: string?): any
	return {
		scriptId = id,
		type = "usereventscript",
		path = "src/Objects/" .. id .. ".xml",
		real = real,
		line = 1,
		isScript = true,
		children = { deploy },
		childPaths = { deploy },
		references = {},
		fileReferences = {},
		deployments = { { scriptId = deploy, status = "RELEASED", logLevel = "DEBUG", line = 9 } },
	}
end

describe("local owners of a deployment", function()
	local billing = project("/work/acme/billing", { object("customscript_a", "customdeploy_a") }, "demo-sb")
	local storefront = project("/work/acme/storefront", {
		object("customscript_a", "customdeploy_a", "/work/acme/shared/customscript_a.xml"),
		object("customscript_b", "customdeploy_b"),
	}, "demo-prod")
	local index = Owners.index({ billing, storefront })

	it("finds the object file and line that define a deployment", function()
		local o = Owners.pick(index, "CUSTOMDEPLOY_B", nil)
		assert(o, "owner")
		expect(o.path).toBe("/work/acme/storefront/src/Objects/customscript_b.xml")
		expect(o.line).toBe(9)
		expect(o.tag).toBe("usereventscript")
		expect(o.authId).toBe("demo-prod")
	end)

	it("edits a symlinked object at its real path so the link survives", function()
		local o = Owners.pick(index, "customdeploy_a", "/work/acme/storefront/src")
		assert(o, "owner")
		expect(o.path).toBe("/work/acme/shared/customscript_a.xml")
	end)

	it("picks the project the block was opened in when several define the deployment", function()
		local o = Owners.pick(index, "customdeploy_a", "/work/acme/billing")
		assert(o, "owner")
		expect(o.root).toBe("/work/acme/billing")
	end)

	it("refuses to guess between projects from outside them", function()
		local o, why = Owners.pick(index, "customdeploy_a", "/work")
		expect(o).toBeNil()
		expect(why).toContain("2 local projects define this deployment (billing, storefront)")
	end)

	it("says when no local project defines the deployment", function()
		local _, why = Owners.pick(index, "customdeploy_zzz", nil)
		expect(why).toContain("no local SDF project")
	end)

	it("builds a deploy command a shell runs as written, and refuses unsafe paths", function()
		expect((Owners.deployCommand("/work/acme/billing"))).toBe("cd /work/acme/billing && suitecloud project:deploy")
		expect((Owners.deployCommand("/work/My Projects/billing"))).toBe(
			"cd '/work/My Projects/billing' && suitecloud project:deploy"
		)
		local cmd, why = Owners.deployCommand("/work/it's/billing")
		expect(cmd).toBeNil()
		expect(why).toContain("quotes")
		expect((Owners.deployCommand("/work/a\\b"))).toBeNil()
	end)
end)

describe("NetSuite UI pages", function()
	it("opens deployments and scripts on the account's own domain", function()
		expect(Pages.deployment("1234567_SB1", 203)).toBe(
			"https://1234567-sb1.app.netsuite.com/app/common/scripting/scriptrecord.nl?id=203"
		)
		expect(Pages.script("1234567", 103)).toBe(
			"https://1234567.app.netsuite.com/app/common/scripting/script.nl?id=103"
		)
	end)

	it("offers no page without a usable internal id or account id", function()
		expect(Pages.deployment("1234567_SB1", nil)).toBeNil()
		expect(Pages.deployment("1234567_SB1", 1.5)).toBeNil()
		expect(Pages.script("evil.example.com/x", 1)).toBeNil()
	end)
end)

describe("deployment filters", function()
	local rows = Query.fromRows(json.decode(fixtures.read("deployments/list-rest.json")).items)

	it("cycles each facet through the values present, then back to all", function()
		local types = Filter.values(rows, "type")
		expect(types).toEqual({ "MAPREDUCE", "RESTLET", "SCHEDULED", "SCRIPTLET", "USEREVENT" })
		expect(Filter.cycle(types, nil)).toBe("MAPREDUCE")
		expect(Filter.cycle(types, "USEREVENT")).toBeNil()
	end)

	it("treats not deployed as a status of its own", function()
		expect(Filter.values(rows, "status")).toEqual({ "NOT DEPLOYED", "NOTSCHEDULED", "RELEASED", "SCHEDULED" })
	end)

	it("needs every word of the text in an id, title, script or record type", function()
		local f = Filter.withText(Filter.new(), "acme SalesOrder")
		local hits = {}
		for _, d in rows do
			if Filter.matches(d, f) then
				table.insert(hits, d.scriptId)
			end
		end
		expect(hits).toEqual({ "customdeploy_acme_order_ue" })
	end)

	it("combines text and facets", function()
		local f = Filter.withText(Filter.new(), "acme")
		f.level = "DEBUG"
		local n = 0
		for _, d in rows do
			if Filter.matches(d, f) then
				n += 1
			end
		end
		expect(n).toBe(2)
	end)
end)

describe("deployments links", function()
	it("opens the block held, so a printed link queries nothing before Enter", function()
		local d = Link.route("tern-netsuite://deployments?connection=acme-sb&q=order%20guard")
		assert(d, "decision")
		expect(d.block).toBe("tern-netsuite.deployments")
		expect(d.args).toEqual({ "connection=acme-sb", "q=order guard", "hold=1" })
		local launch = Link.fromArgs(d.args)
		expect(launch).toEqual({ connection = "acme-sb", query = "order guard", hold = true })
	end)

	it("refuses unknown parameters, paths and repeated values", function()
		expect((Link.route("tern-netsuite://deployments?edit=1"))).toBeNil()
		expect((Link.route("tern-netsuite://deployments/write?x=1"))).toBeNil()
		expect((Link.route("tern-netsuite://deployments?q=a&q=b"))).toBeNil()
		expect((Link.route("tern-netsuite://deployments?connection=Bad%20Id"))).toBeNil()
	end)

	it("round-trips its own URL", function()
		local url = Link.url({ connection = "acme-sb", query = "nightly" })
		expect(url).toBe("tern-netsuite://deployments?connection=acme-sb&q=nightly")
		expect((Link.route(url))).toEqual({
			block = "tern-netsuite.deployments",
			args = { "connection=acme-sb", "q=nightly", "hold=1" },
		})
	end)
end)

return nil
