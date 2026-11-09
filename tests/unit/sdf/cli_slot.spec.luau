--!strict
local CliSlot = require("../../../plugin/lib/sdf/cli_slot")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local DATA = "/Users/demo/Library/Application Support/tern/plugins/tern-netsuite"

-- Words of a line made of bare words, single-quoted strings and backslash
-- escapes, read the way POSIX shells (fish = false) or fish read them.
-- Inside single quotes fish turns \' into ' and \\ into \.
local function words(line: string, fish: boolean): { string }
	local out: { string } = {}
	local cur: { string }? = nil
	local i = 1
	while i <= #line do
		local c = string.sub(line, i, i)
		if c == " " then
			if cur then
				table.insert(out, table.concat(cur))
				cur = nil
			end
			i += 1
		else
			local w = cur or {}
			cur = w
			if c == "'" then
				i += 1
				while true do
					local d = string.sub(line, i, i)
					assert(d ~= "", "unterminated quote")
					if d == "'" then
						i += 1
						break
					end
					local nextChar = string.sub(line, i + 1, i + 1)
					if fish and d == "\\" and (nextChar == "'" or nextChar == "\\") then
						table.insert(w, nextChar)
						i += 2
					else
						table.insert(w, d)
						i += 1
					end
				end
			elseif c == "\\" then
				table.insert(w, string.sub(line, i + 1, i + 1))
				i += 2
			else
				assert(c ~= '"', "double quotes are not expected outside single quotes")
				table.insert(w, c)
				i += 1
			end
		end
	end
	if cur then
		table.insert(out, table.concat(cur))
	end
	return out
end

local function pane(over: { [string]: any }?): CliSlot.Pane
	local p: CliSlot.Pane = {
		title = "tern-netsuite upload /SuiteScripts/a.js -> SB1",
		intro = "uploading /SuiteScripts/a.js from billing to SB1",
		cwd = "/work/acme/billing",
		lock = CliSlot.lockPath(DATA, "demo-sb"),
		argv = {
			"/opt/tern-netsuite/shell/tern-netsuite-guard",
			"suitecloud",
			"file:upload",
			"--paths",
			"/SuiteScripts/a.js",
		},
	}
	for k, v in (over or {}) :: { [string]: any } do
		(p :: any)[k] = v
	end
	return p
end

