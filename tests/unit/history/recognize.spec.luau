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

	it("follows pushd like cd and gives up on popd, so the deploy is not misattributed", function()
		local d = match("pushd ../storefront && suitecloud project:deploy")
		expect(d and d.cwd).toBe("/work/sdf/storefront")
		local p = match("pushd /work/sdf/payments && popd && suitecloud project:deploy")
		expect(p ~= nil).toBe(true)
		expect(p and p.cwd).toBeNil()
		local swap = match("pushd && suitecloud project:deploy")
		expect(swap and swap.cwd).toBeNil()
	end)

	it("sees deploys inside loops, conditionals and groups", function()
		expect(match("for p in a b; do suitecloud project:deploy; done") ~= nil).toBe(true)
		expect(match("if true; then suitecloud project:deploy; fi") ~= nil).toBe(true)
		expect(match("if false; then :; else suitecloud project:deploy; fi") ~= nil).toBe(true)
		expect(match("if false; then :; elif true; then suitecloud project:deploy; fi") ~= nil).toBe(true)
		expect(match("! suitecloud project:deploy") ~= nil).toBe(true)
		expect(match("{ suitecloud project:deploy; }") ~= nil).toBe(true)
		expect(match("env -u HOME -C /tmp suitecloud project:deploy") ~= nil).toBe(true)
	end)
end)

describe("whether the line's exit status is the deploy's", function()
	local function outcome(line: string, exit: number): number?
		return Recognize.status(match(line) :: Recognize.Match, exit)
	end

	it("keeps the status when the deploy is the line's last command", function()
		expect(outcome("suitecloud project:deploy", 1)).toBe(1)
		expect(outcome("cd ../storefront; suitecloud project:deploy", 0)).toBe(0)
		expect(outcome("echo x | suitecloud project:deploy", 3)).toBe(3)
		expect(outcome("(cd ../storefront && suitecloud project:deploy)", 0)).toBe(0)
		expect(outcome("{ suitecloud project:deploy; }", 2)).toBe(2)
		expect(outcome("false || true; suitecloud project:deploy", 1)).toBe(1)
	end)

	it("trusts only success after `&&`: a failure may come from an earlier command", function()
		expect(outcome("cd ../storefront && suitecloud project:deploy", 0)).toBe(0)
		expect(outcome("cd missing && suitecloud project:deploy", 1)).toBeNil()
	end)

	it("is unknown when a pipe, `||`, `&` or a later command decides the status", function()
		expect(outcome("suitecloud project:deploy | tee deploy.log", 0)).toBeNil()
		expect(outcome("check || suitecloud project:deploy", 0)).toBeNil()
		expect(outcome("suitecloud project:deploy &", 0)).toBeNil()
		expect(outcome("suitecloud project:deploy && echo done", 0)).toBeNil()
		expect(outcome("for p in a b; do suitecloud project:deploy; done", 0)).toBeNil()
	end)
end)

return nil
