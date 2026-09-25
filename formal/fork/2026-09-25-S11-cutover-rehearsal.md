# S11 (VLT-62): mainnet-fork rehearsal of the cutover and the module's journey

This work was **read-only against Robinhood Chain (4663)**. Nothing was broadcast and no key was used:
- every state change ran inside a local Foundry fork, with the stop account impersonated by `vm.prank`;
- the only calls to the real node were reads: `cast block/call/logs/code/nonce`, plus `eth_call` simulations with a code override.

Tools: pinned forge/cast 1.7.1. The RPC URL was passed only through the `FORK_RPC_URL` environment variable.

Test file: `contracts/test/fork/PrefundedForkRehearsal.t.sol`. It is new and uncommitted.

Run artefacts (the `s11/` folder in the scratchpad):
- run logs: `run-*.log` and `ethcall.log`;
- pinned headers: `pin-*.json`;
- the run script: `run.sh`;
- calldata: `runbook-tx1.hex`, `runbook-tx2.hex`, `runbook-7702-calldata.hex` and `ctor-args.hex`;
- module code: `creation-{default,release}.hex`, `deploy-data-{default,release}.hex` and `runtime-{default,release}.hex`.

How to run. Pin a fresh block immediately before the run:

```
B=$(cast block-number)
P=$(cast block $B --json | jq -r .l1BlockNumber | cast to-dec)
FORK_RPC_URL=<rpc> FORK_BLOCK=$B FORK_PARENT_BLOCK=$P forge test --root contracts --match-path 'test/fork/PrefundedForkRehearsal.t.sol' -j 2 -vv
```

- `FORK_PARENT_BLOCK` is required when forked, because `vm.rpc` does not return the header as JSON. `setUp` checks the value for plausibility against `lastProofBlock` and the active seed.
- Build first. A release-profile build takes about 3.5 min, and the public RPC dropped state for a pin roughly 10–12 min old during this session, faster than S1's 20–30 min.

## Pinned blocks

| run | L2 block | L2 timestamp (UTC) | parent (L1) block = core clock | profile / spec | result |
|---|---|---|---|---|---|
| r1 (first full run) | 71915486 | 1790307835 (03:43:55) | 26051858 | default / cancun | 9/9 pass |
| t7702-cancun (trace `-vvvv`) | 71916674 | 1790307956 (03:45:56) | 26051868 | default / cancun | 7702 test passes |
| t7702-prague | 71916957 | 1790307985 (03:46:25) | 26051870 | default / `--evm-version prague` | 7702 test passes |
| eth_call on the real node | 71923861 | 1790308678 (03:57:58) | 26051928 | n/a (real ArbOS execution) | see §5b |
| **final-default** | **71931039** | **1790309409 (04:10:09)** | **26051988** | default (no optimizer) / cancun | **9/9 pass** |
| **final-release** | **71932054** | **1790309513 (04:11:53)** | **26051996** | release (optimizer 200) / cancun | **9/9 pass** |
| **final-prague** | **71933043** | **1790309613 (04:13:33)** | **26052005** | default / prague | **9/9 pass** |

Live state at the final pins:
- `acceptedProofs` = `nftsMintedEver` = 452 (S1 had 450).
- `activeChallengeId` = 466.
- `activeSeedParentBlock` = 26051788 and `lastProofBlock` = 26051785.
- `challengeState` at the parent clock = 1 (ACTIVE).
- 4,856,584 s (about 56.2 days) remain to the sunset.

## Results per test (the three final runs; each test logs its L2 pin, timestamp and parent block)

