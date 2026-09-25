# TLA+ model: HunterMiningCore + PrefundedMiningPower (VLT-65, slice S10b, updated for S8b)

`PrefundedMiningPower.tla` models the mining core's wiring rules (`HunterMiningCore.sol`) and
the rules of the stake-gated module (`PrefundedMiningPower.sol`). It covers the stake ledger,
the single-bucket per-mint lock (owner decision 2026-09-25), release, and the failsafe. The
model is checked with TLC. It mirrors the S8b contract (commit 3b7a4f8): backer consent
(`approveBacker`), the failsafe never counting removals, and the eviction withdraw lock.

One TLA+ step is one successful transaction. A transaction that reverts is a stuttering step:
its guard is false, so it changes nothing. That is how "rejected and nothing changes" is
modelled. Every `/\` guard in an action is annotated with the Solidity revert it stands for.

## Running

Tools (not in the repo): a Java 17+ runtime and `tla2tools.jar` (TLC 2.19 was used).

```sh
curl -L -o jre.tar.gz https://api.adoptium.net/v3/binary/latest/21/ga/linux/x64/jre/hotspot/normal/eclipse
mkdir jre && tar xzf jre.tar.gz -C jre --strip-components=1
curl -L -o tla2tools.jar https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar
TLC="jre/bin/java -XX:+UseParallelGC -Xmx4g -cp tla2tools.jar tlc2.TLC -workers 4 -metadir /path/to/scratch/meta"
```

Run these from `formal/tla/`. The broken variants run from `formal/tla/variants/`.

```sh
$TLC -config PrefundedMiningPower.cfg          PrefundedMiningPower.tla   # M1  protocol, two-tx cutover
$TLC -config PrefundedMiningPowerBatched.cfg   PrefundedMiningPower.tla   # M1b protocol, batched cutover
$TLC -config PrefundedMiningPowerLedger.cfg    PrefundedMiningPower.tla   # M2  ledger, two wallets
$TLC -config PrefundedMiningPowerSpecRules.cfg PrefundedMiningPower.tla   # M3  SPEC.md rules only
$TLC -config Liveness.cfg                      PrefundedMiningPower.tla   # liveness (LiveSpec)
$TLC -config checks/NoViewCrossCheck.cfg       PrefundedMiningPower.tla   # VIEW/SYMMETRY cross-check
$TLC -config checks/CurveFailsafe.cfg          PrefundedMiningPower.tla   # F1 fixed (expected to PASS, ~17 min)
$TLC -config checks/<Name>.cfg                 PrefundedMiningPower.tla   # other findings + witnesses (expected to FAIL)
(cd variants && $TLC -config NoHold.cfg NoHold.tla)                       # broken variants (expected to FAIL)
```

Always pass `-metadir` outside the repo, use one metadir per run, and delete it when the run
ends. TLC's state queue for the main runs reaches about 1 GB. Leftover `states/` directories
from killed runs filled the `/tmp` quota during development. The S8b results below used
`-Xmx4g -workers 4`, one run at a time, on a shared machine.

## Constants and configurations

Common to all runs: `Depositors = {d1, d2}`, `MinStake = 2`, `Lock = 1`, `Buyer` (a non-mining
NFT holder), and `CurveEnabled = FALSE` (S0 default 1) unless stated otherwise. Depositors and
wallets are disjoint.

| Config | Wallets | MaxDeposit | MaxTokens | Ids | CutoverMode | S8Rules | S8bRules | CoreChurn | Reduction |
|---|---|---|---|---|---|---|---|---|---|
| `PrefundedMiningPower.cfg` (M1) | {w1} | 2 (3 before S8b) | 2 | unbounded | twoTx | TRUE | TRUE | TRUE | VIEW + SYMMETRY |
| `PrefundedMiningPowerBatched.cfg` (M1b) | {w1} | 2 (3 before S8b) | 2 | unbounded | batched | TRUE | TRUE | TRUE | VIEW + SYMMETRY |
| `PrefundedMiningPowerLedger.cfg` (M2) | {w1, w2} | 2 | 2 | unbounded | twoTx | TRUE | TRUE | FALSE | VIEW + SYMMETRY |
| `PrefundedMiningPowerSpecRules.cfg` (M3) | {w1, w2} | 2 | 2 | unbounded | twoTx | FALSE | FALSE | FALSE | VIEW + SYMMETRY |
| `Liveness.cfg` | {w1}, Depositors {d1} | 2 | 2 | MaxChallenges 2 | twoTx | TRUE | TRUE | FALSE | none |
| `checks/NoViewCrossCheck.cfg` | {w1} | 2 | 2 | MaxChallenges 2 (3 before S8b) | twoTx | TRUE | TRUE | FALSE | none |

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
- `S8bRules` (requires `S8Rules`):
  - `TRUE` adds the S8b rules now in the contract. **Consent:** `approveBacker(d)` by the
    wallet (`ApproveBacker(w, d)`, any state, `d = NoD` clears). Taking an EMPTY slot needs
    `approvedBacker[w] = d` (`BackerNotApproved`); a top-up by the current backer does not;
    `evictBacker` clears the approval if it names the evicted backer. **Failsafe:**
    `_maturedStake` never adds removals back once `gateDisabled` (`RemovalsCount`, every
    later challenge too), `disableRequirement` also sets `holdWaivedEpoch = latest`, and a
    cached freeze above the recomputed matured stake is lowered, never raised (`Cached`).
    **Eviction cooldown:** `evictBacker` sets `withdrawLocked[backer]`; `withdraw` is refused
    while it holds unless the module is retired or the failsafe fired; the explicit
    `CooldownElapses(d)` step clears it.
  - `FALSE` is the S8 contract (or, with `S8Rules = FALSE`, SPEC.md). `ApproveBacker` stays
    enabled in that mode: it records the wallet's intent, which those rules ignore
    (`checks/UnsolicitedBacker.cfg`).
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

The VIEW also drops three kinds of data:

- Informational lock fields: `miner` and `backer`, which are read only on the creating step.
- NFT holder identities: only "live/burned", "burned by a non-miner" and "paid to the
  beneficiary" are kept.
- The S8b state (`approvedBacker`, `withdrawLocked`) once the module is retired or the failsafe
  fired. Both are permanent in the model (retirement needs mint-out or stop, after which
  nothing re-wires), `assign` is refused under either, and the withdraw lock is waived under
  either, so nothing reads that state again. With `S8bRules = FALSE` `approvedBacker` is
  never read by a guard and is dropped too; `OnlyApprovedBackerTakesEmptySlot` is checked in
  that mode only without a VIEW (`checks/UnsolicitedBacker.cfg`).

A VIEW is sound only if nothing bounds the ids, so the main runs set `MaxChallenges` out of
reach. `checks/NoViewCrossCheck.cfg` re-checks the same safety properties with no VIEW, no
SYMMETRY and ids bounded (at 3 before S8b, at 2 since; see Results); it also passes. A VIEW is not used for liveness.

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
| `OnlyApprovedBackerTakesEmptySlot` | action | (S8b) On every step, a wallet whose slot was empty (`assignedOf = 0`) and becomes backed is backed by the depositor it had approved in the pre-state (and it had approved someone). Listed only where `S8bRules = TRUE` |
| `EvictedStakeNotWithdrawnBeforeCooldown` | action | (S8b) No step pays stake out to a depositor (`netIn` falls and its unassigned balance falls) while its eviction lock holds, unless retired or failsafe. Listed only where `S8bRules = TRUE` |
| `EligibleWinnerNeverBlocked` | liveness | Under WF(Submit(w)): `[]<>~CanWin(w)`, so an eligible winner that keeps trying gets through |
| `ExitsAlwaysOpen` | liveness | Under WF of each depositor's unassign-all and withdraw-all: `(retired ∨ gateDisabled) ~> stake(d) = 0` |

## Results (TLC 2.19, S8b model, `-Xmx4g -workers 4`, Temurin 21, shared machine; full logs in the session scratchpad `tla/logs-s8b/*.log`)

| Run | Result | States generated | Distinct | Depth | Time |
|---|---|---|---|---|---|
| M1 `PrefundedMiningPower.cfg` (MaxDeposit 2, see below) | pass (all invariants + action properties, incl. `LockFromCountingStake`, `OnlyApprovedBackerTakesEmptySlot`, `EvictedStakeNotWithdrawnBeforeCooldown`) | 27,972,130 | 2,935,478 | 42 | 13m34s |
| M1b `PrefundedMiningPowerBatched.cfg` (MaxDeposit 2) | pass (same list) | 21,510,786 | 2,250,102 | 40 | 8m03s |
| M2 `PrefundedMiningPowerLedger.cfg` | pass (same list) | 64,659,298 | 5,611,661 | 51 | 24m43s |
| M3 `PrefundedMiningPowerSpecRules.cfg` | pass (all except `LockFromCountingStake` and the two S8b properties, not listed) | 22,523,243 | 2,164,834 | 37 | 9m11s |
| `Liveness.cfg` | pass (both liveness properties) | 1,132,719 | 219,836 | 29 | 1m55s |
| `checks/NoViewCrossCheck.cfg` (MaxChallenges 2) | pass (all safety + action properties, no VIEW, no SYMMETRY) | 64,184,529 | 8,375,805 | 35 | 19m39s |
| `checks/CurveFailsafe.cfg` | **pass** `NoDoubleCount`, `NoDoubleCountStrict`, `StakeNeverLeavesWhileCounting` (F1 fixed) | 64,484,718 | 5,597,394 | 51 | 16m55s |
| `checks/CurveFailsafePreS8b.cfg` | **FAIL** `NoDoubleCount` (F1 before S8b) | 15,112 | 2,717 | 10 | 2s |
| `checks/LockFromCountingStake.cfg` | **FAIL** `LockFromCountingStake` (finding F2, SPEC.md rules) | 48,842 | 8,444 | 11 | 4s |
| `checks/UnsolicitedBacker.cfg` | **FAIL** `OnlyApprovedBackerTakesEmptySlot` (F4, S8 rules without consent) | 476 | 202 | 5 | 2s |
| `checks/TwoTxCutoverGap.cfg` | **FAIL** `WitnessUngatedCutover` (finding F3) | 3,428 | 955 | 6 | 2s |
| `checks/WitnessAdmittedButShort.cfg` | FAIL as intended (non-vacuity) | 30,987 | 5,290 | 10 | 6s |
| `checks/WitnessRewireSameEpoch.cfg` | FAIL as intended (non-vacuity) | 45,568 | 7,623 | 11 | 5s |
| `checks/WitnessClaimToBuyer.cfg` | FAIL as intended (non-vacuity) | 70,675 | 11,723 | 13 | 5s |
| `variants/NoHold` | FAIL `StakeNeverLeavesWhileCounting` | 24,963 | 3,940 | 10 | 3s |
| `variants/TwoBackers` | FAIL `OneBackerPerWallet` | 7,635 | 1,359 | 8 | 2s |
| `variants/NoDetachWaiver` | FAIL `StakeNeverLeavesWhileCounting` | 61,357 | 9,575 | 12 | 4s |
| `variants/NoEvictCooldown` | FAIL `EvictedStakeNotWithdrawnBeforeCooldown` | 17,009 | 2,746 | 10 | 4s |
| `variants/FailsafeEpochOnly` | FAIL `NoDoubleCount` | 41,730 | 6,220 | 11 | 5s |

**Scope change for S8b (M1, M1b).** The S8b state (`approvedBacker`, `withdrawLocked`)
multiplies the graph: M2 went from 607,672 to 5,611,661 distinct states. M1 with
`MaxDeposit = 3` exceeded the 25-minute bound (2.2M distinct states at depth 20 after
7 minutes, queue still growing; the pre-S8b M1 was 2.08M in total), so it was stopped and M1
and M1b now use `MaxDeposit = 2`. What is lost: a single deposit of `MinStake + Lock = 3`
that pays two wins with no top-up (the floor rule with n = 2). Two wins are still reachable in
M1 by a top-up after the first lock. The pre-S8b M1 at `MaxDeposit = 3` passed (S8 rules,
16,922,348 / 2,082,056 / depth 35), and with `CurveEnabled = FALSE` the S8b rules only remove
`assign` / `withdraw` behaviours or change frozen values while the module is not counting.
That argument is reasoned, not re-checked. For the same reason the no-VIEW cross-check now
bounds ids at 2: at 3 it was stopped at 2.9M distinct states, depth 21, after 7 minutes, with
the queue still growing. The pre-S8b cross-check at 3 passed with 3,792,738 distinct states.
At 2 it still covers two challenges, stale-epoch buckets, and the S8b projection.

The distinct counts also grew in M3, which behaves exactly as before (1,264,797 → 2,164,834).
TLC chooses the SYMMETRY representative on the full state before it applies the VIEW, so a
variable the VIEW drops (here `approvedBacker`, which `ApproveBacker` still changes) makes the
symmetry reduction less effective. That is sound; it only costs time.

Depth is the depth of the complete state graph for passing runs, and the counterexample length
for failing runs. Liveness was also checked for non-vacuity (pre-S8b model). A scratch mutation in which the
hold is never waived on retirement or failsafe violates `ExitsAlwaysOpen` (stuttering after 10
steps). That mutation is not a deliverable.

## Design findings

**F1 — Failsafe left withdrawn stake counting. FIXED in S8b; `checks/CurveFailsafe.cfg` now
passes. Only ever mattered with `CURVE_UNIT != 0`.**

Before S8b, `disableRequirement` waived the stake hold (`heldStakeOf` returns 0 when
`gateDisabled`) but `_maturedStake` kept adding back the open epoch's `removingOf`. The pre-S8b
counterexample is kept as `checks/CurveFailsafePreS8b.cfg` (`S8bRules = FALSE`, 9 states):

1. New is attached; the seed becomes ready.
2. d1 deposits 2 and assigns 2 to w1 (pending).
3. The guardian calls `disableRequirement`.
4. Some wallet's `submitProof` is accepted (gate off, no lock). This opens the next challenge,
   so d1's stake is now matured.
5. d1 unassigns 1 (matured, so `removingOf[w1] = 1`) and withdraws it at once (hold waived).

Now `_maturedStake(w1) = 2` while only 1 is in the module (`NoDoubleCount`: 2 > 1). With the
bonus curve on, `powerMultiplierWad` and `eligibilityOf` report stake that has left.

Fixed behaviour (S8b, contract commit 3b7a4f8, modelled with `S8bRules = TRUE`):

- `_maturedStake` never adds `removingOf` back while `gateDisabled`. This holds in every later
  challenge, not just the one open at the failsafe (`RemovalsCount`).
- `disableRequirement` also records `holdWaivedEpoch = latestChallengeId`, as a detach does
  (defence in depth).
- `_freeze` / `_frozenPreview` lower a cached freeze of the latest epoch to the recomputed
  matured stake after the failsafe, and never raise it (`Cached`). In the model this is
  unreachable while counting, because `NoFreezeInOpenChallenge` holds, but it is mirrored.

With these rules, `checks/CurveFailsafe.cfg` (curve on, two wallets, `CoreChurn = FALSE`)
checks `NoDoubleCount`, `NoDoubleCountStrict` and `StakeNeverLeavesWhileCounting` and passes.
Review #2 said that setting `holdWaivedEpoch` once is not enough. The broken variant
`variants/FailsafeEpochOnly` (the old README fix alone) confirms it: stake assigned before
the failsafe and removed in a LATER challenge counts again after it has been withdrawn.
Forge: `test_FailsafeStopsCountingRemovals`, `test_FailsafeLowersCachedFreeze`.

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

**F4 — Unsolicited backer capture (review #3). FIXED in S8b by backer consent;
`OnlyApprovedBackerTakesEmptySlot` holds in M1, M1b and M2.**

Under the S8 rules any depositor with `MIN_STAKE` could take an empty slot. In the review's
attack, the wallet meant the slot for d2 and d1 front-ran d2's first assign. d1 then held the
slot, could not be evicted at or above `MIN_STAKE`, and after its cooldown could front-run the
wallet's proof with a full unassign, so the win could not pay its lock.
`checks/UnsolicitedBacker.cfg` (`S8Rules = TRUE`, `S8bRules = FALSE`, no VIEW) violates
`OnlyApprovedBackerTakesEmptySlot` in 4 states: New is attached, d1 deposits 2, and d1
assigns 2 to w1, which had approved nobody. The review's variant, with w1 having approved d2
first, is the same violation one step later. With `S8bRules = TRUE`, taking an empty slot
requires `approvedBacker[w] = d` (`BackerNotApproved`). The property is checked on every
step, so no other action can fill an empty slot either. An unapproved depositor never takes an
empty slot in any run. Approval is standing: it is not consumed by the assign, and changing it
never evicts the current backer. Top-ups by the current backer need no approval, so the S8
backstops (`FirstAssignBelowMinimum`, `WalletHasCountingRemoval`, `evictBacker`) still apply
unchanged. Evicting the approved backer revokes the approval.

**F5 — Eviction as a cooldown shortcut (review #6). FIXED in S8b;
`EvictedStakeNotWithdrawnBeforeCooldown` holds in M1, M1b and M2.**

`evictBacker` still has no cooldown check of its own, and the slot is freed at once. The
evicted backer's withdrawals, however, wait for its own cooldown (`withdrawLockedUntil`). In
the model, `withdrawLocked[d]` is set by `EvictBacker` and cleared only by `CooldownElapses(d)`.
`withdraw` is refused while it holds, unless the module is retired or the failsafe fired, and
the action property checks every step that pays stake out. Mutation check: the broken variant
`variants/NoEvictCooldown` drops the guard and fails. Scope: the wall-clock cooldown on
`unassign` remains abstracted as always elapsed (see Abstractions). So this checks the lock's
effect on withdrawals, not the timestamp arithmetic. That arithmetic is covered by
`testEvictedStakeKeepsBackerCooldown`.

No other design problem was found. All issue invariants hold in every main run, under the
SPEC.md rules, and under the S8 + S8b rules.

## Broken variants (`variants/`)

Each variant is a textual patch of the main model. It is generated, identical except for the
lines marked `MUTATION`, and its cfg lists only its target invariants.

| Variant | Mutation | Counterexample (minimal) |
|---|---|---|
| `NoHold` | `withdraw` ignores `heldStakeOf` | attach, d1 deposits 2 and assigns 2 to w1, refresh (matured), d1 unassigns 1 (held), d1 withdraws 1: w1 still counts 2 but only 1 is in the module → `StakeNeverLeavesWhileCounting` |
| `TwoBackers` | `assign` drops `WalletAlreadyBacked` | attach, d1 deposits 1, d2 deposits 2, d2 assigns 2 to w1, d1 tops w1 up with 1 → `OneBackerPerWallet` |
| `NoEvictCooldown` | `withdraw` ignores the S8b eviction lock | attach, w1 approves d1, d1 deposits and assigns 2 to w1 (pending), d1 unassigns 1 (pending part, withdrawable), w1 evicts d1 (`withdrawLocked[d1]`), d1 withdraws 1 before its cooldown → `EvictedStakeNotWithdrawnBeforeCooldown` |
| `FailsafeEpochOnly` | the failsafe only records `holdWaivedEpoch` (curve on); `_maturedStake` still adds removals back in later challenges | attach, seed ready, w1 approves d1, d1 deposits and assigns 2 to w1, failsafe (in challenge 1: `holdWaivedEpoch = 1`), a gate-off submit opens challenge 2 (d1's 2 matured), d1 unassigns 1 (matured removal in challenge 2) and withdraws it: w1 still counts 2 with 1 in the module → `NoDoubleCount` (review #2: recording the epoch once is not enough) |
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
| `Assign` | `assign` (S8b: `BackerNotApproved` on an empty slot) | `testApproveBackerRequiredForEmptySlot`, `testSquatterCannotTakeSlotWithoutApproval`, `testSecondBackerRejected`, `testFirstAssignMustReachMinStake`, `testTopUpBelowMinIsFineForExistingBacker`, `testNewBackerRefusedWhileRemovedStakeCounts`, `testTwoDepositorsCannotStealSharedAssignment`, `testSelfAssignmentRule` |
| `Unassign` / `UnassignFrom` | `unassign` / `_unassignFrom` | `testUnassignRemovalAppliesNextChallenge`, `testMaturedUnassignDoesNotLaunderPendingAssignment`, `testCooldownIsPerDepositorAndProofIndependent`, `testBackerClearedWhenStakeReachesZero` |
| `EvictBacker` | `evictBacker` (S8b: raises `withdrawLockedUntil[backer]`, clears a matching `approvedBackerOf`) | `testWalletEvictsSubMinimumBacker`, `testEvictRefusedWhenBackerAtOrAboveMin`, `testOnlyWalletCanEvict`, `testEvictedStakeKeepsBackerCooldown`, `testEvictClearsApproval` |
| `ApproveBacker` | `approveBacker` (S8b) | `testApproveBackerRequiredForEmptySlot`, `testApproveBackerCanBeChangedAndCleared`, `testApproveBackerRejectsSelf` (vacuous in the model), `testApproveBackerAllowedWhenRetiredOrDisabled` |
| `CooldownElapses` | `block.timestamp` reaching `withdrawLockedUntil` (S8b) | `testEvictedStakeKeepsBackerCooldown` |
| `Withdraw` | `withdraw` (+ `heldStakeOf`; S8b: `CooldownNotMet` while `withdrawLockedUntil` runs, waived when retired / failsafe) | `testEvictedStakeKeepsBackerCooldown`, `testEvictCooldownWaivedAfterRetirementOrFailsafe`, `testMaturedUnassignHeldUntilNextSnapshot`, `testPendingUnassignIsImmediatelyWithdrawable`, `testHeldStakeCannotCountTwiceInOneChallenge`, `testHoldWaivedAfterRetirementAndFailsafe` |
| `DisableRequirement` | `disableRequirement` (S8b: records `holdWaivedEpoch`; `_maturedStake` ignores removals and `_freeze` lowers cached values while `gateDisabled`) | `test_FailsafeStopsCountingRemovals`, `test_FailsafeLowersCachedFreeze`, `test_FailsafeOneWayMovesNoFunds`, `test_FailsafeAbsentWhenGuardianZero`, `testGateDisabledRefusesAssignAndWaivesCooldown` |
| `Burn` | transfer / LiveHunt / DirectLoan, then `HunterNFT.redeemAndDestroy` (lifecycle sets `finalBeneficiary`) | `testMinerBurnsAndClaims`, `testTransferMovesRightsToBurner`, `testLiveHuntSaleMovesRightsToCollector`, `testDefaultedLoanMovesRightsToLender`, `testRepaidLoanReturnsRightsToBorrower` |
| `Claim` | `claimCommitted` / `claimCommittedTo` | `testClaimBeforeBurnReverts`, `testNonBeneficiaryClaimReverts`, `testDuplicateClaimReverts`, `testClaimUnknownTokenReverts`, `testClaimToRecipient` |
| `Solvency` (invariant) | `_requireSolvent` | `testCorruptedTotalsBlockEveryExit`, `testFuzz_RandomSequencesConserve` |
| `EligibleWinnerNeverBlockedInv` (invariant) | `eligibilityOf` reasons 0/1/2/4 vs the gate | `testEligibilityReasonFourWhenLiveStakeBelowLock`, `testEligibilityReasonOneWhenModuleNotLive` |

## Abstractions and limitations

- **Amounts are tiny.** `MinStake = 2`, `Lock = 1`, and at most 2 HUNTER per depositor in
  every S8b run (3 in the pre-S8b M1). The properties are about ordering and bookkeeping, not
  magnitudes. The floor rule (n wins from `MinStake + (n-1)·Lock`) from a single deposit was
  exercised up to two wins only by the pre-S8b M1; since S8b, two wins in M1 need a top-up
  (see Results), and `testFloorRuleAllowsExactlyNWins` covers the floor. Partial live
  balances below `LOCK_PER_MINT` are not representable with `Lock = 1` (review #7, F2).
  Measured receipts, fee-on-transfer, hostile tokens and `DebitMismatch` are not modelled:
  token transfers are exact. The Forge hostile suite covers those.
- **Cooldown.** `EXIT_COOLDOWN` is abstracted as always elapsed, so `unassign` is never blocked
  by time. Every cooldown-respecting behaviour is still a behaviour of the model, so safety
  results carry over. The cooldown's own guarantee (no custody hopping before it elapses) is
  not checked here. The S8b eviction lock is modelled explicitly, as the boolean
  `withdrawLocked[d]`. `EvictBacker` sets it even when the backer's cooldown has already run
  out; that case is `EvictBacker` followed at once by `CooldownElapses(d)`, so the model
  over-approximates the contract.
- **PoW, difficulty, digests, tiers, baskets, the curve's value, easing and `tripMining` are
  abstracted.** Any wallet may win an ACTIVE challenge. The curve only matters through
  `CurveEnabled` in the definition of "counting".
- **The transient note is implicit.** Gate, settlement, snapshot and mint are one atomic
  `Submit` step. Replay and forgery of the note, and the counter checks (`CounterMismatch`),
  are covered by Forge tests, not by this model.
- **Old custody is abstract.** It never gates, and only its RetainedAssignments rule
  (`oldRetained`) and the late-attach path are kept.
- **Depositors ∩ Wallets = ∅**, so `SelfAssignment` is vacuous here, for both `assign` and
  `approveBacker` (a wallet approving itself).
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
  `S8bRules` adds the S8b hardening on top of `S8Rules`; M3 runs with both `FALSE`.
- **The S9 `rewiredEpoch` re-freeze is not modelled as its own rule.** Nor is the S8b
  failsafe re-freeze beyond `Cached`. Both lower a CACHED freeze of the open epoch, and
  `NoFreezeInOpenChallenge` shows that no such cache exists while counting.
- **Views without a state change** (`eligibilityOf`, `previewSubmit`, `withdrawableOf`) are
  modelled as the operators `EligibleView`, `Preview` and `Held`.
