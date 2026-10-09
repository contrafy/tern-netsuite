--!strict
-- The XML subset SuiteCloud SDF files use: prolog, comments, a DOCTYPE
-- without internal subset, processing instructions, CDATA, elements,
-- quoted attributes, the five predefined entities and numeric character
-- references. Mixed content is not modelled: an element's `text` is its
-- direct character data concatenated, and indentation between child
-- elements is dropped. Trees are frozen.

export type Node = {
	tag: string,
	attrs: { [string]: string },
	-- Attribute names in source order, so emit() keeps scriptid first.
	attrOrder: { string },
	children: { Node },
	text: string,
	-- 1-based line of the start tag; 0 for nodes built with element().
	line: number,
	selfClosing: boolean,
}

export type ParseError = { message: string, line: number, col: number }

export type Attr = { name: string, value: string }

export type ElementOpts = {
	attrs: { Attr }?,
	children: { Node }?,
	text: string?,
	selfClosing: boolean?,
}

type Open = {
	tag: string,
	attrs: { [string]: string },
	attrOrder: { string },
	children: { Node },
	text: { string },
	line: number,
	selfClosing: boolean,
}

local M = {}

local NAME = "^[%a_:][%w_:%.%-]*"
local BOM = "\239\187\191"

local ENTITIES: { [string]: string } = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'" }

local FAILURE = {}

type Failure = { tag: typeof(FAILURE), message: string, pos: number }

local function fail(message: string, pos: number): never
	local f: Failure = { tag = FAILURE, message = message, pos = pos }
	error(f, 0)
end

local function validCodepoint(cp: number): boolean
	return cp == 0x9
		or cp == 0xA
		or cp == 0xD
		or (cp >= 0x20 and cp <= 0xD7FF)
		or (cp >= 0xE000 and cp <= 0xFFFD)
		or (cp >= 0x10000 and cp <= 0x10FFFF)
end

-- `base` is the absolute position of raw's first byte, for error positions.
local function decode(raw: string, base: number): string
	if not string.find(raw, "&", 1, true) then
		return raw
	end
	local out: { string } = {}
	local i = 1
	while true do
		local amp = string.find(raw, "&", i, true)
		if amp == nil then
			table.insert(out, string.sub(raw, i))
			break
		end
		table.insert(out, string.sub(raw, i, amp - 1))
		local name: string = string.match(raw, "^&(#?%w+);", amp)
			or fail("'&' must start an entity such as &amp;", base + amp - 1)
		local value = ENTITIES[name]
		if value == nil then
			local hex = string.match(name, "^#[xX](%x+)$")
			local dec = string.match(name, "^#(%d+)$")
			local cp: number = (if hex then tonumber(hex, 16) elseif dec then tonumber(dec) else nil)
				or fail(string.format("unknown entity &%s;", name), base + amp - 1)
			if not validCodepoint(cp) then
				fail(string.format("character reference &%s; is not a valid XML character", name), base + amp - 1)
			end
			value = utf8.char(cp)
		end
		table.insert(out, value)
		i = amp + #name + 2
	end
	return table.concat(out)
end

local function close(open: Open): Node
	local text = table.concat(open.text)
	if #open.children > 0 and not string.find(text, "%S") then
		text = ""
	end
	return table.freeze({
		tag = open.tag,
		attrs = table.freeze(open.attrs),
		attrOrder = table.freeze(open.attrOrder),
		children = table.freeze(open.children),
		text = text,
		line = open.line,
		selfClosing = open.selfClosing,
	})
end

