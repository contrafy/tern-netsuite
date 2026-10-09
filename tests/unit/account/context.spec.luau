--!strict
local Context = require("../../../plugin/lib/account/context")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

-- A fake file tree: path -> text (directories are implied by their files;
-- "" marks a directory or marker with no text).
local function lookup(files: { [string]: string }): Context.Lookup
	local dirs: { [string]: { [string]: boolean } } = {}
	for path in files do
		local child = path
		local parent = string.match(child, "^(.*)/[^/]+$")
		while parent do
			local key = if parent == "" then "/" else parent
			dirs[key] = dirs[key] or {}
			dirs[key][string.match(child, "([^/]+)$") :: string] = true
			child = parent
			parent = string.match(child, "^(.*)/[^/]+$")
		end
	end
	return {
		exists = function(path: string): boolean
			return files[path] ~= nil or dirs[path] ~= nil
		end,
		read = function(path: string): string?
			local text = files[path]
			return if text == "" then nil else text
		end,
		list = function(path: string): { string }
			local out: { string } = {}
			local names: { [string]: boolean } = dirs[path] or {}
			for name in names do
				table.insert(out, name)
			end
			table.sort(out)
			return out
		end,
		decode = json.decode,
	}
end

local REPO = {
	["/w/repo/.git"] = "",
	["/w/repo/sdf/billing/suitecloud.config.js"] = "module.exports = {}",
	["/w/repo/sdf/billing/project.json"] = '{"defaultAuthId": "demo-sb"}',
	["/w/repo/sdf/billing/src/FileCabinet/SuiteScripts/a.js"] = "x",
	["/w/repo/sdf/noauth/suitecloud.config.js"] = "x",
	["/w/repo/sdf/broken/suitecloud.config.js"] = "x",
	["/w/repo/sdf/broken/project.json"] = "{not json",
	["/w/repo/sdf/wrongtype/suitecloud.config.js"] = "x",
	["/w/repo/sdf/wrongtype/project.json"] = '{"defaultAuthId": 7}',
	["/w/repo/README.md"] = "x",
}

describe("finding the SDF project of a pane", function()
	local l = lookup(REPO)

	it("finds the project from a deeply nested directory inside it", function()
		local c = Context.forCwd("/w/repo/sdf/billing/src/FileCabinet/SuiteScripts", l) :: Context.Context
		expect(c.projectRoot).toBe("/w/repo/sdf/billing")
		expect(c.projectName).toBe("billing")
		expect(c.authId).toBe("demo-sb")
		expect(c.problem).toBeNil()
	end)

	it("accepts a trailing slash, as some shells report it", function()
		local c = Context.forCwd("/w/repo/sdf/billing/", l) :: Context.Context
		expect(c.projectRoot).toBe("/w/repo/sdf/billing")
	end)

	it("shows nothing outside an SDF project", function()
		expect(Context.forCwd("/w/repo", l)).toBeNil()
		expect(Context.forCwd("/w/repo/sdf", l)).toBeNil()
		expect(Context.forCwd("/", l)).toBeNil()
	end)

	it("shows nothing for an unknown or relative cwd", function()
		expect(Context.forCwd("", l)).toBeNil()
		expect(Context.forCwd("sdf/billing", l)).toBeNil()
	end)

	it("stops at the repository root, so a stray config above it does not claim the repo", function()
		local files = table.clone(REPO)
		files["/w/suitecloud.config.js"] = "x"
		expect(Context.forCwd("/w/repo/docs", lookup(files))).toBeNil()
	end)

	it("still finds a project whose root is the repository root", function()
		local c = Context.forCwd(
			"/p/src",
			lookup({ ["/p/.git"] = "", ["/p/suitecloud.config.js"] = "x", ["/p/src/manifest.xml"] = "x" })
		) :: Context.Context
		expect(c.projectRoot).toBe("/p")
	end)

	it("keeps the project but no auth id when project.json is missing (the CLI would prompt)", function()
		local c = Context.forCwd("/w/repo/sdf/noauth", l) :: Context.Context
		expect(c.projectName).toBe("noauth")
		expect(c.authId).toBeNil()
		expect(c.problem).toContain("no project.json")
	end)

	it("reports invalid project.json instead of guessing an account", function()
		local c = Context.forCwd("/w/repo/sdf/broken", l) :: Context.Context
		expect(c.authId).toBeNil()
		expect(c.problem).toContain("not valid JSON")
		local w = Context.forCwd("/w/repo/sdf/wrongtype", l) :: Context.Context
		expect(w.authId).toBeNil()
		expect(w.problem).toContain("defaultAuthId")
	end)
end)

describe("finding the repository and its projects", function()
	local l = lookup(REPO)

	it("finds the repository root above a project", function()
		expect(Context.repoRoot("/w/repo/sdf/billing/src", l.exists)).toBe("/w/repo")
		expect(Context.repoRoot("/elsewhere", l.exists)).toBeNil()
	end)

	it("lists the projects under the configured roots with their auth ids", function()
		local found = Context.projectsUnder("/w/repo", { "sdf" }, l, 100)
		local names: { string } = {}
		for _, p in found do
			table.insert(names, p.projectName .. "=" .. (p.authId or "-"))
		end
		expect(names).toEqual({ "billing=demo-sb", "broken=-", "noauth=-", "wrongtype=-" })
	end)

	it("caps the scan so a huge directory cannot stall the doctor", function()
		expect(#Context.projectsUnder("/w/repo", { "sdf" }, l, 2)).toBe(2)
	end)

	it("ignores a root that does not exist", function()
		expect(#Context.projectsUnder("/w/repo", { "nope" }, l, 100)).toBe(0)
	end)
end)

return nil
