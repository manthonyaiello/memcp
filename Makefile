# memcp — build / test / proof automation. A thin wrapper over Alire.
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

.PHONY: all build run model test prove prove-deps prove-check docs clean help

all: build

build: ## Build the whole crate DAG (cargo + fetch-deps run automatically)
	$(ALR) build

run: build ## Serve POST /mcp on 127.0.0.1:8786 (blocking)
	$(ALR) run

model: ## Provision the embedding weights into ~/.memcp/models (needs curl)
	$(MODEL)

test: build ## Build + run the unit drivers and the self-contained smoke tests
	$(GPRBUILD) -P tests/memcp_tests.gpr
	./tests/bin/test_dispatch
	./tests/bin/test_store
	./tests/bin/test_tools
	$(GPRBUILD) -P crates/spark_mcp/tests/spark_mcp_tests.gpr
	./crates/spark_mcp/tests/bin/test_spark_mcp
	$(GPRBUILD) -P crates/sqlite_vec_spark/tests/sqlite_smoke.gpr
	./crates/sqlite_vec_spark/tests/sqlite_smoke

prove: ## Prove memcp to SPARK Silver — AoRTE (--level=2)
	$(ALR) gnatprove -P memcp.gpr -j0 --level=2

# Everything gnatprove needs on disk WITHOUT compiling anything. `alr gnatprove`
# is just `alr exec -- gnatprove`, which never runs build actions, so the proof
# job must provision inputs itself. `--stop-after=generation` runs only the
# sync + generation stages: it resolves/fetches the crate dependencies and
# writes the Alire *_config.gpr files (memcp.gpr withs config/memcp_config.gpr),
# then STOPS before the pre-build stage — so the candle and tiny_http cargo
# staticlibs, which gnatprove never links, are not built. fetch-deps vendors the
# C amalgamations, keeping sqlite_vec_spark's project model identical to a real
# build. This is what lets the CI proof job skip the entire Rust toolchain.
prove-deps: ## Provision proof inputs (config + C sources), no cargo/Ada build
	$(ALR) build --stop-after=generation
	bash crates/sqlite_vec_spark/scripts/fetch-deps.sh

prove-check: ## Prove + gate against the expected-failure baseline (CI gate)
	ALR="$(ALR)" ./scripts/check-proof.sh

docs: ## Generate GNATdoc API docs into docs/api
	$(ALR) exec -- gnatdoc --style=gnat --generate=private --warnings -P memcp.gpr

clean: ## Remove build artifacts
	$(ALR) clean
	$(RM) -r obj tests/obj tests/bin

help: ## List targets
	@grep -hE '^[a-z]+:.*?##' $(MAKEFILE_LIST) \
	  | sort | awk 'BEGIN{FS=":.*?## "}{printf "  \033[1m%-12s\033[0m %s\n",$$1,$$2}'