| # | test | default @71931039 | release @71932054 | prague @71933043 | what it proves |
|---|---|---|---|---|---|
| 1 | testRuntimeMatchesReleaseManifest | PASS | PASS | PASS | The extcodehash of core, NFT, lifecycle, reserve, old custody and HUNTER equals the S1 values. |
| 2 | testLiveWiringAndAuthority | PASS | PASS | PASS | `miningPower` is the old custody. `miningPowerWasAttached` holds, the sunset is 1795166097, and `MINING_STOP_MULTISIG` is 0xEE95…6C15. The stop account's code is `0xef0100` followed by **0x63c0c19a282a1B52b07dD5a65b58948A07DAE32B** (delegate codehash 0xa06befcb…e6b0, 11185 bytes). |
| 3 | testDeployModuleAgainstLiveCore | PASS | PASS | PASS | The module deploys against the live token and core, and all 7 immutables, plus unwired, not retired and not disabled, are as expected (hashes in §6). |
| 4 | testCutoverTwoTransactionsFromAuthority | PASS | PASS | PASS | See §4 below. |
| 5 | testCutoverAtomic7702Batch | PASS | PASS | PASS | See §5 below. It passed in all three runs, including the two that used the Cancun spec. |
| 6 | testJourneyWithOverriddenTarget (SIMULATION) | PASS | PASS | PASS | See §6 below. |
| 7 | testLiveTokenBehaviourAgainstModule | PASS | PASS | PASS | Deposit and withdraw of 1e18 with the live HUNTER, before and after wiring: credited exactly, withdrawn exactly, no tax, supply unchanged. |
| 8 | testPostSunsetPermanence | PASS | PASS | PASS | See §8 below. |
| 9 | testOldCustodyExitAfterCutoverForRealDepositor (SIMULATION) | PASS | PASS | PASS | See §9 below. |

Details for the longer rows:

- **4. Two-transaction cutover.** `vm.prank(stop, stop)` sends `setMiningPower(0)` and then `setMiningPower(module)`.
  - The pointer becomes the module. The module is wired, its `latestChallengeId` equals `core.activeChallengeId` (466), and its `lastAcceptedProofs` is 452.
  - The old custody ends up unwired and not retired, with its clock frozen at 452. A third party gets `UnauthorizedMiningStopCaller`.
  - **All four real old-custody depositors** unassign and withdraw at once under the live 12-proof rule. Their proof indices are 2, 9, 46 and 120, against 452. Afterwards the custody holds 0 assigned, 0 locked and a HUNTER balance of 0. All 6,014,424 HUNTER are returned exactly.
- **5. Atomic batch.** The account's own `execute(bytes32,bytes)` runs a batch of detach then attach. It emits exactly two `MiningPowerSet` events in order (0, then the module), both with `caller` = the stop account, and no `ProofAccepted` inside.
  - The probe batch [detach, attach, attach] reverts with `MiningPowerAlreadyWired(module)`, so the pointer is the module *inside the same transaction*.
  - The wrong order reverts atomically. A third party gets `NotEntryPointOrSelf`.
  - Right after the batch, an unstaked wallet is refused with `NotEligible(2)`.
- **6. Journey.** It covers the cutover, then a target override. A funder is dealt 1000 HUNTER, deposits it, and the wallet calls `approveBacker(funder)`. The funder assigns: the stake is pending (reason 2) in the challenge the attach opened.
  - After `refreshExpiredSeed` the wallet is eligible.
  - A real proof is mined through the live core, mints token **453** and takes a lock of 100e18 (miner = wallet, backer = funder).
  - The live `redeemAndDestroy` gives `finalBeneficiary` = wallet, `alive` = false and `reserve.settled` = true.
  - `claimableOf` returns (true, wallet, 100e18). The funder gets `NotBeneficiary`. The wallet's `claimCommitted` pays 100e18 exactly, and `totalCommitted` returns to 0.
- **8. Post-sunset permanence.**
  - At `timestamp` = SUNSET the setter still works; that call was snapshotted and reverted.
  - At SUNSET + 1, `setMiningPower` and `stopMining` revert with `MiningStopSunsetPassed(1795166097, 1795166098)`, and the module stays attached.
  - `disableRequirement`: a third party gets `UnauthorizedCaller`, and the guardian (the stop account) succeeds once; a second call gets `GateDisabled`.
  - With the gate disabled, an unstaked wallet then mines through the live core with no lock (simulation).
