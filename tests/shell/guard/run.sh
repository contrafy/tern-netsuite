#!/bin/sh
# Tests for the tern-netsuite shell guard (shell/tern-netsuite-guard, the PATH
# shim shell/bin/suitecloud and the zsh, bash and fish activation files). No
# Tern and no NetSuite: a fake `tern` plays the approve block and a fake
# `suitecloud` (tests/bin/fake-suitecloud-guard) resolves auth IDs from
# fixture files and records what would have run. The real CLI is never
# reachable: PATH holds only the fakes, the shells under test and the system
# directories. Each case asserts the property the guard exists for: a
# guarded command aimed at production runs only after a matching approval,
# exactly as typed; everything else is untouched.
#
#   sh tests/shell/guard/run.sh      (or: make test-shell)

set -u

repo=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd -P)
here=$repo/tests/shell/guard
core=$repo/shell/tern-netsuite-guard
shim_dir=$repo/shell/bin
luau=${LUAU:-$repo/.tools/bin/luau}
case $luau in
/*) ;;
*) luau=$repo/$luau ;;
esac

root=$(mktemp -d "${TMPDIR:-/tmp}/tns-guard-test.XXXXXX") || exit 2
root=$(cd -P "$root" && pwd -P)
trap 'rm -rf "$root"' EXIT

# Only the fakes and the shells under test are reachable, never a real tern
# or suitecloud (shells are linked one by one because a real CLI may share
# their directory).
mkdir -p "$root/fakebin" "$root/shellbin" "$root/home"
ln -s "$repo/tests/bin/fake-suitecloud-guard" "$root/fakebin/suitecloud"
ln -s "$here/bin/tern" "$root/fakebin/tern"
shells=
for s in zsh bash fish dash; do
	p=$(command -v "$s" 2>/dev/null) || continue
	ln -s "$p" "$root/shellbin/$s"
	shells="$shells $s"
done
for sys in /usr/bin /bin; do
	[ -x "$sys/suitecloud" ] && {
		echo "refusing to run: $sys/suitecloud exists and would be reachable" >&2
		exit 2
	}
done
BASE_PATH=$root/fakebin:$root/shellbin:/usr/bin:/bin:/usr/sbin:/sbin
PATH=$BASE_PATH
HOME=$root/home
XDG_CONFIG_HOME=$root/home/.config
export PATH HOME XDG_CONFIG_HOME
unset TERN_BIN TNS_SPOOL TNS_GUARD_COMMANDS TNS_GUARD_CONFIRM TNS_GUARD_TIMEOUT TNS_GUARD_ACCOUNTS TNS_SUITECLOUD \
	TERN_NETSUITE_GUARD ZDOTDIR FAKE_READ_STDIN BASH_ENV ENV PROMPT_COMMAND GIT_DIR GIT_WORK_TREE
FAKE_DIR=$root/fake
export FAKE_DIR

pass=0
failed=0
skipped=0
case_name=

ok() {
	pass=$((pass + 1))
}

bad() {
	failed=$((failed + 1))
	printf 'FAIL [%s] %s\n' "$case_name" "$*"
	if [ -s "$root/out" ]; then
		sed 's/^/    | /' "$root/out"
	fi
}

skip() {
	skipped=$((skipped + 1))
	printf 'SKIP [%s] %s\n' "$case_name" "$*"
}

P=$root/work/sdf/billing

# Fresh fake state, spool and project; the environment of a new Tern pane.
# The project mirrors an SDF account customization project whose objects
# are symlinks into a shared directory.
fresh() {
	case_name=$1
	rm -rf "$FAKE_DIR" "$root/spool" "$root/work"
	mkdir -p "$FAKE_DIR" "$P/src/Objects" "$P/src/FileCabinet/SuiteScripts/my dir" "$root/work/shared"
	printf '1234567\nProduction\nExample Co\n' >"$FAKE_DIR/auth-prod"
	printf '1234567_SB1\nSandbox\nExample Co\n' >"$FAKE_DIR/auth-sandbox"
	printf '{\n  "defaultAuthId": "prod"\n}\n' >"$P/project.json"
	printf "module.exports = {\n\tdefaultProjectFolder: 'src',\n\tcommands: {},\n};\n" >"$P/suitecloud.config.js"
	cat >"$P/src/deploy.xml" <<'EOF'
<deploy>
    <files>
        <path>~/FileCabinet/*</path>
    </files>
    <objects>
        <path>~/Objects/*</path>
    </objects>
    <translationimports>
        <path>~/Translations/*</path>
    </translationimports>
</deploy>
EOF
	printf '<manifest projecttype="ACCOUNTCUSTOMIZATION"/>\n' >"$P/src/manifest.xml"
	printf '<customscript scriptid="customscript_a"/>\n' >"$root/work/shared/customscript_a.xml"
	ln -s ../../../../shared/customscript_a.xml "$P/src/Objects/customscript_a.xml"
	printf 'define([], () => ({}));\n' >"$P/src/FileCabinet/SuiteScripts/my dir/a b.js"
	printf 'define([], () => ({}));\n' >"$P/src/FileCabinet/SuiteScripts/x.js"
	(
		cd "$root/work" &&
			git init -q -b main . &&
			git add -A &&
			git -c user.name=t -c user.email=t@example.com commit -q -m init
	) >/dev/null 2>&1
	mkdir -m 755 "$root/spool"
	TERM_PROGRAM=tern
	TERN_PANE=4294967309
	TNS_SPOOL=$root/spool
	export TERM_PROGRAM TERN_PANE TNS_SPOOL
	unset TNS_GUARD_COMMANDS TNS_GUARD_CONFIRM TNS_GUARD_TIMEOUT TNS_GUARD_ACCOUNTS TNS_SUITECLOUD TERN_BIN \
		FAKE_READ_STDIN TERN_NETSUITE_GUARD
	PATH=$BASE_PATH
	cd "$P" || exit 2
	: >"$root/out"
}

mode() {
	echo "$1" >"$FAKE_DIR/tern-mode"
}

# run_code SHELL CODE ARGS...: runs CODE in SHELL (no rc files) with ARGS as
# its positional arguments ($argv in fish); output in $root/out, status in $st.
run_code() {
	sh_=$1
	code_=$2
	shift 2
	case $sh_ in
	zsh) zsh -f -c "$code_" zsh "$@" ;;
	bash) bash --norc --noprofile -c "$code_" bash "$@" ;;
	fish) fish --no-config -c "$code_" -- "$@" ;;
	dash) dash -c "$code_" dash "$@" ;;
	esac >"$root/out" 2>&1 <"${STDIN_FILE:-/dev/null}"
	st=$?
}

# Code that sources the activation file of SHELL and runs `suitecloud
# ARGS...` (dash has none: it runs the core directly, as the functions do).
scode() {
	case $1 in
	zsh | bash) printf '%s' 'source "$TNS_SNIP"; suitecloud "$@"' ;;
	fish) printf '%s' 'source $TNS_SNIP; suitecloud $argv' ;;
	dash) printf '%s' '"$TNS_CORE" suitecloud "$@"' ;;
	esac
}

# run_s SHELL ARGS...: `suitecloud ARGS...` through the guard in SHELL.
run_s() {
	sh_s=$1
	shift
	run_code "$sh_s" "$(scode "$sh_s")" "$@"
}

expect_status() {
	if [ "$st" = "$1" ]; then ok; else bad "$2: exit $st, want $1"; fi
}

expect_out() {
	if grep -E -q -- "$1" "$root/out"; then ok; else bad "$2: output lacks /$1/"; fi
}

expect_no_out() {
	if grep -E -q -- "$1" "$root/out"; then bad "$2: output has /$1/"; else ok; fi
}

expect_not_run() {
	if [ -e "$FAKE_DIR/call-1" ]; then bad "$1: suitecloud ran: $(tr '\0' ' ' <"$FAKE_DIR/call-1")"; else ok; fi
}

expect_no_tern() {
	if [ -e "$FAKE_DIR/tern-calls" ]; then bad "$1: tern was invoked"; else ok; fi
}

expect_tern() {
	if [ -e "$FAKE_DIR/tern-calls" ]; then ok; else bad "$1: no approval was requested"; fi
}

# expect_ran WHAT ARGS...: suitecloud ran exactly once, with exactly ARGS, in $P.
expect_ran() {
	what_=$1
	shift
	printf '%s\0' "$@" >"$root/want"
	if [ ! -e "$FAKE_DIR/call-1" ]; then
		bad "$what_: suitecloud did not run"
	elif [ -e "$FAKE_DIR/call-2" ]; then
		bad "$what_: suitecloud ran more than once"
	elif ! cmp -s "$root/want" "$FAKE_DIR/call-1"; then
		bad "$what_: suitecloud argv $(tr '\0' '|' <"$FAKE_DIR/call-1"), want $(tr '\0' '|' <"$root/want")"
	elif [ "$(cat "$FAKE_DIR/cwd-1")" != "$P" ]; then
		bad "$what_: suitecloud ran in $(cat "$FAKE_DIR/cwd-1"), want $P"
	else
		ok
	fi
}

# The spool holds no request/response/scratch left behind (cancel markers allowed).
expect_spool_clean() {
	left=$(cd "$root/spool" 2>/dev/null && ls -A | grep -v '^cancel-')
	if [ -z "$left" ]; then ok; else bad "$1: spool not cleaned: $left"; fi
}

req() {
	cat "$FAKE_DIR/req.json"
}

reqtool() {
	(cd "$here" && "$luau" request.luau -a "$@")
}

sha256_() {
	if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi
}

# The request parses like the approve block parses it, carries ARGS as argv
# and a fingerprint equal to the sha256 of the plugin's canonical string.
expect_request() {
	what_=$1
	shift
	if [ ! -s "$FAKE_DIR/req.json" ]; then
		bad "$what_: no request reached tern"
		return
	fi
	if [ -x "$luau" ]; then
		if msg_=$(reqtool strict "$(req)" 2>&1); then ok; else bad "$what_: request: $msg_"; fi
		if msg_=$(reqtool argv "$(req)" "$@" 2>&1); then ok; else bad "$what_: request argv: $msg_"; fi
		want_fp=$(reqtool canon "$(req)" | sha256_)
		want_fp=${want_fp%% *}
		if req | grep -q "\"fingerprint\":\"$want_fp\""; then ok; else bad "$what_: fingerprint is not sha256 of the plugin's canonical string"; fi
	else
		skip "$what_: request checks need $luau (make bootstrap)"
	fi
	if req | grep -Eq '"nonce":"[0-9a-f]{32}"'; then ok; else bad "$what_: nonce is not 32 lowercase hex"; fi
	if [ "$(cat "$FAKE_DIR/req-mode")" = -rw------- ]; then ok; else bad "$what_: request mode $(cat "$FAKE_DIR/req-mode")"; fi
	if [ "$(cat "$FAKE_DIR/spool-mode")" = drwx------ ]; then ok; else bad "$what_: spool mode $(cat "$FAKE_DIR/spool-mode")"; fi
}

expect_field() {
	got_=$(reqtool field "$(req)" "$1" 2>/dev/null)
	if [ "$got_" = "$2" ]; then ok; else bad "$3: request $1 = '$got_', want '$2'"; fi
}

expect_files() { # what, then the expected sorted paths
	what_=$1
	shift
	reqtool files "$(req)" >"$root/got-files" 2>&1
	: >"$root/want-files"
	for f_ in "$@"; do printf '%s\n' "$f_" >>"$root/want-files"; done
	if cmp -s "$root/got-files" "$root/want-files"; then ok; else bad "$what_: request files: $(tr '\n' '|' <"$root/got-files")"; fi
}

expect_note() {
	if reqtool notes "$(req)" 2>/dev/null | grep -Eq -- "$1"; then ok; else bad "$2: request notes lack /$1/: $(reqtool notes "$(req)" 2>&1 | tr '\n' '|')"; fi
}

# Behaviour of the core, identical whichever shell calls it.
core_cases() {
	sh=$1

	fresh "$sh pass-through"
	printf 'line one\n\tbinary\001 bytes\n' >"$root/stdin"
	echo 7 >"$FAKE_DIR/exit"
	unset TERM_PROGRAM TERN_PANE TNS_SPOOL
	FAKE_READ_STDIN=1
	export FAKE_READ_STDIN
	STDIN_FILE=$root/stdin run_s "$sh" project:validate --server 'a b' ''
	expect_status 7 "exit status of a non-guarded command"
	expect_ran "non-guarded argv" project:validate --server 'a b' ''
	if cmp -s "$root/stdin" "$FAKE_DIR/stdin-1"; then ok; else bad "stdin not passed through unchanged"; fi
	expect_no_tern "non-guarded command"
	[ -e "$FAKE_DIR/info-calls" ] && bad "non-guarded command resolved the account" || ok
	[ -z "$(cat "$root/out")" ] && ok || bad "non-guarded command printed guard output"

	fresh "$sh sandbox target passes through without prompting"
	printf '{"defaultAuthId": "sandbox"}\n' >"$P/project.json"
	unset TERM_PROGRAM TERN_PANE TNS_SPOOL
	run_s "$sh" project:deploy --validate
	expect_status 0 "sandbox deploy"
	expect_ran "sandbox deploy argv" project:deploy --validate
	expect_no_tern "sandbox deploy"
	if grep -q "^sandbox /\$" "$FAKE_DIR/info-calls"; then ok; else bad "the account was not resolved with the CLI from /: $(cat "$FAKE_DIR/info-calls")"; fi

	fresh "$sh approve production deploy"
	echo 5 >"$FAKE_DIR/exit"
	run_s "$sh" project:deploy --log 'my logs/d.log' --accountspecificvalues WARNING
	expect_status 5 "exit status forwarded after approval"
	expect_ran "approved argv" project:deploy --log 'my logs/d.log' --accountspecificvalues WARNING
	expect_request "deploy request" suitecloud project:deploy --log 'my logs/d.log' --accountspecificvalues WARNING
	expect_field command project:deploy "deploy request"
	expect_field auth_id prod "deploy request"
	expect_field account_id 1234567 "deploy request"
	expect_field account_name "Example Co" "deploy request"
	expect_field account_type Production "deploy request"
	expect_field cwd "$P" "deploy request"
	expect_field folder "$P/src" "deploy request"
	expect_field pane 4294967309 "deploy request"
	expect_field program "$root/fakebin/suitecloud" "deploy request"
	expect_field timeout_s 600 "deploy request"
	expect_files "deploy.xml files, symlinked objects followed" \
		"$P/project.json" \
		"$P/src/FileCabinet/SuiteScripts/my dir/a b.js" \
		"$P/src/FileCabinet/SuiteScripts/x.js" \
		"$P/src/Objects/customscript_a.xml" \
		"$P/src/deploy.xml" \
		"$P/src/manifest.xml" \
		"$P/suitecloud.config.js"
	expect_note 'Translations' "missing deploy.xml path"
	if req | grep -q '"git":{"root":"'"$root/work"'","branch":"main","head":"[0-9a-f]\{40\}","dirty":false'; then ok; else bad "git state missing: $(req | sed 's/.*"git":\({[^}]*}\).*/\1/')"; fi
	expect_spool_clean "after approval"
	want_call="open --wait $root/spool/$(sed -n 's/.*"nonce":"\([0-9a-f]*\)".*/req-\1.json/p' "$FAKE_DIR/req.json")"
	if [ "$(cat "$FAKE_DIR/tern-calls")" = "$want_call" ]; then ok; else bad "tern open argv: $(cat "$FAKE_DIR/tern-calls")"; fi

	fresh "$sh dirty tree and odd argv"
	printf 'change\n' >>"$P/src/FileCabinet/SuiteScripts/x.js"
	weird=$(printf 'q"b\\s\tt\nn\001c\033e ü 日本 %%s')
	run_s "$sh" project:deploy --log "$weird"
	expect_status 0 "approve odd argv"
	expect_ran "odd argv executed verbatim" project:deploy --log "$weird"
	expect_request "odd argv request" suitecloud project:deploy --log "$weird"
	if req | grep -q '"dirty":true'; then ok; else bad "dirty tree not reported"; fi

	fresh "$sh file:upload paths"
	run_s "$sh" file:upload --paths /SuiteScripts/x.js '/SuiteScripts/missing.js' -i
	expect_status 0 "upload approved"
	expect_ran "upload argv" file:upload --paths /SuiteScripts/x.js /SuiteScripts/missing.js -i
	expect_request "upload request" suitecloud file:upload --paths /SuiteScripts/x.js /SuiteScripts/missing.js -i
	expect_files "upload fingerprints the uploaded file and the project settings" \
		"$P/project.json" "$P/src/FileCabinet/SuiteScripts/x.js" "$P/suitecloud.config.js"
	expect_note 'missing\.js is not a file' "missing upload path"

	fresh "$sh unknown account asks for approval"
	rm "$FAKE_DIR/auth-prod"
	mode noresp
	run_s "$sh" project:deploy
	expect_status 1 "unknown account"
	expect_tern "unknown account"
	expect_field account_id null "unknown account"
	expect_note 'failed: the target account is unknown' "unknown account"
	expect_not_run "unknown account"
	fresh "$sh unknown account approved"
	rm "$FAKE_DIR/auth-prod"
	run_s "$sh" project:deploy
	expect_status 0 "unknown account approved"
	expect_ran "unknown account approved" project:deploy

	fresh "$sh no project.json asks for approval"
	rm "$P/project.json"
	mode deny
	run_s "$sh" project:deploy
	expect_status 1 "no project.json"
	expect_tern "no project.json"
	expect_field auth_id null "no project.json"
	expect_not_run "no project.json"

	fresh "$sh --authid cannot vouch for a sandbox target"
	printf '{"defaultAuthId": "sandbox"}\n' >"$P/project.json"
	mode deny
	run_s "$sh" project:deploy --authid sandbox
	expect_status 1 "--authid"
	expect_tern "--authid is treated as an unknown target"
	expect_note '--authid is not an option' "--authid note"

	fresh "$sh deploy preview and help need no approval"
	unset TERM_PROGRAM
	run_s "$sh" project:deploy --dryrun
	expect_status 0 "--dryrun"
	expect_ran "--dryrun" project:deploy --dryrun
	expect_no_tern "--dryrun"
	fresh "$sh help needs no approval"
	unset TERM_PROGRAM
	run_s "$sh" file:upload --help
	expect_ran "--help" file:upload --help
	expect_no_tern "--help"
	fresh "$sh --dryrun as an option value is not a preview"
	mode noresp
	run_s "$sh" project:deploy --log --dryrun
	expect_status 1 "--log --dryrun"
	expect_tern "--log --dryrun"
	expect_not_run "--log --dryrun"
	fresh "$sh --dryrun after -- is not a preview"
	mode noresp
	run_s "$sh" project:deploy -- --dryrun
	expect_status 1 "-- --dryrun"
	expect_not_run "-- --dryrun"

	# A beforeExecuting hook runs inside the CLI and can turn a preview into
	# a real deploy: --dryrun is then no reason to skip the target check.
	hook_cfg="module.exports = { defaultProjectFolder: 'src', commands: { 'project:deploy': { beforeExecuting: async (args) => args } } };"
	fresh "$sh --dryrun with a beforeExecuting hook needs approval"
	printf '%s\n' "$hook_cfg" >"$P/suitecloud.config.js"
	mode noresp
	run_s "$sh" project:deploy --dryrun
	expect_status 1 "hooked --dryrun"
	expect_tern "hooked --dryrun"
	expect_note 'beforeExecuting' "hooked --dryrun"
	expect_not_run "hooked --dryrun"
	fresh "$sh --dryrun with a beforeExecuting hook on a sandbox target runs"
	printf '%s\n' "$hook_cfg" >"$P/suitecloud.config.js"
	printf '{"defaultAuthId": "sandbox"}\n' >"$P/project.json"
	unset TERM_PROGRAM
	run_s "$sh" project:deploy --dryrun
	expect_ran "hooked sandbox --dryrun" project:deploy --dryrun
	expect_no_tern "hooked sandbox --dryrun"

	# A config that loads other code may get a hook from it: no shortcut. An
	# unreadable config is refused outright (it cannot be fingerprinted).
	for cfg in "const hooks = require('./hooks'); module.exports = { defaultProjectFolder: 'src', commands: hooks };" \
		"import hooks from './hooks.js'; export default { defaultProjectFolder: 'src', commands: hooks };" \
		"module.exports = { defaultProjectFolder: 'src', commands: import('./hooks.mjs') };" \
		unreadable; do
		fresh "$sh --dryrun with a config that loads code needs approval: $cfg"
		if [ "$cfg" = unreadable ]; then
			chmod 000 "$P/suitecloud.config.js"
		else
			printf '%s\n' "$cfg" >"$P/suitecloud.config.js"
		fi
		mode noresp
		run_s "$sh" project:deploy --dryrun
		chmod 644 "$P/suitecloud.config.js"
		expect_status 1 "$cfg"
		[ "$cfg" = unreadable ] || expect_tern "$cfg"
		expect_not_run "$cfg"
	done

	# The CLI reads project.json with JSON.parse (last duplicate wins, escapes
	# decoded); anything the guard cannot read unambiguously is an unknown
	# target, never the first sandbox-looking value.
	for pj in '{"defaultAuthId": "sandbox", "defaultAuthId": "prod"}' \
		'{"defaultAuthId": "sandbox", "default\u0041uthId": "prod"}' \
		'{"defaultAuthId": "sand\u0062ox"}' \
		'{"defaultAuthId": "sand box"}'; do
		fresh "$sh ambiguous project.json needs approval: $pj"
		printf '%s\n' "$pj" >"$P/project.json"
		mode noresp
		run_s "$sh" project:deploy
		expect_status 1 "$pj"
		expect_tern "$pj"
		expect_field auth_id null "$pj"
		expect_note 'defaultAuthId' "$pj"
		expect_not_run "$pj"
	done

	fresh "$sh guarded commands come from TNS_GUARD_COMMANDS"
	TNS_GUARD_COMMANDS=project:deploy
	export TNS_GUARD_COMMANDS
	run_s "$sh" file:upload --paths /SuiteScripts/x.js
	expect_ran "upload not guarded" file:upload --paths /SuiteScripts/x.js
	expect_no_tern "upload not guarded"
	fresh "$sh an empty TNS_GUARD_COMMANDS guards nothing"
	TNS_GUARD_COMMANDS=
	export TNS_GUARD_COMMANDS
	run_s "$sh" project:deploy
	expect_ran "nothing guarded" project:deploy
	expect_no_tern "nothing guarded"
	fresh "$sh configured object:update is guarded"
	TNS_GUARD_COMMANDS='project:deploy object:update'
	export TNS_GUARD_COMMANDS
	mode deny
	run_s "$sh" object:update --scriptid customscript_a
	expect_status 1 "object:update guarded"
	expect_not_run "object:update guarded"

	fresh "$sh guard.confirm_production false"
	TNS_GUARD_CONFIRM=0
	export TNS_GUARD_CONFIRM
	unset TERM_PROGRAM
	run_s "$sh" project:deploy
	expect_ran "confirmation off" project:deploy
	expect_no_tern "confirmation off"
	expect_out 'confirm_production is false' "confirmation off is announced"

	fresh "$sh configured production flags win"
	printf '{"defaultAuthId": "sandbox"}\n' >"$P/project.json"
	TNS_GUARD_ACCOUNTS='1234567_SB1=prod'
	export TNS_GUARD_ACCOUNTS
	mode deny
	run_s "$sh" project:deploy
	expect_status 1 "sandbox configured as production"
	expect_not_run "sandbox configured as production"
	fresh "$sh configured non-production"
	TNS_GUARD_ACCOUNTS='9999=prod 1234567=nonprod'
	export TNS_GUARD_ACCOUNTS
	run_s "$sh" project:deploy
	expect_ran "production id configured non-production" project:deploy
	expect_no_tern "production id configured non-production"

	fresh "$sh deny"
	mode deny
	run_s "$sh" project:deploy
	expect_status 1 "denied"
	expect_out 'denied' "denied"
	expect_not_run "denied"
	expect_spool_clean "denied"

	fresh "$sh deny with reason"
	mode denyreason
	run_s "$sh" project:deploy
	expect_status 1 "denied with reason"
	expect_out 'denied in Tern: Not in the spool\[31m \(refused\)$' "reason printed without control characters"
	expect_not_run "denied with reason"

	for m in "timeout:no decision within 1s" "noresp:without an approval response" "fail:failed \\(exit 3\\)" \
		"wrongnonce:nonce mismatch" "tamper:fingerprint mismatch" "stale:fingerprint mismatch" \
		"wrongaccount:account mismatch" "retarget:defaultAuthId changed" "old:outside the" "dup:repeats 'decision'"; do
		name=${m%%:*}
		fresh "$sh refusal: $name"
		if [ "$name" = timeout ]; then
			mode hang
			TNS_GUARD_TIMEOUT=1
			export TNS_GUARD_TIMEOUT
		else
			mode "$name"
		fi
		run_s "$sh" project:deploy
		expect_status 1 "$name"
		expect_out "${m#*:}" "$name message"
		expect_out 'nothing was executed' "$name says nothing ran"
		expect_out 'command suitecloud' "$name names the deliberate bypass"
		expect_not_run "$name"
		expect_spool_clean "$name"
		case $name in
		timeout | fail) ls "$root/spool"/cancel-* >/dev/null 2>&1 && ok || bad "$name left no cancel marker for the block" ;;
		esac
	done

	fresh "$sh tern missing"
	TERN_BIN=$root/no-such-tern
	export TERN_BIN
	run_s "$sh" project:deploy
	expect_status 1 "tern missing"
	expect_out "failed \\(exit 127\\)" "tern missing message"
	expect_not_run "tern missing"

	for v in TERM_PROGRAM TERN_PANE TNS_SPOOL; do
		fresh "$sh outside Tern: no $v"
		unset "$v"
		run_s "$sh" project:deploy
		expect_status 1 "no $v"
		case $v in
		TNS_SPOOL) expect_out 'Open a new Tern pane' "no $v message" ;;
		*)
			expect_out 'not a Tern pane' "no $v message"
			expect_out 'account 1234567' "no $v names the production account"
			expect_out 'command suitecloud \.\.\.' "no $v names the deliberate bypass"
			;;
		esac
		expect_not_run "no $v"
		expect_no_tern "no $v"
	done
	fresh "$sh outside Tern: other terminal"
	TERM_PROGRAM=iTerm.app
	run_s "$sh" file:upload --paths /SuiteScripts/x.js
	expect_status 1 "other terminal"
	expect_not_run "other terminal"

	fresh "$sh suitecloud missing"
	PATH=$root/shellbin:/usr/bin:/bin:/usr/sbin:/sbin
	run_s "$sh" project:validate
	expect_status 127 "no CLI"
	expect_out 'not on PATH' "no CLI message"
	fresh "$sh TNS_SUITECLOUD pins the CLI"
	mkdir -p "$root/pinned"
	ln -sf "$repo/tests/bin/fake-suitecloud-guard" "$root/pinned/sc-real"
	TNS_SUITECLOUD=$root/pinned/sc-real
	export TNS_SUITECLOUD
	PATH=$root/shellbin:/usr/bin:/bin:/usr/sbin:/sbin:$here/bin
	run_s "$sh" project:deploy
	expect_status 0 "pinned CLI"
	expect_ran "pinned CLI" project:deploy
	expect_field program "$root/pinned/sc-real" "pinned CLI"

	fresh "$sh Ctrl-C"
	mode hang
	TNS_GUARD_TIMEOUT=30
	export TNS_GUARD_TIMEOUT
	# Ctrl-C reaches the whole foreground process group (see launch_group).
	(launch_group "$sh" project:deploy >"$root/out" 2>&1 </dev/null) &
	pid=$!
	i=0
	while [ $i -lt 100 ] && ! ls "$root/spool"/req-*.json >/dev/null 2>&1; do
		sleep 0.1
		i=$((i + 1))
	done
	kill -s INT -- "-$pid" 2>/dev/null || bad "Ctrl-C: no process group $pid to signal"
	wait "$pid"
	st=$?
	unset TNS_GUARD_TIMEOUT
	i=0
	while [ $i -lt 50 ] && ls "$root/spool"/req-*.json >/dev/null 2>&1; do
		sleep 0.1
		i=$((i + 1))
	done
	expect_status 130 "Ctrl-C"
	expect_not_run "Ctrl-C"
	ls "$root/spool"/cancel-* >/dev/null 2>&1 && ok || bad "Ctrl-C left no cancel marker for the block"
	expect_spool_clean "Ctrl-C"
	sleep 0.3
	expect_not_run "Ctrl-C (late)"
	if pgrep -f 'sleep 1797' >/dev/null 2>&1; then
		bad "Ctrl-C left the waiting tern open running"
		pkill -f 'sleep 1797'
	else ok; fi
}

