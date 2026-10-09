--!strict
-- The git state of a directory, from one read-only probe process that
-- prints `key=value` lines as it learns them, so a probe killed by its
-- timeout still yields what it printed first. The dirty check (git status)
-- is slowest and runs last.

export type Info = {
	root: string?,
	branch: string?,
	head: string?,
	dirty: boolean?,
	remote: string?,
}

local M = {}

-- $1 = directory, $2 = "dirty" to also run the dirty check.
-- GIT_OPTIONAL_LOCKS=0 keeps `git status` from refreshing the index.
M.SCRIPT = table.concat({
	'cd "$1" 2>/dev/null || exit 0',
	"export GIT_OPTIONAL_LOCKS=0",
	"r=$(git rev-parse --show-toplevel 2>/dev/null) || exit 0",
	"printf 'root=%s\\n' \"$r\"",
	"printf 'branch=%s\\n' \"$(git symbolic-ref --short -q HEAD 2>/dev/null)\"",
	"printf 'head=%s\\n' \"$(git rev-parse -q --verify HEAD 2>/dev/null)\"",
	"printf 'remote=%s\\n' \"$(git remote get-url origin 2>/dev/null)\"",
	'[ "$2" = dirty ] || exit 0',
	'if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null | head -c 1)" ]; then echo dirty=1; else echo dirty=0; fi',
}, "\n")

function M.argv(dir: string, dirty: boolean): { string }
	return { "/bin/sh", "-c", M.SCRIPT, "tern-netsuite-git", dir, if dirty then "dirty" else "" }
end

function M.parse(stdout: string): Info
	local info: Info = {}
	for line in string.gmatch(stdout, "[^\n]+") do
		local k, v = string.match(line, "^(%a+)=(.*)$")
		if k == nil or v == nil or v == "" then
			continue
		end
		if k == "root" and string.sub(v, 1, 1) == "/" then
			info.root = v
		elseif k == "branch" then
			info.branch = v
		elseif k == "head" and string.match(v, "^%x+$") and #v >= 40 then
			info.head = v
		elseif k == "remote" then
			info.remote = v
		elseif k == "dirty" and (v == "0" or v == "1") then
			info.dirty = v == "1"
		end
	end
	return info
end

-- `owner/repo` of a github.com remote URL; nil for anything else.
function M.github(remote: string?): string?
	if remote == nil then
		return nil
	end
	local path = string.match(remote, "^git@github%.com:(.+)$")
	if path == nil then
		local host, rest = string.match(remote, "^%a+://([^/]+)/(.+)$")
		if host and (host == "github.com" or string.match(host, "^[^@]+@github%.com$")) then
			path = rest
		end
	end
	if path == nil then
		return nil
	end
	path = string.gsub(path, "/$", "")
	path = string.gsub(path, "%.git$", "")
	local owner, repo = string.match(path, "^([%w%-_%.]+)/([%w%-_%.]+)$")
	if owner == nil or repo == nil then
		return nil
	end
	return owner .. "/" .. repo
end

function M.short(head: string?): string?
	return if head then string.sub(head, 1, 7) else nil
end

return M
