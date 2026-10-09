--!strict
-- One error shape for every NetSuite failure: REST problem documents
-- (`o:errorDetails`), RESTlet platform errors (`{"error": {code, message}}`),
-- RESTlet application errors (`{"ok": false, "error": "..."}`), OAuth 2.0
-- token errors and transport failures. NetSuite signals throttling in
-- several spellings and statuses (403 with SSS_REQUEST_LIMIT_EXCEEDED, 429,
-- or HTTP 200 with the code in an application error), so the code wins over
-- the status.

local M = {}

export type Kind = "auth" | "permission" | "query" | "rate_limit" | "network" | "server"

M.KINDS = table.freeze({
	auth = true,
	permission = true,
	query = true,
	rate_limit = true,
	network = true,
	server = true,
}) :: { [string]: boolean }

export type NsError = {
	kind: Kind,
	message: string,
	status: number?,
	code: string?,
}

-- Codes this plugin raises itself.
M.READ_ONLY = "TNS_READ_ONLY"
M.NO_CONNECTION = "TNS_NO_CONNECTION"
M.NO_CREDENTIALS = "TNS_NO_CREDENTIALS"
M.TIMEOUT = "TNS_TIMEOUT"
M.NETWORK = "TNS_NETWORK"
M.BAD_RESPONSE = "TNS_BAD_RESPONSE"
M.NO_WINDOW = "TNS_NO_WINDOW"
M.SIGNING = "TNS_SIGNING"

local MAX_MESSAGE = 600

local function set(list: { string }): { [string]: boolean }
	local s: { [string]: boolean } = {}
	for _, v in list do
		s[v] = true
	end
	return s
end

local RATE = set({
	"SSS_REQUEST_LIMIT_EXCEEDED",
	"REQUEST_LIMIT_EXCEEDED",
	"WS_REQUEST_BLOCKED",
	"WS_CONCUR_SESSION_DISALLWD",
	"CONCURRENCY_LIMIT_EXCEEDED",
	"TOO_MANY_REQUESTS",
})

local AUTH = set({
	"INVALID_LOGIN",
	"INVALID_LOGIN_ATTEMPT",
	"INVALID_LOGIN_CREDENTIALS",
	"INVALID_ACCOUNT",
	"ACCOUNT_DISABLED",
	"LOGIN_REQUIRED",
	"INVALID_TOKEN",
	"TOKEN_EXPIRED",
	"invalid_client",
	"invalid_grant",
	"invalid_request",
	"unauthorized_client",
	"invalid_token",
	M.NO_CREDENTIALS,
	M.SIGNING,
})

local PERMISSION = set({
	"INSUFFICIENT_PERMISSION",
	"PERMISSION_VIOLATION",
	"INVALID_ROLE",
	"ACCESS_DENIED",
	"FEATURE_DISABLED",
	"invalid_scope",
	"SSS_INVALID_SCRIPTLET_ID",
	"SSS_DEPLOYMENT_NOT_RELEASED",
})

local SERVER = set({
	"UNEXPECTED_ERROR",
	"SSS_USAGE_LIMIT_EXCEEDED",
	"SSS_TIME_LIMIT_EXCEEDED",
	"SSS_REQUEST_TIME_EXCEEDED",
	"SSS_CONNECTION_TIME_OUT",
	"SSS_BACKEND_ERROR",
	"SERVICE_UNAVAILABLE",
	M.BAD_RESPONSE,
})

local function clean(message: string): string
	local m = string.gsub(message, "%s+", " ")
	m = string.gsub(m, "^ ", "")
	m = string.gsub(m, " $", "")
	if #m > MAX_MESSAGE then
		m = string.sub(m, 1, MAX_MESSAGE - 3) .. "..."
	end
	return m
end

-- A known code inside free text ("SSS_REQUEST_LIMIT_EXCEEDED: ...").
local function codeIn(text: string): string?
	for word in string.gmatch(text, "[%u][%u_]+[%u]") do
		if RATE[word] or AUTH[word] or PERMISSION[word] or SERVER[word] then
			return word
		end
	end
	return nil
end

