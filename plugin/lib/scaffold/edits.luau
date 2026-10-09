--!strict
-- Minimal text edits to deploy.xml and manifest.xml that keep the user's
-- formatting: new lines copy the indentation of their neighbours. Each result
-- is parsed back and checked, so an edit that would break the file (or not
-- take effect) comes back as an error instead.

local Xml = require("../sdf/xml")

type Node = Xml.Node

export type DeploySection = "files" | "objects"

export type DeployAdd = { section: DeploySection, pattern: string }

local M = {}

-- First line that starts with whitespace then a tag: its whitespace.
local function indentUnit(text: string, default: string): string
	for line in string.gmatch(text, "[^\n]+") do
		local ws = string.match(line, "^([ \t]+)<")
		if ws then
			return ws
		end
	end
	return default
end

local function lineStart(text: string, pos: number): number
	local i = pos
	while i > 1 and string.sub(text, i - 1, i - 1) ~= "\n" do
		i -= 1
	end
	return i
end

-- The whitespace before `pos` on its line, or nil when the line has other
-- content before it (a one-line document).
local function indentAt(text: string, pos: number): string?
	local before = string.sub(text, lineStart(text, pos), pos - 1)
	return if string.find(before, "^[ \t]*$") then before else nil
end

local function insert(text: string, at: number, s: string): string
	return string.sub(text, 1, at - 1) .. s .. string.sub(text, at)
end

-- Start of the last plain `needle` in text[from, to).
local function lastFind(text: string, needle: string, from: number, to: number): number?
	local found: number? = nil
	local i = from
	while true do
		local s = string.find(text, needle, i, true)
		if s == nil or s + #needle - 1 >= to then
			return found
		end
		found = s
		i = s + 1
	end
end

local function addDeployPath(text: string, section: string, pattern: string): (string?, string?)
	local entry = "<path>" .. pattern .. "</path>"
	local openTag = "<" .. section .. ">"
	local open = string.find(text, openTag, 1, true)
	if open then
		local openEnd = open + #openTag
		local close = string.find(text, "</" .. section .. ">", openEnd, true)
		if close == nil then
			return nil, string.format("deploy.xml: <%s> is not closed", section)
		end
		local lastOpen = lastFind(text, "<path>", openEnd, close)
		local lastClose = lastFind(text, "</path>", openEnd, close)
		if lastOpen and lastClose then
			local indent = indentAt(text, lastOpen)
			local at = lastClose + #"</path>"
			return insert(text, at, if indent then "\n" .. indent .. entry else entry)
		end
		local indent = indentAt(text, open)
		local unit = indentUnit(text, "    ")
		return insert(text, openEnd, if indent then "\n" .. indent .. unit .. entry else entry)
	end
	local close = string.find(text, "</deploy>", 1, true)
	if close == nil then
		return nil, "deploy.xml has no </deploy>"
	end
	local indent = indentAt(text, close)
	if indent == nil then
		return insert(text, close, openTag .. entry .. "</" .. section .. ">")
	end
	local unit = indentUnit(text, "    ")
	local block = string.format(
		"%s%s%s\n%s%s%s%s\n%s%s</%s>\n",
		indent,
		unit,
		openTag,
		indent,
		unit,
		unit,
		entry,
		indent,
		unit,
		section
	)
	return insert(text, lineStart(text, close), block)
end

local function deployHas(root: Node, section: string, pattern: string): boolean
	for _, s in Xml.children(root, section) do
		for _, p in Xml.children(s, "path") do
			if (string.match(p.text, "^%s*(.-)%s*$") :: string) == pattern then
				return true
			end
		end
	end
	return false
end

-- deploy.xml with each `<path>` added to its section (created when missing).
function M.addDeployPaths(text: string, adds: { DeployAdd }): (string?, string?)
	local out = text
	for _, a in adds do
		local next, err = addDeployPath(out, a.section, a.pattern)
		if next == nil then
			return nil, err
		end
		out = next
	end
	local root, perr = Xml.parse(out)
	if root == nil or root.tag ~= "deploy" then
		return nil, "the edited deploy.xml does not parse: " .. (if perr then perr.message else "no <deploy> root")
	end
	for _, a in adds do
		if not deployHas(root, a.section, a.pattern) then
			return nil, string.format("could not add %s to <%s> in deploy.xml", a.pattern, a.section)
		end
	end
	return out, nil