# launch_group SHELL ARGS...: replaces the current (sub)shell with the
# suitecloud call running as the leader of a new process group whose id is
# this (sub)shell's pid, with SIGINT/SIGQUIT at their defaults, as in a
# terminal's foreground job (a background job starts with both ignored and
# a shell cannot trap a signal ignored on entry; perl sets them up).
launch_group() {
	sh_l=$1
	shift
	code_l=$(scode "$sh_l")
	case $sh_l in
	zsh) set -- zsh -f -c "$code_l" zsh "$@" ;;
	bash) set -- bash --norc --noprofile -c "$code_l" bash "$@" ;;
	fish) set -- fish --no-config -c "$code_l" -- "$@" ;;
	dash) set -- dash -c "$code_l" dash "$@" ;;
	esac
	exec perl -e '$SIG{INT} = $SIG{QUIT} = "DEFAULT"; setpgrp(0, 0) or die "setpgrp: $!\n"; exec { $ARGV[0] } @ARGV or die "exec: $!\n"' "$@"
}

# Account classification, identical to plugin/lib/account/classify.luau:
# only `_SB<digits>`, `_RP[<digits>]` and `TSTDRV<digits>` ids are
# non-production; a bare suffix or prefix fails closed as production.
classify_cases() {
	for c in 1234567_SB1:nonprod 1234567_sb12:nonprod 1234567_RP:nonprod 1234567_RP2:nonprod TSTDRV1234567:nonprod \
		1234567_SB:prod X_SB:prod TSTDRV:prod TSTDRVX:prod 1234567:prod; do
		id=${c%%:*}
		fresh "classify $id"
		printf '%s\nSandbox\nExample Co\n' "$id" >"$FAKE_DIR/auth-prod"
		mode noresp
		sh -c '"$1" suitecloud project:deploy' sh "$core" >"$root/out" 2>&1
		st=$?
		if [ "${c#*:}" = nonprod ]; then
			expect_ran "$id is non-production" project:deploy
			expect_no_tern "$id is non-production"
		else
			expect_status 1 "$id is production"
			expect_tern "$id is production"
			expect_not_run "$id is production"
		fi
	done
}

