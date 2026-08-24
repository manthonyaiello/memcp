# memcp — build / test / proof / documentation automation. A thin wrapper over
# Alire.
#
# `alr build` already runs each crate's Alire pre-build action: the cargo
# builds for the tiny_http and candle staticlibs, and the fetch-deps.sh that
# vendors the pinned SQLite + sqlite-vec C amalgamations. What Alire does NOT
# do is provision the embedding model (a *runtime* dependency), run the proof,
# or build and run the test drivers — that is what this Makefile adds.
#
# Run `make help` for the target list.

ALR      ?= alr
GPRBUILD  = $(ALR) exec -- gprbuild -p
MODEL     = crates/candle_spark/scripts/install-model.sh
MCP       = crates/spark_mcp

.PHONY: all build run model test test-hooks hook-version prove prove-deps \
        prove-check prove-mcp prove-mcp-deps docs docs-check docs-placement \
        trust trust-check clean help

all: build

build: ## Build the whole crate DAG (cargo + fetch-deps run automatically)
	$(ALR) build

run: build ## Serve POST /mcp on 127.0.0.1:8786 (blocking)
	$(ALR) run

model: ## Provision the embedding weights into ~/.memcp/models (needs curl)
	$(MODEL)

test: build test-hooks ## Build + run the unit drivers and the self-contained smoke tests
	$(GPRBUILD) -P tests/memcp_tests.gpr
	./tests/bin/test_dispatch
	./tests/bin/test_store
	./tests/bin/test_tools
	$(GPRBUILD) -P crates/spark_mcp/tests/spark_mcp_tests.gpr
	./crates/spark_mcp/tests/bin/test_spark_mcp
	$(GPRBUILD) -P crates/sqlite_vec_spark/tests/sqlite_smoke.gpr
	./crates/sqlite_vec_spark/tests/sqlite_smoke

# No Alire, no compiler: the hooks are bash + curl + jq and so is their harness,
# which is why this is separable from `test` and runs on a bare checkout.
test-hooks: hook-version ## Run the SessionStart / SessionEnd hook tests
	./tests/hooks/run_tests.sh

# The bump half needs a base ref to diff against, which only CI has, so it is
# passed there rather than defaulted here.
hook-version: ## Check the hook release string agrees across bash and Ada
	./scripts/check-hook-version.sh

# --timeout matches scripts/check-proof.sh, so this target and the gate agree on
# what is proved; see that script for why the wall-clock extra is needed.
prove: ## Prove memcp to SPARK Silver — AoRTE (--level=2)
	$(ALR) gnatprove -P memcp.gpr -j0 --level=2 --timeout=10

# Provision what gnatprove needs WITHOUT building the Rust staticlibs. gnatprove
# processes memcp.gpr's whole closure via gprbuild, which requires every withed
# *library* project (SPARKlib, json, and our crate libs) to be built — its
# Library_Dir must exist — so we can't skip the Ada library build. What we CAN
# skip is the Rust: the candle / tiny_http cargo staticlibs are pure
# Linker_Options, needed only to link the memcp *executable*, which the proof
# never does. So:
#   1. `alr build --stop-after=generation` — write the Alire *_config.gpr files
#      (memcp.gpr withs config/memcp_config.gpr) and sync dep sources, stopping
#      before the pre-build stage, so cargo never runs.
#   2. fetch-deps — vendor the C amalgamations sqlite_vec_spark compiles.
#   3. `gprbuild -c` — compile the closure and build the library dirs
#      (incl. SPARKlib) WITHOUT linking any executable, so no Rust staticlib is
#      needed. This is the whole point: the proof job skips the Rust toolchain.
prove-deps: ## Provision proof inputs (Ada libs + C sources), no cargo, no exe link
	$(ALR) build --stop-after=generation
	bash crates/sqlite_vec_spark/scripts/fetch-deps.sh
	$(ALR) exec -- gprbuild -p -c -P memcp.gpr

prove-check: ## Prove + gate against the expected-failure baseline (CI gate)
	ALR="$(ALR)" ./scripts/check-proof.sh

# Spark_Mcp.Server is generic: its body is analyzed only through an
# instantiation, and memcp.gpr's closure supplies only memcp's own. This proves
# it through the second, parser-free one in crates/spark_mcp/prove/.
#
# Both --checks-as-errors and --warnings=error: an unproved check alone exits 0.
prove-mcp: prove-mcp-deps ## Prove the reusable MCP core via its proof harness (CI gate)
	cd $(MCP) && $(ALR) exec -- gnatprove -P spark_mcp_prove.gpr \
	  -j0 --level=2 --checks-as-errors=on --warnings=error

prove-mcp-deps: ## Provision the MCP proof inputs (config GPR only, no cargo)
	cd $(MCP) && $(ALR) build --stop-after=generation

# GNATdoc (issue #22). The same report/gate split as prove/prove-check, and for
# the same underlying reason: `gnatdoc --warnings` lists every undocumented
# entity and then exits 0 regardless, so a bare gnatdoc run cannot fail a build.
# scripts/check-docs.sh reads the report and sets the exit status; it also drives
# every project root (the proof harness and the four test drivers are not in
# memcp.gpr's closure) and is the durable record of the --style=gnat choice,
# which no GPR attribute can express.
#
# Both depend on prove-deps rather than on `build`: gnatdoc needs the same
# provisioned tree the prover does -- the Alire config GPRs, the synced
# dependency sources, and the crates' obj/ and lib/ directories, whose absence
# gnatdoc reports as a project warning the gate deliberately does not filter --
# but it never links the executable, so it needs no Rust staticlib either. A
# fresh checkout can therefore run `make docs` with no cargo toolchain.
#
# Needs gnatdoc on PATH: `alr -n install gnatdoc_bin=26.0.0`. The script says so
# and stops if it is missing; it installs nothing itself.
docs: prove-deps ## Generate the API docs into docs/api + report undocumented entities
	./scripts/check-docs.sh --no-gate

docs-check: prove-deps ## `docs` as a gate: undocumented entity or misplaced block => exit 1
	./scripts/check-docs.sh
	./scripts/check-doc-placement.sh

# check-docs.sh cannot see placement: --warnings is per entity, not per
# declaration, so a block on the wrong side of a declaration either reads as a
# missing comment on the entity below or silently satisfies the entity above.
# This is the source-level lint that does see it. No toolchain needed -- it is
# awk over `git ls-files` -- so unlike docs-check it has no prerequisite and
# runs on a bare checkout.
docs-placement: ## Report doc blocks attributed to the wrong declaration
	./scripts/check-doc-placement.sh --no-gate

# grep over `git ls-files`, so like docs-placement it needs no toolchain and runs
# on a bare checkout. That is what lets CI gate on it before anything compiles.
trust: ## List the derived trust surface, in manifest form
	./scripts/check-trust-surface.sh --list

trust-check: ## `trust` as a gate: any drift from scripts/trust-surface.txt => exit 1
	./scripts/check-trust-surface.sh

clean: ## Remove build artifacts
	$(ALR) clean
	$(RM) -r obj tests/obj tests/bin docs/api gnatdoc-run.txt

# `[a-z-]`, not `[a-z]`: the hyphenated targets (prove-check, prove-deps and now
# docs-check) were silently absent from this listing.
help: ## List targets
	@grep -hE '^[a-z-]+:.*?##' $(MAKEFILE_LIST) \
	  | sort | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-12s\033[0m %s\n",$$1,$$2}'
