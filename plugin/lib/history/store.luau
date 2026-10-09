--!strict
-- history.jsonl text: append-only, one JSON line per entry, rotated to the
-- newest `max` entries on every write. The adapter writes the whole result
-- to a temporary file and renames it, so readers never see half a file; a
-- line without its newline can only be a leftover of an interrupted older
-- writer and is dropped.

local M = {}

local function complete(text: string?): { string }
	local out: { string } = {}
	if text == nil then
		return out
	end
	for line, nl in string.gmatch(text, "([^\n]*)(\n?)") do
		if nl == "" then
			break
		end
		if string.find(line, "%S") then
			table.insert(out, line)
		end
	end
	return out
end

function M.append(existing: string?, lines: { string }, max: number): string
	local all = complete(existing)
	for _, l in lines do
		local body = string.gsub(l, "\n+$", "")
		if string.find(body, "%S") then
			table.insert(all, body)
		end
	end
	local first = math.max(1, #all - max + 1)
	if first > #all then
		return ""
	end
	return table.concat(all, "\n", first, #all) .. "\n"
end

-- The newest `max` non-blank lines of `text`, oldest first.
function M.lines(text: string?, max: number): { string }
	local out: { string } = {}
	if text == nil then
		return out
	end
	for line in string.gmatch(text, "[^\n]+") do
		if string.find(line, "%S") then
			table.insert(out, line)
		end
	end
	if #out <= max then
		return out
	end
	return table.move(out, #out - max + 1, #out, 1, {})
end

return M
