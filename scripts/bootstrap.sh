#!/bin/sh
# Installs pinned dev tools into .tools/ (repo-local, nothing global).
# Supported hosts: macOS arm64, Linux x86_64. Re-running is cheap: tools whose
# stamp matches the pinned version and checksum are skipped.
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
TOOLS="$ROOT/.tools"
BIN="$TOOLS/bin"
STAMPS="$TOOLS/stamps"
TYPES="$TOOLS/types"

LUAU_VERSION=0.741
LUAU_LSP_VERSION=1.70.1
STYLUA_VERSION=2.5.2
SELENE_VERSION=0.32.0
TERN_SDK_COMMIT=19658cb2a3205ce57c67ad8c5c1c54ed80fefa7e
TERN_TYPES_SHA256=84682931deee44134bdd38502f81be37fd14ac1697618985228f5cab7e25c51f

die() {
	printf 'bootstrap: %s\n' "$*" >&2
	exit 1
}

host="$(uname -s)-$(uname -m)"
case "$host" in
Darwin-arm64)
	LUAU_ASSET=luau-macos.zip
	LUAU_SHA256=839cc1de39b0f765fbaea8e89421c12acfed6bd3d8d2cc2a2d3fc64bdde32b0f
	LUAU_LSP_ASSET=luau-lsp-macos.zip
	LUAU_LSP_SHA256=7d3936e8dec6dc77547abd061d2e950da392562a5f94858b880f23dba50d84cd
	STYLUA_ASSET=stylua-macos-aarch64.zip
	STYLUA_SHA256=92ff0889e16324801bc072692974bb67f8161e62010fc90f96c62a17f81f32c7
	SELENE_ASSET=selene-$SELENE_VERSION-macos.zip
	SELENE_SHA256=d8aa4701530a81334836f9c5e3bf38b91f633d9ad88f4d15cf29f63fe8589dc0
	;;
Linux-x86_64)
	LUAU_ASSET=luau-ubuntu.zip
	LUAU_SHA256=134dc762ad26232af83e43f98dec03ff6030dd3a4452f9408b9d50ccea025503
	LUAU_LSP_ASSET=luau-lsp-linux-x86_64.zip
	LUAU_LSP_SHA256=1a2ea1ae4f98f8946cefd970a4b54853e11ab4775e6932faa7f60cf920346567
	STYLUA_ASSET=stylua-linux-x86_64.zip
	STYLUA_SHA256=bcb0d855e91f102f28a370e850f8566b3b44b79e6274d806ea5246837c0fd5ab
	SELENE_ASSET=selene-$SELENE_VERSION-linux.zip
	SELENE_SHA256=d3773393578580074386e69337d35b7acddfbaa9fc38964c07fa3e28436ade9b
	;;
*)
	die "unsupported host '$host' (supported: Darwin-arm64, Linux-x86_64)"
	;;
esac

for cmd in curl unzip tar uname; do
	command -v "$cmd" >/dev/null 2>&1 || die "missing required command: $cmd"
done

if command -v sha256sum >/dev/null 2>&1; then
	sha256() { sha256sum "$1" | cut -d ' ' -f 1; }
elif command -v shasum >/dev/null 2>&1; then
	sha256() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
else
	die "missing required command: sha256sum or shasum"
fi

mkdir -p "$BIN" "$STAMPS" "$TYPES"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/tern-netsuite-bootstrap.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM

fetch() {
	url=$1
	dest=$2
	want=$3
	curl -fsSL --retry 3 --retry-delay 2 -o "$dest" "$url" || die "download failed: $url"
	got=$(sha256 "$dest")
	[ "$got" = "$want" ] || die "checksum mismatch for $url: expected $want, got $got"
}

