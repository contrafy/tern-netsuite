--!strict
-- One SuiteCloud account command per auth ID on this machine.
--
-- Two account commands (the CLI's isSetupRequired ones: object:list,
-- file:list, object:import, file:import, file:upload, project:deploy, ...)
-- running at once for the same auth ID race on its OAuth token refresh,
-- which can void the stored credentials (seen with CLI 3.2.0). A lock held
-- inside a plugin VM cannot prevent that: a reloaded VM's process keeps
-- running without a callback, other VMs and split panes run their own. So
-- the slot is a lock directory taken by the process itself:
--
--   <tern.plugin.data>/cli-slots/<auth ID>   (mkdir is atomic)
--   <lock>/owner                             pid|start time|label|cwd
--
-- SCRIPT (POSIX sh) waits for the lock, records itself as the owner and
-- then `exec`s the CLI, so the owner pid is the CLI process. Nothing ever
-- releases the lock explicitly: the next taker finds the owner gone (dead
-- pid, or a reused pid with another start time) and removes it. A crash,
-- a kill on timeout, a closed pane or a plugin reload therefore never
-- leaves a lock behind for longer than it takes the next taker to look.
-- Removal of a stale lock is serialized by `<lock>.reap`, and the taker
-- checks again inside it, so a fresh lock is never removed by a waiter
-- that saw the previous one stale.
--
-- How a module adopts the slot (every plugin module that starts an account
-- command must):
--   - a background run (tern.process.run): run `CliSlot.argv(argv, lock,
--     CliSlot.waitSeconds(timeoutMs))` instead of argv; exit status
--     BUSY_STATUS with a one-line stderr means the slot stayed taken;
--   - a pane: `CliSlot.paneScript{...}` and launch `CliSlot.paneLine`;
--     the pane says what it waits for and waits until the slot frees.
-- `lock` is `CliSlot.lockPath(tern.plugin.data, authId)`;
-- plugin/cli_slot_host.luau does that for adapters.
--
-- Every word that goes into a shell line must pass `M.unsafe` (fish reads
-- `\'` inside single quotes as an escaped quote, so POSIX quoting is only
-- valid in both shells for words without backslashes or quotes).

local M = {}

M.DIR = "cli-slots"
-- Exit status when a bounded wait for the slot ran out (EX_TEMPFAIL).
M.BUSY_STATUS = 75
-- $0 of the slot shell, as `ps` shows it.
M.NAME = "tern-netsuite-cli"
-- Bounds of a background run's wait, in seconds.
M.MIN_WAIT = 5
M.MAX_WAIT = 300

-- The CLI's account commands (isSetupRequired in CLI 3.2.0).
M.ACCOUNT_COMMANDS = table.freeze({
	"project:deploy",
	"project:validate",
	"file:import",
	"object:import",
	"file:list",
	"object:list",
	"object:update",
	"file:upload",
})

-- Takes the slot `$1` (lock dir), waits at most `$2` seconds (0: until it
-- frees, telling stderr once what it waits for), records `$3` as what holds
-- it and execs the rest of the arguments. One line, no single quotes and no
-- backslashes, so it survives being quoted inside another POSIX/fish line.
M.SCRIPT = table.concat({
	"lock=$1 wait=$2 label=$3",
	"shift 3",
	'mkdir -p "${lock%/*}" 2>/dev/null',
	'me=$(ps -o lstart= -p "$$" 2>/dev/null)',
	'held() { pid= start= what= dir=; IFS="|" read -r pid start what dir <"$lock/owner" 2>/dev/null; [ -n "$pid" ]; }',
	'gone() { ! kill -0 "$pid" 2>/dev/null || [ "$(ps -o lstart= -p "$pid" 2>/dev/null)" != "$start" ]; }',
	'reap() { if mkdir "$lock.reap" 2>/dev/null; then if held; then gone && rm -rf "$lock"; elif [ "$missing" -ge 5 ]; then rm -rf "$lock"; fi; rmdir "$lock.reap"; elif [ -n "$(find "$lock.reap" -prune -mmin +1 2>/dev/null)" ]; then rmdir "$lock.reap" 2>/dev/null; fi; }',
	"n=0 missing=0 told=",
	'until mkdir "$lock" 2>/dev/null; do'
		.. " if held; then missing=0; else missing=$((missing + 1)); fi;"
		.. ' if { [ -n "$pid" ] && gone; } || [ "$missing" -ge 5 ]; then reap; mkdir "$lock" 2>/dev/null && break; fi;'
		.. ' if [ "$wait" -eq 0 ] && [ -z "$told" ] && [ -n "$pid" ]; then'
		.. ' printf "tern-netsuite: waiting for %s (pid %s, in %s) to finish: one SuiteCloud account command at a time per auth ID" "$what" "$pid" "$dir" >&2; echo >&2; told=1;'
		.. " fi;"
		.. " n=$((n + 1));"
		.. ' if [ "$wait" -gt 0 ] && [ "$n" -ge "$wait" ]; then'
		.. ' printf "tern-netsuite: %s (pid %s) still holds this auth ID after %s s; nothing was run, try again when it finishes" "${what:-another SuiteCloud command}" "${pid:-?}" "$wait" >&2; echo >&2;'
		.. " exit 75;"
		.. " fi;"
		.. " sleep 1;"
		.. " done",
	'printf "%s|%s|%s|%s" "$$" "$me" "$label" "$PWD" >"$lock/owner"',
	'exec "$@"',
}, "; ")

