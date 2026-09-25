# TLA+ model: HunterMiningCore + PrefundedMiningPower (VLT-65, slice S10b)

`PrefundedMiningPower.tla` models the mining core's wiring rules (`HunterMiningCore.sol`) and
the rules of the stake-gated module (`PrefundedMiningPower.sol`). It covers the stake ledger,
the single-bucket per-mint lock (owner decision 2026-09-25), release, and the failsafe. The
model is checked with TLC.

One TLA+ step is one successful transaction. A transaction that reverts is a stuttering step:
its guard is false, so it changes nothing. That is how "rejected and nothing changes" is
modelled. Every `/\` guard in an action is annotated with the Solidity revert it stands for.

## Running

Tools (not in the repo): a Java 17+ runtime and `tla2tools.jar` (TLC 2.19 was used).

```sh
curl -L -o jre.tar.gz https://api.adoptium.net/v3/binary/latest/21/ga/linux/x64/jre/hotspot/normal/eclipse
mkdir jre && tar xzf jre.tar.gz -C jre --strip-components=1
curl -L -o tla2tools.jar https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar
TLC="jre/bin/java -XX:+UseParallelGC -Xmx6g -cp tla2tools.jar tlc2.TLC -workers auto -metadir /tmp/tlc-meta"
```

Run these from `formal/tla/`. The broken variants run from `formal/tla/variants/`.

```sh
$TLC -config PrefundedMiningPower.cfg          PrefundedMiningPower.tla   # M1  protocol, two-tx cutover
$TLC -config PrefundedMiningPowerBatched.cfg   PrefundedMiningPower.tla   # M1b protocol, batched cutover
$TLC -config PrefundedMiningPowerLedger.cfg    PrefundedMiningPower.tla   # M2  ledger, two wallets
$TLC -config PrefundedMiningPowerSpecRules.cfg PrefundedMiningPower.tla   # M3  SPEC.md rules only
$TLC -config Liveness.cfg                      PrefundedMiningPower.tla   # liveness (LiveSpec)
$TLC -config checks/NoViewCrossCheck.cfg       PrefundedMiningPower.tla   # VIEW/SYMMETRY cross-check
$TLC -config checks/<Name>.cfg                 PrefundedMiningPower.tla   # findings + witnesses (expected to FAIL)
(cd variants && $TLC -config NoHold.cfg NoHold.tla)                       # broken variants (expected to FAIL)
```

Always pass `-metadir` outside the repo. TLC's state queue for the main runs reaches about
1 GB. Leftover `states/` directories from killed runs filled the `/tmp` quota during
development.

## Constants and configurations

Common to all runs: `Depositors = {d1, d2}`, `MinStake = 2`, `Lock = 1`, `Buyer` (a non-mining
NFT holder), and `CurveEnabled = FALSE` (S0 default 1) unless stated otherwise. Depositors and
wallets are disjoint.

| Config | Wallets | MaxDeposit | MaxTokens | Ids | CutoverMode | S8Rules | CoreChurn | Reduction |
|---|---|---|---|---|---|---|---|---|
| `PrefundedMiningPower.cfg` (M1) | {w1} | 3 | 2 | unbounded | twoTx | TRUE | TRUE | VIEW + SYMMETRY |
| `PrefundedMiningPowerBatched.cfg` (M1b) | {w1} | 3 | 2 | unbounded | batched | TRUE | TRUE | VIEW + SYMMETRY |
| `PrefundedMiningPowerLedger.cfg` (M2) | {w1, w2} | 2 | 2 | unbounded | twoTx | TRUE | FALSE | VIEW + SYMMETRY |
| `PrefundedMiningPowerSpecRules.cfg` (M3) | {w1, w2} | 2 | 2 | unbounded | twoTx | FALSE | FALSE | VIEW + SYMMETRY |
| `Liveness.cfg` | {w1}, Depositors {d1} | 2 | 2 | MaxChallenges 2 | twoTx | TRUE | FALSE | none |
| `checks/NoViewCrossCheck.cfg` | {w1} | 2 | 2 | MaxChallenges 3 | twoTx | TRUE | FALSE | none |

What each constant means:

- `MaxDeposit` bounds each depositor's `unassigned + assigned`. It is a model bound, not a
  contract rule.
- `MaxTokens` is `MAX_NFTS_EVER`, so reaching it is the mint-out.
- `S8Rules`:
  - `FALSE` means exactly the SPEC.md rules.
  - `TRUE` adds the S8 rules now in the contract: the first assign must be at least
    `MIN_STAKE` (decision 8); no new backer while a removal still counts (decision 9,
    `WalletHasCountingRemoval`); `evictBacker`; and `deposit` refused once the module is
    retired or the failsafe has fired.
- `CoreChurn`:
  - `TRUE` models the old `MiningPowerCustody` ("Old"), the stop sunset, and
    `attachMiningPowerLate`.
  - `FALSE` keeps power in {None, New} and drops the sunset. The module cannot tell Old from
    None, and the sunset only removes behaviours. So M2/M3 over-approximate every
    module-visible behaviour of M1 with two wallets.
- `CutoverMode`:
  - `batched`: a module swap is only `setMiningPower(0); setMiningPower(x)` in one
    transaction, for example a Safe multiSend (`Cutover(x)`).
  - `twoTx`: detach and attach are separate transactions (`DetachTx`, `AttachTx`).

**Why a VIEW.** Challenge ids are real naturals in the model, so ids grow without bound.
`ViewMap` canonicalises them relative to `latestChallengeId`. This is a bisimulation quotient,
because the contract only ever compares an epoch tag with `latest`/`active` (`==` or `<`):

- A stale-tagged bucket (`pendingOf`, `removingOf`, `pendingBy`, `heldBy`) reads exactly as a
  zeroed one.
- `holdWaivedEpoch`, `baseEpoch` and the frozen record matter only through equality with
  `latest`/`active`.

The VIEW also drops two kinds of data:

- Informational lock fields: `miner` and `backer`, which are read only on the creating step.
- NFT holder identities: only "live/burned", "burned by a non-miner" and "paid to the
  beneficiary" are kept.

A VIEW is sound only if nothing bounds the ids, so the main runs set `MaxChallenges` out of
reach. `checks/NoViewCrossCheck.cfg` re-checks the same safety properties with no VIEW, no
SYMMETRY and ids bounded at 3; it also passes. A VIEW is not used for liveness.

## Properties checked

The names follow the issue. "Counting" means the module is the live one and the frozen stake
influences something: `wired /\ ~retired /\ (~gateDisabled \/ CurveEnabled)`. The counted
value of a wallet is its recorded freeze for the challenge, or else what `_freeze` would record
now (`Preview`). The core freezes only inside an accepted `submitProof`, and every acceptance
closes its challenge. So the checked quantity is the would-be freeze of every wallet in every
state, which dominates the recorded ones (`NoFreezeInOpenChallenge` checks this premise).

| Name | Kind | Statement |
|---|---|---|
| `TypeOK` | inv | Types; epoch tags ≤ latest; bucketed pending ≤ assigned |
| `WiredTracksCore` | inv | `wired ⇒ power = New`; New attached and core live ⇒ wired, not retired, `latest = active` |
| `LedgerConsistent` | inv | Wallet pending bucket = its backer's pending share; `removingOf[w]` = sum of the ghost per-depositor removals |
| `Solvency` | inv | balance = Σunassigned + ΣassignedOf + unreleased locks; totalStake / totalAssigned / totalCommitted equal their sums; balance ≥ totalStake + totalCommitted |
| `NoDoubleCount` | inv | Counting ⇒ Σ_w counted(w) ≤ deposited − withdrawn |
| `NoDoubleCountStrict` | inv | Counting ⇒ Σ_w counted(w) ≤ totalStake (excludes locked stake) |
| `OneBackerPerWallet` | inv | `assignedOf[w] > 0` ⇒ exactly one depositor has stake on w, it is `backerOf[w]`, and `assignedBy[backer] = assignedOf[w]` |
| `StakeNeverLeavesWhileCounting` | inv | Counting ⇒ for each depositor d: the stake counted for the open challenge that is attributable to d (d's matured assigned stake plus d's counted matured removals, tracked by an independent ghost) ≤ d's stake still in the module |
| `LockIffMint` | inv | lock(t) exists ⇔ t minted while New was wired with the gate enabled |
| `OneLockPerToken` | inv | Each lock is written at most once and its amount is `Lock` |
| `ReleaseOnceAfterBurnToBeneficiary` | inv | Released at most once, only after the burn, only to `finalBeneficiary` |
| `FrozenVsLive` | action | A gated acceptance happens only if frozen ≥ MinStake and live ≥ Lock, and charges exactly the live stake of the wallet's backer. Steps without a mint never change freezes or locks (a rejected submit changes nothing) |
| `CutoverNoGap` | inv | batched: no ungated `submitProof` inside any cutover. twoTx: no ungated submit inside a gap that stayed entirely in WAITING_FOR_SEED (history flags `inGap`, `gapAllWaiting`, `gapSubmit`) |
| `PostSunsetPermanent` | action | After the sunset: whether New is wired never changes; `stopped` never changes; the only pointer change left is the one-time late attach of a fresh old-type custody |
| `RewireSameEpochLowersOnly` | inv | After detach → attach into the same challenge, every wallet's counted value ≤ its value at the detach (ghost `baseline`) |
| `LocksMonotone` | action | Locks are never rewritten; releases are never undone |
| `NoFreezeInOpenChallenge` | inv | Counting ⇒ no wallet is frozen for the still-open challenge |
| `EligibleWinnerNeverBlockedInv` | inv | If `eligibilityOf(w)` says eligible, the core is ACTIVE, and (gate on ⇒ live ≥ Lock), then `ENABLED Submit(w)` |
| `ExitsOpenInv` | inv | retired ∨ gateDisabled ⇒ every depositor can unassign all and withdraw all now, and its hold is 0 |
| `LockFromCountingStake` | inv | (extra) A lock is paid from stake that was matured, i.e. counted, for the challenge it settles |
| `EligibleWinnerNeverBlocked` | liveness | Under WF(Submit(w)): `[]<>~CanWin(w)`, so an eligible winner that keeps trying gets through |
| `ExitsAlwaysOpen` | liveness | Under WF of each depositor's unassign-all and withdraw-all: `(retired ∨ gateDisabled) ~> stake(d) = 0` |

## Results (TLC 2.19, 8 workers, Temurin 21; full logs in the session scratchpad `tla/logs/*.log`)

| Run | Result | States generated | Distinct | Depth | Time |
|---|---|---|---|---|---|
| M1 `PrefundedMiningPower.cfg` | pass (all invariants + action properties + `LockFromCountingStake`) | 16,922,348 | 2,082,056 | 35 | 3m16s |
| M1b `PrefundedMiningPowerBatched.cfg` | pass | 13,051,272 | 1,600,132 | 35 | 2m31s |
| M2 `PrefundedMiningPowerLedger.cfg` | pass | 3,827,009 | 607,672 | 37 | 1m13s |
| M3 `PrefundedMiningPowerSpecRules.cfg` | pass (all except `LockFromCountingStake`, not listed) | 8,153,738 | 1,264,797 | 36 | 2m12s |
| `Liveness.cfg` | pass (both liveness properties) | 217,799 | 56,353 | 24 | 43s |
| `checks/NoViewCrossCheck.cfg` | pass (all safety, no VIEW) | 19,803,610 | 3,792,738 | 34 | 9m26s |
| `checks/CurveFailsafe.cfg` | **FAIL** `NoDoubleCount` (finding F1) | 9,525 | 2,539 | 10 | 8s |
| `checks/LockFromCountingStake.cfg` | **FAIL** `LockFromCountingStake` (finding F2, SPEC.md rules) | 33,161 | 7,711 | 11 | 3s |
| `checks/TwoTxCutoverGap.cfg` | **FAIL** `WitnessUngatedCutover` (finding F3) | 3,717 | 1,128 | 6 | 2s |
| `checks/WitnessAdmittedButShort.cfg` | FAIL as intended (non-vacuity) | 11,447 | 2,871 | 9 | 3s |
| `checks/WitnessRewireSameEpoch.cfg` | FAIL as intended (non-vacuity) | 18,361 | 4,390 | 10 | 3s |
| `checks/WitnessClaimToBuyer.cfg` | FAIL as intended (non-vacuity) | 22,847 | 5,509 | 11 | 5s |
| `variants/NoHold` | FAIL `StakeNeverLeavesWhileCounting` | 6,649 | 1,844 | 9 | 5s |
| `variants/TwoBackers` | FAIL `OneBackerPerWallet` | 2,083 | 681 | 8 | 3s |
| `variants/NoDetachWaiver` | FAIL `StakeNeverLeavesWhileCounting` | 15,725 | 4,073 | 12 | 5s |

Depth is the depth of the complete state graph for passing runs, and the counterexample length
for failing runs. Liveness was also checked for non-vacuity. A scratch mutation in which the
hold is never waived on retirement or failsafe violates `ExitsAlwaysOpen` (stuttering after 10
steps). That mutation is not a deliverable.

## Design findings

**F1 — Failsafe leaves withdrawn stake counting. Applies to the current contract; only matters
with `CURVE_UNIT != 0`.**

`disableRequirement` waives the stake hold (`heldStakeOf` returns 0 when `gateDisabled`). It
does not record `holdWaivedEpoch`, so `_maturedStake` keeps adding back that epoch's
`removingOf`. Minimal trace (`checks/CurveFailsafe.cfg`, 9 states):

1. d1 deposits 2.
2. The seed becomes ready.
3. New is attached.
4. d1 assigns 2 to w1 (pending).
5. The guardian calls `disableRequirement`.
6. Some wallet's `submitProof` is accepted (gate off, no lock). This opens challenge 2, so d1's stake is now matured.
7. d1 unassigns 1 (matured → `removingOf[w1] = 1`, `heldBy[d1] = 1`).
8. d1 withdraws 1. This is allowed because the hold is waived.

Now `_maturedStake(2, w1) = 2` while only 1 is in the module (`NoDoubleCount`: 2 > 1).

Impact: with the gate off nothing is gated, but `powerMultiplierWad` still returns
`multiplierFromLockedAmount(frozen)`, and `eligibilityOf` reports that stake. With the bonus
curve enabled, a wallet's multiplier is driven by stake that has left. With the S0 default
`CURVE_UNIT = 0` it has no effect, which is why the main runs use `CurveEnabled = FALSE`.

Fix: in `disableRequirement`, set `holdWaivedEpoch = latestChallengeId`, as
`onMiningPowerDetached` does. Alternatively, skip `removingOf` in `_maturedStake` when
`gateDisabled`.

**F2 — Under the SPEC.md rules, a lock can be paid from stake that did not count. Fixed in the
contract by S8 decision 9 only in the narrower sense that a DIFFERENT backer never pays for a win
admitted on the previous backer's removed stake; confirmed by TLC for the modelled amounts. The
same backer's partial removal plus re-assign is not covered (review #7, below).**

With `S8Rules = FALSE` (`checks/LockFromCountingStake.cfg`, 11 states):

1. New is attached; d1 deposits 2 and assigns 2 to w1.
2. A refresh opens challenge 2 (d1's stake is matured) and the seed becomes ready.
3. d1 unassigns 2 (`removingOf[w1] = 2`, held).
4. d1 re-assigns 1 to w1, which is pending in challenge 2.
5. w1 submits. The gate admits on 0 + 2 removed, and settlement charges the live 1, which is
   the pending stake.

With a second depositor d2 in step 4, this is the old
`testLimitation_NewBackerPaysWinAdmittedOnRemovedStake`: d2 pays for a win it did not qualify.
With `S8Rules = TRUE`, `LockFromCountingStake` holds in M1 and M2 (`WalletHasCountingRemoval`
refuses step 4, including for the same depositor).

Scope of that result (independent review #7): `WalletHasCountingRemoval` only guards an EMPTY
slot. A backer that removes only PART of its matured stake keeps the slot and may re-assign held
stake to the same wallet as a pending top-up; a win admitted on the frozen stake (which still
includes the removal) then consumes that pending top-up with the rest of the live stake (e.g.
minimum 1,000, lock 100: remove 950 of 1,000, re-assign 50, win: the whole live 100 is locked).
Per the review, the model's amounts do not cover partial live balances below `LOCK_PER_MINT`,
so `LockFromCountingStake` passing does NOT mean held stake can never be locked. What
is established is narrower: a DIFFERENT backer never pays for a win admitted on the previous
backer's removed stake, and every lock is full-sized and charged to the wallet's current backer.

**F3 — A two-transaction cutover has an ungated window. Operational: the core does not enforce
the safe ordering.**

`setMiningPower` has no challenge-state check. Minimal trace (`checks/TwoTxCutoverGap.cfg`,
6 states):

1. The seed becomes ready (ACTIVE).
2. The multisig attaches Old.
3. The multisig detaches (tx 1).
4. Any miner's `submitProof` is accepted with no module and no lock.
5. The multisig attaches (tx 2).

Even a gap that starts in WAITING_FOR_SEED is unsafe if the seed becomes readable before tx 2
lands. `CutoverNoGap` for twoTx shows that an ungated submit requires the gap to leave WAITING,
but nothing makes both transactions land in the same WAITING window. The batched flavour (M1b)
has no gap. Recommendation: perform every swap as one batched transaction (Safe multiSend) and
never as two transactions. An NFT minted in the gap simply has no lock
(`testPreCutoverNftHasNothingCommitted`); nothing is lost, but it is an unintended ungated mint.

No other design problem was found. All issue invariants hold in every main run, under both the
SPEC.md rules and the S8 rules.

## Broken variants (`variants/`)

Each variant is a textual patch of the main model. It is generated, identical except for the
lines marked `MUTATION`, and its cfg lists only its target invariants.

| Variant | Mutation | Counterexample (minimal) |
|---|---|---|
| `NoHold` | `withdraw` ignores `heldStakeOf` | attach, d1 deposits 2 and assigns 2 to w1, refresh (matured), d1 unassigns 1 (held), d1 withdraws 1: w1 still counts 2 but only 1 is in the module → `StakeNeverLeavesWhileCounting` |
| `TwoBackers` | `assign` drops `WalletAlreadyBacked` | attach, d1 deposits 1, d2 deposits 2, d2 assigns 2 to w1, d1 tops w1 up with 1 → `OneBackerPerWallet` |
| `NoDetachWaiver` | `onMiningPowerDetached` does not set `holdWaivedEpoch` | attach, d1 deposits and assigns 2 to w1, refresh (matured), detach, d1 unassigns 2 (matured removal), d1 withdraws 1 (hold waived while detached), re-attach into the same challenge: w1 counts the full removal of 2 again, but only 1 is in the module → `StakeNeverLeavesWhileCounting` |

A fourth mutation was tried and rejected as a variant: dropping the settlement check
`live >= LOCK`. It cannot fail. With `backerOf = 0` the wallet has 0 live stake, and in
Solidity 0.8 `assignedOf[w] - L` would revert on underflow anyway. The explicit
`InsufficientFunds` check is defence in depth, not load-bearing.

## Mapping: TLA+ action → Solidity → Forge tests

| TLA+ action | Solidity | Forge tests |
|---|---|---|
| `SeedReady`, `Expire` | `HunterMiningCore.challengeState()` (block-derived) | `testStaleIdSeedWaitingExpiredRejected` |
| `Refresh` | `refreshExpiredSeed` → `snapshotChallenge(id+1)` | `testSeedRefreshOpensEpochWithoutLock` |
| `Submit` / `SubmitNew` | `submitProof` → `powerMultiplierWad` (gate, `_freeze`, note) → `onProofAccepted` → `_settleLock` → `snapshotChallenge` or `_retireMiningPower(true)` → `PROOF_NFT.mint` | `testEligibleDirectSubmissionMintsAndLocksOnce`, `testIneligibleRevertsWithReasonAndNoStateChange`, `testStakeAssignedAfterScheduleCountsNextChallenge`, `testLockDeductedFromLiveStakeNotFrozen`, `testRemovedStakeAdmitsButLiveStakeBelowLockReverts`, `testRemovedStakeAdmitsAndLiveStakePaysLock`, `testFloorRuleAllowsExactlyNWins`, `testGateDisabledSkipsChecksAndWritesNoNote`, `testExistingLockNeverOverwritten`, `testMintOutLocksFinalNftThenOpensExits`, `testFuzz_PreviewMatchesGate` |
| `SubmitUngated` | `submitProof` with `miningPower == 0` or old custody | `testFuzz_DifficultyMatchesUngatedCore`, `testPreCutoverNftHasNothingCommitted` |
| `DetachTx` | `setMiningPower(0)` → `onMiningPowerDetached(false)` | `testAttachDetachBookkeeping`, `testDetachWaivesHoldAndRewiredEpochIgnoresReleasedRemoval`, `testExitsWorkUnwiredDetachedAndRetired` |
| `AttachTx` | `setMiningPower(x)` → `snapshotChallenge(active)` (RetainedAssignments / re-wire) + bootstrap `onProofAccepted` | `testAttachBootstrapRecordsNoLock`, `testSetMiningPowerRequiresDetachBeforeRewire`, `testAssignRefusedUnwiredDetachedRetiredAndAllowedWhenWired` |
| `Cutover` | `setMiningPower(0); setMiningPower(x)` in one batch | none (recommendation F3) |
| `LateAttachOld` | `attachMiningPowerLate` (old-type custody only) | `testLateAttachGuardMatrix`, `testPriorAttachConsumesTheOneTimeSlot`, `testPostSunsetAttachBindsCanonicalTokenAndCore` |
| `StopMining` | `stopMining` → `_retireMiningPower(true)` | `testStopMiningAndTripMiningOpenExits`, `testStopMiningRetiresWiredModule`, `testClaimAfterMiningStoppedStillPays` |
| `SunsetPass` (+ `PostSunsetPermanent`) | `MINING_STOP_SUNSET` checks in `setMiningPower` / `stopMining` | `testSunsetBoundary`, `testLimitation_PostSunsetModuleIsPermanent`, `testSetMiningPowerSunsetAndEndedRefuse` |
| `OldUsers` | `MiningPowerCustody.assign` / `unassign` (abstract) | `testHarnessOldCustodyAttachesAndDetaches` |
| `Deposit` | `deposit` | `testStakeRoundTripConserves`, `testFeeOnTransferCreditsMeasuredReceipt`, `testOverReceiptPolicy`, `testNoNewEntriesAfterRetirement` |
| `Assign` | `assign` | `testSecondBackerRejected`, `testFirstAssignMustReachMinStake`, `testTopUpBelowMinIsFineForExistingBacker`, `testNewBackerRefusedWhileRemovedStakeCounts`, `testTwoDepositorsCannotStealSharedAssignment`, `testSelfAssignmentRule` |
| `Unassign` / `UnassignFrom` | `unassign` / `_unassignFrom` | `testUnassignRemovalAppliesNextChallenge`, `testMaturedUnassignDoesNotLaunderPendingAssignment`, `testCooldownIsPerDepositorAndProofIndependent`, `testBackerClearedWhenStakeReachesZero` |
| `EvictBacker` | `evictBacker` | `testWalletEvictsSubMinimumBacker`, `testEvictRefusedWhenBackerAtOrAboveMin`, `testOnlyWalletCanEvict` |
| `Withdraw` | `withdraw` (+ `heldStakeOf`) | `testMaturedUnassignHeldUntilNextSnapshot`, `testPendingUnassignIsImmediatelyWithdrawable`, `testHeldStakeCannotCountTwiceInOneChallenge`, `testHoldWaivedAfterRetirementAndFailsafe` |
| `DisableRequirement` | `disableRequirement` | `test_FailsafeOneWayMovesNoFunds`, `test_FailsafeAbsentWhenGuardianZero`, `testGateDisabledRefusesAssignAndWaivesCooldown` |
| `Burn` | transfer / LiveHunt / DirectLoan, then `HunterNFT.redeemAndDestroy` (lifecycle sets `finalBeneficiary`) | `testMinerBurnsAndClaims`, `testTransferMovesRightsToBurner`, `testLiveHuntSaleMovesRightsToCollector`, `testDefaultedLoanMovesRightsToLender`, `testRepaidLoanReturnsRightsToBorrower` |
| `Claim` | `claimCommitted` / `claimCommittedTo` | `testClaimBeforeBurnReverts`, `testNonBeneficiaryClaimReverts`, `testDuplicateClaimReverts`, `testClaimUnknownTokenReverts`, `testClaimToRecipient` |
| `Solvency` (invariant) | `_requireSolvent` | `testCorruptedTotalsBlockEveryExit`, `testFuzz_RandomSequencesConserve` |
| `EligibleWinnerNeverBlockedInv` (invariant) | `eligibilityOf` reasons 0/1/2/4 vs the gate | `testEligibilityReasonFourWhenLiveStakeBelowLock`, `testEligibilityReasonOneWhenModuleNotLive` |

## Abstractions and limitations

- **Amounts are tiny.** `MinStake = 2`, `Lock = 1`, and at most 2–3 HUNTER per depositor. The
  properties are about ordering and bookkeeping, not magnitudes. The floor rule (n wins from
  `MinStake + (n-1)·Lock`) is exercised only up to two wins (M1). Measured receipts,
  fee-on-transfer, hostile tokens and `DebitMismatch` are not modelled: token transfers are
  exact. The Forge hostile suite covers those.
- **Cooldown.** `EXIT_COOLDOWN` is abstracted as always elapsed, so `unassign` is never blocked
  by time. Every cooldown-respecting behaviour is still a behaviour of the model, so safety
  results carry over. The cooldown's own guarantee (no custody hopping before it elapses) is
  not checked here.
- **PoW, difficulty, digests, tiers, baskets, the curve's value, easing and `tripMining` are
  abstracted.** Any wallet may win an ACTIVE challenge. The curve only matters through
  `CurveEnabled` in the definition of "counting".
- **The transient note is implicit.** Gate, settlement, snapshot and mint are one atomic
  `Submit` step. Replay and forgery of the note, and the counter checks (`CounterMismatch`),
  are covered by Forge tests, not by this model.
- **Old custody is abstract.** It never gates, and only its RetainedAssignments rule
  (`oldRetained`) and the late-attach path are kept.
- **Depositors ∩ Wallets = ∅**, so `SelfAssignment` is vacuous here.
- **NFT transfer is folded into the burn.** `Burn(t, h)` means "held by h, then burned by h".
  Escrow and loans appear only as "burned by the miner or by someone else".
- **Scope is split for tractability.** Two wallets are checked with `CoreChurn = FALSE` (M2/M3),
  and the full core churn with one wallet (M1). The combined 2-wallet, full-churn, 2-token scope
  exceeded 8M distinct states (over 25 minutes) and was not completed.
- **Liveness is checked in a small scope** without VIEW: one depositor, one wallet, ids ≤ 2.
  `EligibleWinnerNeverBlocked` assumes weak fairness on that wallet's submission.
  `ExitsAlwaysOpen` assumes weak fairness on the depositor's own unassign-all and withdraw-all.
- **SPEC.md vs current contract.** SPEC.md says `deposit` is always allowed. The S8 contract
  refuses it after retirement or failsafe. `S8Rules` switches between the two, and both pass.
- **Views without a state change** (`eligibilityOf`, `previewSubmit`, `withdrawableOf`) are
  modelled as the operators `EligibleView`, `Preview` and `Held`.
