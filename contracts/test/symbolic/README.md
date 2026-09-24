# Symbolic verification of PrefundedMiningPower (S10c, VLT-66)

`PrefundedMiningPower.halmos.t.sol` is a Halmos suite. Every property is a
`check_*` function. `forge test` only runs `test*` / `invariant*`, so in CI this
file is compiled but runs no tests: `forge test --root contracts --match-path
'test/symbolic/*'` exits 0 with "No tests found".

The module under test is the real `src/bloom/PrefundedMiningPower.sol`,
unmodified. Everything around it is a minimal symbolic harness: a non-taxing
mock HUNTER token and mock core, PROOF_NFT and lifecycle contracts.

## Versions

| Tool | Version |
|---|---|
| halmos | 0.3.3 (pip, user venv) |
| solver | yices 2.6.4 (`yices-solver` pip wheel, the halmos default) |
| forge | 1.7.1 (CI pin, used by halmos for the build) |
| solc | 0.8.24 (`~/.svm/0.8.24/solc-0.8.24`) |
| SMTChecker backend | z3 4.12.6 (`z3-solver` pip wheel `libz3.so`, loaded through `LD_LIBRARY_PATH`) |

## How to run

```sh
python3 -m venv venv && ./venv/bin/pip install halmos==0.3.3
# halmos calls `forge build`; put the 1.7.1 binary first on PATH
PATH=<forge-1.7.1-dir>:$PATH ./venv/bin/halmos --root contracts \
  --contract PrefundedMiningPowerHalmos --loop 8 --solver-timeout-assertion 0 \
  --match-test '^check_P7_hooksCoreOnly\('
```

Run each check in its own process, one at a time, with a wall-clock
timeout. The results below used `timeout 900`. The slow checks need 1–3 GB of
memory each, and running them in parallel with the SMTChecker exhausted a 24 GB
machine.

SMTChecker:

```sh
LD_LIBRARY_PATH=<venv>/lib/python3.14/site-packages/z3/lib \
~/.svm/0.8.24/solc-0.8.24 --evm-version cancun \
  @openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/ forge-std/=lib/forge-std/src/ \
  --base-path . --allow-paths .,lib \
  --model-checker-engine chc --model-checker-targets assert \
  --model-checker-timeout 20000 \
  --model-checker-contracts src/bloom/PrefundedMiningPower.sol:PrefundedMiningPower \
  --model-checker-show-unproved --model-checker-show-proved-safe \
  src/bloom/PrefundedMiningPower.sol          # run from contracts/
```

## Harness and what "PASS" means

- **Arbitrary pre-state.** Every check calls `svm.enableSymbolicStorage` on the
  module, token, core, NFT and lifecycle. Every storage slot starts as an
  unconstrained symbol, restricted only by the assumptions stated in the check.
  A PASS is therefore an inductive step: if the precondition holds in any
  state, it holds after the call. It is not a bounded replay of histories. The
  one exception is the OpenZeppelin reentrancy guard slot, which is pinned to
  NOT_ENTERED because that is its value between transactions.
- **Accounts.** U = 3 depositors (D0–D2) and 2 mining wallets (W0, W1).
  Depositor calls come from D and wallet arguments from W. Sums and the
  one-backer structure range over all of U. Summed values are assumed below
  2^128 so the property arithmetic itself cannot overflow. The module's own
  arithmetic is unbounded.
- **The core is modelled, not run.** Settlement is
  `vm.prank(core); powerMultiplierWad(c, miner); vm.prank(core); onProofAccepted(n)`
  inside a single frame (`settleAsCore`). A revert in either call reverts both,
  as in `submitProof`. The core, NFT and lifecycle views (`activeChallengeId`,
  `nftsMintedEver`, `previousAcceptedDigest`, `PROOF_NFT.mintedEver`,
  `ownerOf`, `currentMember`, `finalBeneficiary`) are arbitrary symbolic
  values. That is a superset of what the real `HunterMiningCore` can present.
  The real hook order, and the fact that only the real core can reach the
  hooks, are covered by the concrete suites, not by this one.
- **Non-taxing token.** Taxing and hostile tokens are covered by
  `PrefundedMiningPowerHostile.t.sol`.

## Results on the unmodified contract

Settings: halmos 0.3.3, yices, `--loop 8`, `--solver-timeout-assertion 0`, and a
900s wall-clock limit per check. "Time" is Halmos' own solver-phase time.

