--!strict
local Recognize = require("../../../plugin/lib/history/recognize")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local WRAPPERS = {
	{ prefix = "npm run deploy", command = "project:deploy" },
	{ prefix = "./scripts/sdf.sh upload", command = "file:upload" },
	{ prefix = "./scripts/sdf.sh validate", command = "project:validate" },
}

local function match(line: string, cwd: string?): Recognize.Match?
	return Recognize.line(line, { cwd = cwd or "/work/sdf/billing", home = "/home/dev", wrappers = WRAPPERS })
end

describe("which finished command lines are deploys", function()
	it("records a typed deploy and an upload, the two commands that change an account", function()
		local d = match("suitecloud project:deploy")
		expect(d and d.command).toBe("project:deploy")
		local u = match("suitecloud file:upload --paths /SuiteScripts/a.js /SuiteScripts/b.js")
		expect(u and u.command).toBe("file:upload")
		expect(u and u.invocation.flags.paths).toBe("/SuiteScripts/a.js /SuiteScripts/b.js")
	end)

	it("ignores every other SuiteCloud command and unrelated programs", function()
		expect(match("suitecloud project:validate --server")).toBeNil()
		expect(match("suitecloud account:manageauth --list")).toBeNil()
		expect(match("git push")).toBeNil()
		expect(match("echo suitecloud project:deploy")).toBeNil()
		expect(match("")).toBeNil()
	end)

	it("ignores help and dry runs: neither touches the account", function()
		expect(match("suitecloud project:deploy --help")).toBeNil()
		expect(match("suitecloud project:deploy -h")).toBeNil()
		expect(match("suitecloud project:deploy --dryrun")).toBeNil()
	end)

	it("sees through npx, environment prefixes and `command` (the guard bypass)", function()
		expect((match("npx @oracle/suitecloud-cli@3.2.0 project:deploy") :: any).command).toBe("project:deploy")
		expect((match("npx --yes suitecloud file:upload --paths /SuiteScripts/a.js") :: any).command).toBe(
			"file:upload"
		)
		expect((match("FOO=1 command suitecloud project:deploy") :: any).command).toBe("project:deploy")
		expect((match("env JAVA_HOME=/opt/jdk suitecloud project:deploy") :: any).command).toBe("project:deploy")
		expect((match("/usr/local/bin/suitecloud project:deploy --log d.log") :: any).command).toBe("project:deploy")
	end)

	it("recognizes the configured wrappers, so `npm run deploy` counts as a deploy", function()
		local d = match("npm run deploy billing")
		expect(d and d.command).toBe("project:deploy")
		expect(d and d.invocation.viaWrapper).toBe("npm run deploy")
		expect((match("./scripts/sdf.sh upload x") :: any).command).toBe("file:upload")
		expect(match("./scripts/sdf.sh validate billing")).toBeNil()
	end)

	it("finds the deploy inside a compound line and follows `cd` to where it ran", function()
		local d = match("cd ../payroll && suitecloud project:deploy --log out.log | tee x")
		expect(d and d.command).toBe("project:deploy")
		expect(d and d.cwd).toBe("/work/sdf/payroll")
		expect((match("cd /work/other; suitecloud project:deploy") :: any).cwd).toBe("/work/other")
		expect((match("cd && suitecloud project:deploy") :: any).cwd).toBe("/home/dev")
		expect((match("cd ~/p && suitecloud project:deploy") :: any).cwd).toBe("/home/dev/p")
		expect((match("suitecloud project:validate && suitecloud project:deploy") :: any).command).toBe(
			"project:deploy"
		)
	end)

	it("leaves the directory unknown when a `cd` cannot be followed", function()
		local d = match("cd - && suitecloud project:deploy")
		expect(d and d.command).toBe("project:deploy")
		expect(d and d.cwd).toBeNil()
		expect((match('cd "$DIR" && suitecloud project:deploy') :: any).cwd).toBeNil()
	end)

	it("does not split on operators inside quotes", function()
		local d = match("suitecloud project:deploy --log 'a && b.log'")
		expect(d and d.invocation.flags.log).toBe("a && b.log")
	end)
end)

return nil
