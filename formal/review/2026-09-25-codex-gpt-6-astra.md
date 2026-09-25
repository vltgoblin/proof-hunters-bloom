# Independent review: Codex gpt-6-astra, 2026-09-25

Tool: OpenAI Codex CLI 0.156.1, model gpt-6-astra, reasoning effort high, sandbox read-only, run against commit e75fb41 of this branch. Brief: adversarial security review of PrefundedMiningPower against the core, NFT, lifecycle, old custody, tests and the TLA+ findings. Dispositions are tracked on Linear VLT-64.

---

I found no way to mint a missing or undersized lock **while this module is attached and enforcing**, using the supplied core and NFT. The following findings cover operational bypasses, griefing, exit restrictions, and misleading guarantees. Known findings are identified below.

1. **High — A cutover gap can become permanently ungated at sunset.**  
   **Location:** `HunterMiningCore.setMiningPower`, [HunterMiningCore.sol:479](contracts/src/bloom/HunterMiningCore.sol:479); `submitProof`, line 355.

   **Sequence:** The multisig detaches the current module in one transaction. Before the attach transaction lands, a miner submits a valid proof. Both module calls are skipped, so the NFT has no lock. If the attach lands after `MINING_STOP_SUNSET`, it reverts and mining remains ungated permanently. The late-attachment route cannot rescue a replacement: the previous attachment already consumed `miningPowerWasAttached`.

   Starting during `WAITING_FOR_SEED` only postpones the risk; it does not make two transactions atomic.

   **Fix:** Perform detach and attach in one reverting batch, before sunset, and verify the resulting pointer. Treat a separately submitted detach as an explicit transition to ungated mining. This is **known formal finding F3**, with a more severe outcome when the gap crosses sunset.

2. **Medium — The failsafe permits withdrawn stake to retain its mining bonus.**  
   **Location:** `disableRequirement`, [PrefundedMiningPower.sol:713](contracts/src/bloom/PrefundedMiningPower.sol:713); `heldStakeOf`, line 814; `_maturedStake`, line 1073.

   **Sequence:** A wallet has matured stake. The guardian disables the requirement. Its backer unassigns and withdraws that stake immediately because the hold is waived. Nevertheless, `_maturedStake` adds the removal back, and `powerMultiplierWad` still applies the curve to it. With `CURVE_UNIT != 0`, a miner can obtain a bonus using tokens that have left the module.

   **Fix:** Permanently exclude removals when `gateDisabled`, or return the base multiplier immediately after failsafe activation if the intended outcome is entirely unweighted mining. Merely setting `holdWaivedEpoch` once, as suggested in the README, does **not** cover removals in subsequent challenges.

   This is **known formal finding F1**. With `CURVE_UNIT == 0`, the stale stake has no effect on proof difficulty.

3. **Medium — An unsolicited backer can capture a miner’s slot and invalidate its work.**  
   **Location:** `assign`, [PrefundedMiningPower.sol:579](contracts/src/bloom/PrefundedMiningPower.sol:579); `evictBacker`, line 662; `_settleLock`, line 887.

   **Sequence:** An attacker front-runs a legitimate backer’s first assignment with `MIN_STAKE`. The legitimate assignment then fails, and the miner cannot evict the attacker while its assignment remains at least `MIN_STAKE`. After the cooldown expires, the attacker watches for the miner’s proof and front-runs it by unassigning everything. The frozen stake still passes the gate, but settlement fails because the live assignment is zero.

   A replacement backer is blocked by `WalletHasCountingRemoval` for the current challenge. Its eventual assignment is then pending for another challenge. The attacker’s stake is recoverable; the cost is capital availability and transaction fees. Repetition requires winning subsequent transaction-ordering races.

   **Fix:** Require the mining wallet’s approval or signature before a depositor can acquire its empty backer slot. The minimum assignment increases the attack’s capital requirement but does not establish consent.

4. **Medium — Cutover can strand recent depositors in the old custody indefinitely.**  
   **Location:** `MiningPowerCustody.unassign`, [MiningPowerCustody.sol:179](contracts/src/bloom/MiningPowerCustody.sol:179); new-module gate, [PrefundedMiningPower.sol:435](contracts/src/bloom/PrefundedMiningPower.sol:435).

   **Sequence:** A depositor assigns shortly before cutover and still needs up to twelve accepted proofs to exit the old custody. After cutover, nobody has enough available HUNTER to qualify in the new module. Seed refreshes advance challenges but not accepted-proof counts, so the old assignment never unlocks. If the available staking supply is itself trapped in recent old assignments, this becomes a circular dependency.

   After sunset, keyed stop and replacement are unavailable. A missing or unavailable failsafe guardian leaves no guaranteed recovery path.

   **Fix:** Make legacy exit completion a cutover requirement, or secure sufficient independent stake and mining capacity to complete the outstanding proof delays before sunset. Retain a usable failsafe until those exits are satisfied.

   This limitation is already demonstrated by `testLimitation_OldCustodyExitWaitsDuringStall`; the new wall-clock cooldown does not repair old deposits.

