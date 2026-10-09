--!strict
-- The plugin side of the shell guard protocol (shell/PROTOCOL.md): request
-- files written by shell/tern-netsuite-guard, the fingerprint both sides
-- compute, and the response file the guard verifies. Keep all three in sync.
--
-- Fingerprint format "tern-netsuite/fp/v1", every line ending in "\n",
-- lengths in bytes:
--   tern-netsuite/fp/v1
--   argv <n>             then n lines `<len>:<arg>` (argv[1] is `suitecloud`)
--   cwd <len>:<physical cwd>
--   folder <len>:<project folder>
--   authid <len>:<auth ID>          or `authid -`
--   account <len>:<account id>      or `account -`
--   files <m>            then m lines `<len>:<abspath> <sha256>`, sorted bytewise
-- Length prefixes make values with spaces or newlines unambiguous.

local M = {}

M.VERSION = "tern-netsuite/fp/v1"
-- Requests list one entry per fingerprinted file; this bounds what a huge
-- project makes the block read.
M.MAX_REQUEST_BYTES = 8 * 1024 * 1024

export type FileDigest = { path: string, sha256: string }

export type Git = {
	root: string,
	branch: string?,
	head: string?,
	dirty: boolean,
	upstream: string?,
	ahead: number?,
	behind: number?,
	defaultBranch: string?,
}

export type Request = {
	path: string,
	dir: string,
	nonce: string,
	argv: { string },
	command: string,
	program: string,
	cwd: string,
	folder: string,
	authId: string?,
	accountId: string?,
	accountName: string?,
	accountType: string?,
	pane: string,
	git: Git?,
	notes: { string },
	files: { FileDigest },
	fingerprint: string,
	createdAt: number,
	timeoutS: number,
}

export type FingerprintInput = {
	argv: { string },
	cwd: string,
	folder: string,
	authId: string?,
	accountId: string?,
	files: { FileDigest },
}

export type Decision = "approve" | "deny"

export type Response = {
	nonce: string,
	decision: Decision,
	fingerprint: string,
	-- nil: the target account was unknown.
	account: string?,
	at: number,
	reason: string?,
}

local REQUEST_NAME = "^(/.*)/req%-(%x+)%.json$"

local function isHex(v: any, n: number): boolean
	return type(v) == "string" and #v == n and string.find(v, "^[0-9a-f]+$") ~= nil
end

local function isAbs(v: any): boolean
	return type(v) == "string" and string.sub(v, 1, 1) == "/" and string.find(v, "%c") == nil
end

local function isCount(v: any): boolean
	return type(v) == "number" and v == math.floor(v) and v >= 0 and v < 2 ^ 53
end

local function line(v: any): boolean
	return type(v) == "string" and v ~= "" and string.find(v, "[\n\r]") == nil
end

-- tern.json.decode drops null members, so null arrives as nil.
local function optLine(v: any): (boolean, string?)
	if v == nil then
		return true, nil
	end
	return line(v), if line(v) then v else nil
end

function M.splitPath(path: string): (string?, string?)
	local dir, nonce = string.match(path, REQUEST_NAME)
	if dir == nil or nonce == nil or not isHex(nonce, 32) then
		return nil, nil
	end
	return dir, nonce
end

-- Whether `tern open` was asked to show a guard request (the window claims it).
function M.isRequestPath(path: string): boolean
	local dir = M.splitPath(path)
	return dir ~= nil and string.find(dir, "/tern%-netsuite/spool$") ~= nil
end

local function parseGit(v: any): (boolean, Git?)
	if v == nil then
		return true, nil
	end
	if type(v) ~= "table" or not isAbs(v.root) or type(v.dirty) ~= "boolean" then
		return false, nil
	end
	for _, k in { "branch", "head", "upstream", "default_branch" } do
		if v[k] ~= nil and not line(v[k]) then
			return false, nil
		end
	end
	for _, k in { "ahead", "behind" } do
		if v[k] ~= nil and not isCount(v[k]) then
			return false, nil
		end
	end
	return true,
		{
			root = v.root,
			branch = v.branch,
			head = v.head,
			dirty = v.dirty,
			upstream = v.upstream,
			ahead = v.ahead,
			behind = v.behind,
			defaultBranch = v.default_branch,
		}
end

