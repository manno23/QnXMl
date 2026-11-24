# QnXMl agent guidance

This repository explores OCaml systems primitives on QNX Neutrino 8 and a
capability-based virtual working copy (VWC). For architecture, implementation,
correctness, or defensive security reviews, use the `qnxml-design-review` skill
in `.agents/skills/qnxml-design-review/SKILL.md`.

Read the relevant requirements and implementation notes, then compare them with
the current branch's code and tests. A trace-matrix entry or README claim is not
proof that a feature is implemented. In particular, `vwc/lib/dune` currently
declares VWC interfaces without implementations. State the branch and commit
reviewed, separate host checks from QNX builds and on-device tests, and cite
the files and lines behind each proposed change.
