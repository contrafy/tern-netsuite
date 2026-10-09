#!/bin/sh
# Tests for scripts/tern-netsuite-wrappers. Every case uses a temporary config
# and plugin dir; nothing reads the real config, plugin dir or tern.
#
#   sh tests/shell/wrappers/run.sh

set -u

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/../../.." && pwd)
tool=$repo/scripts/tern-netsuite-wrappers
real_manifest=$repo/plugin.toml

root=$(mktemp -d "${TMPDIR:-/tmp}/tns-wrappers-test.XXXXXX") || exit 2
trap 'rm -rf "$root"' EXIT

HOME=$root/home
mkdir -p "$HOME"
export HOME
unset XDG_CONFIG_HOME TNS_WRAPPERS_JSON
TERN_BIN=$root/no-such-tern
export TERN_BIN

pass=0
failed=0
skipped=0

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

run() {
	"$tool" "$@" >"$root/out" 2>&1
	st=$?
}

expect_status() {
	if [ "$st" = "$1" ]; then ok; else bad "$2: exit $st, want $1"; fi
}

expect_out() {
	if grep -E -q -- "$1" "$root/out"; then ok; else bad "$2: output lacks /$1/"; fi
}

expect_same() {
	if cmp -s "$1" "$2"; then ok; else bad "$3: $1 differs from $2"; fi
}

# The lens block proposed for plugin.toml (the real manifest is checked below).
write_manifest() {
	cat >"$1" <<'EOF'
schema = 1
id = "tern-netsuite"
host = "plugin/host.luau"

[[lenses]]
id = "other"
match = [
	"other",
]

[[lenses]]
id = "suitecloud"
match = [
	"suitecloud project:validate",
	"suitecloud project:validate *",
	"suitecloud account:manageauth *",
	# BEGIN tern-netsuite wrappers
	# END tern-netsuite wrappers
]

[[blocks]]
id = "doctor"
EOF
}

fresh() {
	rm -rf "$root/plugin"
	mkdir -p "$root/plugin"
	P=$root/plugin
	M=$P/plugin.toml
	write_manifest "$M"
	cp "$M" "$root/pristine.toml"
}

config() { # JSON
	mkdir -p "$HOME/.config/tern-netsuite"
	printf '%s\n' "$1" >"$HOME/.config/tern-netsuite/config.json"
}

block() {
	awk '/# END tern-netsuite wrappers/ { b = 0 } b { print } /# BEGIN tern-netsuite wrappers/ { b = 1 }' "$1"
}

TWO='{"lens":{"wrappers":[{"prefix":"npm run validate","command":"project:validate"},{"prefix":"./scripts/sdf.sh   deploy","command":"project:deploy"},{"prefix":"npm run validate","command":"project:validate"},{"command":"project:deploy"}]}}'
WANT='	"./scripts/sdf.sh deploy",
	"./scripts/sdf.sh deploy *",
	"npm run validate",
	"npm run validate *",'

case_name=help
run --help
expect_status 0 "--help"
expect_out 'tern plugin reload' "help mentions reload"

case_name=sync
fresh
config "$TWO"
run --plugin-dir "$P"
expect_status 0 "sync"
expect_out 'updated' "update note"
if [ "$(block "$M")" = "$WANT" ]; then ok; else bad "block is '$(block "$M")'"; fi
if [ "$(grep -v -F -x -e '	"./scripts/sdf.sh deploy",' -e '	"./scripts/sdf.sh deploy *",' -e '	"npm run validate",' -e '	"npm run validate *",' "$M")" = "$(cat "$root/pristine.toml")" ]; then ok; else bad "lines outside the block changed"; fi
cp "$M" "$root/after.toml"
run --plugin-dir "$P"
expect_status 0 "second sync"
expect_out 'claims every wrapper prefix \(2\)' "idempotent note"
expect_same "$M" "$root/after.toml" "sync is not idempotent"

case_name=check
run --check --plugin-dir "$P"
expect_status 0 "check in sync"
config '{"lens":{"wrappers":[{"prefix":"make validate","command":"project:validate"}]}}'
run --check --plugin-dir "$P"
expect_status 1 "check out of sync"
expect_same "$M" "$root/after.toml" "check modified the manifest"
run --plugin-dir "$P"
expect_status 0 "resync"
if [ "$(block "$M")" = "$(printf '\t"make validate",\n\t"make validate *",')" ]; then ok; else bad "removed prefixes kept their claims"; fi

case_name=empty
config '{"lens":{"wrappers":[]}}'
run --plugin-dir "$P"
expect_status 0 "no wrappers"
expect_same "$M" "$root/pristine.toml" "emptying did not restore the manifest"
rm -f "$HOME/.config/tern-netsuite/config.json"
run --plugin-dir "$P"
expect_status 0 "no config"
expect_out 'no config' "no-config note"