- **9. Real depositor exit.** The real depositor 0xA135…3C65 (9,314 HUNTER on wallet 0x5220…9C2B) tops up by 1 HUNTER and re-assigns before the cutover, which resets its proof index to 452. After the two-transaction cutover:
  - unassign reverts `UnlockDelayNotMet(464, 452)`;
  - a funded wallet on the new module (1000 + 11×100 HUNTER) mines 11 real proofs, and unassign still reverts `(464, 463)`;
  - the 12th real proof makes unassign succeed, while the custody's own clock stays at 452;
  - the withdrawal of 9,315 HUNTER pays exactly;
  - the wallet ends at 900 < MIN, the floor rule.

Run without `FORK_RPC_URL`: `forge test --root contracts --match-path 'test/fork/*'` compiles, and all **18 tests are skipped** (9 S1 + 9 S11), with 0 passed and 0 failed.

## Runbook calldata (placeholders marked)

Addresses:
- core: `0xF213854c6D5D4334D23D452574556bD53CA24c2C`
- stop account (the sender and, for (b), also the target): `0xEE951AA16F261B31B921E54FCA6bA2074b496C15`
- **MODULE PLACEHOLDER:** `0x000000000000000000000000000000000000dEaD`. Replace the last 20 bytes of the attach word with the deployed module address.

### (a) Two transactions from the stop account (plain type-2 transactions, value 0, `to` = core)

The selector is `setMiningPower(address)` = `0x9fd0ab38`.

- **tx 1 (detach):** `0x9fd0ab380000000000000000000000000000000000000000000000000000000000000000`
- **tx 2 (attach):** `0x9fd0ab38000000000000000000000000000000000000000000000000000000000000dEaD`. Put the module in place of dEaD.

Between tx 1 and tx 2 the core has no module, and **anyone can mine ungated**. The S9 mitigation is to send both inside the WAITING_FOR_SEED window. That window is the 3 parent blocks after an accepted proof, while `block.number ≤ activeSeedParentBlock`, about 36–48 s at 12.1 s per parent block. On this chain the L2 produces about 360 blocks in that time, so a two-transaction sequence fits easily if it is sent promptly. It is still one key signing two separate transactions.

### (b) Atomic ERC-7579 batch through the account's EIP-7702 delegation (one transaction, `from` = `to` = stop account, value 0)

The ABI this assumes is MetaMask Delegation Framework's EIP7702StatelessDeleGator 1.3.0, confirmed live at 0x63c0…E32B:
- `execute(bytes32 mode, bytes executionCalldata)`, selector `0xe9ae5c53`, guarded by `onlyEntryPointOrSelf` (error `NotEntryPointOrSelf()` = `0x0796d945`);
- `mode` = `0x0100…00`: ERC-7579 callType BATCH (0x01), execType DEFAULT (0x00, reverts if any call fails), modeSelector 0 and payload 0. `supportsExecutionMode` returns true for it both live and on the fork;
- `supportsExecutionMode` also returns true for 0x00… (single) and 0x0101… (batch, try). It returns **false** for ERC-7821's `0x01000000000078210001…` opData mode, so do not use that mode;
- `executionCalldata` = `abi.encode(Execution[])`, where `Execution` = `(address target, uint256 value, bytes callData)`.

The batch is [(core, 0, detach), (core, 0, attach(module))], with the module shown as the dEaD placeholder:

```
0xe9ae5c53010000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000
0000000040000000000000000000000000000000000000000000000000000000
0000000200000000000000000000000000000000000000000000000000000000
0000000020000000000000000000000000000000000000000000000000000000
0000000002000000000000000000000000000000000000000000000000000000
0000000040000000000000000000000000000000000000000000000000000000
0000000100000000000000000000000000f213854c6d5d4334d23d452574556b
d53ca24c2c000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000
0000000060000000000000000000000000000000000000000000000000000000
00000000249fd0ab380000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000f213854c6d5d4334d23d452574556b
d53ca24c2c000000000000000000000000000000000000000000000000000000
0000000000000000000000000000000000000000000000000000000000000000
0000000060000000000000000000000000000000000000000000000000000000
00000000249fd0ab380000000000000000000000000000000000000000000000
00000000000000dead0000000000000000000000000000000000000000000000
0000000000
```

