--!strict
-- Reads `object:list` and `file:list` output. object:list prints a header
-- and then `<type>:<scriptid>` per object (ListObjectsOutputHandler);
-- file:list prints one File Cabinet path per line and no header
-- (ListFilesOutputHandler). Both print an SDK sentence when nothing
-- matched. Lines that are neither stay in `unknown`; output with no line
-- recognized at all (a failed run) parses to nil.

local Output = require("./output")

export type Object = { type: string, scriptId: string }
export type Unknown = { line: number, text: string }

export type ObjectList = {
	objects: { Object },
	-- The CLI said nothing matched.
	empty: boolean,
	unknown: { Unknown },
	status: number?,
}

export type FileList = {
	-- File Cabinet paths ("/SuiteScripts/x.js"), in the CLI's order.
	files: { string },
	empty: boolean,
	unknown: { Unknown },
	status: number?,
}

export type TypeCount = { type: string, count: number }
export type FolderCount = { folder: string, count: number }

local M = {}

local OBJECTS_HEADER = "The following objects were found in your account:"
local NO_OBJECTS = "There are no objects matching your search criteria"
local NO_FILES = "No files found."

-- Process output as cleaned lines: spinner escapes dropped, trailing blank
-- lines trimmed.
function M.split(text: string): { string }
	local out: { string } = {}
	for line in string.gmatch(text, "([^\n]*)\n?") do
		table.insert(out, Output.clean(line))
	end
	while #out > 0 and string.find(out[#out], "^%s*$") do
		table.remove(out)
	end
	return out
end

function M.objects(lines: { string }, status: number?): ObjectList?
	local objects: { Object } = {}
	local unknown: { Unknown } = {}
	local header, empty = false, false
	for i, raw in lines do
		local line = Output.clean(raw)
		if line == "" then
			continue
		end
		if line == OBJECTS_HEADER then
			header = true
			continue
		end
		if string.sub(line, 1, #NO_OBJECTS) == NO_OBJECTS then
			empty = true
			continue
		end
		local kind, id = string.match(line, "^(%a%w*):([%w_%.%-]+)$")
		if header and kind and id then
			table.insert(objects, { type = kind, scriptId = id })
		else
			table.insert(unknown, { line = i, text = line })
		end
	end
	if not header and not empty then
		return nil
	end
	return { objects = objects, empty = empty and #objects == 0, unknown = unknown, status = status }
end

function M.files(lines: { string }, status: number?): FileList?
	local files: { string } = {}
	local unknown: { Unknown } = {}
	local empty = false
	for i, raw in lines do
		local line = Output.clean(raw)
		if line == "" then
			continue
		end
		if line == NO_FILES then
			empty = true
		elseif string.sub(line, 1, 1) == "/" then
			table.insert(files, line)
		else
			table.insert(unknown, { line = i, text = line })
		end
	end
	if #files == 0 and not empty then
		return nil
	end
	return { files = files, empty = empty and #files == 0, unknown = unknown, status = status }
end

-- The first non-blank line, which is where the CLI states why it failed.
function M.errorText(lines: { string }): string?
	for _, raw in lines do
		local line = string.match(Output.clean(raw), "^%s*(.-)%s*$") or ""
		if line ~= "" then
			return line
		end
	end
	return nil
end

local function counted<T>(keys: { string }, make: (string, number) -> T): { T }
	local counts: { [string]: number } = {}
	local order: { string } = {}
	for _, k in keys do
		if counts[k] == nil then
			counts[k] = 0
			table.insert(order, k)
		end
		counts[k] += 1
	end
	table.sort(order, function(a: string, b: string): boolean
		if counts[a] ~= counts[b] then
			return counts[a] > counts[b]
		end
		return a < b
	end)
	local out: { T } = table.create(#order)
	for i, k in order do
		out[i] = make(k, counts[k])
	end
	return out
end

-- Objects per type, most first (ties by name).
function M.byType(objects: { Object }): { TypeCount }
	local keys: { string } = table.create(#objects)
	for i, o in objects do
		keys[i] = o.type
	end
	return counted(keys, function(k: string, n: number): TypeCount
		return { type = k, count = n }
	end)
end

-- Files per folder, most first (ties by name).
function M.byFolder(files: { string }): { FolderCount }
	local keys: { string } = table.create(#files)
	for i, f in files do
		local dir = string.match(f, "^(.*)/[^/]*$")
		keys[i] = if dir == nil or dir == "" then "/" else dir
	end
	return counted(keys, function(k: string, n: number): FolderCount
		return { folder = k, count = n }
	end)
end

return table.freeze(M)