local function classify(code: string?, status: number?): Kind
	if code then
		if RATE[code] then
			return "rate_limit"
		elseif AUTH[code] then
			return "auth"
		elseif PERMISSION[code] then
			return "permission"
		elseif SERVER[code] then
			return "server"
		end
	end
	if status == 429 then
		return "rate_limit"
	elseif status == 401 then
		return "auth"
	elseif status == 403 then
		return "permission"
	elseif status == nil or status == 0 then
		return "network"
	elseif status >= 500 then
		return "server"
	elseif status >= 400 or (status >= 200 and status < 300) then
		-- 2xx here is an application error a RESTlet reported in its body.
		return "query"
	end
	return "server"
end

-- An error of `kind` (or the kind `code` implies when `kind` is nil).
function M.new(kind: Kind?, message: string, code: string?, status: number?): NsError
	return {
		kind = kind or classify(code, status),
		message = clean(message),
		status = status,
		code = code,
	}
end

-- Classifies an error a NetSuite payload or a script reported as text.
function M.fromText(message: string, code: string?, status: number?): NsError
	local c = code or codeIn(message)
	return M.new(nil, message, c, status)
end

local function str(v: any): string?
	return if type(v) == "string" and v ~= "" then v else nil
end

-- RESTlet messages are sometimes a JSON-encoded SuiteScriptError.
local function unwrap(message: string, decode: (string) -> any): (string, string?)
	if string.sub(message, 1, 1) ~= "{" then
		return message, nil
	end
	local ok, inner = pcall(decode, message)
	if ok and type(inner) == "table" then
		local m = str(inner.message) or message
		return m, str(inner.name) or str(inner.code)
	end
	return message, nil
end

-- (message, code) from a decoded NetSuite error body, or nil.
local function fromBody(doc: any, decode: (string) -> any): (string?, string?)
	if type(doc) ~= "table" then
		return nil, nil
	end
	local details = doc["o:errorDetails"]
	if type(details) == "table" and type(details[1]) == "table" then
		local d = details[1]
		return str(d.detail) or str(doc.title), str(d["o:errorCode"])
	end
	local e = doc.error
	if type(e) == "table" then
		local message, inner = unwrap(str(e.message) or "", decode)
		return (if message ~= "" then message else nil), inner or str(e.code) or str(e.name)
	end
	if type(e) == "string" then
		-- OAuth 2.0 token error (error, error_description) or a RESTlet's
		-- { ok: false, error: "..." }.
		local description = str(doc.error_description)
		if description or string.find(e, "^[a-z_]+$") then
			return description or e, e
		end
		local message, inner = unwrap(e, decode)
		return message, inner
	end
	return str(doc.title) or str(doc.message), str(doc.code)
end

-- The error a decoded NetSuite body describes (any status), or nil when it
-- carries no error message.
function M.fromDocument(doc: any, status: number, decode: (string) -> any): NsError?
	local message, code = fromBody(doc, decode)
	if message == nil then
		return nil
	end
	return M.fromText(message, code, status)
end

export type HttpResult = {
	status: number,
	body: string,
	error: string?,
	timed_out: boolean?,
}

-- The error a fetch result represents, or nil for a 2xx response (whose
-- body the transport parses; it may still carry an application error).
function M.fromHttp(res: HttpResult, decode: (string) -> any): NsError?
	if res.error ~= nil or res.status == 0 then
		if res.timed_out then
			return M.new("network", "NetSuite did not answer in time", M.TIMEOUT)
		end
		return M.new("network", "could not reach NetSuite: " .. tostring(res.error or "no response"), M.NETWORK)
	end
	if res.status >= 200 and res.status < 300 then
		return nil
	end
	local ok, doc = pcall(decode, res.body)
	local message, code = fromBody(if ok then doc else nil, decode)
	if message == nil then
		local text = string.gsub(res.body, "<[^>]*>", " ")
		message = if string.find(text, "%S")
			then string.format("HTTP %d: %s", res.status, text)
			else string.format("HTTP %d", res.status)
	end
	return M.fromText(message :: string, code or codeIn(res.body), res.status)
end

-- Rate limits, transport failures and server-side limits can succeed on a
-- later attempt; auth, permission and query errors cannot.
function M.retryable(e: NsError): boolean
	return e.kind == "rate_limit" or e.kind == "network" or e.kind == "server"
end

return M
