SHELL = /bin/sh

BIN = .tools/bin
LUAU = $(BIN)/luau
LUAU_LSP = $(BIN)/luau-lsp
STYLUA = $(BIN)/stylua
SELENE = $(BIN)/selene
TERN_DEFS = .tools/types/tern.lsp.d.luau

LUAU_DIRS = $(wildcard plugin tests)
FILTER =

.PHONY: bootstrap tools fixtures test test-shell smoke smoke-real lint fmt fmt-check typecheck check

bootstrap:
	sh scripts/bootstrap.sh

fixtures:
	@sh scripts/fixtures/embed.sh

tools:
	@for f in $(LUAU) $(LUAU_LSP) $(STYLUA) $(SELENE) $(TERN_DEFS); do \
		[ -e "$$f" ] || { echo "missing $$f: run 'make bootstrap'" >&2; exit 1; }; \
	done

test: tools fixtures
	@[ -d tests/unit ] || { echo "no tests/unit directory" >&2; exit 1; }; \
	set -- $$(find tests/unit -name '*.spec.luau' | sort); \
	[ $$# -gt 0 ] || { echo "no specs under tests/unit" >&2; exit 1; }; \
	if [ -n "$(FILTER)" ]; then set -- "$(FILTER)" "$$@"; fi; \
	$(LUAU) tests/run.luau -a "$$@"

# Shell-level suites (guard wrappers): every tests/shell/<name>/run.sh.
test-shell: tools
	@set -- $$(find tests/shell -name run.sh 2>/dev/null | sort); \
	[ $$# -gt 0 ] || { echo "no shell suites"; exit 0; }; \
	for s in "$$@"; do echo "== $$s"; LUAU=$(LUAU) sh "$$s" || exit 1; done

# Loads plugin/host.luau and plugin/window.luau under standalone luau with a
# strict stub `tern` global and checks every manifest lens/block is defined.
smoke: tools
	@LUAU=$(LUAU) sh tests/smoke/run.sh

# Links the package into an isolated real Tern daemon and requires it to load
# without problems (local only; skipped when `tern` is absent).
smoke-real:
	@sh scripts/smoke-real.sh

lint: tools
	$(SELENE) $(LUAU_DIRS)

fmt: tools
	$(STYLUA) $(LUAU_DIRS)

fmt-check: tools
	$(STYLUA) --check $(LUAU_DIRS)

typecheck: tools fixtures
	$(LUAU_LSP) analyze --platform=standard --definitions=@tern=$(TERN_DEFS) --ignore='tests/smoke/.generated/**' $(LUAU_DIRS)

check: fmt-check lint typecheck test test-shell smoke
