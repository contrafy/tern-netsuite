--!strict
local Library = require("../../../plugin/lib/console/library")
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

-- A folder tree in memory: path -> file text, plus the folders.
local function fakeFs(files: { [string]: string }, dirs: { [string]: { string } }): Library.Fs
	return {
		list = function(dir: string): { string }?
			return dirs[dir]
		end,
		read = function(path: string, max: number): string?
			local text = files[path]
			if text == nil or #text > max then
				return nil
			end
			return text
		end,
	}
end

describe("console saved query folders", function()
	it("resolves relative folders in the repository, ~/ in the home directory", function()
		local folders, problems = Library.folders(
			{ "sql/queries", "~/acme-sql", "/srv/shared/./sql/", "sql/queries/" },
			"/tmp/acme",
			"/Users/demo"
		)
		expect(folders).toEqual({
			{ configured = "sql/queries", path = "/tmp/acme/sql/queries" },
			{ configured = "~/acme-sql", path = "/Users/demo/acme-sql" },
			{ configured = "/srv/shared/./sql/", path = "/srv/shared/sql" },
		})
		expect(problems).toEqual({})
	end)

	it("explains folders it cannot resolve instead of guessing", function()
		local folders, problems = Library.folders({ "sql", "~demo/sql" }, nil, "/Users/demo")
		expect(folders).toEqual({})
		expect(#problems).toBe(2)
		expect(problems[2]).toContain("only ~/ (your home) is expanded")
	end)

	it("lists .sql files titled by their leading comment, else by file name", function()
		local fs = fakeFs({
			["/tmp/acme/sql/open-orders.sql"] = fixtures.read("console/sql/open-orders.sql"),
			["/tmp/acme/sql/customers.sql"] = fixtures.read("console/sql/customers.sql"),
		}, { ["/tmp/acme/sql"] = { "README.md", "customers.sql", "open-orders.sql", ".hidden.sql" } })
		local files, problems = Library.collect(fs, { { configured = "sql", path = "/tmp/acme/sql" } })
		expect(problems).toEqual({})
		expect(files).toEqual({
			{ path = "/tmp/acme/sql/customers.sql", name = "customers.sql", folder = "sql" } :: any,
			{
				path = "/tmp/acme/sql/open-orders.sql",
				name = "open-orders.sql",
				title = "Open sales orders, newest first",
				folder = "sql",
			},
		})
	end)

	it("reports a folder it cannot list and keeps going", function()
		local fs = fakeFs({}, { ["/b"] = { "x.sql" } })
		local files, problems =
			Library.collect(fs, { { configured = "a", path = "/a" }, { configured = "b", path = "/b" } })
		expect(#files).toBe(1)
		expect(problems).toEqual({ "console.saved_dirs: cannot list /a" })
	end)
end)

describe("console query picker", function()
	local items = Library.items({
		{ name = "Old", sql = "-- Old one\nSELECT 1", at = 1 },
		{ name = "New", sql = "\n  SELECT id FROM customer\n", at = 2 },
	}, {
		{ path = "/tmp/acme/sql/open-orders.sql", name = "open-orders.sql", title = "Open orders", folder = "sql" },
	})

	it("lists saved queries newest first, then folder files", function()
		expect(items[1].label).toBe("New")
		expect(items[1].detail).toBe("SELECT id FROM customer")
		expect(items[2].label).toBe("Old")
		expect(items[2].detail).toBe("SELECT 1")
		expect(items[3]).toEqual({
			kind = "file",
			label = "Open orders",
			detail = "sql/open-orders.sql",
			path = "/tmp/acme/sql/open-orders.sql",
		})
	end)

	it("filters on every typed word in the title or the location", function()
		expect(#Library.filter(items, "")).toBe(3)
		local found = Library.filter(items, "SQL open")
		expect(#found).toBe(1)
		expect(found[1].kind).toBe("file")
	end)
end)

return nil