| # | Property | Check | Result | Time |
|---|---|---|---|---|
| 1a | Solvency is preserved by every state-changing function | `check_P1op_{Deposit,Assign,Withdraw,Claim,Settle}` (P1 with `op` fixed) | PASS ×5 | 17s / 397s / 73s / 15s / 289s |
| 1a | same, other ops | `check_P1op_{Unassign,Evict,ClaimTo,Snapshot,Detach,Disable,Freeze,Gate,Accept}`, and the combined `check_P1_solvencyPreserved` | NOT RUN (time budget) | – |
| 1b | Every exit (withdraw, claim, claimTo, unassign, evictBacker) reverts when insolvent before the call | `check_P1_exitsRevertWhenInsolvent` | PASS | 15.5s |
| 2 | `withdraw(x)` succeeds ⇒ `x <= withdrawableOf` before; caller +x, module −x, unassigned −x, totalStake −x exactly | `check_P2_withdrawBoundedAndExact` | PASS | 14.9s |
| 2' | Liveness: `0 < x <= withdrawableOf` ⇒ withdraw succeeds (in a conserving, one-backer, solvent state) | `check_P2_withdrawWithinWithdrawableSucceeds` | TIMEOUT (900s) | – |
| 3+4 | Conservation (`Σunassigned + ΣassignedBy == totalStake`, `ΣassignedOf == totalAssigned`) and the one-backer bijection are preserved | `check_P34op_Settle` | TIMEOUT (900s) | – |
| 3, 4 | same, all ops | `check_P3_conservation`, `check_P4_oneBacker`, other `check_P34op_*` | NOT RUN (the Settle split already exceeds the budget) | – |
| 5 | Settlement takes exactly LOCK from the winner wallet and its backer, from nobody else; lock recorded for `nftsMintedEver` | `check_P5_settlementTakesExactLock` | TIMEOUT (900s) | – |
| 5 | same, without the sweep over other accounts (smaller bound) | `check_P5_settleExactLockCore` | PASS | 322.8s |
| 5' | No note ⇒ no lock (bare `onProofAccepted`, or gate with failsafe fired): nothing changes | `check_P5_noNoteNoLock` | PASS | 62.4s |
| 6 | Claim pays only a nonzero `finalBeneficiary`, only after the burn, exactly the lock, totalCommitted −lock, once (a second claim by anyone reverts) | `check_P6_claimOnceToBeneficiary` | PASS | 3.6s |
| 7 | All 5 hooks revert `UnauthorizedCaller(caller)` for every caller ≠ core | `check_P7_hooksCoreOnly` | PASS | 0.4s |
| 7' | `disableRequirement` only by the guardian, changes nothing but the flag | `check_P7_failsafeGuardianOnly` | PASS | 5.2s |
| 8a | `unassign` succeeds ⇒ cooldown elapsed, or retired, or failsafe fired | `check_P8_unassignRespectsCooldown` | PASS | 131.8s |
| 8b | Withdraw of held stake reverts until the next snapshot or a waiver (spec restated independently of `heldStakeOf`) | `check_P8_withdrawRespectsHold` | PASS | 11.5s |
| 9a | Gate enforcing ⇒ reverts unless frozen stake >= MIN_STAKE (symbolic `c`, symbolic `w`) | `check_P9_gateRevertsBelowMinimum` | TIMEOUT (1227s) | – |
| 9a | split: wallet in {W0, W1}, first freeze | `check_P9_gateBelowMin_fresh` | PASS | 4.4s |
| 9a | split: wallet in {W0, W1}, cached freeze | `check_P9_gateBelowMin_cached` | TIMEOUT (900s) | – |
| 9a | split: cached freeze, `c = latestChallengeId` (smaller bound) | `check_P9_gateBelowMin_cachedLatest` | TIMEOUT (900s) | – |
| 9b | `CURVE_UNIT == 0` ⇒ gate, `multiplierFromLockedAmount` and `previewSubmit` return exactly 1e18 (the curve never reverts) | `check_P9_curveZeroIsExactlyOne` | PASS | 17.9s |
| 9c | For any `CURVE_UNIT` and amount, the curve and the gate return a value in [1e18, 3e18] | `check_P9_multiplierNeverAboveThree` | TIMEOUT (900s) | – |
| 9c | curve only (smaller bound) | `check_P9_curveNeverAboveThree` | TIMEOUT (900s) | – |
| 10 | `evictBacker`: only the wallet, only `0 < assignedOf < MIN_STAKE`; the whole assignment moves to the backer's unassigned balance; slots cleared; pending-first / removal / hold bookkeeping exact; nothing else changes | `check_P10_evictBacker` | TIMEOUT (900s) | – |

**No counterexample was found on the unmodified contract.**

## Non-vacuity (broken variants)

Each variant is a copy of the HEAD contract with exactly one line changed. The
runner asserts that. Each is compiled in its own scratch project and checked
with `--early-exit` against its target property. The variants live outside the
repo (scratchpad `s10c/variants/`, driven by `run_variants.py`).