5. **Medium — A failed basket payout can strand an otherwise solvent mint lock; permissionless materialisation can trigger the dependency.**  
   **Location:** `_release`, [PrefundedMiningPower.sol:928](contracts/src/bloom/PrefundedMiningPower.sol:928); `HunterLifecycle.onBurn`, [HunterLifecycle.sol:274](contracts/src/bloom/HunterLifecycle.sol:274); `materialise`, [WeightedRoundMaterialisation.sol:147](contracts/src/bloom/WeightedRoundMaterialisation.sol:147).

   **Sequence:** A live NFT has a funded, unmaterialised basket entitlement. The basket token begins refusing outbound transfers. Anyone can materialise the entitlement, adding positive backing without calling the token. Burning now attempts that basket payout and reverts. Consequently, the module refuses to release the HUNTER lock, even though its own tokens are healthy and fully funded.

   Reserve payout failures also prevent burning. `claimCommittedTo` cannot help because it operates only after a successful burn.

   **Fix:** Independent recovery requires the lifecycle/backing system to record the burn and preserve payouts as separately claimable obligations. This cannot be repaired solely in this module while retaining the required completed-burn condition. With an immutable lifecycle, this dependency must be accepted and addressed through token admission restrictions.

   The basic payout dependency is already covered by the companion tests; permissionless materialisation makes it relevant to third-party griefing.

6. **Low — Cooperating miner/backer addresses can bypass the wall-clock cooldown through eviction.**  
   **Location:** `evictBacker`, [PrefundedMiningPower.sol:659](contracts/src/bloom/PrefundedMiningPower.sol:659); `_unassignFrom`, line 974.

   **Sequence:** A win leaves an assignment below `MIN_STAKE`. The backer adds a small pending top-up that keeps the total below the minimum, restarting its cooldown. The cooperating miner immediately evicts the backer. The pending portion becomes withdrawable immediately; the matured portion becomes withdrawable after the next snapshot, potentially well before the cooldown expires.

   This does **not** let stake leave while it still counts. It does defeat an unconditional wall-clock exit restriction. The exemption is documented, but having different caller addresses does not prevent cooperation.

   **Fix:** Let eviction clear the backer relationship immediately while retaining the depositor’s remaining withdrawal cooldown on returned assigned funds. Otherwise, explicitly define eviction as an exception to the design’s cooldown guarantee.

7. **Info — The “held stake can never be locked” statement and formal conclusion overstate the guarantee.**  
   **Location:** contract NatSpec, [PrefundedMiningPower.sol:109](contracts/src/bloom/PrefundedMiningPower.sol:109); `assign`, line 604; `_settleLock`, line 896; [formal/tla/README.md:184](formal/tla/README.md:184).

   **Sequence:** With minimum 1,000 and lock 100, a backer starts with 1,000 matured stake, unassigns 950, and reassigns 50 from that held balance. It retains its backer slot throughout. The wallet now has 100 live stake, including 50 pending, while its frozen stake remains 1,000. A win consumes the entire 100, including the reassigned held portion.

   The lock remains full-sized and charges the correct backer. However, the claim that held stake cannot be locked is false, and the README’s broader claim that `LockFromCountingStake` is fixed does not hold for this partial-removal sequence. Existing settlement tests already demonstrate consumption of pending top-ups.

   **Fix:** Document that held funds can be reassigned and subsequently consumed by settlement. Narrow the formal conclusion to preventing a **different backer** from paying against the previous backer’s removal, and expand model amounts to cover partial live balances below `LOCK_PER_MINT`.

Outside those findings:

- **Accounting:** I found no additional conservation, single-backer, pending-bucket, or hold bypass under a balance-conserving token. Settlement moves exactly `LOCK_PER_MINT` from stake to commitments.
- **Reentrancy and callbacks:** I found no lock forgery, replay, premature release, or double payout. There is no intervening attacker callback between gate and settlement. Failed submissions and failed burns roll back their nested effects.
- **Hostile tokens:** Inbound fees are measured; outbound recipient taxes can reduce actual proceeds despite a full nominal lock. Pauses, blacklists, dishonest balance reports, or negative rebases remain token-level risks. Insolvency blocks exits, while hooks deliberately continue without checking token balances.
- **Hooks and gas:** The module hooks make no HUNTER calls and contain no depositor-dependent loops. I found no population-driven hook DoS. The failsafe intentionally allows future lock-free mints; existing locks remain subject to burn and solvency checks.

I read the requested contracts, tests and helpers, including the existing untracked invariant files. Direct Solidity 0.8.24 compilation succeeded: runtime size was 23,257 bytes unoptimized and 13,228 bytes optimized. Forge attempts under both configured profiles stopped at a stack-depth compilation error in `PrefundedMiningPowerSettlement.t.sol:706` with dynamic test linking enabled; no test-pass claim is made. No files were modified.

**Overall verdict:** The enforced mint-and-lock path is coherent, and I found no direct theft or missing-lock exploit within that path. Mainnet deployment still needs the curve/failsafe issue resolved, atomic cutover enforced operationally, and legacy exits secured. Backer consent, cooldown exceptions, and the immutable burn-payout dependency also need explicit resolution or acceptance; the tests and formal results do not establish those broader guarantees.