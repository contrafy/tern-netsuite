# tern-netsuite shell guard for zsh (opt-in). Add to ~/.zshrc:
#   source /path/to/tern-netsuite/shell/tern-netsuite.zsh
# Function mode (default): defines `suitecloud`, so commands typed in this
# shell go through the guard. PATH shim mode guards child processes too
# (npm/bun scripts and other wrappers calling suitecloud):
#   TERN_NETSUITE_GUARD=shim
#   source /path/to/tern-netsuite/shell/tern-netsuite.zsh
# Also defines `tern-netsuite-guard-status` and `tern-netsuite-guard-uninstall`.
# See shell/README.md.

typeset -g _tern_netsuite_guard_dir=${${(%):-%x}:A:h}
typeset -g _tern_netsuite_guard_core=$_tern_netsuite_guard_dir/tern-netsuite-guard

if [[ ${TERN_NETSUITE_GUARD-} == shim ]]; then
	[[ ${functions[suitecloud]-} == *_tern_netsuite_guard_core* ]] && unfunction suitecloud
	if (( ${+aliases[suitecloud]} )) || (( ${+functions[suitecloud]} )); then
		print -u2 -r -- "tern-netsuite guard: warning: suitecloud is $(whence -w suitecloud | sed 's/^suitecloud: //') in this shell, so commands typed here bypass the PATH shim (child processes are still guarded)."
	fi
	path=("$_tern_netsuite_guard_dir/bin" ${path:#${(b)_tern_netsuite_guard_dir}/bin})
	export PATH
	typeset -g _tern_netsuite_guard_mode=shim
else
	if (( ! ${+_tern_netsuite_guard_installed} )) && { (( ${+aliases[suitecloud]} )) || (( ${+functions[suitecloud]} )); }; then
		print -u2 -r -- "tern-netsuite guard: not installed: suitecloud is already defined as $(whence -w suitecloud | sed 's/^suitecloud: //') in this shell."
		print -u2 -r -- "tern-netsuite guard: your definition was left untouched. To use the guard, remove it before sourcing $(print -r -- ${(%):-%x}), or use TERN_NETSUITE_GUARD=shim."
		return 1
	fi
	path=(${path:#${(b)_tern_netsuite_guard_dir}/bin})
	export PATH
	suitecloud() {
		if [[ ! -x $_tern_netsuite_guard_core ]]; then
			print -u2 -r -- "tern-netsuite guard: the guard core $_tern_netsuite_guard_core is missing, so suitecloud was not run."
			print -u2 -r -- "tern-netsuite guard: restore it, run tern-netsuite-guard-uninstall, or bypass the guard (no confirmation) with: command suitecloud ..."
			return 127
		fi
		"$_tern_netsuite_guard_core" suitecloud "$@"
	}
	typeset -g _tern_netsuite_guard_mode=function
fi
typeset -g _tern_netsuite_guard_installed=1

tern-netsuite-guard-status() {
	if [[ $_tern_netsuite_guard_mode == shim ]]; then
		print -r -- "mode: PATH shim ($_tern_netsuite_guard_dir/bin)"
		print -r -- "suitecloud resolves to: $(whence -w suitecloud | sed 's/^suitecloud: //') $(whence -p suitecloud)"
	elif [[ ${functions[suitecloud]-} == *_tern_netsuite_guard_core* ]]; then
		print -r -- "mode: shell function"
		print -r -- "suitecloud function: tern-netsuite guard (zsh)"
	else
		print -r -- "mode: shell function"
		print -r -- "suitecloud function: not the tern-netsuite guard ($(whence -w suitecloud))"
	fi
	if [[ -x $_tern_netsuite_guard_core ]]; then
		"$_tern_netsuite_guard_core" status
	else
		print -r -- "tern-netsuite guard core: MISSING at $_tern_netsuite_guard_core (suitecloud is refused)"
		return 1
	fi
}

tern-netsuite-guard-uninstall() {
	[[ ${functions[suitecloud]-} == *_tern_netsuite_guard_core* ]] && unfunction suitecloud
	path=(${path:#${(b)_tern_netsuite_guard_dir}/bin})
	export PATH
	unfunction tern-netsuite-guard-status tern-netsuite-guard-uninstall
	unset _tern_netsuite_guard_dir _tern_netsuite_guard_core _tern_netsuite_guard_installed _tern_netsuite_guard_mode
	print -r -- "tern-netsuite guard removed from this shell; also delete the 'source .../tern-netsuite.zsh' line from your ~/.zshrc."
}