| Variant (one-line change) | Target check | Result | Time |
|---|---|---|---|
| P1a `totalCommitted += lockAmount + 1` in settlement | `check_P1op_Settle` | COUNTEREXAMPLE | 27s wall |
| P1b drop `_requireSolvent()` in `unassign` | `check_P1_exitsRevertWhenInsolvent` | COUNTEREXAMPLE | 2.4s |
| P2a withdraw ignores the hold (`min(0, …)`) | `check_P2_withdrawBoundedAndExact` | COUNTEREXAMPLE | 3.8s |
| P2b withdraw over-holds (`held + 1`) | `check_P2_withdrawWithinWithdrawableSucceeds` | COUNTEREXAMPLE | 9.7s |
| P3 `unassign` does not reduce `totalAssigned` | `check_P3_conservation` | COUNTEREXAMPLE (op = evict) | 543.9s |
| P4 `WalletAlreadyBacked` check disabled | `check_P34op_Assign` | COUNTEREXAMPLE | 626.5s wall |
| P5a backer's `assignedBy` not charged | `check_P5_settlementTakesExactLock` | COUNTEREXAMPLE | 8.6s |
| P5b note written even with failsafe fired | `check_P5_noNoteNoLock` | COUNTEREXAMPLE | 14.0s |
| P6a no `NotBeneficiary` check | `check_P6_claimOnceToBeneficiary` | COUNTEREXAMPLE | 2.1s |
| P6b lock not marked released | `check_P6_claimOnceToBeneficiary` | COUNTEREXAMPLE | 1.7s |
| P7 `onProofAccepted` without `onlyMiningCore` | `check_P7_hooksCoreOnly` | COUNTEREXAMPLE (h = 3) | 0.4s |
| P8a cooldown off by one | `check_P8_unassignRespectsCooldown` | COUNTEREXAMPLE | 1.8s |
| P8b hold compared to `latest + 1` | `check_P8_withdrawRespectsHold` | COUNTEREXAMPLE | 1.3s |
| P9a gate `frozen + 1 < MIN_STAKE` | `check_P9_gateRevertsBelowMinimum` | COUNTEREXAMPLE | 2.4s |
| P9b no `CURVE_UNIT == 0` short-circuit (divides by zero) | `check_P9_curveZeroIsExactlyOne` | COUNTEREXAMPLE | 1.1s |
| P9c bonus cap removed | `check_P9_multiplierNeverAboveThree` | COUNTEREXAMPLE (CURVE_UNIT = 2^249) | 98.6s |
| P10 evictable at `== MIN_STAKE` | `check_P10_evictBacker` | COUNTEREXAMPLE (caller = W0) | 23.4s |

Some properties find counterexamples quickly on a variant but time out on the
unmodified contract: P2', P3/P4, P5, P9a-cached, P9c and P10. For those, the
variant result shows the property is not vacuous, but the property itself is
**not proven**. Finding one counterexample stops at the first bad path;
proving means exhausting every path.

## Unproven targets and why

- **P3 / P4 (all ops), P2', P10.** Each assumes conservation and the one-backer
  bijection over all 5 accounts in a fully arbitrary state: 15 symbolic
  mappings, each address hashed into 5 mapping bases, with equality chains
  between them. Yices does not close the resulting queries within 900s. Next
  step: shrink U to 2 depositors × 1 wallet, or replace the arbitrary state
  with a bounded concrete history (`invariant_*` with halmos
  `--invariant-depth`).
- **P5 (full; the reduced form is PASS), P9a (cached freeze).** These read keccak-derived slots at
  symbolic keys (`_frozen[c][w]`, `_committed[tokenId]`, the Lock struct), which
  multiplies the aliasing cases. The fresh-freeze half of P9a is proven. The
  cached half is a pure read of a stored value, and the concrete suites cover
  it.
- **P9c (full and curve-only).** The combination of `Math.log2` (bit-search branches),
  `mulDiv` and a symbolic divisor (`CURVE_UNIT`) is slow for bit-vector
  solvers.
- **P1a for 9 of 14 operations** was not run within the time budget. The 5 that
  carry money (deposit, assign, withdraw, claim, settle) are proven.

## SMTChecker (solc 0.8.24, CHC)

| Run | Targets | Timeout per query | Result |
|---|---|---|---|
| 1 | assert, underflow, overflow, divByZero | 60 000 ms | **Not finished.** Killed by the 20-minute watchdog after 1216s with no output; solc reached about 4 GB of memory. |
| 2 | same | 10 000 ms | **Not finished.** Killed by host memory pressure while running alongside Halmos. Not retried: the coordinator reduced the SMTChecker run to the assert target only. |
| 3 | assert | 20 000 ms | Completed in 38s, exit 0. **0 verification conditions:** `PrefundedMiningPower.sol` has no `assert` statements, so nothing was proven or refuted. |

Unsupported constructs reported in run 3:

- `address.code.length` in the constructor (lines 390 and 393) and in OZ `SafeERC20`.
- `10 ** result` in OZ `Math.log10`.
- The inline assembly for the transient note (`tload` / `tstore`). SMTChecker
  treats it as a havoc, so any property that depends on the note is out of its
  reach. P5 above covers the note with Halmos instead.

**Underflow, overflow and division-by-zero are all UNPROVEN by SMTChecker.** The
CHC engine did not return within the budget on the full contract. Halmos covers
the same ground for the paths it proves: arithmetic panics are reverts, and
every PASS above holds on the paths that do not revert. Checked 0.8 arithmetic
cannot silently wrap; the risk is a stuck exit. That is what P1b and P2'
target, and P2' is still unproven.
