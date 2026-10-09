#!/bin/sh
# Loads the package in a real, isolated Tern (local only: Tern is closed beta
# and cannot be installed in CI). Starts a sandbox window (it appears on
# screen for a few seconds) with its own config dir and daemon socket under
# TNS_SANDBOX (default /tmp/tns-smoke), links this checkout, reloads, and
# requires the plugin to report `ready` with exactly the manifest's lenses
# and blocks. Never touches the user's Tern config, daemon or plugins.
# Skipped (exit 0) when `tern` is not installed.
set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
sb=${TNS_SANDBOX:-/tmp/tns-smoke}
tern_bin=${TERN_BIN:-tern}

case $sb in
/tmp/?*) ;;
*)
	echo "smoke-real: TNS_SANDBOX must be under /tmp" >&2
	exit 2
	;;
esac

if ! command -v "$tern_bin" >/dev/null 2>&1; then
	echo "smoke-real: skipped (tern not installed)"
	exit 0
fi

export TERN_CONFIG_DIR="$sb/cfg"
export TERN_DAEMON_SOCKET="$sb/d.sock"
export STENCIL_LOG_DIR="$sb/logs"
export STENCIL_LOG=warn
# Inherited from a surrounding Tern pane; they describe the user's Tern.
unset TERN_WINDOW_KEY TERN_WINDOW_SOCKET TERN_PANE TERN_PANE_SOCKET TERN_BLOB_DIR \
	TERN_COMPLETE TERN_IDENTITY TERN_LENSES TERM_PROGRAM TERM_PROGRAM_VERSION
ctl_sock="$sb/ctl.sock"

stop() {
	"$tern_bin" ctl --control "$ctl_sock" quit >/dev/null 2>&1 || true
}

rm -rf "$sb"
mkdir -p "$TERN_CONFIG_DIR" "$STENCIL_LOG_DIR"
trap stop EXIT INT TERM
nohup "$tern_bin" --control "$ctl_sock" /tmp >"$sb/window.out" 2>&1 &

i=0
until "$tern_bin" ctl --control "$ctl_sock" ready >/dev/null 2>&1; do
	i=$((i + 1))
	if [ "$i" -gt 60 ]; then
		echo "smoke-real: the sandbox window did not become ready (see $sb/window.out)" >&2
		exit 1
	fi
	sleep 0.5
done

"$tern_bin" plugin link "$repo" >/dev/null
if ! "$tern_bin" plugin reload; then
	echo "smoke-real: reload failed" >&2
	exit 1
fi

manifest_ids() { # $1 = table name
	awk -v want="[[$1]]" '
		/^\[\[/ { cur = $0; next }
		/^\[/ { cur = ""; next }
		cur == want && /^[ \t]*id[ \t]*=/ {
			v = $0; sub(/^[^=]*=[ \t]*"/, "", v); sub(/".*$/, "", v); print v
		}
	' "$repo/plugin.toml" | LC_ALL=C sort | paste -sd, -
}

"$tern_bin" plugin list --json >"$sb/list.json"
python3 - "$sb/list.json" "$(manifest_ids lenses)" "$(manifest_ids blocks)" <<'EOF'
import json, sys

doc = json.load(open(sys.argv[1]))
want_lenses = [x for x in sys.argv[2].split(",") if x]
want_blocks = [x for x in sys.argv[3].split(",") if x]
plugin = next((p for p in doc["plugins"] if p["id"] == "tern-netsuite"), None)
errors = []
if plugin is None:
    errors.append("tern-netsuite is not listed")
else:
    if plugin["status"] != "ready":
        errors.append(f"status: {plugin['status']}")
    if not plugin.get("host") or not plugin.get("window"):
        errors.append("a plugin half did not load")

    def ids(entries):
        return sorted(e["id"] if isinstance(e, dict) else str(e) for e in entries)

    if ids(plugin.get("lenses", [])) != want_lenses:
        errors.append(f"lenses {ids(plugin.get('lenses', []))} != manifest {want_lenses}")
    if ids(plugin.get("blocks", [])) != want_blocks:
        errors.append(f"blocks {ids(plugin.get('blocks', []))} != manifest {want_blocks}")
for p in doc.get("problems", []):
    errors.append(f"problem: {p}")
for e in errors:
    print(f"smoke-real: {e}", file=sys.stderr)
if errors:
    sys.exit(1)
print(f"smoke-real: ok (lenses {want_lenses}, blocks {want_blocks})")
EOF
