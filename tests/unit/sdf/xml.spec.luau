--!strict
local Xml = require("../../../plugin/lib/sdf/xml")
local fixtures = require("../../lib/fixtures")
local t = require("../../lib/test")

local describe, it, expect = t.describe, t.it, t.expect

local function parse(text: string): Xml.Node
	local node, err = Xml.parse(text)
	if node == nil then
		error("unexpected parse error: " .. (if err then err.message else "?"), 2)
	end
	return node
end

local function failure(text: string): Xml.ParseError
	local node, err = Xml.parse(text)
	expect(node).toBeNil()
	if err == nil then
		error("expected a parse error", 2)
	end
	return err
end

-- Drops source lines so trees parsed from differently formatted text compare.
local function shape(node: Xml.Node): any
	local kids = {}
	for i, c in node.children do
		kids[i] = shape(c)
	end
	return { tag = node.tag, attrs = node.attrs, text = node.text, children = kids }
end

describe("reading SDF XML", function()
	it("reads elements, attributes and leaf text so object fields can be looked up", function()
		local root = parse(
			'<usereventscript scriptid="customscript_demo"><name>Demo</name><notifyemails></notifyemails></usereventscript>'
		)
		expect(root.tag).toBe("usereventscript")
		expect(root.attrs.scriptid).toBe("customscript_demo")
		expect(#root.children).toBe(2)
		expect(Xml.childText(root, "name")).toBe("Demo")
		expect(Xml.childText(root, "notifyemails")).toBe("")
		expect(Xml.childText(root, "missing")).toBeNil()
	end)

	it("skips the prolog, comments and doctype that hand-edited files carry", function()
		local root = parse([[<?xml version="1.0" encoding="UTF-8"?>
<!-- generated -->
<!DOCTYPE manifest>
<manifest projecttype="SUITEAPP"><!-- inline --><projectname>x</projectname></manifest>
<!-- trailing -->
]])
		expect(root.tag).toBe("manifest")
		expect(root.attrs.projecttype).toBe("SUITEAPP")
		expect(Xml.childText(root, "projectname")).toBe("x")
	end)

	it("decodes the predefined entities and character references NetSuite exports use", function()
		local root = parse("<d>a &lt;b&gt; &amp; &quot;c&quot; &apos;d&apos;&#xd;&#10;&#233;</d>")
		expect(root.text).toBe("a <b> & \"c\" 'd'\r\n\195\169")
	end)

	it("keeps CDATA content verbatim, markup included", function()
		local root = parse("<d><![CDATA[if (a < b && c) { x = '<p>' }]]></d>")
		expect(root.text).toBe("if (a < b && c) { x = '<p>' }")
	end)

	it("accepts single- and double-quoted attributes with entities", function()
		local root = parse([[<a x='1 "q"' y="2 &amp; &apos;3&apos;"/>]])
		expect(root.attrs.x).toBe('1 "q"')
		expect(root.attrs.y).toBe("2 & '3'")
		expect(root.attrOrder).toEqual({ "x", "y" })
		expect(root.selfClosing).toBe(true)
	end)

	it("ignores indentation between child elements but keeps a leaf's whitespace", function()
		local root = parse("<a>\n  <b>  spaced  </b>\n  <c/>\n</a>")
		expect(root.text).toBe("")
		expect(Xml.childText(root, "b")).toBe("  spaced  ")
	end)

	it("records 1-based source lines so findings can point into the file", function()
		local root = parse("<a>\n\n  <b>\n    <c>x</c>\n  </b>\n</a>")
		expect(root.line).toBe(1)
		local b = Xml.child(root, "b") :: Xml.Node
		expect(b.line).toBe(3)
		expect((Xml.child(b, "c") :: Xml.Node).line).toBe(4)
	end)

	it("returns frozen trees so cached projects cannot be mutated by a consumer", function()
		local root = parse("<a><b/></a>")
		expect(table.isfrozen(root)).toBe(true)
		expect(table.isfrozen(root.children)).toBe(true)
		expect(table.isfrozen(root.attrs)).toBe(true)
	end)

	it("finds every descendant with a tag, for nested script deployments", function()
		local root = parse("<s><ds><d scriptid='a'/><d scriptid='b'/></ds><d scriptid='c'/></s>")
		local ids = {}
		for _, d in Xml.descendants(root, "d") do
			table.insert(ids, d.attrs.scriptid)
		end
		expect(ids).toEqual({ "a", "b", "c" })
	end)
end)

describe("reporting malformed XML with a position instead of raising", function()
	it("reports a mismatched closing tag at the closing tag", function()
		local err = failure("<a>\n  <b>x</c>\n</a>")
		expect(err.line).toBe(2)
		expect(err.col).toBe(7)
		expect(err.message).toContain("</c>")
		expect(err.message).toContain("<b>")
	end)

	it("reports an element left open at end of file with where it was opened", function()
		local err = failure("<a>\n<b>\n")
		expect(err.message).toContain("line 2")
		expect(err.line).toBe(3)
	end)

	it("rejects unknown entities, which NetSuite would reject on deploy", function()
		local err = failure("<a>\n x &nbsp; y</a>")
		expect(err.line).toBe(2)
		expect(err.col).toBe(4)
		expect(err.message).toContain("&nbsp;")
	end)

	it("rejects a bare ampersand", function()
		expect(failure("<a>R&D</a>").message).toContain("&")
	end)

	it("rejects unquoted and duplicate attributes", function()
		expect(failure("<a x=1/>").message).toContain("quoted")
		expect(failure("<a x='1' x='2'/>").message).toContain("duplicate")
	end)

	it("rejects unterminated comments and CDATA", function()
		expect(failure("<a><!-- x</a>").message).toContain("comment")
		expect(failure("<a><![CDATA[x</a>").message).toContain("CDATA")
	end)

	it("rejects content after the root element and documents without one", function()
		expect(failure("<a/><b/>").message).toContain("root")
		expect(failure("text").message).toContain("root")
		expect(failure("").message).toContain("root")
	end)

	it("never raises, whatever the input", function()
		for _, text in { "<", "<a", "<a x", "<a x=", "<a x='", "</a>", "<a></", "<?xml", "<!DOCTYPE", "&#xFFFFFFF;" } do
			local ok = pcall(Xml.parse, text)
			expect(ok).toBe(true)
			expect((Xml.parse(text))).toBeNil()
		end
	end)
end)

describe("real SDF files", function()
	it("parses every fixture object, manifest and deploy file", function()
		local n = 0
		for _, path in fixtures.list("projects/") do
			if string.sub(path, -4) == ".xml" then
				n += 1
				local node, err = Xml.parse(fixtures.read(path))
				if node == nil then
					error(path .. ": " .. (if err then err.message else "?"))
				end
			end
		end
		expect(n > 10).toBe(true)
	end)

	it("reads a script's deployment fields from a real map/reduce object", function()
		local root = parse(fixtures.read("projects/orders/src/Objects/customscript_demo_order_sync.xml"))
		expect(root.tag).toBe("mapreducescript")
		local deployments = Xml.descendants(root, "scriptdeployment")
		expect(#deployments).toBe(1)
		expect(Xml.childText(deployments[1], "status")).toBe("NOTSCHEDULED")
		expect(Xml.childText(deployments[1], "loglevel")).toBe("AUDIT")
	end)
end)

describe("writing SDF XML for the scaffolder", function()
	it("reproduces a NetSuite-exported object byte for byte", function()
		for _, path in
			{
				"projects/backup/src/Objects/customscript2294.xml",
				"projects/backup/src/Objects/customscript_demo_util_filedetection.xml",
			}
		do
			local text = fixtures.read(path)
			expect(Xml.emit(parse(text))).toBe(text)
		end
	end)

	it("round-trips every fixture file to the same tree", function()
		for _, path in fixtures.list("projects/") do
			if string.sub(path, -4) == ".xml" then
				local tree = parse(fixtures.read(path))
				expect(shape(parse(Xml.emit(tree)))).toEqual(shape(tree))
			end
		end
	end)

	it("escapes text and attributes so generated objects stay well-formed", function()
		local node = Xml.element("a", {
			attrs = { { name = "scriptid", value = "x\"<&'" } },
			children = { Xml.element("b", { text = "1 < 2 & 'q'\r\n" }), Xml.element("c") },
		})
		local text = Xml.emit(node, "\t")
		expect(text).toBe(
			'<a scriptid="x&quot;&lt;&amp;&apos;">\n\t<b>1 &lt; 2 &amp; &apos;q&apos;&#xd;\n</b>\n\t<c></c>\n</a>'
		)
		expect(shape(parse(text))).toEqual(shape(node))
	end)
end)

return nil
