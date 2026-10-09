--!strict
-- A lens loses its state on reload and is rebuilt from the captured output
-- alone, so every clickable carries the whole view choice in its action
-- name: "v=w:1;i:1;s:1". The encoded form holds no "=", so Tern splits the
-- action into act/value at the only "=" there is.

export type ViewState = {
	-- Warnings expanded (they start collapsed).
	warnings: boolean,
	-- Every deployed/uploaded item, not just the first ones.
	items: boolean,
	-- Every server validation step, not just the failed ones.
	steps: boolean,
}

local M = {}

function M.default(): ViewState
	return { warnings = false, items = false, steps = false }
end

function M.encode(vs: ViewState): string
	local parts: { string } = {}
	if vs.warnings then
		table.insert(parts, "w:1")
	end
	if vs.items then
		table.insert(parts, "i:1")
	end
	if vs.steps then
		table.insert(parts, "s:1")
	end
	return table.concat(parts, ";")
end

-- Unknown or malformed fields are ignored: actions encoded by another plugin
-- version must still decode to a usable state.
function M.decode(s: string): ViewState
	local vs = M.default()
	for part in string.gmatch(s, "[^;]+") do
		local k, v = string.match(part, "^(%a+):(.*)$")
		local on = v == "1"
		if k == "w" then
			vs.warnings = on
		elseif k == "i" then
			vs.items = on
		elseif k == "s" then
			vs.steps = on
		end
	end
	return vs
end

function M.action(vs: ViewState): string
	return "v=" .. M.encode(vs)
end

function M.toggled(vs: ViewState, field: "warnings" | "items" | "steps"): ViewState
	local out = table.clone(vs)
	out[field] = not vs[field]
	return out
end

return table.freeze(M)
