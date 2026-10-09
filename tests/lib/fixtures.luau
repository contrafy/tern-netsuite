--!strict
-- Fixture access for specs. Standalone luau cannot read files, so every file
-- under tests/fixtures/ (and examples/) is embedded into
-- tests/fixtures/generated.luau by scripts/fixtures/embed.sh (`make fixtures`).
-- Paths are relative to tests/fixtures, e.g. "suitecloud/validate/ok.txt";
-- examples keep their prefix, e.g. "examples/config.json".

local files: { [string]: string } = require("../fixtures/generated")

local M = {}

function M.has(path: string): boolean
	return files[path] ~= nil
end

function M.read(path: string): string
	local text = files[path]
	if text == nil then
		error(string.format("fixture %q not embedded; run `make fixtures`", path), 2)
	end
	return text
end

-- Splits text the way Tern hands lines to a lens: one entry per line, no
-- terminators, trailing blank lines trimmed.
function M.toLines(text: string): { string }
	local lines: { string } = {}
	for line in string.gmatch(text, "([^\n]*)\n?") do
		table.insert(lines, (string.gsub(line, "\r$", "")))
	end
	while #lines > 0 and string.find(lines[#lines], "^%s*$") do
		table.remove(lines)
	end
	return lines
end

function M.lines(path: string): { string }
	return M.toLines(M.read(path))
end

-- Sorted fixture paths starting with `prefix`.
function M.list(prefix: string): { string }
	local out: { string } = {}
	for path in files do
		if string.sub(path, 1, #prefix) == prefix then
			table.insert(out, path)
		end
	end
	table.sort(out)
	return out
end

return M