The fork test and `cast calldata 'execute(bytes32,bytes)' 0x01… $(cast abi-encode 'f((address,uint256,bytes)[])' …)` produce byte-identical calldata. To substitute the module, replace the single `…dead` word, which is the second inner call's argument.

### Module deployment (PLACEHOLDER parameters)

Constructor: `(address hunterToken, address miningCore, uint256 minStake, uint256 lockPerMint, uint256 exitCooldown, uint256 curveUnit, address failsafeGuardian)`.

The placeholder values are HUNTER 0xBBDD…7960, core 0xF213…4c2c, MIN_STAKE = 1_000e18, LOCK = 100e18, cooldown = 86400, curveUnit = 0 and guardian = the stop account 0xEE95…6C15. **These are not launch decisions.** Encoded:

```
0x000000000000000000000000bbdd439fd49ade6ff3c96f748867de4356647960000000000000000000000000f213854c6d5d4334d23d452574556bd53ca24c2c00000000000000000000000000000000000000000000003635c9adc5dea000000000000000000000000000000000000000000000000000056bc75e2d6310000000000000000000000000000000000000000000000000000000000000000151800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000ee951aa16f261b31b921e54fca6ba2074b496c15
```

| profile | creation bytes | keccak(creationCode) | keccak(creation ++ args) = deploy data | runtime bytes | **extcodehash after deploy** |
|---|---|---|---|---|---|
| **release** (solc 0.8.24, cancun, optimizer 200; the profile S1 matched the live stack against) | 14828 | 0x73fda95161f2b55d32a9ec14f85690dee6c5d451c8db2ebd24c07852f240e9f9 | 0x09528c2ce44f23662e5af60ae656ebcb2cde6d4d4b1be3a7f1cfe1de7ce3c25b | 14091 | **0x7e6302b3844faa01d51d6e27098c7c0d406b321c5231aa811fcbb52aeb988af5** |
| default (no optimizer) | 26370 | 0x018849288cd7f94314add7059131a4c9275f41e0a99d21590e65be3d415cb4f4 | 0x6c42b25c91cce5fd8c15a4f2f2ca352e9ba3f4bac58c913898cf2f45c8fb0175 | 25028 | 0xefd731910de6b2f967cd8c069a33e36bfbbfb80fa339cbe8fa59f0796d0829b4 |

- The extcodehash includes the immutables, so it is valid only for exactly these constructor arguments and this source (HEAD 7c683f4; PrefundedMiningPower.sol is unmodified in the worktree).
- Both runtime hashes were reproduced twice: once by the fork deploy, and once by `eth_call` of the creation code plus arguments on the real node (`cast call --create`). That eth_call only simulates the constructor; nothing was deployed.
- The CBOR metadata hash inside the code depends on the exact source text and compiler settings. Any change to the source, even in a comment, changes these hashes.

## 5b. Real-node eth_call checks of the batch (L2 71923861, parent 26051928)

These ran as `eth_call` on the real ArbOS node, which **does execute the 7702 delegation**, with `from` = the stop account. The release runtime from the row above was code-overridden at the 0xdEaD placeholder. Nothing was broadcast.

| call | result |
|---|---|
| the runbook batch above, from = to = stop account | **success (`0x`)**: the detach and the attach both pass the core's `msg.sender == MINING_STOP_MULTISIG` check, and the module's `snapshotChallenge` and `onProofAccepted` run |
| probe batch [detach, attach, attach] | reverts `0xec0b1cee…dead` = `MiningPowerAlreadyWired(0x…dEaD)`: the pointer is the module within one transaction |
| wrong order [attach, detach] | reverts `MiningPowerAlreadyWired(0x73a9…F306)` |
| the runbook batch sent by a third party | reverts `NotEntryPointOrSelf()` |
| tx 1 alone (stop account → core, `setMiningPower(0)`) | success |
| tx 2 alone before a detach | reverts `MiningPowerAlreadyWired(old custody)` |
| `setMiningPower(0)` from a non-stop sender | reverts `UnauthorizedMiningStopCaller(0x…bAd0)` (`0xab6d9954`) |

