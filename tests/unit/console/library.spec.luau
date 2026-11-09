--!strict
local Library = require("../../../plugin/lib/console/library")
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

-- Files in memory plus find's answers per folder (nil: not a folder).
local function fakeIo(files: { [string]: string }, finds: { [string]: Library.Run }): (Library.Io, { { string } })
	local calls: { { string } } = {}
	return {
		list = function(dir: string): { string }?
			return if finds[dir] then {} else nil
		end,
		read = function(path: string, max: number): string?
			local text = files[path]
			if text == nil or #text > max then
				return nil
			end
			return text
		end,
		run = function(argv: { string }, _timeoutMs: number, cb: (Library.Run) -> ())
			table.insert(calls, argv)
			cb(finds[argv[3]])
		end,
	},
		calls
end

local function ok(paths: { string }): Library.Run
	return {
		status = 0,
		stdout = table.concat(paths, "\0") .. (if #paths > 0 then "\0" else ""),
		stderr = "",
		timed_out = false,
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

	it("walks folders with find, not following symlinks below them, skipping hidden folders", function()
		local argv = Library.findArgv("/tmp/acme/sql")
		expect(table.concat(argv, " ")).toBe(
			"find -H /tmp/acme/sql -mindepth 1 ( -type d ( -name .* -o -name node_modules ) ) -prune -o -type f -iname *.sql -print0"
		)
	end)

	it("keeps .sql paths relative to the folder, sorted, dropping a cut-off last record", function()
		local out = "/tmp/acme/sql/z.sql\0/tmp/acme/sql/reports/open.SQL\0/tmp/acme/sql/.x.sql\0"
			.. "/tmp/acme/sql/a/b.sql\0/tmp/acme/sql/cut"
		expect(Library.parseFound("/tmp/acme/sql", out)).toEqual({ "a/b.sql", "reports/open.SQL", "z.sql" })
		expect(Library.parseFound("/", "/q.sql\0")).toEqual({ "q.sql" })
	end)

	it("lists .sql files of subfolders titled by their leading comment, else by file name", function()
		local io, calls = fakeIo({
			["/tmp/acme/sql/orders/open-orders.sql"] = fixtures.read("console/sql/open-orders.sql"),
			["/tmp/acme/sql/customers.sql"] = fixtures.read("console/sql/customers.sql"),
		}, {
			["/tmp/acme/sql"] = ok({ "/tmp/acme/sql/orders/open-orders.sql", "/tmp/acme/sql/customers.sql" }),
		})
		local got: { any } = {}
		Library.collect(io, { { configured = "sql", path = "/tmp/acme/sql" } }, function(files, problems, omitted)
			got = { files, problems, omitted }
		end)
		expect(calls[1][3]).toBe("/tmp/acme/sql")
		expect(got[2]).toEqual({})
		expect(got[3]).toBe(0)
		expect(got[1]).toEqual({
			{ path = "/tmp/acme/sql/customers.sql", name = "customers.sql", rel = "customers.sql", folder = "sql" } :: any,
			{
				path = "/tmp/acme/sql/orders/open-orders.sql",
				name = "open-orders.sql",
				rel = "orders/open-orders.sql",
				title = "Open sales orders, newest first",
				folder = "sql",
			},
		})
	end)

	it("reports a folder it cannot list or fully read and keeps going", function()
		local io = fakeIo({}, {
			["/b"] = {
				status = 1,
				stdout = "/b/x.sql\0",
				stderr = "find: /b/locked: Permission denied\n",
				timed_out = false,
			},
			["/c"] = { status = -1, stdout = "/c/y.sql\0/c/z", stderr = "", timed_out = true },
		})
		local got: { any } = {}
		Library.collect(io, {
			{ configured = "a", path = "/a" },
			{ configured = "b", path = "/b" },
			{ configured = "c", path = "/c" },
		}, function(files, problems)
			got = { files, problems }
		end)
		expect(#got[1]).toBe(2)
		expect(got[2]).toEqual({
			"console.saved_dirs: cannot list /a",
			"console.saved_dirs: could not read all of /b (find: /b/locked: Permission denied)",
			"console.saved_dirs: reading /c took over 10 s; listing what was found by then",
		})
	end)

	it("lists a file once when configured folders overlap", function()
		local files = Library.entries(function()
			return nil
		end, {
			{ configured = "sql", path = "/r/sql" },
			{ configured = "sql/reports", path = "/r/sql/reports" },
		}, { { "reports/a.sql" }, { "a.sql", "b.sql" } })
		expect(#files).toBe(2)
		expect(files[1].rel).toBe("reports/a.sql")
		expect(files[2].path).toBe("/r/sql/reports/b.sql")
	end)

	it("lists at most MAX_FILES in all and counts the rest", function()
		local first: { string } = {}
		for i = 1, Library.MAX_FILES - 2 do
			table.insert(first, string.format("q%04d.sql", i))
		end
		local reads = 0
		local files, omitted = Library.entries(function()
			reads += 1
			return nil
		end, {
			{ configured = "a", path = "/a" },
			{ configured = "b", path = "/b" },
		}, { first, { "x.sql", "y.sql", "z/1.sql", "z/2.sql", "z/3.sql" } })
		expect(#files).toBe(Library.MAX_FILES)
		expect(reads).toBe(Library.MAX_FILES)
		expect(omitted).toBe(3)
		expect(files[Library.MAX_FILES].rel).toBe("y.sql")
		expect(Library.omittedText(3)).toBe("3 more .sql files not listed: only the first 500 are")
		expect(Library.omittedText(1)).toBe("1 more .sql file not listed: only the first 500 are")
	end)

	it("adds the count of files not listed to the problems", function()
		local paths: { string } = {}
		for i = 1, Library.MAX_FILES + 4 do
			table.insert(paths, string.format("/s/n/q%04d.sql", i))
		end
		local io = fakeIo({}, { ["/s"] = ok(paths) })
		local got: { any } = {}
		Library.gather(
			io,
			function()
				return false
			end,
			{ "/s" },
			nil,
			nil,
			function(files, problems, omitted)
				got = { files, problems, omitted }
			end
		)
		expect(#got[1]).toBe(Library.MAX_FILES)
		expect(got[2]).toEqual({ Library.omittedText(4) })
		expect(got[3]).toBe(4)
	end)

	it("runs find through the adapter's spawn, passing its extra answer values on", function()
		local opts: any, extra: any
		local io = Library.io(function()
			return nil
		end, function()
			return nil
		end, function(argv, o, cb)
			opts = o
			cb({ status = 0, stdout = argv[3] .. "/q.sql\0", stderr = "", timed_out = false }, "fresh cx")
		end, function(x)
			extra = x
		end)
		local got: any
		io.run(Library.findArgv("/s"), 5000, function(r)
			got = r
		end)
		expect(opts).toEqual({ timeout_ms = 5000 })
		expect(extra).toBe("fresh cx")
		expect(got.stdout).toBe("/s/q.sql\0")
		local failing = Library.io(function()
			return nil
		end, function()
			return nil
		end, function()
			error("no processes here", 0)
		end)
		failing.run({ "find" }, 1, function(r)
			got = r
		end)
		expect(got).toEqual({ status = -1, stdout = "", stderr = "no processes here", timed_out = false })
	end)
end)

describe("console query picker", function()
	local items = Library.items({
		{ name = "Old", sql = "-- Old one\nSELECT 1", at = 1 },
		{ name = "New", sql = "\n  SELECT id FROM customer\n", at = 2 },
	}, {
		{
			path = "/tmp/acme/sql/orders/open-orders.sql",
			name = "open-orders.sql",
			rel = "orders/open-orders.sql",
			title = "Open orders",
			folder = "sql",
		},
	})

	it("lists saved queries newest first, then folder files", function()
		expect(items[1].label).toBe("New")
		expect(items[1].detail).toBe("SELECT id FROM customer")
		expect(items[2].label).toBe("Old")
		expect(items[2].detail).toBe("SELECT 1")
		expect(items[3]).toEqual({
			kind = "file",
			label = "Open orders",
			detail = "orders/open-orders.sql",
			path = "/tmp/acme/sql/orders/open-orders.sql",
		})
	end)

	it("filters on every typed word in the title or the location", function()
		expect(#Library.filter(items, "")).toBe(3)
		local found = Library.filter(items, "orders/ open")
		expect(#found).toBe(1)
		expect(found[1].kind).toBe("file")
	end)

	it("names the configured folder only when files come from several", function()
		local one = Library.items({}, {
			{ path = "/r/a/x.sql", name = "x.sql", rel = "x.sql", folder = "a" },
			{ path = "/r/a/s/y.sql", name = "y.sql", rel = "s/y.sql", folder = "a" },
		})
		expect(one[2].folder).toBe(nil)
		local two = Library.items({}, {
			{ path = "/r/a/x.sql", name = "x.sql", rel = "x.sql", folder = "a" },
			{ path = "/home/demo/team/y.sql", name = "y.sql", rel = "y.sql", folder = "~/team" },
		})
		expect(two[1].folder).toBe("a")
		expect(two[2].folder).toBe("~/team")
		expect(#Library.filter(two, "team")).toBe(1)
	end)

	it("offers window choices grouped by folder, ending with what was not listed", function()
		local choices = Library.choices(
			Library.items({ { name = "Mine", sql = "SELECT 1", at = 1 } }, {
				{ path = "/r/a/x.sql", name = "x.sql", rel = "x.sql", folder = "a" },
				{ path = "/home/demo/team/y.sql", name = "y.sql", rel = "y.sql", folder = "~/team" },
			}),
			2
		)
		expect(#choices).toBe(4)
		expect(choices[1].group).toBe("Saved queries")
		expect(choices[1].name).toBe("Mine")
		expect(choices[2].group).toBe("Query folder a")
		expect(choices[3].path).toBe("/home/demo/team/y.sql")
		expect(choices[4]).toEqual({
			label = "2 more .sql files not listed: only the first 500 are",
			detail = "narrow console.saved_dirs to list them",
			group = "Not listed",
			icon = "info",
		})
		expect(Library.choices({}, 0)).toEqual({})
	end)
end)

return nil
