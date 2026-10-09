--!strict
-- tests/fixtures/history/gh-run-list.json is real `gh run list --json
-- databaseId,displayTitle,headBranch,headSha,status,conclusion,createdAt,
-- updatedAt,event,url` output (gh 2.97.0) of a deploy workflow, plus queued and
-- in-progress rows from a public repository, sanitized: owner/repo, titles,
-- run ids and some SHAs are synthetic; layout and key order are byte-for-byte.
local Ci = require("../../../plugin/lib/history/ci")
local fixtures = require("../../lib/fixtures")
local json = require("../../lib/json")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local CI = { gh = "gh", workflow = "sdf-deploy.yml", limit = 20, timeout_ms = 20000, poll_seconds = 120 }

local function runs(): { Ci.Run }
	local list, err = Ci.parse(fixtures.read("history/gh-run-list.json"), json.decode)
	assert(list, err)
	return list
end

describe("gh run list output", function()
	it("reads every run with its state, branch, commit, times and link", function()
		local list = runs()
		expect(#list).toBe(6)
		local r = list[2]
		expect(r.id).toBe(1000000106)
		expect(r.status).toBe("in_progress")
		expect(r.conclusion).toBeNil()
		expect(r.branch).toBe("develop")
		expect(r.sha).toBe("a64c64ab9ce9136625cf080db3cd091263d90e0c")
		expect(r.created).toBe(1791481210)
		expect(r.updated).toBe(1791481226)
		expect(r.event).toBe("push")
		expect(r.url).toBe("https://github.com/example-org/example-repo/actions/runs/1000000106")
		expect(list[6].conclusion).toBe("failure")
	end)

	it("reports output that is not a run list instead of showing nothing", function()
		local list, err = Ci.parse("not json", json.decode)
		expect(list).toBeNil()
		expect(type(err)).toBe("string")
		local empty = Ci.parse("[]", json.decode)
		expect(empty).toEqual({})
	end)

	it("drops a run whose link is not a GitHub https URL, since rows open their link", function()
		local list = Ci.parse('[{"databaseId":1,"status":"completed","url":"file:///etc/passwd"}]', json.decode)
		expect(list and list[1] and list[1].url).toBeNil()
	end)
end)

describe("the gh command lines", function()
	it("lists the configured workflow's runs of one repository, read only", function()
		expect(Ci.argv(CI, "example-org/example-repo")).toEqual({
			"gh",
			"run",
			"list",
			"-R",
			"example-org/example-repo",
			"--workflow",
			"sdf-deploy.yml",
			"--json",
			"databaseId,displayTitle,headBranch,headSha,status,conclusion,createdAt,updatedAt,event,url",
			"--limit",
			"20",
		})
	end)

	it("shows a failed run's failing step logs", function()
		expect(Ci.logCommand("gh", "example-org/example-repo", 1000000102)).toBe(
			"'gh' run view 1000000102 -R 'example-org/example-repo' --log-failed"
		)
		expect(Ci.logCommand("/opt/my gh", "o/r", 7)).toBe("'/opt/my gh' run view 7 -R 'o/r' --log-failed")
	end)

	it("explains gh failures with gh's own first line", function()
		expect(
			Ci.errorText(
				1,
				"HTTP 404: workflow nonexistent.yml not found on the default branch (https://api.github.com/x)\n",
				false
			)
		).toBe("HTTP 404: workflow nonexistent.yml not found on the default branch (https://api.github.com/x)")
		expect(Ci.errorText(-1, "", true)).toBe("gh timed out")
		expect(Ci.errorText(1, "", false)).toBe("gh exited with 1")
	end)
end)

describe("the latest CI deploy of a branch", function()
	it("is the newest run of that branch, whatever order gh returned", function()
		local list = runs()
		local shuffled = { list[6], list[3], list[2], list[5], list[4], list[1] }
		expect((Ci.latestCi(shuffled, "develop") :: Ci.Run).id).toBe(1000000106)
		expect((Ci.latestCi(list, "master") :: Ci.Run).id).toBe(1000000104)
		expect(Ci.latestCi(list, "no-such-branch")).toBeNil()
		expect(Ci.latestCi(list, nil)).toBeNil()
	end)

	it("reads as running, failed or ok on the status line", function()
		local list = runs()
		expect(Ci.segment(list[1])).toEqual({ text = "CI deploy: running", tone = "info" })
		expect(Ci.segment(list[2])).toEqual({ text = "CI deploy: running", tone = "info" })
		expect(Ci.segment(list[3])).toEqual({ text = "CI deploy: ok", tone = "muted" })
		expect(Ci.segment(list[5])).toEqual({ text = "CI deploy: cancelled", tone = "muted" })
		expect(Ci.segment(list[6])).toEqual({ text = "CI deploy: failed", tone = "error" })
	end)
end)

describe("GitHub timestamps", function()
	it("convert to Unix seconds", function()
		expect(Ci.iso("1970-01-01T00:00:00Z")).toBe(0)
		expect(Ci.iso("2000-02-29T12:00:00Z")).toBe(951825600)
		expect(Ci.iso("2026-08-25T21:17:00Z")).toBe(1787692620)
		expect(Ci.iso("yesterday")).toBeNil()
	end)
end)

return nil
