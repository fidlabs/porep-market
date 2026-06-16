# PoRep Market V1 Reference

This folder is a reference-only V1 snapshot copied from `v1.2.0`
(`e660e5870256`) while preparing `main` for V2 work.

It is for reading old contract code, test setup, mocks, and lifecycle
assertions without switching branches. It is not active source.

Use the separate `v1` maintenance branch for V1 fixes, upgrades, releases,
tags, deployments, verification, and release notes.

Do not deploy, upgrade, verify, generate ABIs, run tests, or run releases from
this folder. Files under `v1/` must stay outside normal Foundry build, lint,
test, coverage, ABI, deploy, and verification flows on V2-focused `main`.

Do not import files from `v1/` into active `src/`, `test/`, or `script/`.
Copy a pattern into active V2 code only as an intentional V2 implementation
change.

Contents:

- `src/` - V1 contract source for browsing and copying patterns.
- `test/` - V1 tests and test mocks for setup examples and lifecycle
  assertions.