local function parseDocument(text: string): Node
	local n = #text
	local pos = if string.sub(text, 1, 3) == BOM then 4 else 1

	-- Lines are counted incrementally; positions mostly only move forward.
	local lineNo, lineStart, scanned = 1, 1, 1
	local function lineOf(p: number): number
		if p < lineStart then
			lineNo, lineStart, scanned = 1, 1, 1
		end
		while true do
			local nl = string.find(text, "\n", scanned, true)
			if nl == nil or nl >= p then
				break
			end
			lineNo += 1
			lineStart = nl + 1
			scanned = nl + 1
		end
		return lineNo
	end

	local stack: { Open } = {}
	local root: Node? = nil

	local function attach(node: Node)
		local parent = stack[#stack]
		if parent then
			table.insert(parent.children, node)
		else
			root = node
		end
	end

	while pos <= n do
		local lt = string.find(text, "<", pos, true)
		local chunkEnd = (lt or n + 1) - 1
		if chunkEnd >= pos then
			local raw = string.sub(text, pos, chunkEnd)
			local top = stack[#stack]
			if top then
				table.insert(top.text, decode(raw, pos))
			else
				local first = string.find(raw, "%S")
				if first then
					fail("text outside the root element", pos + first - 1)
				end
			end
		end
		if lt == nil then
			break
		end
		pos = lt
		if string.sub(text, pos, pos + 3) == "<!--" then
			local e: number = string.find(text, "-->", pos + 4, true) or fail("unterminated comment", pos)
			pos = e + 3
		elseif string.sub(text, pos, pos + 8) == "<![CDATA[" then
			local e: number = string.find(text, "]]>", pos + 9, true) or fail("unterminated CDATA section", pos)
			local top: Open = stack[#stack] or fail("CDATA outside the root element", pos)
			table.insert(top.text, string.sub(text, pos + 9, e - 1))
			pos = e + 3
		elseif string.sub(text, pos, pos + 1) == "<?" then
			local e: number = string.find(text, "?>", pos + 2, true) or fail("unterminated processing instruction", pos)
			pos = e + 2
		elseif string.sub(text, pos, pos + 1) == "<!" then
			if string.sub(text, pos, pos + 8) ~= "<!DOCTYPE" or root ~= nil or #stack > 0 then
				fail("unexpected markup declaration", pos)
			end
			local e = string.find(text, ">", pos, true)
			local bracket = string.find(text, "[", pos, true)
			if bracket and (e == nil or bracket < e) then
				fail("DOCTYPE internal subsets are not supported", bracket)
			end
			pos = (e or fail("unterminated DOCTYPE", pos)) + 1
		elseif string.sub(text, pos, pos + 1) == "</" then
			local name: string = string.match(text, NAME, pos + 2) or fail("expected a tag name after '</'", pos + 2)
			local after: number = (string.match(text, "^%s*>()", pos + 2 + #name) :: number?)
				or fail(string.format("expected '>' to end </%s>", name), pos + 2 + #name)
			local top: Open = stack[#stack] or fail(string.format("closing tag </%s> has no open element", name), pos)
			if top.tag ~= name then
				fail(
					string.format("closing tag </%s> does not match <%s> opened at line %d", name, top.tag, top.line),
					pos
				)
			end
			table.remove(stack)
			attach(close(top))
			pos = after
		else
			if root ~= nil then
				fail("only one root element is allowed; found an element after the root element", pos)
			end
			local name: string = string.match(text, NAME, pos + 1) or fail("expected a tag name after '<'", pos + 1)
			local open: Open = {
				tag = name,
				attrs = {},
				attrOrder = {},
				children = {},
				text = {},
				line = lineOf(pos),
				selfClosing = false,
			}
			local p = pos + 1 + #name
			while true do
				local ws, q = string.match(text, "^(%s*)()", p)
				local at = q :: number
				local c = string.sub(text, at, at)
				if c == ">" then
					p = at + 1
					table.insert(stack, open)
					break
				elseif c == "/" and string.sub(text, at + 1, at + 1) == ">" then
					p = at + 2
					open.selfClosing = true
					attach(close(open))
					break
				elseif c == "" then
					fail(string.format("unterminated tag <%s>", name), at)
				end
				local attr: string = string.match(text, NAME, at)
					or fail(string.format("unexpected %q in <%s>", c, name), at)
				if ws == "" then
					fail(string.format("expected whitespace before attribute %s", attr), at)
				end
				local eq: number = (string.match(text, "^%s*=%s*()", at + #attr) :: number?)
					or fail(string.format("expected '=' after attribute %s", attr), at + #attr)
				local quote = string.sub(text, eq, eq)
				if quote ~= '"' and quote ~= "'" then
					fail(string.format("the value of attribute %s must be quoted", attr), eq)
				end
				local e: number = string.find(text, quote, eq + 1, true)
					or fail(string.format("unterminated value of attribute %s", attr), eq)
				local raw = string.sub(text, eq + 1, e - 1)
				local bad = string.find(raw, "<", 1, true)
				if bad then
					fail("'<' is not allowed in attribute values", eq + bad)
				end
				if open.attrs[attr] ~= nil then
					fail(string.format("duplicate attribute %s", attr), at)
				end
				open.attrs[attr] = decode(raw, eq + 1)
				table.insert(open.attrOrder, attr)
				p = e + 1
			end
			pos = p
		end
	end

	local top = stack[#stack]
	if top then
		fail(string.format("unclosed <%s> (opened at line %d)", top.tag, top.line), n + 1)
	end
	return root or fail("no root element", n + 1)
end

local function position(text: string, pos: number): (number, number)
	local line, start = 1, 1
	local limit = math.min(pos, #text + 1)
	while true do
		local nl = string.find(text, "\n", start, true)
		if nl == nil or nl >= limit then
			break
		end
		line += 1
		start = nl + 1
	end
	return line, pos - start + 1
end

-- Never raises: malformed input yields nil and the position of the first
-- problem.
function M.parse(text: string): (Node?, ParseError?)
	local ok, result = pcall(parseDocument, text)
	if ok then
		return result, nil
	end
	if type(result) == "table" and (result :: any).tag == FAILURE then
		local f = result :: any
		local line, col = position(text, f.pos)
		return nil, table.freeze({ message = f.message :: string, line = line, col = col })
	end
	return nil, table.freeze({ message = "malformed XML: " .. tostring(result), line = 1, col = 1 })
end

-- Builds a node for emit(); attributes keep the given order.
function M.element(tag: string, opts: ElementOpts?): Node
	local o: ElementOpts = opts or {}
	local attrs: { [string]: string } = {}
	local order: { string } = {}
	local given: { Attr } = o.attrs or {}
	for _, a in given do
		if attrs[a.name] == nil then
			table.insert(order, a.name)
		end
		attrs[a.name] = a.value
	end
	return table.freeze({
		tag = tag,
		attrs = table.freeze(attrs),
		attrOrder = table.freeze(order),
		children = table.freeze(table.clone(o.children or {})),
		text = o.text or "",
		line = 0,
		selfClosing = o.selfClosing == true,
	})
end

-- NetSuite's own exports escape all five specials and carriage returns.
local ESCAPES: { [string]: string } = {
	["&"] = "&amp;",
	["<"] = "&lt;",
	[">"] = "&gt;",
	['"'] = "&quot;",
	["'"] = "&apos;",
	["\r"] = "&#xd;",
}

local function escape(s: string): string
	return (string.gsub(s, "[&<>\"'\r]", ESCAPES))
end

local function emitNode(node: Node, depth: number, indent: string, out: { string })
	local pad = string.rep(indent, depth)
	table.insert(out, pad .. "<" .. node.tag)
	local seen: { [string]: boolean } = {}
	for _, name in node.attrOrder do
		local value = node.attrs[name]
		if value ~= nil and not seen[name] then
			seen[name] = true
			table.insert(out, string.format(' %s="%s"', name, escape(value)))
		end
	end
	local rest: { string } = {}
	for name in node.attrs do
		if not seen[name] then
			table.insert(rest, name)
		end
	end
	table.sort(rest)
	for _, name in rest do
		table.insert(out, string.format(' %s="%s"', name, escape(node.attrs[name])))
	end
	if #node.children == 0 then
		if node.text == "" and node.selfClosing then
			table.insert(out, "/>")
		else
			table.insert(out, ">" .. escape(node.text) .. "</" .. node.tag .. ">")
		end
		return
	end
	table.insert(out, ">" .. escape(node.text))
	for _, child in node.children do
		table.insert(out, "\n")
		emitNode(child, depth + 1, indent, out)
	end
	table.insert(out, "\n" .. pad .. "</" .. node.tag .. ">")
end

-- Serializes without prolog or trailing newline, as NetSuite exports
-- objects. `indent` defaults to two spaces.
function M.emit(node: Node, indent: string?): string
	local out: { string } = {}
	emitNode(node, 0, indent or "  ", out)
	return table.concat(out)
end

-- First direct child with the tag.
function M.child(node: Node, tag: string): Node?
	for _, c in node.children do
		if c.tag == tag then
			return c
		end
	end
	return nil
end

-- Direct children with the tag.
function M.children(node: Node, tag: string): { Node }
	local out: { Node } = {}
	for _, c in node.children do
		if c.tag == tag then
			table.insert(out, c)
		end
	end
	return out
end

function M.childText(node: Node, tag: string): string?
	local c = M.child(node, tag)
	return if c then c.text else nil
end

-- Descendants (not the node itself) with the tag, in document order.
function M.descendants(node: Node, tag: string): { Node }
	local out: { Node } = {}
	local function walk(n: Node)
		for _, c in n.children do
			if c.tag == tag then
				table.insert(out, c)
			end
			walk(c)
		end
	end
	walk(node)
	return out
end

return table.freeze(M)
