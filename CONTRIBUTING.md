# Contributing

## Setup

Supported dev hosts: macOS arm64 and Linux x86_64.

```sh
make bootstrap   # pinned luau, luau-lsp, StyLua, selene and Tern types into .tools/
make check       # format check, lint, typecheck, unit specs, shell suites, stub smoke
make smoke-real  # local only: load the checkout in an isolated real Tern under /tmp
```

Tools are repo-local (`.tools/`, gitignored, checksums pinned in
`scripts/bootstrap.sh`); nothing is installed globally. The shell suites
also need zsh, bash and fish. `make smoke-real` needs Tern; it opens a
sandbox window for a few seconds and never touches your Tern config.

## Conventions

- **Conventional Commits** (`feat:`, `fix:`, `docs:`, `test:`, `build:`,
  `chore:`, `refactor:`), imperative, small and atomic. One branch per
  change, PR against `master`.
- **TDD**: write the failing spec first; spec names state why the behavior
  matters. Bugs get a regression spec.
- **Pure core**: code under `plugin/lib/` never references the `tern`
  global; inject what it needs (decoders, clocks, file reads). Only
  `plugin/host.luau`, `plugin/window.luau` and the `plugin/*_host.luau` /
  `plugin/*_window.luau` adapters call `tern.*`, and they decide nothing.
- `--!strict` in every Luau file. Small pure functions, immutable data where
  practical, early returns.
- Comments only where the code cannot say it (SDK constraints, safety
  reasons). No emojis in code, docs or commit messages.
- The package is the repository root: `plugin.toml` there, and everything it
  loads under `plugin/`, which holds only what ships (`.luau`). Tests,
  fixtures, scripts and docs live outside it; CI rejects anything else.
- Safety defaults fail closed: an account the plugin cannot classify is
  production, connections are read-only, a config typo never weakens the
  guard. Keep it that way.
- Keep `README.md` true to the code in the same PR; add a line to
  `CHANGELOG.md` for user-visible changes.

## Testing safely

- Never run tests against a production NetSuite account. Specs use
  fixtures; the guard and lens checks use the fake CLI in `tests/bin/`.
- Fixtures captured from a real account must be sanitized before they are
  committed: synthetic account ids (`1234567`, `1234567_SB1`), auth IDs,
  script ids, names, emails, domains and paths. Keep the byte layout of the
  CLI output otherwise.
- Do not run two SuiteCloud account commands for the same auth ID at the
  same time: the CLI refreshes OAuth tokens per command and a race can
  invalidate the token (it then asks for a browser login).
- Tern only through a sandbox under `/tmp` (`TNS_SANDBOX=/tmp/tns-<name>
  make smoke-real`, or `tern --control /tmp/<sandbox>/ctl.sock` with its own
  `TERN_CONFIG_DIR` and `TERN_DAEMON_SOCKET`). Never store real credentials
  in the keychain from tests.

## Pull request checklist

- [ ] Commits follow Conventional Commits.
- [ ] Failing spec added first; `make check` passes.
- [ ] Shell changes: `make test-shell` passes (zsh, bash, fish, dash).
- [ ] Plugin changes: `make smoke-real` passes locally.
- [ ] No `tern` reference added under `plugin/lib/`.
- [ ] README and CHANGELOG updated.
- [ ] No secrets, credentials, real account ids or unsanitized CLI output in
      the diff.
