---
name: qnxml-design-review
description: Use when QnXMl's OCaml/QNX substrate or VWC design, implementation, correctness, or defensive security needs review.
---

# QnXMl design review

Use this skill when asked to assess a design, find implementation gaps, review
security properties, or choose the next fix in QnXMl.

1. Record the branch, commit, working-tree changes, and any pull request under
   review. Compare a pull request's head with its base; do not attribute an open
   pull request's changes to `main`.
2. Read the relevant sources: `README.md`, `docs/SPEC.md`,
   `vwc/docs/VWC-SRS-001.md`, `vwc/docs/TRACE.md`, and the applicable
   `vwc/docs/IMPL-*.md`. Then inspect the corresponding `lib/`, `vwc/lib/`,
   `test/`, and `demo/` files. Check for disagreements between documents.
3. Pick a specific invariant or requirement ID. Mark its status as implemented,
   interface only, proposed, or unverified. Use code and tests to establish
   implementation status; use the requirements documents to establish intent.
4. For memory, IPC, and capability questions, trace the producer and consumer,
   publication and acquisition order, mapping permissions, generation checks,
   reader lifetime, reclaim path, and crash/restart sequence. Identify the
   smallest failing scenario or proof obligation before recommending a change.
5. Offer a recommended solution and material alternatives with their tradeoffs.
   Give a minimal experiment or test that could disprove the recommendation.
   Prioritize correctness and security issues that block later VWC work.
6. Run `make host` when Dune and OCaml are available. Run `make target` only
   with a configured QNX SDP and cross toolchain. Treat a successful cross
   build as build evidence, not runtime evidence. Report any unavailable
   toolchain or device separately from failing tests.

Return a short, prioritized list with requirement IDs, file and line evidence,
the proposed fix, verification steps, and remaining uncertainty. When asked to
implement a fix, make the targeted change and run the checks that can verify it.