# install_tool NAME VERSION URL SHA256 BINARY... ; archive assets (zip,
# tar.gz, tar.bz2) install every listed archive member under its basename,
# raw assets are installed as the first BINARY.
install_tool() {
	name=$1
	version=$2
	url=$3
	want=$4
	shift 4
	stamp="$STAMPS/$name"
	expected_stamp="$version $want"
	if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$expected_stamp" ]; then
		missing=0
		for b in "$@"; do
			[ -x "$BIN/$(basename "$b")" ] || missing=1
		done
		if [ "$missing" = 0 ]; then
			printf 'bootstrap: %s %s already installed\n' "$name" "$version"
			return 0
		fi
	fi
	printf 'bootstrap: installing %s %s\n' "$name" "$version"
	dir="$WORK/$name"
	mkdir -p "$dir"
	asset="$dir/$(basename "$url")"
	fetch "$url" "$asset" "$want"
	case "$asset" in
	*.zip | *.tar.gz | *.tar.bz2)
		mkdir -p "$dir/out"
		case "$asset" in
		*.zip) unzip -q -o "$asset" -d "$dir/out" ;;
		*.tar.bz2) tar -xjf "$asset" -C "$dir/out" ;;
		*) tar -xzf "$asset" -C "$dir/out" ;;
		esac
		for b in "$@"; do
			[ -f "$dir/out/$b" ] || die "$b not found in $(basename "$url")"
			chmod 755 "$dir/out/$b"
			mv -f "$dir/out/$b" "$BIN/$(basename "$b")"
		done
		;;
	*)
		chmod 755 "$asset"
		mv -f "$asset" "$BIN/$1"
		;;
	esac
	printf '%s\n' "$expected_stamp" >"$stamp"
}

install_tool luau "$LUAU_VERSION" \
	"https://github.com/luau-lang/luau/releases/download/$LUAU_VERSION/$LUAU_ASSET" \
	"$LUAU_SHA256" luau luau-analyze luau-compile luau-ast
install_tool luau-lsp "$LUAU_LSP_VERSION" \
	"https://github.com/JohnnyMorganz/luau-lsp/releases/download/$LUAU_LSP_VERSION/$LUAU_LSP_ASSET" \
	"$LUAU_LSP_SHA256" luau-lsp
install_tool stylua "$STYLUA_VERSION" \
	"https://github.com/JohnnyMorganz/StyLua/releases/download/v$STYLUA_VERSION/$STYLUA_ASSET" \
	"$STYLUA_SHA256" stylua
install_tool selene "$SELENE_VERSION" \
	"https://github.com/Kampfkarren/selene/releases/download/$SELENE_VERSION/$SELENE_ASSET" \
	"$SELENE_SHA256" selene

types_file="$TYPES/tern.d.luau"
if [ -f "$types_file" ] && [ "$(sha256 "$types_file")" = "$TERN_TYPES_SHA256" ]; then
	printf 'bootstrap: tern.d.luau @ %s already installed\n' "$TERN_SDK_COMMIT"
else
	printf 'bootstrap: installing tern.d.luau @ %s\n' "$TERN_SDK_COMMIT"
	fetch "https://raw.githubusercontent.com/stencil-hq/tern-sdk/$TERN_SDK_COMMIT/plugins/tern.d.luau" \
		"$WORK/tern.d.luau" "$TERN_TYPES_SHA256"
	mv -f "$WORK/tern.d.luau" "$types_file"
fi

# Upstream tern.d.luau uses the `userdata` type (WindowCx:wait), which Luau
# does not define, so luau-lsp rejects the whole file. Typecheck with a copy
# that declares it as an opaque type; the pristine file stays untouched.
{
	printf 'declare extern type userdata with end\n'
	cat "$types_file"
} >"$TYPES/tern.lsp.d.luau"

# The luau CLI has no --version flag; running a script proves it executes.
printf 'return nil\n' >"$WORK/probe.luau"
"$BIN/luau" "$WORK/probe.luau" || die "luau failed to execute"
printf 'luau %s\n' "$LUAU_VERSION"
lsp_version=$("$BIN/luau-lsp" --version) || die "luau-lsp failed to execute"
printf 'luau-lsp %s\n' "$lsp_version"
"$BIN/stylua" --version || die "stylua failed to execute"
"$BIN/selene" --version || die "selene failed to execute"
