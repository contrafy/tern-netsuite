--!strict
-- Canonical form of SDF object XML, so formatting is never reported as
-- drift. `object:import` writes objects with a two-space indent, empty
-- elements as `<x></x>`, no prolog, no trailing newline and all five
-- specials escaped; a project may keep them with any indent, prolog,
-- comments, `<x/>`, other quoting and CRLF line endings. Both sides are
-- parsed (lib/sdf/xml.luau, which drops indentation between elements),
-- rebuilt with attributes sorted by name and every empty element written
-- one way, and emitted again. Text inside an element is kept as written:
-- NetSuite stores values verbatim.

local Xml = require("../sdf/xml")

type Node = Xml.Node

export type Verdict = {
	-- Equal canonical trees (or equal bytes when a side does not parse).
	same: boolean,
	-- Byte-identical texts.
	exact: boolean,
	-- Why the texts were compared as bytes.
	parseError: string?,
}

local M = {}

local function rebuild(n: Node): Node
	local names: { string } = table.clone(n.attrOrder)
	table.sort(names)
	local attrs: { Xml.Attr } = table.create(#names)
	for i, name in names do
		attrs[i] = { name = name, value = n.attrs[name] }
	end
	local children: { Node } = table.create(#n.children)
	for i, c in n.children do
		children[i] = rebuild(c)
	end
	return Xml.element(n.tag, {
		attrs = attrs,
		children = children,
		text = n.text,
		selfClosing = #children == 0 and n.text == "",
	})
end

-- XML parsers read every CRLF (and lone CR) in the document as LF; a CR
-- written as `&#xd;` survives because it is decoded after this.
local function lineEnds(text: string): string
	return (string.gsub(text, "\r\n?", "\n"))
end

-- The canonical text of `text`, or nil and the parse error.
function M.canonical(text: string): (string?, Xml.ParseError?)
	local root, err = Xml.parse(lineEnds(text))
	if root == nil then
		return nil, err
	end
	return Xml.emit(rebuild(root)), nil
end

function M.compare(projectText: string, accountText: string): Verdict
	if projectText == accountText then
		return { same = true, exact = true, parseError = nil }
	end
	local a, errA = M.canonical(projectText)
	local b, errB = M.canonical(accountText)
	if a == nil or b == nil then
		local which = if a == nil then "project copy" else "account copy"
		local e = (errA or errB) :: Xml.ParseError
		return {
			same = false,
			exact = false,
			parseError = string.format("the %s is not well-formed XML (line %d: %s)", which, e.line, e.message),
		}
	end
	return { same = a == b, exact = false, parseError = nil }
end

return table.freeze(M)
