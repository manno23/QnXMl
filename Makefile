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

clean:
	dune clean

.PHONY: host demo target clean
