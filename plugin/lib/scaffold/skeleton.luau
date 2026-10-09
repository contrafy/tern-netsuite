--!strict
-- SuiteScript 2.1 file contents for a new script: the built-in skeleton
-- (JSDoc tags and empty entry points, no business code) or a user template
-- with {{scriptId}} and {{name}} placeholders.

local Kinds = require("./kinds")

type Kind = Kinds.Kind

local M = {}

M.INDENT = "    "

-- Parameter names as the SDK's ss_2_1_* templates call them.
local PARAMS: { [string]: string } = {
	get = "requestParams",
	delete = "requestParams",
	post = "requestBody",
	put = "requestBody",
	getInputData = "inputContext",
	map = "mapContext",
	reduce = "reduceContext",
	summarize = "summaryContext",
}

-- Bodies that must not be empty for the script to run at all.
local BODIES: { [string]: string } = {
	-- An undefined input fails the map/reduce run before map is called.
	getInputData = "return [];",
}

-- `delete` is a reserved word, so the function gets another local name.
local function localName(entry: string): string
	return if entry == "delete" then "doDelete" else entry
end

function M.builtin(kind: Kind): string
	local i = M.INDENT
	local out = {
		"/**",
		" * @NApiVersion 2.1",
		" * @NScriptType " .. kind.nScriptType,
		" */",
		"define([], () => {",
	}
	local exports: { string } = {}
	for _, entry in kind.entryPoints do
		local name = localName(entry)
		local head = string.format("%sconst %s = (%s) => {", i, name, PARAMS[entry] or "scriptContext")
		local body = BODIES[entry]
		if body then
			table.insert(out, head)
			table.insert(out, i .. i .. body)
			table.insert(out, i .. "};")
		else
			table.insert(out, head .. "};")
		end
		table.insert(out, "")
		table.insert(exports, if name == entry then entry else entry .. ": " .. name)
	end
	table.insert(out, i .. "return { " .. table.concat(exports, ", ") .. " };")
	table.insert(out, "});")
	return table.concat(out, "\n") .. "\n"
end

export type Vars = { scriptId: string, name: string }

-- Replaces {{scriptId}} and {{name}}; any other {{...}} stays as written.
function M.render(template: string, vars: Vars): string
	local values: { [string]: string } = { scriptId = vars.scriptId, name = vars.name }
	return (
		string.gsub(template, "{{(%w+)}}", function(key: string): string
			return values[key] or "{{" .. key .. "}}"
		end)
	)
end

return table.freeze(M)
