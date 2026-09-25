# Bloom (whole-Hunter loans) — handoff for the implementing agent

Written 2026-09-25 by the planning session. Read this first, then the Linear issues, then the code.

## Where things are

| What | Where |
| --- | --- |
| Repo | https://github.com/vltgoblin/proof-hunters-bloom (public, Apache-2.0) |
| Base for Bloom work | `main` at `b5a6bc0` = this branch `dev/vlt-12-bloom-whole-hunter-loans` (nothing else on it yet) |
| Local worktree for Bloom | `/home/obanj/orca/workspaces/proof-hunters-mining-upgrade/vlt-12-bloom` (submodules initialised; git author set to `vltgoblin`) |
| Mining upgrade (separate product, may be parked) | branch `dev/vlt-50-mining-upgrade-pre-funded-token-eligibility-and-per-mint`, worktree `.../vlt-50-mining-upgrade`. **Do not base Bloom on it and do not touch it.** Its harness (`PrefundedMiningStack`) is not needed for Bloom. |
| Linear epic | VLT-12 "M3.2–M3.5 Borrowing implementation" — status review comment of 2026-09-25 |
| Linear slices | VLT-68 (B0 decisions) → VLT-69 (B1) → VLT-70 (B2) · VLT-71 (B3) · VLT-72 (B4) · VLT-73 (B5) · VLT-74 (B6) · VLT-75 (B7) · VLT-76 (B8) |
| Build spec for agents | `docs/bloom/BUILD-SPEC.md` (this directory) |
| Design authority (private repo `vltgoblin/bonded-proof`, `origin/main`) | `docs/product/bonded-proof/hunter-bloom/DELIVERY-PLAN.md`, `system-design-v2/M3.1-LENDING-INTERFACE-FREEZE.md`, `system-design-v2/LOAN-RULES-AND-CORE-BOUNDARY.md`, `system-design-v2/M3-M5-M6-ROADMAP.md` |

## What Bloom is, in one paragraph

Whole-Hunter loans, peer to peer, fixed term. The borrower escrows the NFT into `DirectLoan` with posted terms (principal, repayment, duration); a lender funds it (borrower receives principal minus one origination fee); the borrower repays (partial deposits allowed and withdrawable until full) and claims the NFT back, or defaults and the lender claims the NFT; partial deposits are refunded to the borrower on default; every claim is independent and pull-based; an entry-stop authority can halt new loans but never exits. One active loan per Hunter. Backing earned while in escrow follows the token. Route B (basket-token lending via Morpho) is **blocked** on the live immutable lifecycle/vaults and is not part of this work unless B0 decides otherwise.

## What exists on `main` today

- `contracts/src/bloom/DirectLoan.sol` — the module. Do **not** change it in B1–B4; findings are reported, fixes are a separate decision (B6).
- Tests: `DirectLoan.t.sol` (34), `DirectLoanBackingInEscrow.t.sol` (2), `DirectLoanMutualExclusion.t.sol` (5), `DirectLoanMoneyInvariant.t.sol` (4 invariants + fuzz). All green on Forge 1.7.1: `forge test --root contracts` → 339 passed.
- Harness pieces to reuse: `LifecycleTestBase` in `contracts/test/HunterLifecycleCore.t.sol` (real lifecycle/ledger/backing/reserve/NFT/registry), the DirectLoan + LiveHunt assembly in `DirectLoanMutualExclusion.t.sol`, fixtures in `contracts/test/helpers/HunterReserveFixtures.sol`.
- Anvil deploy script exists only in the private repo (`contracts/script/DeployDirectLoanAnvil.s.sol`).

## What is missing (the B slices)

