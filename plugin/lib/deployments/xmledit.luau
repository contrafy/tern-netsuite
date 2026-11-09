--!strict
-- A minimal text edit of one script deployment in an SDF object file: the
-- character data of its <loglevel> or <status> element is replaced and
-- every other byte of the file (indentation, comments, line endings,
-- attribute quoting) stays as it was.
--
-- `locate` parses the file (lib/sdf/xml.luau) to know the object type,
-- the deployment's values and whether it has a <recurrence>, then finds
-- the same elements in the raw text, with comments, CDATA and processing
-- instructions blanked so a commented-out copy of the deployment is never
-- edited. Anything ambiguous (two deployments with the id, two <loglevel>
-- elements, entities in the value) is refused rather than guessed.

local Values = require("./values")
local Xml = require("../sdf/xml")

local M = {}

type Field = Values.Field

-- Byte range of an element's character data (first > last when empty).
export type Span = { first: number, last: number, line: number }

export type Target = {
	-- Root tag of the object, e.g. "mapreducescript".
	tag: string,
	deployment: string,
	-- Current values (trimmed); nil when the element is absent.
	values: { [string]: string },
	recurrence: boolean,
	spans: { [string]: Span },
}

export type Plan = {
	field: Field,
	old: string,
	new: string,
	line: number,
	-- The changed line before and after (no terminator).
	before: string,
	after: string,
	text: string,
}

local function escape(s: string): string
	return (string.gsub(s, "[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

local function blank(s: string): string
	return (string.gsub(s, "[^\n]", " "))
end

-- `text` with comments, CDATA sections and processing instructions blanked
-- (same length, newlines kept).
function M.mask(text: string): string
	local out = string.gsub(text, "<!%-%-.-%-%->", blank)
	out = string.gsub(out, "<!%[CDATA%[.-%]%]>", blank)
	out = string.gsub(out, "<%?.-%?>", blank)
	return out
end

local function lineAt(text: string, pos: number): number
	local _, n = string.gsub(string.sub(text, 1, pos - 1), "\n", "")
	return n + 1
end

local function lineBounds(text: string, pos: number): (number, number)
	local first = pos
	while first > 1 and string.sub(text, first - 1, first - 1) ~= "\n" do
		first -= 1
	end
	local last = string.find(text, "\n", pos, true)
	local stop = if last then last - 1 else #text
	if stop >= first and string.sub(text, stop, stop) == "\r" then
		stop -= 1
	end
	return first, stop
end

-- Every match of `pattern` in `s` from `init` to `stop`: start and end.
local function findAll(s: string, pattern: string, init: number, stop: number): { { number } }
	local out: { { number } } = {}
	local i = init
	while i <= stop do
		local a, b = string.find(s, pattern, i)
		if a == nil or a > stop then
			break
		end
		table.insert(out, { a, b :: number })
		i = (b :: number) + 1
	end
	return out
end

local function trimmedRange(text: string, first: number, last: number): (number, number)
	while first <= last and string.find(string.sub(text, first, first), "%s") do
		first += 1
	end
	while last >= first and string.find(string.sub(text, last, last), "%s") do
		last -= 1
	end
	return first, last
end

-- The deployment `deploymentId` in the object file `text`, or nil and why.
function M.locate(text: string, deploymentId: string): (Target?, string?)
	local root, perr = Xml.parse(text)
	if root == nil then
		return nil,
			if perr
				then string.format("the file does not parse (line %d: %s)", perr.line, perr.message)
				else "the file does not parse"
	end
	local id = string.lower(deploymentId)
	local nodes: { Xml.Node } = {}
	for _, d in Xml.descendants(root, "scriptdeployment") do
		if string.lower(d.attrs.scriptid or "") == id then
			table.insert(nodes, d)
		end
	end
	if #nodes == 0 then
		return nil, string.format("the file has no deployment %s", deploymentId)
	elseif #nodes > 1 then
		return nil, string.format("the file has %d deployments %s", #nodes, deploymentId)
	end
	local node = nodes[1]
	local masked = M.mask(text)
	local opens = findAll(
		string.lower(masked),
		"<scriptdeployment%s[^>]-scriptid%s*=%s*[\"']" .. escape(id) .. "[\"'][^>]->",
		1,
		#masked
	)
	if #opens ~= 1 then
		return nil, string.format("deployment %s could not be located in the file text", deploymentId)
	end
	local bodyStart = opens[1][2] + 1
	if string.sub(masked, opens[1][2] - 1, opens[1][2]) == "/>" then
		return nil, string.format("deployment %s is empty", deploymentId)
	end
	local close = string.find(masked, "</scriptdeployment%s*>", bodyStart)
	if close == nil then
		return nil, string.format("deployment %s has no closing tag", deploymentId)
	end
	local target: Target = {
		tag = root.tag,
		deployment = id,
		values = {},
		recurrence = Xml.child(node, "recurrence") ~= nil,
		spans = {},
	}
	for _, field in Values.FIELDS do
		local elements = Xml.children(node, field)
		if #elements > 1 then
			return nil, string.format("deployment %s has %d <%s> elements", deploymentId, #elements, field)
		end
		local element = elements[1]
		if element then
			local starts = findAll(masked, "<" .. field .. "%s*/?>", bodyStart, close - 1)
			if #starts ~= 1 then
				return nil,
					string.format("<%s> of deployment %s could not be located in the file text", field, deploymentId)
			end
			local open = starts[1]
			local value = string.match(element.text, "^%s*(.-)%s*$") :: string
			if string.sub(masked, open[2] - 1, open[2]) == "/>" then
				target.values[field] = ""
				target.spans[field] = { first = open[2] + 1, last = open[2], line = lineAt(text, open[1]) }
			else
				local endTag = string.find(masked, "</" .. field .. "%s*>", open[2] + 1)
				if endTag == nil or endTag > close then
					return nil, string.format("<%s> of deployment %s has no closing tag", field, deploymentId)
				end
				local first, last = trimmedRange(text, open[2] + 1, endTag - 1)
				local raw = string.sub(text, first, last)
				if raw ~= value or string.find(raw, "[<&\n]") then
					return nil,
						string.format(
							"<%s> of deployment %s holds markup or entities; edit it by hand",
							field,
							deploymentId
						)
				end
				target.values[field] = value
				target.spans[field] = { first = first, last = last, line = lineAt(text, first) }
			end
		end
	end
	return target, nil
end

-- The edit setting `field` to `value`, or nil and why.
function M.plan(text: string, target: Target, field: Field, value: string): (Plan?, string?)
	local allowed, why = Values.allowed(target.tag, field, target.recurrence)
	if allowed == nil then
		return nil, why
	end
	if not table.find(allowed, value) then
		return nil, string.format("%s is not a %s this deployment can take", value, Values.LABELS[field])
	end
	local span = target.spans[field]
	if span == nil then
		return nil,
			string.format("deployment %s has no <%s> element; add it in the file by hand", target.deployment, field)
	end
	if span.first > span.last then
		return nil,
			string.format("<%s> of deployment %s is empty; set it in the file by hand", field, target.deployment)
	end
	local old = target.values[field] :: string
	if old == value then
		return nil, string.format("the %s is already %s", Values.LABELS[field], value)
	end
	local new = string.sub(text, 1, span.first - 1) .. value .. string.sub(text, span.last + 1)
	local a, b = lineBounds(text, span.first)
	local c, d = lineBounds(new, span.first)
	return {
		field = field,
		old = old,
		new = value,
		line = span.line,
		before = string.sub(text, a, b),
		after = string.sub(new, c, d),
		text = new,
	},
		nil
end

return table.freeze(M)
