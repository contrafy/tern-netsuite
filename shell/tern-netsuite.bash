# tern-netsuite shell guard for bash (opt-in). Add to ~/.bashrc:
#   source /path/to/tern-netsuite/shell/tern-netsuite.bash
# Function mode (default): defines `suitecloud`, so commands typed in this
# shell go through the guard. PATH shim mode guards child processes too
# (npm/bun scripts and other wrappers calling suitecloud):
#   TERN_NETSUITE_GUARD=shim
#   source /path/to/tern-netsuite/shell/tern-netsuite.bash
# Also defines `tern-netsuite-guard-status` and `tern-netsuite-guard-uninstall`.
# See shell/README.md.

_tern_netsuite_guard_dir=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
_tern_netsuite_guard_core=$_tern_netsuite_guard_dir/tern-netsuite-guard

# PATH without the shim directory.
_tern_netsuite_path_without_shim() {
	local out= p
	local -a parts
	IFS=: read -r -a parts <<<"$PATH"
	for p in "${parts[@]}"; do
		[[ $p == "$_tern_netsuite_guard_dir/bin" ]] || out=${out:+$out:}$p
	done
	printf '%s' "$out"
}

if [[ ${TERN_NETSUITE_GUARD-} == shim ]]; then
	[[ $(declare -f suitecloud 2>/dev/null) == *_tern_netsuite_guard_core* ]] && unset -f suitecloud
	if alias suitecloud >/dev/null 2>&1 || declare -F suitecloud >/dev/null; then
		printf 'tern-netsuite guard: warning: suitecloud is a shell %s in this shell, so commands typed here bypass the PATH shim (child processes are still guarded).\n' "$(type -t suitecloud)" >&2
	fi
	PATH=$_tern_netsuite_guard_dir/bin:$(_tern_netsuite_path_without_shim)
	export PATH
	_tern_netsuite_guard_mode=shim
else
	if [[ -z ${_tern_netsuite_guard_installed-} ]] && { alias suitecloud >/dev/null 2>&1 || declare -F suitecloud >/dev/null; }; then
		printf 'tern-netsuite guard: not installed: suitecloud is already defined as %s in this shell.\n' "$(type -t suitecloud)" >&2
		printf 'tern-netsuite guard: your definition was left untouched. To use the guard, remove it before sourcing %s, or use TERN_NETSUITE_GUARD=shim.\n' "${BASH_SOURCE[0]}" >&2
		unset -f _tern_netsuite_path_without_shim
		unset _tern_netsuite_guard_dir _tern_netsuite_guard_core
		return 1
	fi
	PATH=$(_tern_netsuite_path_without_shim)
	export PATH
	suitecloud() {
		if [[ ! -x $_tern_netsuite_guard_core ]]; then
			printf 'tern-netsuite guard: the guard core %s is missing, so suitecloud was not run.\n' "$_tern_netsuite_guard_core" >&2
			printf 'tern-netsuite guard: restore it, run tern-netsuite-guard-uninstall, or bypass the guard (no confirmation) with: command suitecloud ...\n' >&2
			return 127
		fi
		"$_tern_netsuite_guard_core" suitecloud "$@"
	}
	_tern_netsuite_guard_mode=function
fi
_tern_netsuite_guard_installed=1

tern-netsuite-guard-status() {
	if [[ $_tern_netsuite_guard_mode == shim ]]; then
		echo "mode: PATH shim ($_tern_netsuite_guard_dir/bin)"
		echo "suitecloud resolves to: $(type -t suitecloud) $(type -P suitecloud)"
	elif [[ $(declare -f suitecloud 2>/dev/null) == *_tern_netsuite_guard_core* ]]; then
		echo "mode: shell function"
		echo "suitecloud function: tern-netsuite guard (bash)"
	else
		echo "mode: shell function"
		echo "suitecloud function: not the tern-netsuite guard ($(type -t suitecloud))"
	fi
	if [[ -x $_tern_netsuite_guard_core ]]; then
		"$_tern_netsuite_guard_core" status
	else
		echo "tern-netsuite guard core: MISSING at $_tern_netsuite_guard_core (suitecloud is refused)"
		return 1
	fi
}

tern-netsuite-guard-uninstall() {
	[[ $(declare -f suitecloud 2>/dev/null) == *_tern_netsuite_guard_core* ]] && unset -f suitecloud
	PATH=$(_tern_netsuite_path_without_shim)
	export PATH
	unset -f _tern_netsuite_path_without_shim tern-netsuite-guard-status tern-netsuite-guard-uninstall
	unset _tern_netsuite_guard_dir _tern_netsuite_guard_core _tern_netsuite_guard_installed _tern_netsuite_guard_mode
	echo "tern-netsuite guard removed from this shell; also delete the 'source .../tern-netsuite.bash' line from your ~/.bashrc."
}
