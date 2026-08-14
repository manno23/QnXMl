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
OPENGREP_RULES ?= /home/jm/data/qnx/.opengrep-rules
opengrep:
	@sed 's/^CAMLprim value/static value/' lib/region_stubs.c > /tmp/qnxml_stubs_scan.c
	opengrep scan --no-git-ignore --exclude 'region_stubs.c' \
	  --config $(OPENGREP_RULES)/semgrep-rules/ocaml \
	  --config $(OPENGREP_RULES)/semgrep-rules/c \
	  --config tools/opengrep/qnxml.yml \
	  lib demo test /tmp/qnxml_stubs_scan.c

clean:
	dune clean

.PHONY: host demo target clean opengrep