# The PATH shim, independent of any activation file.
shim_cases() {
	fresh "shim skips itself on PATH"
	PATH=$shim_dir:$BASE_PATH
	sh -c 'suitecloud project:validate --server' >"$root/out" 2>&1
	st=$?
	expect_status 0 "through the shim"
	expect_ran "the shim ran the real CLI, not itself" project:validate --server

	fresh "shim guards child processes (npm/bun scripts)"
	PATH=$shim_dir:$BASE_PATH
	mode noresp
	sh -c 'exec suitecloud project:deploy' >"$root/out" 2>&1
	st=$?
	expect_status 1 "child deploy denied"
	expect_tern "child deploy was guarded"
	expect_not_run "child deploy"
	expect_no_out 'command suitecloud' "shim mode does not suggest a bypass that reaches the shim"
	expect_out "call the CLI directly: $root/fakebin/suitecloud" "shim mode names the real CLI as the bypass"

	fresh "shim approval runs the real CLI with the exact argv"
	PATH=$shim_dir:$BASE_PATH
	sh -c 'exec suitecloud project:deploy --log "a b"' >"$root/out" 2>&1
	st=$?
	expect_status 0 "child deploy approved"
	expect_ran "child deploy approved" project:deploy --log "a b"

	fresh "a copied shim is skipped too"
	mkdir -p "$root/shimcopy"
	cp "$shim_dir/suitecloud" "$root/shimcopy/suitecloud"
	ln -s "$core" "$root/tern-netsuite-guard"
	PATH=$root/shimcopy:$BASE_PATH
	sh -c 'exec suitecloud project:validate' >"$root/out" 2>&1
	st=$?
	expect_status 0 "copied shim"
	expect_ran "copied shim" project:validate
	rm -f "$root/tern-netsuite-guard"

	fresh "shim without a real CLI"
	PATH=$shim_dir:$root/shellbin:/usr/bin:/bin:/usr/sbin:/sbin
	sh -c 'exec suitecloud project:validate' >"$root/out" 2>&1
	st=$?
	expect_status 127 "no real CLI behind the shim"
	expect_out 'not on PATH' "no real CLI message"
}

