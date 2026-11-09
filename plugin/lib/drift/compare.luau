--!strict
-- One compared entry (a project object or File Cabinet file, or an object
-- only the account has) and the verdict for a project copy against the
-- copy imported from the account. Objects compare as canonical XML
-- (canon.luau); files compare byte for byte. A changed entry carries a
-- unified diff of the original texts.

local Canon = require("./canon")
local TextDiff = require("./textdiff")

export type Kind = "object" | "file"
export type Status = "pending" | "identical" | "changed" | "missing" | "account" | "error"

export type Entry = {
	kind: Kind,
	-- Script id, or File Cabinet path ("/SuiteScripts/x.js").
	id: string,
	-- Object type (the XML root tag, or object:list's type).
	type: string?,
	-- Relative to the project root; nil for account-only objects.
	localPath: string?,
	status: Status,
	-- Why (error), or what kind of difference (formatting only, line endings).
	note: string?,
	diff: string?,
	-- The diff was cut at TextDiff.MAX_BYTES.
	truncated: boolean?,
}

local M = {}

-- Files above this are not compared (the host reads one byte more to tell).
M.MAX_FILE_BYTES = 4 * 1024 * 1024
M.DIFF_BYTES = 128 * 1024

local function with(e: Entry, status: Status, note: string?): Entry
	local out = table.clone(e)
	out.status = status
	out.note = note
	out.diff = nil
	out.truncated = nil
	return out
end

function M.pending(kind: Kind, id: string, ty: string?, localPath: string?): Entry
	return { kind = kind, id = id, type = ty, localPath = localPath, status = "pending" }
end

function M.missing(e: Entry): Entry
	return with(e, "missing", nil)
end

function M.failed(e: Entry, why: string): Entry
	return with(e, "error", why)
end

local function changed(e: Entry, projectText: string, accountText: string, note: string?): Entry
	local out = with(e, "changed", note)
	local d = TextDiff.unified(e.localPath or e.id, projectText, accountText, { maxBytes = M.DIFF_BYTES })
	out.diff = d.text
	out.truncated = d.truncated or nil
	return out
end

local function tooLarge(e: Entry, projectText: string, accountText: string): Entry?
	if #projectText > M.MAX_FILE_BYTES or #accountText > M.MAX_FILE_BYTES then
		return with(e, "error", string.format("larger than %d MiB; not compared", M.MAX_FILE_BYTES // (1024 * 1024)))
	end
	return nil
end

function M.object(e: Entry, projectText: string?, accountText: string?): Entry
	if projectText == nil then
		return with(e, "error", "the project copy could not be read")
	end
	if accountText == nil then
		return with(e, "error", "the CLI reported the object imported, but no file was written")
	end
	local big = tooLarge(e, projectText, accountText)
	if big then
		return big
	end
	local v = Canon.compare(projectText, accountText)
	if v.same then
		return with(e, "identical", if v.exact then nil else "formatting differs only")
	end
	return changed(e, projectText, accountText, v.parseError)
end

local function lf(s: string): string
	return (string.gsub(s, "\r\n", "\n"))
end

function M.file(e: Entry, projectText: string?, accountText: string?): Entry
	if projectText == nil then
		return with(e, "error", "the project file could not be read")
	end
	if accountText == nil then
		return with(e, "error", "the CLI reported the file imported, but no file was written")
	end
	local big = tooLarge(e, projectText, accountText)
	if big then
		return big
	end
	if projectText == accountText then
		return with(e, "identical", nil)
	end
	if string.find(projectText, "\0", 1, true) or string.find(accountText, "\0", 1, true) then
		return with(
			e,
			"changed",
			string.format(
				"binary file differs (%d bytes in the project, %d in the account)",
				#projectText,
				#accountText
			)
		)
	end
	if lf(projectText) == lf(accountText) then
		local where = if string.find(accountText, "\r\n", 1, true) then "the account" else "the project"
		return with(e, "changed", "only line endings differ (CRLF in " .. where .. ")")
	end
	return changed(e, projectText, accountText, nil)
end

return table.freeze(M)