case_name="explicit config"
printf '%s\n' "$TWO" >"$root/other.json"
run --config "$root/other.json" --plugin-dir "$P"
expect_status 0 "--config"
if [ "$(block "$M")" = "$WANT" ]; then ok; else bad "--config ignored"; fi
fresh
mkdir -p "$root/xdg/tern-netsuite"
printf '%s\n' "$TWO" >"$root/xdg/tern-netsuite/config.json"
XDG_CONFIG_HOME=$root/xdg "$tool" --plugin-dir "$P" >"$root/out" 2>&1
st=$?
expect_status 0 "XDG_CONFIG_HOME"
if [ "$(block "$M")" = "$WANT" ]; then ok; else bad "XDG_CONFIG_HOME ignored"; fi

case_name="bad prefixes"
for p in 'bun run *' 'make sdf[1]' 'a?b' 'say \"hi\"' 'back\\\\slash'; do
	fresh
	config "{\"lens\":{\"wrappers\":[{\"prefix\":\"$p\",\"command\":\"project:validate\"}]}}"
	run --plugin-dir "$P"
	expect_status 2 "prefix '$p'"
	expect_same "$M" "$root/pristine.toml" "prefix '$p' modified the manifest"
done
fresh
config '{"lens":'
run --plugin-dir "$P"
expect_status 2 "invalid JSON"
expect_same "$M" "$root/pristine.toml" "invalid JSON modified the manifest"

case_name=markers
config "$TWO"
fresh
grep -v 'tern-netsuite wrappers$' "$M" >"$M.new" && mv "$M.new" "$M"
cp "$M" "$root/nomark.toml"
run --plugin-dir "$P"
expect_status 2 "no markers"
expect_out 'refusing to edit' "no-markers message"
expect_same "$M" "$root/nomark.toml" "marker-less manifest modified"
fresh
printf '\t# END tern-netsuite wrappers\n' >>"$M"
run --plugin-dir "$P"
expect_status 2 "duplicate END"
fresh
awk '/# BEGIN tern-netsuite wrappers/ { next } { print } /^id = "other"/ { print "# BEGIN tern-netsuite wrappers" }' "$root/pristine.toml" >"$M"
run --plugin-dir "$P"
expect_status 2 "BEGIN outside lens suitecloud"
run --check --plugin-dir "$P"
expect_status 2 "check with bad markers"

case_name=readers
for reader in jq plutil python3; do
	if ! command -v "$reader" >/dev/null 2>&1; then
		skipped=$((skipped + 1))
		printf 'SKIP reader %s: not installed\n' "$reader"
		continue
	fi
	fresh
	config "$TWO"
	TNS_WRAPPERS_JSON=$reader "$tool" --plugin-dir "$P" >"$root/out" 2>&1
	st=$?
	expect_status 0 "reader $reader"
	if [ "$(block "$M")" = "$WANT" ]; then ok; else bad "reader $reader wrote '$(block "$M")'"; fi
done
TNS_WRAPPERS_JSON=awk "$tool" --plugin-dir "$P" >"$root/out" 2>&1
st=$?
expect_status 2 "unknown reader"

case_name="plugin dir resolution"
cat >"$root/tern" <<EOF
#!/bin/sh
[ "\$*" = "plugin dir" ] || { echo "fake tern: unexpected \$*" >&2; exit 9; }
echo "$root/plugins"
EOF
chmod +x "$root/tern"
TERN_BIN=$root/tern
mkdir -p "$root/plugins/tern-netsuite"
write_manifest "$root/plugins/tern-netsuite/plugin.toml"
run
expect_status 0 "installed plugin"
if [ "$(block "$root/plugins/tern-netsuite/plugin.toml")" = "$WANT" ]; then ok; else bad "installed manifest not edited"; fi
fresh
printf '%s\n' "$P" >"$root/plugins/tern-netsuite.path"
run
expect_status 0 "linked plugin"
expect_out 'linked' "linked note"
if [ "$(block "$M")" = "$WANT" ]; then ok; else bad "linked manifest not edited"; fi
rm -rf "$root/plugins"
mkdir -p "$root/plugins"
run
expect_status 2 "not installed"
expect_out 'not installed' "not-installed message"
TERN_BIN=$root/no-such-tern
run
expect_status 2 "no tern"

case_name="shipped manifest"
if grep -q '^id = "suitecloud"$' "$real_manifest"; then
	if [ "$(grep -c '^	# BEGIN tern-netsuite wrappers$' "$real_manifest")" = 1 ] &&
		[ "$(grep -c '^	# END tern-netsuite wrappers$' "$real_manifest")" = 1 ]; then ok; else bad "plugin.toml lacks the marker block"; fi
	if [ -z "$(block "$real_manifest")" ]; then ok; else bad "plugin.toml wrapper block is not empty"; fi
	cp "$real_manifest" "$root/shipped.toml"
	mkdir -p "$root/shipped"
	cp "$real_manifest" "$root/shipped/plugin.toml"
	config "$TWO"
	run --plugin-dir "$root/shipped"
	expect_status 0 "sync the shipped manifest"
else
	skipped=$((skipped + 1))
	echo "SKIP shipped manifest: plugin.toml declares no suitecloud lens yet"
fi

printf '%d passed, %d failed, %d skipped\n' "$pass" "$failed" "$skipped"
[ "$failed" = 0 ]