end

local function escapePattern(s: string): string
	return (string.gsub(s, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

local function addFeature(text: string, name: string): (string?, string?)
	local entry = '<feature required="true">' .. name .. "</feature>"
	local optional = '<feature%s+required%s*=%s*"false"%s*>%s*' .. escapePattern(name) .. "%s*</feature>"
	local s, e = string.find(text, optional)
	if s and e then
		local fixed = string.gsub(string.sub(text, s, e), 'required%s*=%s*"false"', 'required="true"', 1)
		return string.sub(text, 1, s - 1) .. fixed .. string.sub(text, e + 1), nil
	end
	local unit = indentUnit(text, "  ")
	local featuresOpen = string.find(text, "<features>", 1, true)
	if featuresOpen then
		local openEnd = featuresOpen + #"<features>"
		local close = string.find(text, "</features>", openEnd, true)
		if close == nil then
			return nil, "manifest.xml: <features> is not closed"
		end
		local lastOpen = lastFind(text, "<feature ", openEnd, close) or lastFind(text, "<feature>", openEnd, close)
		local lastClose = lastFind(text, "</feature>", openEnd, close)
		if lastOpen and lastClose then
			local indent = indentAt(text, lastOpen)
			return insert(text, lastClose + #"</feature>", if indent then "\n" .. indent .. entry else entry), nil
		end
		local indent = indentAt(text, featuresOpen)
		return insert(text, openEnd, if indent then "\n" .. indent .. unit .. entry else entry), nil
	end
	local depsOpen = string.find(text, "<dependencies>", 1, true)
	if depsOpen then
		local openEnd = depsOpen + #"<dependencies>"
		local indent = indentAt(text, depsOpen)
		if indent == nil then
			return insert(text, openEnd, "<features>" .. entry .. "</features>"), nil
		end
		local block = string.format(
			"\n%s%s<features>\n%s%s%s%s\n%s%s</features>",
			indent,
			unit,
			indent,
			unit,
			unit,
			entry,
			indent,
			unit
		)
		return insert(text, openEnd, block), nil
	end
	local close = string.find(text, "</manifest>", 1, true)
	if close == nil then
		return nil, "manifest.xml has no </manifest>"
	end
	local indent = indentAt(text, close)
	if indent == nil then
		return insert(text, close, "<dependencies><features>" .. entry .. "</features></dependencies>"), nil
	end
	local i1, i2, i3 = indent .. unit, indent .. unit .. unit, indent .. unit .. unit .. unit
	local block = string.format(
		"%s<dependencies>\n%s<features>\n%s%s\n%s</features>\n%s</dependencies>\n",
		i1,
		i2,
		i3,
		entry,
		i2,
		i1
	)
	return insert(text, lineStart(text, close), block), nil
end

local function requires(root: Node, name: string): boolean
	for _, deps in Xml.children(root, "dependencies") do
		for _, features in Xml.children(deps, "features") do
			for _, f in Xml.children(features, "feature") do
				if (string.match(f.text, "^%s*(.-)%s*$") :: string) == name and f.attrs.required == "true" then
					return true
				end
			end
		end
	end
	return false
end

-- manifest.xml with feature `name` required (flipped from required="false",
-- or added, creating <dependencies>/<features> when missing).
function M.requireFeature(text: string, name: string): (string?, string?)
	local out, err = addFeature(text, name)
	if out == nil then
		return nil, err
	end
	local root, perr = Xml.parse(out)
	if root == nil or root.tag ~= "manifest" then
		return nil, "the edited manifest.xml does not parse: " .. (if perr then perr.message else "no <manifest> root")
	end
	if not requires(root, name) then
		return nil, string.format("could not require feature %s in manifest.xml", name)
	end
	return out, nil
end

return table.freeze(M)
