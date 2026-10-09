--!strict
-- Reads the approve block's decisions from `<plugin data>/audit.log`
-- (written by lib/guard/audit.luau), so the history shows them without
-- recording them a second time.

export type Decision = "approved" | "denied" | "cancelled"

export type Entry = {
	-- Unix seconds of the decision.
	at: number,
	decision: Decision,
	command: string,
	-- The command as typed, rebuilt from the argv.
	line: string,
	cwd: string?,
	authId: string?,
	accountId: string?,
	accountLabel: string?,
	production: boolean?,
	branch: string?,
	head: string?,
	dirty: boolean?,
	reason: string?,
}

local M = {}

local DECISIONS: { [string]: boolean } = { approved = true, denied = true, cancelled = true }

local function str(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

local function bool(v: any): boolean?
	return if type(v) == "boolean" then v else nil
end

-- Shell-quotes words that need it, for display.
function M.join(argv: { string }): string
	local parts: { string } = table.create(#argv)
	for i, w in argv do
		if w ~= "" and not string.find(w, "[^%w%-_%./:=@,+%%]") then
			parts[i] = w
		else
			parts[i] = "'" .. string.gsub(w, "'", "'\\''") .. "'"
		end
	end
	return table.concat(parts, " ")
end

local function entry(doc: any): Entry?
	if type(doc) ~= "table" or doc.v ~= 1 or type(doc.decided_at) ~= "number" then
		return nil
	end
	local decision = doc.decision
	local command = str(doc.command)
	if not DECISIONS[decision] or command == nil then
		return nil
	end
	local argv: { string } = {}
	if type(doc.argv) == "table" then
		for _, a in doc.argv do
			if type(a) == "string" then
				table.insert(argv, a)
			end
		end
	end
	return {
		at = doc.decided_at,
		decision = decision,
		command = command :: string,
		line = if #argv > 0 then M.join(argv) else "suitecloud " .. command,
		cwd = str(doc.cwd),
		authId = str(doc.auth_id),
		accountId = str(doc.account_id),
		accountLabel = str(doc.account_label),
		production = bool(doc.production),
		branch = str(doc.branch),
		head = str(doc.head),
		dirty = bool(doc.dirty),
		reason = str(doc.reason),
	}
end

function M.parse(text: string?, decode: (string) -> any): { Entry }
	local out: { Entry } = {}
	if text == nil then
		return out
	end
	for line in string.gmatch(text, "[^\n]+") do
		local ok, doc = pcall(decode, line)
		local e = if ok then entry(doc) else nil
		if e then
			table.insert(out, e)
		end
	end
	return out
end

return M