## What was and was not verified about the 7702 batch

**Verified:**
- The live delegate's ABI, the batch mode's support, and the self-call semantics: `msg.sender` inside `setMiningPower` equals the stop account, both on the fork (from the `MiningPowerSet.caller` topic) and on the real node through `eth_call`.
- Atomicity (wrong order and the probe both revert as a whole).
- That the pointer changes inside a single transaction.
- That a third party cannot trigger the batch.

**Not verified:**
- Signing, the account nonce, and fee payment. The real transaction is an ordinary type-2 transaction from the EOA to itself; the delegation is already installed, so no type-4 authorization is needed.
- The ERC-4337 EntryPoint path.
- That the delegation is still the same at cutover time. The stop key can re-delegate at any moment with a type-4 transaction, so this must be re-checked.
- A real broadcast. On a fork, `vm.prank(stop, stop)` stands in for the signed transaction; that is faithful for `msg.sender` and `tx.origin` but not for gas or nonce.

**No ungated window.** A single transaction's calls execute back to back, and the EVM cannot interleave another transaction between two inner calls of one transaction. So no `submitProof` can land between the detach and the attach. The recorded logs show no `ProofAccepted` between the two `MiningPowerSet` events, and a probe `submitProof` from an unstaked wallet right after the batch is refused. A proof mined in the same block *before* the batch runs against the old (optional) custody; one mined *after* it is gated.

## Where the fork differs from mainnet

1. **`block.number`.** A Foundry fork uses the L2 number (about 71.9M). On chain, `block.number` is the parent (L1) block (about 26.05M). `setUp` runs `vm.roll(FORK_PARENT_BLOCK)`. `vm.roll` does not change the L2 timestamp. All rolls forward (seed expiry, the 12 proofs) are simulated future time.
2. **Seed blockhashes** are set with `vm.setBlockhash` and do not equal ArbOS's recorded values. The digests, and therefore which nonces win, are fork-only.
3. **`currentTarget` is overridden** by `vm.store` in slot 4, to `type(uint256).max >> 3` (1 in 8), in tests 5, 6, 8 and 9. This is a labelled simulation, not live difficulty. The live target is about 1 in 6e10 hashes.
4. **Impersonation.** Pranks stand in for the stop account and for the real depositors, two of whom are themselves 7702-delegated EOAs. HUNTER balances come from `deal` (storage writes), not from real purchases.
5. **EIP-7702 on the fork.** Forge 1.7.1 **executed the delegation even with `evm_version = "cancun\"`**, so the Cancun runs also exercised the real DeleGator code (the `-vvvv` trace shows `execute` running and the inner calls). The `--evm-version prague` run gives identical results and gas.
   - With solc 0.8.24, the `prague` flag compiled the same `cancun` bytecode (verified byte-equal); it only changed the runtime spec.
   - The test's skip branch (7702 not honoured, so skip with a message) therefore never triggered in this session.
   - The S1 note "Cancun forks do not execute 7702 delegations" was **not reproduced** with `forge test`.
6. **Gas and fees are not rehearsed.** Measured: the 7702 batch costs about 127k gas in the fork trace (the 3-call probe that reverts costs about 132k). The stop account holds 0.0361 ETH and the gas price is about 0.04 gwei, so fees are not a constraint.

## Checklist: the real cutover must re-verify at a fresh block (within 24 h, ideally within the same hour)

1. Code:
   - `extcodehash` of core, NFT, lifecycle, reserve, old custody and HUNTER equals the table in test 1;
   - the deployed module's `extcodehash` equals the release value above *for the final constructor arguments*; recompute it if any parameter differs from the placeholders;
   - `module.HUNTER`, `miningCore`, `MIN_STAKE`, `LOCK_PER_MINT`, `EXIT_COOLDOWN`, `CURVE_UNIT` and `FAILSAFE_GUARDIAN` hold the final values; the module is unwired with `totalAssigned` = 0.
