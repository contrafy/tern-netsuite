#!/bin/sh
# Tests for the machine-wide SuiteCloud CLI slot (plugin/lib/sdf/cli_slot.luau):
# real processes take, wait for and recover the lock directory. Every case
# uses a temporary directory; nothing touches the plugin's data directory.
#
#   sh tests/shell/cli-slot/run.sh

set -u

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
here=$repo/tests/shell/cli-slot
luau=${LUAU:-$repo/.tools/bin/luau}
case $luau in
/*) ;;
*) luau=$PWD/$luau ;;
esac

root=$(mktemp -d "${TMPDIR:-/tmp}/tns-cli-slot-test.XXXXXX") || exit 2
trap 'rm -rf "$root"' EXIT
root=$(cd "$root" && pwd)

script=$(cd "$here" && "$luau" slot.luau -a script) || {
	echo "could not generate the slot script" >&2
	exit 2
}

pass=0
failed=0
case_name=

ok() {
	pass=$((pass + 1))
}

bad() {
	failed=$((failed + 1))
	printf 'FAIL [%s] %s\n' "$case_name" "$*"
	for f in "$root/log" "$root/err"; do
		if [ -s "$f" ]; then
			sed 's/^/    | /' "$f"
		fi
	done
}

# slot LOCK WAIT LABEL CMD...: CMD inside the slot. Background holders call
# `sh -c "$script"` directly so that $! is the slot's own pid.
slot() {
	sh -c "$script" tern-netsuite-cli "$@"
}

reset() {
	case_name=$1
	rm -rf "$root/locks" "$root/log" "$root/err"
	: >"$root/log"
	lock=$root/locks/auth-demo-sb
}

# --------------------------------------------------------------------------
reset "two account commands for one auth ID never overlap"
slot "$lock" 30 object:list sh -c "echo start-a >>'$root/log'; sleep 2; echo end-a >>'$root/log'" 2>"$root/err" &
a=$!
sleep 0.5
slot "$lock" 30 file:list sh -c "echo start-b >>'$root/log'; echo end-b >>'$root/log'" 2>>"$root/err"
wait "$a"
if [ "$(tr '\n' ' ' <"$root/log")" = "start-a end-a start-b end-b " ]; then ok; else bad "runs overlapped"; fi

# --------------------------------------------------------------------------
reset "commands for different auth IDs run side by side"
slot "$root/locks/auth-a" 30 object:list sh -c "echo start-a >>'$root/log'; sleep 2; echo end-a >>'$root/log'" &
a=$!
sleep 0.5
slot "$root/locks/auth-b" 30 object:list sh -c "echo start-b >>'$root/log'; echo end-b >>'$root/log'"
wait "$a"
if [ "$(tr '\n' ' ' <"$root/log")" = "start-a start-b end-b end-a " ]; then ok; else bad "different auth IDs were serialized"; fi

# --------------------------------------------------------------------------
reset "a lock left by a process that died (crash, kill, reload) is taken over"
mkdir -p "$lock"
sh -c 'exit 0' &
dead=$!
wait "$dead"
printf '%s|%s|object:list|/w' "$dead" "Mon Jan  1 00:00:00 2024" >"$lock/owner"
start=$(date +%s)
slot "$lock" 10 file:list sh -c "echo ran >>'$root/log'" 2>"$root/err"
st=$?
if [ "$st" = 0 ] && grep -q ran "$root/log"; then ok; else bad "exit $st, the command did not run"; fi
if [ $(($(date +%s) - start)) -le 3 ]; then ok; else bad "took over the stale lock only after waiting"; fi

# --------------------------------------------------------------------------
reset "a lock whose pid was reused by another process is taken over"
mkdir -p "$lock"
printf '%s|%s|object:list|/w' "$$" "Mon Jan  1 00:00:00 2024" >"$lock/owner"
slot "$lock" 10 file:list sh -c "echo ran >>'$root/log'" 2>"$root/err"
if grep -q ran "$root/log"; then ok; else bad "a live pid with another start time kept the slot"; fi

# --------------------------------------------------------------------------
reset "a holder killed with SIGKILL (no traps run) frees the slot"
sh -c "$script" tern-netsuite-cli "$lock" 30 object:list sleep 30 &
holder=$!
sleep 0.5
kill -9 "$holder"
wait "$holder" 2>/dev/null
slot "$lock" 10 file:list sh -c "echo ran >>'$root/log'" 2>"$root/err"
if grep -q ran "$root/log"; then ok; else bad "the killed holder's lock was never recovered"; fi

# --------------------------------------------------------------------------
reset "the lock's owner is the command itself, so a kill on timeout ends the holder"
sh -c "$script" tern-netsuite-cli "$lock" 30 object:list sleep 30 &
holder=$!
sleep 0.5
IFS='|' read -r pid _ what dir <"$lock/owner"
if [ "$pid" = "$holder" ]; then ok; else bad "owner pid $pid, command pid $holder"; fi
if [ "$what" = "object:list" ] && [ -n "$dir" ]; then ok; else bad "owner names '$what' in '$dir'"; fi
kill "$holder"
wait "$holder" 2>/dev/null

# --------------------------------------------------------------------------
reset "a bounded wait gives up with status 75 and says what holds the slot"
sh -c "$script" tern-netsuite-cli "$lock" 30 object:list sleep 5 &
holder=$!
sleep 0.5
slot "$lock" 1 file:list sh -c "echo ran >>'$root/log'" 2>"$root/err"
st=$?
if [ "$st" = 75 ]; then ok; else bad "exit $st, want 75"; fi
if [ ! -s "$root/log" ]; then ok; else bad "the command ran although the slot was taken"; fi
if grep -q "object:list (pid $holder) still holds this auth ID" "$root/err"; then ok; else bad "no reason on stderr"; fi
kill "$holder"
wait "$holder" 2>/dev/null

# --------------------------------------------------------------------------
reset "a pane waits until the slot frees and says once what it waits for"
sh -c "$script" tern-netsuite-cli "$lock" 30 object:list sleep 2 &
holder=$!
sleep 0.5
slot "$lock" 0 file:upload sh -c "echo ran >>'$root/log'" 2>"$root/err"
st=$?
wait "$holder" 2>/dev/null
if [ "$st" = 0 ] && grep -q ran "$root/log"; then ok; else bad "exit $st, the waiting command did not run"; fi
if [ "$(grep -c 'waiting for object:list' "$root/err")" = 1 ]; then ok; else bad "want one waiting line"; fi

# --------------------------------------------------------------------------
reset "a lock directory without an owner (taker died before writing it) is recovered"
mkdir -p "$lock"
slot "$lock" 30 file:list sh -c "echo ran >>'$root/log'" 2>"$root/err"
if grep -q ran "$root/log"; then ok; else bad "an ownerless lock was never recovered"; fi

# --------------------------------------------------------------------------
reset "the command gets its arguments and exit status unchanged"
slot "$lock" 10 object:list sh -c 'printf "%s|" "$@"; exit 7' x 'a b' '$HOME' '' >"$root/log" 2>"$root/err"
st=$?
if [ "$st" = 7 ]; then ok; else bad "exit $st, want 7"; fi
if [ "$(cat "$root/log")" = 'a b|$HOME||' ]; then ok; else bad "arguments changed"; fi

# --------------------------------------------------------------------------
# A pane line is typed through the user's shell: it must reach sh intact in
# POSIX shells and in fish, whose single quotes treat \' and \\ as escapes.
reset "a pane line passes every word intact through sh, bash, zsh and fish"
mkdir -p "$root/proj dir \$x;y"
cat >"$root/fake" <<'EOF'
#!/bin/sh
pwd >"$TNS_OUT"
printf '%s\n' "$@" >>"$TNS_OUT"
EOF
chmod +x "$root/fake"
line=$(cd "$here" && "$luau" slot.luau -a pane "$root/proj dir \$x;y" "$lock" "title it's \\ \"x\"" \
	"intro \$(touch $root/pwned) \\'" "$root/fake" file:upload --paths '/SuiteScripts/a b $c;&.js') || bad "pane line refused"
printf '%s\n' "$root/proj dir \$x;y" file:upload --paths '/SuiteScripts/a b $c;&.js' >"$root/want"
for shell in sh bash zsh fish; do
	if ! command -v "$shell" >/dev/null 2>&1; then
		echo "skip [$case_name] $shell is not installed"
		continue
	fi
	rm -f "$root/got" "$root/pwned"
	TNS_OUT=$root/got "$shell" -c "$line" </dev/null >"$root/log" 2>"$root/err"
	if cmp -s "$root/want" "$root/got"; then ok; else bad "$shell passed other words: $(cat "$root/got" 2>/dev/null)"; fi
	if [ ! -e "$root/pwned" ]; then ok; else bad "$shell ran text from the intro"; fi
	if grep -q "file:upload exited 0" "$root/log"; then ok; else bad "$shell: no exit line"; fi
done

# --------------------------------------------------------------------------
reset "a pane refuses words that cannot pass through a shell line"
for w in "/a\\b" "/a'b" '/a"b'; do
	if (cd "$here" && "$luau" slot.luau -a pane "$w" "$lock" t i "$root/fake" file:upload) >/dev/null 2>&1; then
		bad "accepted $w"
	else
		ok
	fi
done

# --------------------------------------------------------------------------
reset "a holder that exited but was not reaped yet (a zombie) frees the slot"
# perl forks the holder and does not wait for it while it sleeps.
perl -e 'my $p = fork(); if ($p == 0) { exec "sh", "-c", $ARGV[0], "tern-netsuite-cli", $ARGV[1], "30", "object:list", "true" } sleep 6' \
	"$script" "$lock" &
parent=$!
i=0
while [ $i -lt 50 ] && [ ! -s "$lock/owner" ]; do
	sleep 0.1
	i=$((i + 1))
done
sleep 0.5
start=$(date +%s)
slot "$lock" 10 file:list sh -c "echo ran >>'$root/log'" 2>"$root/err"
if grep -q ran "$root/log" && [ $(($(date +%s) - start)) -le 3 ]; then ok; else bad "a zombie holder kept the slot"; fi
kill "$parent" 2>/dev/null
wait "$parent" 2>/dev/null

# --------------------------------------------------------------------------
# A slot script that execs another taker of the same slot in the same
# process (the plugin's script running the guard through the PATH shim).
reset "a process that already owns the slot keeps it instead of waiting for itself"
slot "$lock" 3 object:import sh -c "$script" tern-netsuite-cli "$lock" 3 object:import sh -c "echo ran >>'$root/log'" 2>"$root/err"
st=$?
if [ "$st" = 0 ] && grep -q ran "$root/log"; then ok; else bad "exit $st: the same process waited for itself"; fi

# --------------------------------------------------------------------------
# The guard (shell/tern-netsuite-guard) takes the same locks for commands
# typed in a shell; both sides must agree on the code and the names.
guard=$repo/shell/tern-netsuite-guard
reset "the guard's copy of the acquire step is the plugin's"
want=$(cd "$here" && "$luau" slot.luau -a acquire)
got=$(sed -n "s/^tng_slot_acquire='\\(.*\\)'\$/\\1/p" "$guard")
if [ -n "$want" ] && [ "$want" = "$got" ]; then ok; else bad "shell/tern-netsuite-guard tng_slot_acquire differs from CliSlot.ACQUIRE"; fi

reset "the guard names the same lock directory as the plugin for every auth ID"
mkdir -p "$root/proj"
long=a0123456789012345678901234567890123456789012345678901234567890123456789
for id in demo-sb demo_prod.v2 .hidden -dash "$long" none; do
	if [ "$id" = none ]; then
		rm -f "$root/proj/project.json"
		want=$(cd "$here" && "$luau" slot.luau -a lock "$root/data")
	else
		printf '{\n  "defaultAuthId": "%s"\n}\n' "$id" >"$root/proj/project.json"
		want=$(cd "$here" && "$luau" slot.luau -a lock "$root/data" "$id")
	fi
	got=$(cd "$root/proj" && TNS_CLI_SLOTS=$root/data/cli-slots sh "$guard" status 2>/dev/null |
		sed -n 's/^CLI slot: account commands typed here wait in //p')
	if [ "$got" = "$want" ]; then ok; else bad "auth ID $id: guard '$got', plugin '$want'"; fi
done

echo "cli-slot: $pass passed, $failed failed"
[ "$failed" = 0 ]