function M.parse(path: string, text: string, decode: (string) -> any): (Request?, string?)
	local dir, nonce = M.splitPath(path)
	if dir == nil or nonce == nil then
		return nil, "not a guard request path (<spool>/req-<32 hex>.json): " .. path
	end
	local ok, doc = pcall(decode, text)
	if not ok or type(doc) ~= "table" then
		return nil, "the request is not valid JSON"
	end
	if doc.version ~= 1 then
		return nil, "unsupported request version " .. tostring(doc.version)
	end
	if doc.nonce ~= nonce then
		return nil, "the request's nonce does not match its file name"
	end
	-- The host decoder returns locked tables: copy instead of keeping them.
	local argv: { string } = {}
	if type(doc.argv) ~= "table" then
		return nil, "the request argv must be a list"
	end
	for _, a in doc.argv do
		if type(a) ~= "string" then
			return nil, "the request argv must hold strings"
		end
		table.insert(argv, a)
	end
	if #argv < 2 or argv[1] ~= "suitecloud" then
		return nil, "the request argv must start with suitecloud"
	end
	if not line(doc.command) or table.find(argv, doc.command) == nil then
		return nil, "the request command is not in its argv"
	end
	if not isAbs(doc.program) or not isAbs(doc.cwd) or not isAbs(doc.folder) then
		return nil, "the request program, cwd and folder must be absolute paths"
	end
	local okAuth, authId = optLine(doc.auth_id)
	local okAcct, accountId = optLine(doc.account_id)
	local okName, accountName = optLine(doc.account_name)
	local okType, accountType = optLine(doc.account_type)
	if not (okAuth and okAcct and okName and okType) then
		return nil, "the request auth_id/account fields must be one-line strings or null"
	end
	if type(doc.pane) ~= "string" or not string.find(doc.pane, "^%d+$") then
		return nil, "the request has no Tern pane"
	end
	local okGit, git = parseGit(doc.git)
	if not okGit then
		return nil, "the request git state is malformed"
	end
	local notes: { string } = {}
	if doc.notes ~= nil and type(doc.notes) ~= "table" then
		return nil, "the request notes must be a list"
	end
	for _, n in doc.notes or {} do
		if not line(n) then
			return nil, "the request notes must be one-line strings"
		end
		table.insert(notes, n)
	end
	if type(doc.files) ~= "table" then
		return nil, "the request files must be a list"
	end
	local files: { FileDigest } = {}
	for _, f in doc.files do
		if type(f) ~= "table" or not isAbs(f.path) or not isHex(f.sha256, 64) then
			return nil, "the request lists a malformed file digest"
		end
		table.insert(files, { path = f.path, sha256 = f.sha256 })
	end
	if not isHex(doc.fingerprint, 64) then
		return nil, "the request fingerprint is not a sha256 hex digest"
	end
	if not isCount(doc.created_at) or not isCount(doc.timeout_s) or doc.timeout_s <= 0 then
		return nil, "the request created_at/timeout_s are not whole seconds"
	end
	return {
		path = path,
		dir = dir,
		nonce = nonce,
		argv = argv,
		command = doc.command,
		program = doc.program,
		cwd = doc.cwd,
		folder = doc.folder,
		authId = authId,
		accountId = accountId,
		accountName = accountName,
		accountType = accountType,
		pane = doc.pane,
		git = git,
		notes = notes,
		files = files,
		fingerprint = doc.fingerprint,
		createdAt = doc.created_at,
		timeoutS = doc.timeout_s,
	},
		nil
end

local function lp(s: string): string
	return #s .. ":" .. s
end

-- Bytewise order (LC_ALL=C sort), independent of any collation.
local function byteLess(a: FileDigest, b: FileDigest): boolean
	local x, y = a.path, b.path
	for i = 1, math.min(#x, #y) do
		local p, q = string.byte(x, i), string.byte(y, i)
		if p ~= q then
			return p < q
		end
	end
	return #x < #y
end

function M.canonical(input: FingerprintInput): (string?, string?)
	local files = table.clone(input.files)
	table.sort(files, byteLess)
	for i = 2, #files do
		if files[i].path == files[i - 1].path then
			return nil, string.format("file %s listed twice", files[i].path)
		end
	end
	local out: { string } = { M.VERSION, "argv " .. #input.argv }
	for _, a in input.argv do
		table.insert(out, lp(a))
	end
	table.insert(out, "cwd " .. lp(input.cwd))
	table.insert(out, "folder " .. lp(input.folder))
	local authId, accountId = input.authId, input.accountId
	table.insert(out, if authId then "authid " .. lp(authId) else "authid -")
	table.insert(out, if accountId then "account " .. lp(accountId) else "account -")
	table.insert(out, "files " .. #files)
	for _, f in files do
		table.insert(out, lp(f.path) .. " " .. string.lower(f.sha256))
	end
	return table.concat(out, "\n") .. "\n", nil
end

function M.fingerprintInput(r: Request): FingerprintInput
	return {
		argv = r.argv,
		cwd = r.cwd,
		folder = r.folder,
		authId = r.authId,
		accountId = r.accountId,
		files = r.files,
	}
end

function M.deadline(r: Request): number
	return r.createdAt + r.timeoutS
end

function M.responsePath(r: Request): string
	return r.dir .. "/resp-" .. r.nonce .. ".env"
end

function M.cancelPath(r: Request): string
	return r.dir .. "/cancel-" .. r.nonce
end

function M.response(resp: Response): string
	local out = {
		"nonce=" .. resp.nonce,
		"decision=" .. resp.decision,
		"fingerprint=" .. resp.fingerprint,
		"account=" .. (resp.account or "-"),
		string.format("approved_at=%d", resp.at),
	}
	local reason = resp.reason
	if reason then
		table.insert(out, "reason=" .. (string.gsub(reason, "%c", " ")))
	end
	return table.concat(out, "\n") .. "\n"
end

return M