describe("the slot of an auth ID", function()
	it("is one lock directory per auth ID under the plugin's data directory", function()
		expect(CliSlot.lockPath(DATA, "demo-sb")).toBe(DATA .. "/cli-slots/auth-demo-sb")
		expect(CliSlot.lockPath(DATA, "demo-prod") ~= CliSlot.lockPath(DATA, "demo-sb")).toBe(true)
	end)

	it("keeps an auth ID that is not a plain name inside the slot directory", function()
		local p = CliSlot.lockPath(DATA, "../../x")
		expect(p).toBe(DATA .. "/cli-slots/hex-2e2e2f2e2e2f78")
		expect(CliSlot.lockPath(DATA, ".hidden") ~= DATA .. "/cli-slots/auth-.hidden").toBe(true)
	end)

	it("gives projects without an auth ID one shared slot", function()
		expect(CliSlot.lockPath(DATA, nil)).toBe(DATA .. "/cli-slots/none")
	end)

	it("keeps every lock in the one directory the guard is told about, so shells and the plugin share them", function()
		local dir = CliSlot.slotsDir(DATA)
		for _, id in { "demo-sb", "../../x", "" } do
			local p = CliSlot.lockPath(DATA, id)
			expect(string.sub(p, 1, #dir + 1)).toBe(dir .. "/")
			expect((string.find(string.sub(p, #dir + 2), "/", 1, true))).toBeNil()
		end
	end)

	it("knows which CLI commands talk to the account and so need the slot", function()
		expect(CliSlot.isAccountCommand("object:list")).toBe(true)
		expect(CliSlot.isAccountCommand("file:upload")).toBe(true)
		expect(CliSlot.isAccountCommand("account:manageauth")).toBe(false)
		expect(CliSlot.isAccountCommand(nil)).toBe(false)
	end)
end)

describe("a background run in the slot", function()
	it("runs the CLI argv unchanged after the slot script, naming the subcommand as the holder", function()
		local argv = CliSlot.argv({ "/opt/bin/suitecloud", "file:list", "--folder", "/SuiteScripts" }, "/d/l", 45)
		expect(argv).toEqual({
			"sh",
			"-c",
			CliSlot.SCRIPT,
			CliSlot.NAME,
			"/d/l",
			"45",
			"file:list",
			"/opt/bin/suitecloud",
			"file:list",
			"--folder",
			"/SuiteScripts",
		})
	end)

	it("waits for the slot within half its timeout, so the command still has time to run", function()
		expect(CliSlot.waitSeconds(600000)).toBe(300)
		expect(CliSlot.waitSeconds(90000)).toBe(45)
		expect(CliSlot.waitSeconds(1000)).toBe(CliSlot.MIN_WAIT)
		expect(CliSlot.waitSeconds(3600000)).toBe(CliSlot.MAX_WAIT)
	end)

	it("never waits forever in the background: a zero wait would mean 'until it frees'", function()
		expect(CliSlot.argv({ "suitecloud", "object:list" }, "/d/l", 0)[6]).toBe("1")
	end)
end)

describe("shell lines", function()
	it("refuses words with backslashes, quotes or control characters", function()
		expect(CliSlot.unsafe("/work/acme/billing app")).toBeNil()
		expect(CliSlot.unsafe("/a\\b")).toContain("backslash")
		expect(CliSlot.unsafe("/a'b")).toContain("quote")
		expect(CliSlot.unsafe('/a"b')).toContain("quote")
		expect(CliSlot.unsafe("/a\nb")).toContain("control")
	end)

	it(
		"keeps the slot script free of single quotes and backslashes, so it can be quoted inside another line",
		function()
			expect((string.find(CliSlot.SCRIPT, "'", 1, true))).toBeNil()
			expect((string.find(CliSlot.SCRIPT, "\\", 1, true))).toBeNil()
		end
	)

	it("quotes words so a shell runs exactly the argv", function()
		expect(CliSlot.quote("suitecloud")).toBe("suitecloud")
		expect(CliSlot.quote("a;rm -rf ~")).toBe("'a;rm -rf ~'")
		expect(CliSlot.quote("$(x)")).toBe("'$(x)'")
		expect(CliSlot.quote("")).toBe("''")
	end)

	it("quotes every word by the POSIX rule, so no word can inject shell syntax", function()
		local function unquote(q: string): string
			local out = {}
			local i = 1
			while i <= #q do
				local c = string.sub(q, i, i)
				if c == "'" then
					local j = string.find(q, "'", i + 1, true) :: number
					table.insert(out, string.sub(q, i + 1, j - 1))
					i = j + 1
				elseif c == "\\" then
					table.insert(out, string.sub(q, i + 1, i + 1))
					i += 2
				else
					table.insert(out, c)
					i += 1
				end
			end
			return table.concat(out)
		end
		for _, s in { "plain", "a b", "it's", "'", "''", 'say "hi"', "$HOME `x` \\n", "" } do
			expect(unquote(CliSlot.quote(s))).toBe(s)
		end
	end)
end)

describe("a pane in the slot", function()
	it("runs the command in its directory inside the slot and keeps the pane open with the exit status", function()
		local script = CliSlot.paneScript(pane()) :: string
		expect(script).toContain("cd /work/acme/billing && sh -c ")
		expect(script).toContain(
			"file:upload /opt/tern-netsuite/shell/tern-netsuite-guard suitecloud file:upload --paths /SuiteScripts/a.js"
		)
		expect(script).toContain("s=$?; printf")
		expect(script).toContain([[%s exited %s; press Enter to close\n' file:upload "$s"]])
		expect(script).toContain('exit "$s"')
	end)

	it("waits for the slot as long as it takes (the user sees why and can close the pane)", function()
		local script = CliSlot.paneScript(pane()) :: string
		expect(script).toContain(CliSlot.NAME .. " " .. CliSlot.quote(CliSlot.lockPath(DATA, "demo-sb")) .. " 0 ")
	end)

	it("reads the same in fish as in POSIX shells, whatever the title and message say", function()
		local p = pane({
			title = [[it's a \' trap "x"]],
			intro = "intro \\ $(touch /tmp/x) `y` ; z",
			cwd = "/work/acme/bill ing $x;y",
		})
		local line = CliSlot.paneLine(CliSlot.paneScript(p) :: string)
		expect(words(line, true)).toEqual(words(line, false))
		expect(#words(line, false)).toBe(3)
	end)

	it("refuses a directory, lock or argument that cannot pass through a shell line", function()
		for _, bad in { [[/work/a\b]], "/work/it's", '/work/"x"', "/work/a\nb" } do
			local script, why = CliSlot.paneScript(pane({ cwd = bad }))
			expect(script).toBeNil()
			expect(why).toContain("cannot be passed safely through a shell line")
			expect((CliSlot.paneScript(pane({ lock = bad })))).toBeNil()
			expect((CliSlot.paneScript(pane({ argv = { "suitecloud", "file:import", "--paths", bad } })))).toBeNil()
		end
	end)

	it("lets a command that takes the slot itself (the guard, after approval) run without waiting first", function()
		local p = pane()
		p.lock = nil
		local script = CliSlot.paneScript(p) :: string
		expect((string.find(script, CliSlot.NAME, 1, true))).toBeNil()
		expect(script).toContain(
			"cd /work/acme/billing && /opt/tern-netsuite/shell/tern-netsuite-guard suitecloud file:upload"
		)
		expect(script).toContain([[%s exited %s; press Enter to close\n' file:upload "$s"]])
	end)
end)

return nil