# Behaviour of the zsh/bash/fish activation files.
snippet_cases() {
	sh=$1
	case $sh in
	zsh | bash) src='source "$TNS_SNIP"' ;;
	fish) src='source $TNS_SNIP' ;;
	esac
	case $sh in
	fish)
		last_status='echo source-status=$status'
		child_status='echo child-status=$status'
		shim_on='set -g TERN_NETSUITE_GUARD shim'
		first_path='echo first=$PATH[1]'
		;;
	*)
		last_status='echo source-status=$?'
		child_status='echo child-status=$?'
		shim_on='TERN_NETSUITE_GUARD=shim'
		first_path='echo "first=${PATH%%:*}"'
		;;
	esac

	fresh "$sh existing suitecloud function is preserved"
	case $sh in
	fish) pre='function suitecloud; echo user-function $argv; end' ;;
	*) pre='suitecloud() { echo user-function "$@"; }' ;;
	esac
	run_code "$sh" "$pre
$src
$last_status
suitecloud project:deploy"
	expect_out 'not installed' "conflict message"
	expect_out 'user-function project:deploy' "user function still runs"
	expect_out 'source-status=1' "source reports the conflict"
	expect_not_run "conflict"

	fresh "$sh re-sourcing is not a conflict"
	run_code "$sh" "$src