2. Core state:
   - `miningPower` = old custody 0x73a9…F306;
   - `miningPowerWasAttached` holds and `miningStopped` = false;
   - `nftsMintedEver` < 5000;
   - `block.timestamp` is well below 1795166097 (2026-11-20 09:14:57 UTC). The setter is dead from `timestamp` > SUNSET, and after that the module is permanent.
3. Stop account:
   - `MINING_STOP_MULTISIG` = 0xEE95…6C15;
   - its code is still `0xef0100 63c0c19a282a1b52b07dd5a65b58948a07dae32b` (for path b). If the delegation has changed, re-derive the ABI or fall back to path (a);
   - its ETH balance is enough for gas;
   - its nonce is known, and there are no pending transactions from the key (the nonce moved 14 → 15 since S1).
4. Re-simulate the exact final calldata with `eth_call` from the stop account at the latest block. Expected results:
   - the batch succeeds;
   - the probe batch reverts `MiningPowerAlreadyWired(<module>)`;
   - or, for path (a), tx 1 succeeds.
5. Timing:
   - for path (a), watch for a `ProofAccepted` and send both transactions inside the 3-parent-block WAITING_FOR_SEED window;
   - for path (b), no window is needed.
6. After sending, read back:
   - `miningPower` = module;
   - `module.wired` holds;
   - `module.latestChallengeId` = `core.activeChallengeId`;
   - `module.lastAcceptedProofs` = `core.acceptedProofs`;
   - the old custody has `wired` = false and `retired` = false;
   - there are exactly two `MiningPowerSet` events from the stop account.
7. Expect a stall of up to one challenge after the attach: no wallet can be eligible in the challenge the attach opened. Mining resumes after seed expiry (about 52 min) and a permissionless `refreshExpiredSeed`. Backers should deposit before the attach (deposit is open while unwired) and assign right after it.
8. Old custody: re-read `totalAssigned` and `totalLocked`, and the depositors' `assignProofIndex`. Any depositor who assigned within the last 12 proofs waits for 12 proofs on the new module.
9. Re-run this suite with a fresh `FORK_BLOCK` / `FORK_PARENT_BLOCK`. Build first; the pin goes stale in about 10 min.

## Surprises

1. **The fork executes EIP-7702 under Cancun** with forge 1.7.1, which contradicts the S1 note. The batch was therefore rehearsed faithfully under every profile, and it was also confirmed on the real node with `eth_call`.
2. **The stop account's nonce went from 14 (S1, pin B2, 03:21 UTC) to 15 (03:43 UTC).** The stop key signed one transaction in that window. The delegation and the core wiring are unchanged at the final pins. The transaction was not identified, because the non-archive RPC no longer serves that state. The operator should confirm it was theirs.
3. **Two of the four real old-custody depositors are 7702-delegated EOAs:**
   - 0xC388…4315 (5M HUNTER) delegates to the same MetaMask DeleGator, 0x63c0…E32B;
   - 0x60Ca…d332 (1M HUNTER) delegates to 0xe6cae83bde06e4c305530e199d7217f42808555b, which was not identified.

   Both exit fine on the fork, because a HUNTER transfer makes no receiver call.
4. **Every real depositor is already matured.** Their proof indices are 2 to 120, against 452, so today nobody is subject to the 12-proof delay after a cutover. Test 9 had to create a recent assignment on purpose, through a real top-up by a real depositor.
5. The custody logs show 5 Assigned, 5 Deposited, 0 Unassigned and 0 Withdrawn events: nobody has ever exited the old custody.
6. `vm.rpc` does not return a JSON header, so the parent block must be supplied as `FORK_PARENT_BLOCK`.
7. The RPC's state window was shorter than S1 measured: about 10–12 min.
