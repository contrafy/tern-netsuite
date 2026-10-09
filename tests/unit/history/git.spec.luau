--!strict
local Git = require("../../../plugin/lib/history/git")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local HEAD = "74fbe1735dfd1db4fe1faf64bcf5e28849817553"

describe("the git state a deploy ran from", function()
	it("reads branch, HEAD, dirty flag and remote from the probe's key=value lines", function()
		local info = Git.parse(
			"root=/work/repo\nbranch=develop\nhead="
				.. HEAD
				.. "\nremote=git@github.com:example-org/example-repo\ndirty=1\n"
		)
		expect(info).toEqual({
			root = "/work/repo",
			branch = "develop",
			head = HEAD,
			remote = "git@github.com:example-org/example-repo",
			dirty = true,
		})
	end)

	it("keeps what is known when the probe was cut short (timeout before the dirty check)", function()
		local info = Git.parse("root=/work/repo\nbranch=develop\nhead=" .. HEAD .. "\n")
		expect(info.branch).toBe("develop")
		expect(info.head).toBe(HEAD)
		expect(info.dirty).toBeNil()
	end)

	it("treats a detached HEAD and a missing remote as unknown rather than empty", function()
		local info = Git.parse("root=/work/repo\nbranch=\nhead=" .. HEAD .. "\nremote=\ndirty=0\n")
		expect(info.branch).toBeNil()
		expect(info.remote).toBeNil()
		expect(info.dirty).toBe(false)
	end)

	it("knows nothing outside a repository", function()
		expect(Git.parse("")).toEqual({})
	end)

	it("rejects a HEAD that is not a commit id", function()
		expect(Git.parse("head=HEAD\n").head).toBeNil()
	end)
end)

describe("the GitHub repository of a remote", function()
	it("accepts the ssh, scp-like and https spellings", function()
		expect(Git.github("git@github.com:example-org/example-repo")).toBe("example-org/example-repo")
		expect(Git.github("git@github.com:example-org/example-repo.git")).toBe("example-org/example-repo")
		expect(Git.github("https://github.com/example-org/example-repo.git")).toBe("example-org/example-repo")
		expect(Git.github("https://user@github.com/example-org/example-repo/")).toBe("example-org/example-repo")
		expect(Git.github("ssh://git@github.com/example-org/example-repo.git")).toBe("example-org/example-repo")
	end)

	it("returns nil for other hosts and malformed names, so gh is never asked about them", function()
		expect(Git.github("git@gitlab.com:example-org/example-repo.git")).toBeNil()
		expect(Git.github("https://github.com/example-org")).toBeNil()
		expect(Git.github("https://github.com/a/b;rm -rf")).toBeNil()
		expect(Git.github(nil)).toBeNil()
	end)
end)

return nil