$src
tern-netsuite-guard-status"
	expect_no_out 'not installed' "re-source"
	expect_out "suitecloud function: tern-netsuite guard \\($sh\\)" "status after re-source"
	expect_out 'guarded commands: project:deploy file:upload' "status lists the guarded commands"
	expect_out 'ask for approval' "status in a Tern pane"

	fresh "$sh typed command is guarded"
	mode deny
	run_s "$sh" project:deploy
	expect_status 1 "typed deploy denied"
	expect_tern "typed deploy"
	expect_not_run "typed deploy"

	fresh "$sh command suitecloud bypass"
	case $sh in
	fish) run_code "$sh" "$src; command suitecloud \$argv" project:deploy ;;
	*) run_code "$sh" "$src; command suitecloud \"\$@\"" project:deploy ;;
	esac
	expect_status 0 "command suitecloud"
	expect_ran "command suitecloud runs immediately" project:deploy
	expect_no_tern "command suitecloud"

	fresh "$sh guard core missing"
	rm -rf "$root/copy"
	cp -R "$repo/shell" "$root/copy"
	rm "$root/copy/tern-netsuite-guard"
	case $sh in
	fish) run_code "$sh" "source $root/copy/tern-netsuite.fish; suitecloud \$argv" project:validate ;;
	*) run_code "$sh" "source '$root/copy/tern-netsuite.$sh'; suitecloud \"\$@\"" project:validate ;;
	esac
	expect_status 127 "core missing"
	expect_out 'is missing, so suitecloud was not run' "core missing message"
	expect_not_run "core missing"

	fresh "$sh shim mode guards child processes"
	mode deny
	run_code "$sh" "$shim_on
