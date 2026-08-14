# Host build (Linux): library + test suite + demo executables.
host:
	dune build
	dune test

# Two-process demo on the host: consumer attaches (retrying), producer streams.
demo: host
	./_build/default/demo/consumer.exe & \
	./_build/default/demo/producer.exe 100000; \
	wait

# QNX cross build. Requires (see docs/CROSS.md):
#   1. SDP env sourced:  . ~/qnx800/qnxsdp-env.sh
#   2. an OCaml cross toolchain registered with findlib as toolchain "qnx"
# Produces target binaries under _build/qnx/.
target:
	dune build -x qnx

# Static analysis: community OCaml/C rulebooks + project-specific rules
# (tools/opengrep/qnxml.yml). region_stubs.c is scanned via a CAMLprim-free
# copy so the C parser sees the whole file (tree-sitter chokes on the
# `CAMLprim value` token pair); the original is excluded to avoid dupes.
# JSON + SARIF copies land under tools/opengrep/ for CI / review.
OPENGREP_RULES ?= /home/jm/data/qnx/.opengrep-rules
OPENGREP_OUT ?= tools/opengrep
opengrep:
	@sed 's/^CAMLprim value/static value/' lib/region_stubs.c > /tmp/qnxml_stubs_scan.c
	opengrep scan --no-git-ignore --exclude 'region_stubs.c' \
	  --config $(OPENGREP_RULES)/semgrep-rules/ocaml \
	  --config $(OPENGREP_RULES)/semgrep-rules/c \
	  --config tools/opengrep/qnxml.yml \
	  --json-output=$(OPENGREP_OUT)/qnxml.json \
	  --sarif-output=$(OPENGREP_OUT)/qnxml.sarif \
	  lib demo test /tmp/qnxml_stubs_scan.c

# Positive/negative fixtures co-located with the rules (qnxml.ml / qnxml.c).
opengrep-test:
	opengrep test tools/opengrep/

clean:
	dune clean
	rm -f $(OPENGREP_OUT)/qnxml.json $(OPENGREP_OUT)/qnxml.sarif

.PHONY: host demo target clean opengrep opengrep-test
