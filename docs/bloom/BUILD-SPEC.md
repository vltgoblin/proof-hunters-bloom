# Bloom (whole-Hunter DirectLoan) — build spec shared by all B-slice agents

Worktree: /home/obanj/orca/workspaces/proof-hunters-mining-upgrade/vlt-12-bloom
Branch: dev/vlt-12-bloom-whole-hunter-loans (from origin/main b5a6bc0). Do NOT push. Do NOT commit; the orchestrator commits.
Contracts root: contracts/ (Solidity 0.8.24, cancun, OZ v5 + forge-std as submodules, already initialised).

## Toolchain rules (hard)
- Forge binary: <a Forge v1.7.1 binary run by absolute path; download from https://github.com/foundry-rs/foundry/releases/tag/v1.7.1> (v1.7.1 = CI pin). Never ~/.foundry/bin/forge (1.8.1 isolates calls by default and breaks transient-storage tests). Never foundryup.
- Env for every forge call: FOUNDRY_OUT=<scratchpad>/bloom/out-<slice> FOUNDRY_CACHE_PATH=<scratchpad>/bloom/cache-<slice> FOUNDRY_FUZZ_FAILURE_PERSIST_DIR=<scratchpad>/fuzzfail, where <scratchpad> = any directory outside the worktree. Use `-j 2`; other agents share the machine.
- Run both profiles: default and FOUNDRY_PROFILE=release. Full existing suite (`--no-match-test '^invariant_'`) must stay 339 passed + your additions.
- Do NOT modify any existing file: no src/ changes (DirectLoan.sol is under review, not being changed in B1–B4), no existing tests, no CI, no foundry.toml, no publication guard. New files only. The guard rejects new files on dev branches; expected.
- Every new .sol starts with exactly:
  // SPDX-License-Identifier: Apache-2.0
  // Copyright (c) 2026 vltgoblin
  pragma solidity 0.8.24;
- Match existing style (NatSpec ///, custom errors, forge-std Test). Read contracts/src/bloom/DirectLoan.sol fully before anything.

## The contract under test (unchanged in B1–B4)
contracts/src/bloom/DirectLoan.sol — fixed-term whole-NFT loans: onERC721Received (escrowTo callback creates the request from posted Terms{version,principal,repayment,duration}), cancel, fund (lender pays principal; borrower gets principal − fee; fee credited to FEE_RECIPIENT), depositRepayment / withdrawDeposit (partial deposits until full), claimNft (borrower if Repaid, lender if Defaulted), claimLender / claimBorrowerRefund / claimFee (pull claims), resolveDefault (lender after deadline; anyone after deadline + defaultResolutionWindow), stopEntry (STOP_AUTHORITY; blocks new requests/funding only). Liabilities: totalUncommittedDeposits + totalLenderClaims + totalBorrowerRefunds + totalFeeCredits; _assertSolvent after money moves; claimFee additionally refuses to dip below user liabilities.
Frozen rules (M3.1): one origination fee only on successful funding, floor(P*feeBps/10_000) capped by feeCap when nonzero (feeCap=0 = no cap, never zero fee); rate/cap/recipient/bounds are immutable constructor values; borrower always gets NFT on repayment, lender on default; partial deposits refund to borrower on default; independent claims; no admin withdrawal; exact-asset loan tokens only (fee-on-transfer unsupported — pin the actual contract behaviour).

## Harness to reuse (already on main)
- contracts/test/HunterLifecycleCore.t.sol: `abstract contract LifecycleTestBase` — real HunterLifecycle, WeightedRoundLedger, HunterBackingVault, HunterReserveVault, HunterNFT (test contract is the minter), BasketRegistry, ReserveTokenFixture token, helpers `_mint(owner, tier, basket)`.
- contracts/test/DirectLoanMutualExclusion.t.sol: shows LifecycleTestBase + DirectLoan (+ mock loan asset) + LiveHunt assembly and the escrowTo/terms pattern.
- contracts/test/DirectLoan.t.sol: constructor Config values used in tests (placeholders), `_terms()`, MockLoanAsset.
- contracts/test/DirectLoanBackingInEscrow.t.sol: backing during escrow.
- contracts/test/DirectLoanMoneyInvariant.t.sol: existing handler + 4 invariants + fuzz.
- contracts/test/HunterLiveHuntIntegration.t.sol: LiveHunt offer/fill.
Create ONE shared helper for the B slices: contracts/test/helpers/BloomLoanStack.sol (`abstract contract BloomLoanStack is LifecycleTestBase`) that assembles DirectLoan (placeholder Config: feeBps 100, feeCap 0, bounds and windows as in DirectLoan.t.sol) with a mock exact-asset loan token, a LiveHunt, plus helpers `_request(tokenId, borrower, terms)`, `_fund(loanId, lender)`, `_repay(loanId, amount)`, `_default(loanId, by)`, `_assertBooks()` (balance ≥ liabilities, buckets sum, escrow holds while Requested/Funded), constants BORROWER, LENDER, THIRD, FEE_SINK, STOP. Whoever needs it first (B1) creates it; later slices extend only by adding.

## Defaults standing in for open B0 decisions (flag "B0 default" in NatSpec)
Loan asset: exact-asset ERC-20 test token (USDG-shaped, 6 decimals in fork tests only). Fee: placeholder 1% no cap. Route B: not in scope. Stop authority: STOP constant.

## Definition of done per slice
Named tests exist and pass on 1.7.1 under default AND release; escrow/transient tests also with --isolate; no existing file changed; report files, pass counts per profile, commands, deviations, and any REAL finding against DirectLoan with a minimal sequence (do not "fix" the contract; report it — fixes are a separate decision).