$src
$first_path
tern-netsuite-guard-status
sh -c 'suitecloud project:deploy'
$child_status" project:deploy
	expect_out "^first=$shim_dir\$" "shim directory first on PATH"
	expect_out 'mode: PATH shim' "status shows shim mode"
	expect_out '^child-status=1$' "child deploy denied"
	expect_tern "child deploy guarded"
	expect_not_run "child deploy"

	fresh "$sh shim mode is not added twice"
	run_code "$sh" "$shim_on
$src
$src
sh -c 'printf %s \"\$PATH\"' | tr ':' '\\n' | grep -c '^$shim_dir\$'"
	expect_out '^1$' "one shim entry"

	fresh "$sh uninstall"
	case $sh in
	zsh) post='whence -w suitecloud; echo "path=$PATH"' ;;
	bash) post='type -t suitecloud; echo "path=$PATH"' ;;
	fish) post='type -t suitecloud; echo "path=$PATH"' ;;
	esac
	run_code "$sh" "$shim_on
$src
tern-netsuite-guard-uninstall
$post"
	expect_out 'tern-netsuite guard removed' "uninstall message"
	expect_out '(^suitecloud: command$|^file$)' "suitecloud is the plain command again"
	expect_no_out "path=.*$shim_dir" "shim directory removed from PATH"
}