function M.isAccountCommand(command: string?): boolean
	return command ~= nil and table.find(M.ACCOUNT_COMMANDS, command) ~= nil
end

local function hex(s: string): string
	return (string.gsub(s, ".", function(c: string): string
		return string.format("%02x", string.byte(c))
	end))
end

-- The lock directory of `authId` (nil: a project without defaultAuthId,
-- whose commands fail in the CLI anyway, share one slot).
function M.lockPath(dataDir: string, authId: string?): string
	local name: string
	if authId == nil then
		name = "none"
	elseif #authId <= 64 and string.find(authId, "^[%w_][%w_%.%-]*$") then
		name = "auth-" .. authId
	else
		name = "hex-" .. hex(authId)
	end
	return dataDir .. "/" .. M.DIR .. "/" .. name
end

-- Seconds a background run waits for the slot: half its timeout, so the
-- command itself still has time once it gets the slot.
function M.waitSeconds(timeoutMs: number): number
	return math.clamp(math.floor(timeoutMs / 2000), M.MIN_WAIT, M.MAX_WAIT)
end

-- What the owner file names as the holder: the CLI subcommand (the first
-- `word:word` argument, past a wrapper like the guard), restricted to
-- characters that cannot break the owner line or glob in a shell.
local function label(argv: { string }): string
	local word = argv[1] or "?"
	for _, w in argv do
		if string.find(w, "^%a+:%a+$") then
			word = w
			break
		end
	end
	return (string.gsub(string.sub(word, 1, 64), "[^%w:%._%-/]", "_"))
end

-- `argv` run inside the slot `lock`, waiting at most `wait` seconds.
function M.argv(argv: { string }, lock: string, wait: number): { string }
	local out = { "sh", "-c", M.SCRIPT, M.NAME, lock, tostring(math.max(math.floor(wait), 1)), label(argv) }
	table.move(argv, 1, #argv, #out + 1, out)
	return out
end

-- Why `s` cannot go into a shell line, or nil.
function M.unsafe(s: string): string?
	if string.find(s, "%c") then
		return "contains a control character"
	end
	if string.find(s, "\\", 1, true) then
		return "contains a backslash"
	end
	if string.find(s, "['\"]") then
		return "contains a quote"
	end
	return nil
end

-- Text for display inside a shell line (titles, messages): every character
-- `unsafe` refuses becomes `?`.
function M.printable(s: string): string
	return (string.gsub(s, "[%c\\'\"]", "?"))
end

-- One POSIX shell word: bare when it has only safe characters, else single
-- quoted with each ' written as '\''.
function M.quote(s: string): string
	if s ~= "" and string.find(s, "^[%w%-_%./:=@+,]+$") then
		return s
	end
	return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

export type Pane = {
	-- Pane title (OSC 0) and the first line the pane prints.
	title: string,
	intro: string,
	-- Where the command runs (the CLI reads project.json from there).
	cwd: string,
	lock: string,
	argv: { string },
}

-- The `sh` script of a pane that runs `p.argv` in `p.cwd` inside the slot,
-- then shows the exit status and waits for Enter so the output stays. Nil
-- and why when a word cannot be put into a shell line safely.
function M.paneScript(p: Pane): (string?, string?)
	for _, w in { p.cwd, p.lock } do
		local why = M.unsafe(w)
		if why then
			return nil, w .. " " .. why .. ", which cannot be passed safely through a shell line"
		end
	end
	for _, w in p.argv do
		local why = M.unsafe(w)
		if why then
			return nil, M.printable(w) .. " " .. why .. ", which cannot be passed safely through a shell line"
		end
	end
	local words: { string } = { "sh", "-c", M.quote(M.SCRIPT), M.NAME, M.quote(p.lock), "0", label(p.argv) }
	for _, w in p.argv do
		table.insert(words, M.quote(w))
	end
	return table.concat({
		"printf '\\033]0;%s\\007' " .. M.quote(M.printable(p.title)),
		"printf 'tern-netsuite: %s\\n' " .. M.quote(M.printable(p.intro)),
		"cd " .. M.quote(p.cwd) .. " && " .. table.concat(words, " "),
		"s=$?",
		"printf '\\ntern-netsuite: %s exited %s; press Enter to close\\n' " .. label(p.argv) .. ' "$s"',
		"read -r _",
		'exit "$s"',
	}, "; "),
		nil
end

-- The command line of a pane running `script`.
function M.paneLine(script: string): string
	return "sh -c " .. M.quote(script)
end

return table.freeze(M)