1. **B1** money-path proofs: default at the exact deadline boundary, refund of partial deposits, lender-only vs public default windows, fee only on successful funding, cap semantics, independent claims, stop-safe exits, backing during escrow to the final holder, hostile/fee-on-transfer loan assets, plus a hand-applied mutation kill list. Creates the shared harness `contracts/test/helpers/BloomLoanStack.sol`.
2. **B2** stateful invariant campaign over the real stack + full mutation run.
3. **B3** TLA+ model (`formal/tla/DirectLoan.tla`) of the loan state machine and custody exclusions; TLC green; broken variants fail.
4. **B4** Halmos symbolic proofs of the money paths.
5. **B5** fork rehearsal on chain 4663 against the live NFT; loan-asset check (candidate USDG `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`, 6 decimals; no canonical WETH exists on the chain).
6. **B6** independent review + dispositions (the mining upgrade used Codex `gpt-6-astra`, read-only, with an adversarial brief; the report was saved under `formal/review/`).
7. **B7** borrow UI and docs (largest piece; nothing exists).
8. **B8** go/no-go: terms, deployment, lenders, disclosures.

Owner decisions that gate values (B0, VLT-68): route B fate; loan asset; feeBps/cap/recipient; principal/duration bounds and windows; stop authority. Code can start on placeholders; every number is a constructor value.

## Rules (from the project, not negotiable)

- Forge **1.7.1** exactly (CI pin). The machine's global forge is 1.8.1 and isolates calls by default, which breaks transient-storage tests; a 1.7.1 binary is downloadable from the Foundry releases and must be run by absolute path. Keep `FOUNDRY_OUT` / `FOUNDRY_CACHE_PATH` outside the worktree.
- Run both profiles (`default` and `FOUNDRY_PROFILE=release`); escrow/transient tests also with `--isolate`.
- New files only in B1–B5; no edits to `foundry.toml`, CI, or `scripts/check-publication.mjs`. The publication guard rejects new files on dev branches by design; the maintainers update the provenance policy before any merge to `main`.
- Every new `.sol` starts with the exact three-line header (`// SPDX-License-Identifier: Apache-2.0` / `// Copyright (c) 2026 vltgoblin` / `pragma solidity 0.8.24;`).
- Commits authored as `vltgoblin <307016275+vltgoblin@users.noreply.github.com>` (repo-local config is set). Push only when the owner says so.
- Never describe Bloom as live, audited, or yield-bearing. No fee rate or loan asset is chosen until B0 says so.
- Real findings against `DirectLoan.sol` are reported with a minimal sequence, not silently fixed.

## Evidence bar (same as the mining upgrade)

Named tests per slice on the real contracts (no pranked hooks on positive paths), invariants at default size in CI and a long campaign before review, TLA+ model with failing variants, symbolic proofs with non-vacuity variants, mutation kill lists posted to Linear, fork rehearsal at a fresh pinned block, independent review with every finding dispositioned. The mining branch shows the pattern: `contracts/test/Prefunded*.t.sol`, `formal/tla/README.md`, `contracts/test/symbolic/README.md`, `formal/fork/*.md`, `formal/review/*.md`.

## Live-chain facts you will need (verified 2026-09-25)

- Chain 4663 public RPC: `https://rpc.mainnet.chain.robinhood.com` (no credentials; keeps ~10–30 min of state; pin a fresh block per run). The core's `block.number` is the **L1 parent block** (~12.1 s); Foundry forks use the L2 number, so `vm.roll` to the parent block before touching lifecycle timing.
- Live addresses: HunterNFT `0x924a65312cd535bc8787acECdfa5F71609B4e273`, HunterLifecycle `0x3eed4ffabbe8ff92d84bcd5e6a53f41d05ddef7d`, HunterBackingVault `0x7cb8b19d356169664e3debee61fc9529f557347d`, LiveHunt `0x0621902bf715ca4e57a7f9152e8b42b6819e7bf6`, HUNTER `0xBBDD439FD49ADE6Ff3C96f748867de4356647960`. Live code matches the public source under the release profile modulo metadata.
- Morpho on 4663 lends only USDG across its listed markets; no Hunter-related market exists.

## Suggested order for the implementing agent

B1 → B3 (parallel is fine, different files) → B2 → B4 → B5 (needs the B0 loan-asset answer) → B6 → B7 → B8. Commit per slice, post evidence on the Linear issue, mark it Done only after both profiles are green.