for sh in $shells; do
	TNS_SNIP=$repo/shell/tern-netsuite.$sh
	TNS_CORE=$core
	export TNS_SNIP TNS_CORE
	core_cases "$sh"
	[ "$sh" = dash ] || snippet_cases "$sh"
done
shim_cases
classify_cases
for want in zsh bash fish; do
	case " $shells " in
	*" $want "*) ;;
	*)
		case_name=$want
		skip "$want is not installed"
		;;
	esac
done

case_name="pass-through overhead"
fresh "$case_name"
unset TERM_PROGRAM
n=40
t_direct=$(bash -c 'TIMEFORMAT=%R; time (for i in $(seq '$n'); do suitecloud project:validate; done)' 2>&1 >/dev/null)
t_guard=$(bash -c 'TIMEFORMAT=%R; time (for i in $(seq '$n'); do "$1" suitecloud project:validate --server; done)' bash "$core" 2>&1 >/dev/null)
over=$(awk -v d="$t_direct" -v g="$t_guard" -v n="$n" 'BEGIN { printf "%.1f", (g - d) * 1000 / n }')
printf 'pass-through overhead: %s ms per call (guard %ss vs direct %ss for %d calls)\n' "$over" "$t_guard" "$t_direct" "$n"
if awk -v o="$over" 'BEGIN { exit !(o < 40) }'; then ok; else bad "pass-through overhead ${over}ms per call exceeds 40ms"; fi

printf '%d passed, %d failed, %d skipped\n' "$pass" "$failed" "$skipped"
[ "$failed" = 0 ]
