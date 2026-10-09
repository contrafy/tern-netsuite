# tern-netsuite shell guard for fish (opt-in). Add to ~/.config/fish/config.fish:
#   source /path/to/tern-netsuite/shell/tern-netsuite.fish
# Function mode (default): defines `suitecloud`, so commands typed in this
# shell go through the guard. PATH shim mode guards child processes too
# (npm/bun scripts and other wrappers calling suitecloud):
#   set -g TERN_NETSUITE_GUARD shim
#   source /path/to/tern-netsuite/shell/tern-netsuite.fish
# Also defines `tern-netsuite-guard-status` and `tern-netsuite-guard-uninstall`.
# See shell/README.md.

set -g _tern_netsuite_guard_dir (builtin realpath (status dirname))
set -g _tern_netsuite_guard_core $_tern_netsuite_guard_dir/tern-netsuite-guard

if test "$TERN_NETSUITE_GUARD" = shim
    if string match -q -- '*_tern_netsuite_guard_core*' (functions suitecloud 2>/dev/null)
        functions -e suitecloud
    end
    if functions -q suitecloud; or abbr -q suitecloud
        printf 'tern-netsuite guard: warning: suitecloud is a function or abbreviation in this shell, so commands typed here bypass the PATH shim (child processes are still guarded).\n' >&2
    end
    set -gx PATH $_tern_netsuite_guard_dir/bin (string match -v -- $_tern_netsuite_guard_dir/bin $PATH)
    set -g _tern_netsuite_guard_mode shim
else
    if not set -q _tern_netsuite_guard_installed
        and begin
            functions -q suitecloud
            or abbr -q suitecloud
        end
        printf 'tern-netsuite guard: not installed: suitecloud is already defined as a function, alias or abbreviation in this shell.\n' >&2
        printf 'tern-netsuite guard: your definition was left untouched. To use the guard, remove it before sourcing %s, or use TERN_NETSUITE_GUARD=shim.\n' (status filename) >&2
        set -e _tern_netsuite_guard_dir
        set -e _tern_netsuite_guard_core
        return 1
    end
    set -gx PATH (string match -v -- $_tern_netsuite_guard_dir/bin $PATH)
    function suitecloud --description 'suitecloud through the tern-netsuite guard'
        if not test -x "$_tern_netsuite_guard_core"
            printf 'tern-netsuite guard: the guard core %s is missing, so suitecloud was not run.\n' "$_tern_netsuite_guard_core" >&2
            printf 'tern-netsuite guard: restore it, run tern-netsuite-guard-uninstall, or bypass the guard (no confirmation) with: command suitecloud ...\n' >&2
            return 127
        end
        $_tern_netsuite_guard_core suitecloud $argv
    end
    set -g _tern_netsuite_guard_mode function
end
set -g _tern_netsuite_guard_installed 1

function tern-netsuite-guard-status --description 'show what the tern-netsuite guard does in this shell'
    if test "$_tern_netsuite_guard_mode" = shim
        echo "mode: PATH shim ($_tern_netsuite_guard_dir/bin)"
        echo "suitecloud resolves to: "(type -t suitecloud)" "(command -s suitecloud)
    else if string match -q -- '*_tern_netsuite_guard_core*' (functions suitecloud 2>/dev/null)
        echo "mode: shell function"
        echo "suitecloud function: tern-netsuite guard (fish)"
    else
        echo "mode: shell function"
        echo "suitecloud function: not the tern-netsuite guard"
    end
    if test -x "$_tern_netsuite_guard_core"
        $_tern_netsuite_guard_core status
    else
        echo "tern-netsuite guard core: MISSING at $_tern_netsuite_guard_core (suitecloud is refused)"
        return 1
    end
end

function tern-netsuite-guard-uninstall --description 'remove the tern-netsuite guard from this shell'
    if string match -q -- '*_tern_netsuite_guard_core*' (functions suitecloud 2>/dev/null)
        functions -e suitecloud
    end
    set -gx PATH (string match -v -- $_tern_netsuite_guard_dir/bin $PATH)
    functions -e tern-netsuite-guard-status
    set -e _tern_netsuite_guard_dir
    set -e _tern_netsuite_guard_core
    set -e _tern_netsuite_guard_installed
    set -e _tern_netsuite_guard_mode
    echo "tern-netsuite guard removed from this shell; also delete the 'source .../tern-netsuite.fish' line from your config.fish."
    functions -e tern-netsuite-guard-uninstall
end
