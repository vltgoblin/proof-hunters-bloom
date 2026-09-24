// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {HunterMiningCore} from "../src/bloom/HunterMiningCore.sol";
import {MiningPowerCustody} from "../src/bloom/MiningPowerCustody.sol";
import {IMiningPower} from "../src/bloom/IMiningPower.sol";
import {PrefundedMiningPower} from "../src/bloom/PrefundedMiningPower.sol";
import {PrefundedMiningStack} from "./helpers/PrefundedMiningStack.sol";
import {PrefundedCutoverBatch, PrefundedCutoverEncoding} from "./helpers/PrefundedCutoverBatch.sol";

/// @notice S9 (VLT-60) cutover from the live OLD `MiningPowerCustody` to
/// `PrefundedMiningPower` on the REAL stack: every hook call comes from the
/// real `HunterMiningCore` (`setMiningPower`, `submitProof`,
/// `refreshExpiredSeed`, `stopMining`). The single exception is
/// `testRewireIntoSameChallengeRefreezesLowerOnly`, which must plant a
/// cached freeze for the open challenge through a pranked core call — see
/// its NatSpec for why the real core cannot produce one.
/// @dev The module under test uses MIN_STAKE 1_000e18, LOCK 100e18, a 1 hour
/// exit cooldown, no bonus and GUARDIAN as failsafe key. Every test starts
/// with the old custody attached by the `STOP` EOA (the live situation)
/// except `testSafeStyleBatchLeavesNoUngatedWindow`, which builds a SECOND
/// real stack whose `MINING_STOP_MULTISIG` is a Safe-style batch contract
/// (option (a): the multisig is an immutable of the core, so a contract
/// multisig needs its own core; the harness `_buildStack` is the same code
/// path `setUp` uses, so both stacks are wired identically).
/// All amounts are TEST-ONLY fixture values.
contract PrefundedMiningPowerCutoverTest is PrefundedMiningStack {
    address internal constant CAROL = address(0xCA201);
    address internal constant MINER2 = address(0x222E);
    address internal constant OUTSIDER = address(0x0B5E);
    address internal constant GUARDIAN = address(0x6A2D);

    uint256 private constant MIN = 1_000e18;
    uint256 private constant LOCK = 100e18;
    uint256 private constant COOLDOWN = 1 hours;

    uint8 private constant WAITING_FOR_SEED = uint8(HunterMiningCore.ChallengeState.WAITING_FOR_SEED);

    function setUp() public override {
        super.setUp();
        _deployModule(MIN, LOCK, COOLDOWN, 0, GUARDIAN);
        _attachOld();
    }

    // ------------------------------------------------------------------
    // Cutover transaction shapes
    // ------------------------------------------------------------------

    /// @notice With a contract multisig the detach and the attach run in ONE
    /// transaction (a Safe `multiSend` batch), so no submission can ever see
    /// the core without a module. The old module is optional power before
    /// the batch; the new one is a hard gate right after it.
    function testSafeStyleBatchLeavesNoUngatedWindow() public {
        PrefundedCutoverBatch batch = new PrefundedCutoverBatch(address(this));
        _buildStack(address(batch));
        _deployModule(MIN, LOCK, COOLDOWN, 0, GUARDIAN);
        assertEq(core.MINING_STOP_MULTISIG(), address(batch));

        // The Safe wires the old custody (the live situation), depositors join.
        batch.exec(address(core), abi.encodeCall(core.setMiningPower, (IMiningPower(address(oldCustody)))));
        assertTrue(oldCustody.wired());
        _mixedOldDepositors();

        // The STOP EOA has no power over this core.
        vm.prank(STOP);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.UnauthorizedMiningStopCaller.selector, STOP));
        core.setMiningPower(IMiningPower(address(0)));

        // Old module = optional power: an unstaked wallet mines at base.
        uint256 free = _win(OUTSIDER);
        (uint256 freeLock,,,,,) = module.committedOf(free);
        assertEq(freeLock, 0);

        // A backer prefunds the new module before the cutover (deposit is
        // open while unwired; assign is not).
        _deposit(ALICE, MIN);

        // Wrong order (attach before detach) fails atomically: nothing changes.
        bytes memory wrong = bytes.concat(
            PrefundedCutoverEncoding.packCall(address(core), PrefundedCutoverEncoding.attachCalldata(address(module))),
            PrefundedCutoverEncoding.packCall(address(core), PrefundedCutoverEncoding.detachCalldata())
        );
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.MiningPowerAlreadyWired.selector, address(oldCustody)));
        batch.multiSend(wrong);
        assertEq(address(core.miningPower()), address(oldCustody));
        assertTrue(oldCustody.wired());

        // THE cutover: one call, detach then attach.
        uint256 proofsBefore = core.acceptedProofs();
        vm.recordLogs();
        batch.multiSend(PrefundedCutoverEncoding.cutoverTransactions(address(core), address(module)));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(address(core.miningPower()), address(module));
        assertTrue(module.wired());
        assertFalse(oldCustody.wired());
        assertFalse(oldCustody.retired()); // non-terminal: old exits keep their proof delay
        assertEq(core.acceptedProofs(), proofsBefore);
        assertEq(module.latestChallengeId(), core.activeChallengeId());
        assertEq(module.lastAcceptedProofs(), proofsBefore);

        // Inside that one transaction: detach then attach, both by the Safe,
        // and no proof was accepted between them.
        uint256 sets;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(core)) continue;
            assertTrue(logs[i].topics[0] != HunterMiningCore.ProofAccepted.selector, "proof inside the batch");
            if (logs[i].topics[0] != HunterMiningCore.MiningPowerSet.selector) continue;
            address power = address(uint160(uint256(logs[i].topics[1])));
            assertEq(power, sets == 0 ? address(0) : address(module), "batch order");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), address(batch));
            sets++;
        }
        assertEq(sets, 2);

        // Right after the batch an unstaked wallet is refused...
        _activate();
        (uint256 n,) = _nonce(OUTSIDER);
        _expectNotEligible(2);
        _send(OUTSIDER, n);
        // ...and so is the old custody's biggest wallet (old stake never counts).
        (n,) = _nonce(OLD_MATURED_WALLET);
        _expectNotEligible(2);
        _send(OLD_MATURED_WALLET, n);

        // A qualified wallet mines from the next snapshot, with a lock.
        _assign(ALICE, MINER, MIN);
        (n,) = _nonce(MINER);
        _expectNotEligible(2); // pending in the challenge the attach opened
        _send(MINER, n);
        _nextChallenge();
        uint256 id = _win(MINER);
        (uint256 amount,,, address miner, address backer, bool released) = module.committedOf(id);
        assertEq(amount, LOCK);
        assertEq(miner, MINER);
        assertEq(backer, ALICE);
        assertFalse(released);
        _assertBooks();
    }

    /// @notice With the STOP EOA the cutover is TWO transactions. Sent inside
    /// the WAITING_FOR_SEED window that follows an accepted proof (the seed
    /// parent block is `SEED_DELAY_PARENT_BLOCKS` = 3 blocks ahead), no
    /// submission can land between them. Missing the window (negative
    /// branch) lets anyone mine ungated until the attach lands — the EOA
    /// risk — although the attach itself still works before the sunset.
    function testEoaSequenceInsideWaitingWindow() public {
        _mixedOldDepositors();
        _win(OLD_SOLO); // accepted at block B; next seed parent is B + 3
        uint256 acceptedAt = block.number;
        assertEq(core.activeSeedParentBlock(), acceptedAt + core.SEED_DELAY_PARENT_BLOCKS());
        assertEq(uint8(core.challengeState()), WAITING_FOR_SEED);

        _detach(); // tx 1
        cid = core.activeChallengeId();
        seed = core.activeSeedParentBlock();
        uint256 snap = vm.snapshotState();

        // Safe branch: no submission can run while the core waits for the seed.
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.ChallengeNotActive.selector, WAITING_FOR_SEED));
        core.submitProof(cid, seed, 0, basket);
        vm.roll(seed); // the last waiting block
        assertEq(uint8(core.challengeState()), WAITING_FOR_SEED);
        vm.prank(OUTSIDER);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.ChallengeNotActive.selector, WAITING_FOR_SEED));
        core.submitProof(cid, seed, 0, basket);
        _attach(module); // tx 2, still inside the window
        assertEq(module.latestChallengeId(), cid);

        _activate(); // seed readable: ACTIVE, gated
        assertEq(uint8(core.challengeState()), uint8(HunterMiningCore.ChallengeState.ACTIVE));
        (uint256 n,) = _nonce(OUTSIDER);
        _expectNotEligible(2);
        _send(OUTSIDER, n);
        _assertBooks();

        // Negative branch: tx 2 is late — past the seed delay with no module.
        vm.revertToState(snap);
        assertEq(address(core.miningPower()), address(0));
        uint256 free = _win(OUTSIDER); // ungated base mining
        assertEq(nft.ownerOf(free), OUTSIDER);
        free = _win(OUTSIDER);
        assertEq(module.lastAcceptedProofs(), 0); // the module never saw them
        assertEq(module.totalCommitted(), 0); // and took no lock
        // The late attach still works before the sunset and gates from then on.
        assertLt(block.timestamp, core.MINING_STOP_SUNSET());
        _attach(module);
        _activate();
        (n,) = _nonce(OUTSIDER);
        _expectNotEligible(2);
        _send(OUTSIDER, n);
    }

    /// @notice S0 default 4 (strict): stake counts only from the NEXT snapshot
    /// after it is assigned — including right after attach. Nothing can be
    /// assigned before the attach (`NotWired`), so the challenge the attach
    /// opens has NO eligible wallet: expect a one-challenge stall. Worst
    /// case, attaching in the block that accepted the last old-module proof,
    /// the next minable block is 264 parent blocks later (3 waiting + 257 to
    /// expire the unminable seed + 3 new seed delay + 1), and it needs a
    /// permissionless `refreshExpiredSeed` call. The stall also crosses
    /// `STALL_INTERVAL_PARENT_BLOCKS` (250), so anyone may ease the target
    /// once while it lasts.
    function testAttachRuleForOpenChallenge() public {
        _mixedOldDepositors();
        _deposit(ALICE, MIN); // prefunding is open while unwired
        vm.prank(ALICE);
        vm.expectRevert(PrefundedMiningPower.NotWired.selector);
        module.assign(MINER, MIN);

        _win(OLD_SOLO);
        uint256 acceptedAt = block.number;
        _detach();
        _attach(module);
        uint256 c = core.activeChallengeId();
        assertEq(module.latestChallengeId(), c);

        // Assigned right after the attach, same challenge: pending.
        _assign(ALICE, MINER, MIN);
        assertEq(module.pendingOf(MINER), MIN);
        (bool eligible, uint8 reason, uint256 stake) = module.eligibilityOf(MINER);
        assertFalse(eligible);
        assertEq(reason, 2);
        assertEq(stake, 0);
        _activate();
        (uint256 n,) = _nonce(MINER);
        _expectNotEligible(2);
        _send(MINER, n);

        // Nobody can mine challenge c: the stall eases difficulty once...
        vm.roll(acceptedAt + core.STALL_INTERVAL_PARENT_BLOCKS());
        uint256 target = core.currentTarget();
        core.easeDifficulty();
        assertGt(core.currentTarget(), target);
        // ...and ends only when the unminable seed expires and is refreshed.
        _nextChallenge();
        assertEq(core.activeChallengeId(), c + 1);
        _activate();
        assertEq(block.number - acceptedAt, 264, "stall length in parent blocks");
        (eligible, reason, stake) = module.eligibilityOf(MINER);
        assertTrue(eligible);
        assertEq(reason, 0);
        assertEq(stake, MIN);
        uint256 id = _win(MINER);
        (uint256 amount,,,,,) = module.committedOf(id);
        assertEq(amount, LOCK);
        _assertBooks();
    }

    // ------------------------------------------------------------------
    // Old custody depositors after the cutover
    // ------------------------------------------------------------------

    /// @notice MATURED (assigned >= 12 proofs ago) exits the detached old
    /// custody at once: it reads the live core clock, and the detach was
    /// non-terminal so nothing else changed.
    function testOldMaturedDepositorsExitImmediately() public {
        uint256 proofs = _mixedOldDepositors();
        _cutoverEoa();
        assertFalse(oldCustody.retired());
        assertEq(oldCustody.lastAcceptedProofs(), proofs);

        vm.startPrank(OLD_MATURED);
        oldCustody.unassign(OLD_MATURED_WALLET, OLD_MATURED_STAKE);
        oldCustody.withdraw(OLD_MATURED_STAKE);
        vm.stopPrank();
        assertEq(token.balanceOf(OLD_MATURED), OLD_MATURED_STAKE);
        assertEq(oldCustody.assignedOf(OLD_MATURED_WALLET), 0);
        assertEq(oldCustody.totalAssigned(), OLD_RECENT_STAKE);
        _assertBooks();
    }

    /// @notice RECENT (assigned within the last 12 proofs) waits for 12 more
    /// proofs — which after the cutover can only come from wallets qualified
    /// on the NEW module. The detached old custody never sees them; it
    /// reads the core's live `acceptedProofs`.
    function testOldRecentAssignersExitAfterTwelveLiveProofs() public {
        uint256 proofs = _mixedOldDepositors();
        _cutoverEoa();
        uint256 earliest = proofs + oldCustody.UNLOCK_DELAY_PROOFS();
        _expectOldDelay(earliest, proofs);

        _qualifyFor(ALICE, MINER, 12);
        for (uint256 i = 0; i < 11; i++) {
            _win(MINER);
        }
        assertEq(core.acceptedProofs(), earliest - 1);
        _expectOldDelay(earliest, earliest - 1);

        _win(MINER); // 12th live proof on the new module
        assertEq(core.acceptedProofs(), earliest);
        assertEq(oldCustody.lastAcceptedProofs(), proofs); // never notified
        vm.startPrank(OLD_RECENT);
        oldCustody.unassign(OLD_RECENT_WALLET, OLD_RECENT_STAKE);
        oldCustody.withdraw(OLD_RECENT_STAKE);
        vm.stopPrank();
        assertEq(token.balanceOf(OLD_RECENT), OLD_RECENT_STAKE);
        assertEq(module.totalCommitted(), 12 * LOCK);
        _assertBooks();
    }

    /// @notice IDLE (deposited, never assigned) withdraws in every state.
    function testOldIdleDepositorWithdrawsAnytime() public {
        _mixedOldDepositors();
        vm.prank(OLD_IDLE);
        oldCustody.withdraw(500e18); // old custody still attached
        _cutoverEoa();
        vm.prank(OLD_IDLE);
        oldCustody.withdraw(500e18); // detached, same challenge
        _nextChallenge();
        vm.prank(STOP);
        core.stopMining();
        vm.prank(OLD_IDLE);
        oldCustody.withdraw(500e18); // after a terminal stop
        assertEq(token.balanceOf(OLD_IDLE), OLD_IDLE_STAKE);
        assertEq(oldCustody.unassignedOf(OLD_IDLE), 0);
        _assertBooks();
    }

    /// @notice LIMITATION: the old custody's unlock delay counts PROOFS, not
    /// time. While nobody mines on the new module (the post-cutover stall,
    /// or no backer ever qualifies a wallet) RECENT stays locked however much
    /// time passes. Relief used here: `stopMining` (terminal, the old
    /// custody reads the live STOPPED state) — only before the sunset.
    /// Other reliefs, documented: mint-out (ENDED is read the same way, but
    /// needs the 5,000th NFT); after the sunset neither stop nor re-attach
    /// is possible, so the only relief is proofs — ultimately the new
    /// module's failsafe (`disableRequirement`) makes mining free again,
    /// shown in the second branch.
    function testLimitation_OldCustodyExitWaitsDuringStall() public {
        uint256 proofs = _mixedOldDepositors();
        _cutoverEoa();
        uint256 earliest = proofs + oldCustody.UNLOCK_DELAY_PROOFS();

        // Days pass and seeds are refreshed, but no proof is mined.
        for (uint256 i = 0; i < 5; i++) {
            _nextChallenge();
            vm.warp(block.timestamp + 5 days);
        }
        assertEq(core.acceptedProofs(), proofs);
        _expectOldDelay(earliest, proofs);
        uint256 snap = vm.snapshotState();

        // Branch 1: terminal stop before the sunset releases RECENT.
        assertLt(block.timestamp, core.MINING_STOP_SUNSET());
        vm.prank(STOP);
        core.stopMining();
        assertFalse(oldCustody.retired()); // detached custody got no notice...
        vm.startPrank(OLD_RECENT); // ...but reads STOPPED from the live core
        oldCustody.unassign(OLD_RECENT_WALLET, OLD_RECENT_STAKE);
        oldCustody.withdraw(OLD_RECENT_STAKE);
        vm.stopPrank();
        assertEq(token.balanceOf(OLD_RECENT), OLD_RECENT_STAKE);
        assertTrue(module.retired()); // the attached module was notified
        _assertBooks();

        // Branch 2: past the sunset nothing but proofs can release RECENT.
        vm.revertToState(snap);
        uint256 sunset = core.MINING_STOP_SUNSET();
        vm.warp(sunset + 1);
        vm.prank(STOP);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.MiningStopSunsetPassed.selector, sunset, sunset + 1));
        core.stopMining();
        _expectOldDelay(earliest, proofs);
        vm.prank(GUARDIAN);
        module.disableRequirement(); // failsafe: mining is free again
        _nextChallenge();
        for (uint256 i = 0; i < 12; i++) {
            _win(OUTSIDER);
        }
        vm.startPrank(OLD_RECENT);
        oldCustody.unassign(OLD_RECENT_WALLET, OLD_RECENT_STAKE);
        oldCustody.withdraw(OLD_RECENT_STAKE);
        vm.stopPrank();
        assertEq(module.totalCommitted(), 0); // the disabled gate takes no lock
        _assertBooks();
    }

    /// @notice The old custody can never come back while it still holds
    /// assignments (`RetainedAssignments`), and never replaces a wired
    /// module directly (`MiningPowerAlreadyWired`).
    function testOldCustodyCannotReattachWithAssignments() public {
        _mixedOldDepositors();
        _cutoverEoa();

        vm.prank(STOP);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.MiningPowerAlreadyWired.selector, address(module)));
        core.setMiningPower(IMiningPower(address(oldCustody)));

        _detach();
        vm.prank(STOP);
        vm.expectRevert(
            abi.encodeWithSelector(
                MiningPowerCustody.RetainedAssignments.selector, OLD_MATURED_STAKE + OLD_RECENT_STAKE
            )
        );
        core.setMiningPower(IMiningPower(address(oldCustody)));

        // Even after MATURED leaves, RECENT's assignment still blocks it.
        vm.prank(OLD_MATURED);
        oldCustody.unassign(OLD_MATURED_WALLET, OLD_MATURED_STAKE);
        vm.prank(STOP);
        vm.expectRevert(abi.encodeWithSelector(MiningPowerCustody.RetainedAssignments.selector, OLD_RECENT_STAKE));
        core.setMiningPower(IMiningPower(address(oldCustody)));
        assertFalse(oldCustody.wired());

        // The new module (no assignments) can be re-attached.
        _attach(module);
        assertTrue(module.wired());
        _assertBooks();
    }

    /// @notice Rollback = detaching the new module. Mining is then free
    /// (no module: base target, no gate, no lock) until another attach; the
    /// detached module keeps its exit cooldown, waives the stake hold, and
    /// its existing locks stand.
    function testRollbackDetachMeansUngatedBaseMining() public {
        _mixedOldDepositors();
        _cutoverEoa();
        _qualify(ALICE, MINER, MIN + LOCK);
        uint256 locked = _win(MINER);
        vm.warp(block.timestamp + COOLDOWN);
        _deposit(BOB, MIN);
        _assign(BOB, MINER2, MIN); // fresh assign: BOB's cooldown runs
        uint256 bobEarliest = block.timestamp + COOLDOWN;

        _detach(); // rollback
        assertFalse(module.wired());
        assertFalse(module.retired());

        // Ungated base mining for anyone, no lock.
        uint256 free = _win(OUTSIDER);
        (uint256 freeLock,,,,,) = module.committedOf(free);
        assertEq(freeLock, 0);
        assertEq(module.totalCommitted(), LOCK);
        (uint256 amount,,,,, bool released) = module.committedOf(locked);
        assertEq(amount, LOCK);
        assertFalse(released);

        // Exits keep their cooldown...
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(PrefundedMiningPower.CooldownNotMet.selector, bobEarliest, block.timestamp)
        );
        module.unassign(MINER2, MIN);
        // ...and the hold is waived: ALICE's matured stake leaves at once.
        _unassign(ALICE, MINER, MIN);
        assertEq(module.heldStakeOf(ALICE), 0);
        _withdraw(ALICE, MIN);
        assertEq(token.balanceOf(ALICE), MIN);
        vm.warp(bobEarliest);
        _unassign(BOB, MINER2, MIN);
        _withdraw(BOB, MIN);
        _assertBooks();
    }

    /// @notice Old deposits are never counted or moved by the new module:
    /// the old custody's balances are untouched through mining on the new
    /// module, and the new module's eligibility ignores old stake.
    function testOldDepositsNeverCountedOrMoved() public {
        uint256 proofs = _mixedOldDepositors();
        uint256 oldBalance = token.balanceOf(address(oldCustody));
        uint256 oldLocked = oldCustody.totalLocked();
        uint256 oldAssigned = oldCustody.totalAssigned();
        uint256 oldChallenge = oldCustody.latestChallengeId();
        _cutoverEoa();

        (bool eligible, uint8 reason, uint256 stake) = module.eligibilityOf(OLD_MATURED_WALLET);
        assertFalse(eligible);
        assertEq(reason, 2);
        assertEq(stake, 0);
        assertEq(module.previewSubmit(OLD_MATURED_WALLET), 1e18);
        assertEq(module.unassignedOf(OLD_MATURED), 0);
        assertEq(module.unassignedOf(OLD_IDLE), 0);

        _qualifyFor(ALICE, MINER, 3);
        (uint256 n,) = _nonce(OLD_MATURED_WALLET);
        _expectNotEligible(2);
        _send(OLD_MATURED_WALLET, n);
        for (uint256 i = 0; i < 3; i++) {
            _win(MINER);
        }

        assertEq(token.balanceOf(address(oldCustody)), oldBalance);
        assertEq(oldCustody.totalLocked(), oldLocked);
        assertEq(oldCustody.totalAssigned(), oldAssigned);
        assertEq(oldCustody.assignedOf(OLD_MATURED_WALLET), OLD_MATURED_STAKE);
        assertEq(oldCustody.assignedOf(OLD_RECENT_WALLET), OLD_RECENT_STAKE);
        assertEq(oldCustody.unassignedOf(OLD_IDLE), OLD_IDLE_STAKE);
        assertEq(oldCustody.lastAcceptedProofs(), proofs);
        assertEq(oldCustody.latestChallengeId(), oldChallenge);
        assertEq(token.balanceOf(address(module)), module.totalStake() + module.totalCommitted());
        assertEq(module.totalStake() + module.totalCommitted(), MIN + 2 * LOCK);
        _assertBooks();
    }

    /// @notice `setMiningPower` needs a detach before an attach and works up
    /// to and including `MINING_STOP_SUNSET`; one second later the wiring is
    /// frozen for good — a core left detached then mines ungated forever.
    function testAttachRequiresDetachAndPreSunset() public {
        vm.prank(STOP);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.MiningPowerAlreadyWired.selector, address(oldCustody)));
        core.setMiningPower(module);

        _detach();
        uint256 sunset = core.MINING_STOP_SUNSET();
        uint256 snap = vm.snapshotState();

        // Sunset + 1 with no module: the attach is refused, mining stays free.
        vm.warp(sunset + 1);
        vm.prank(STOP);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.MiningStopSunsetPassed.selector, sunset, sunset + 1));
        core.setMiningPower(module);
        _win(OUTSIDER);
        assertEq(address(core.miningPower()), address(0));

        // Exactly at the sunset the attach is allowed; one second later the
        // module can no longer be detached.
        vm.revertToState(snap);
        vm.warp(sunset);
        _attach(module);
        vm.warp(sunset + 1);
        vm.prank(STOP);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.MiningStopSunsetPassed.selector, sunset, sunset + 1));
        core.setMiningPower(IMiningPower(address(0)));
        assertEq(address(core.miningPower()), address(module));
    }

    /// @notice A detached (non-terminal) module refuses new entries
    /// (`assign` → `NotWired`; `deposit` stays open by design, an unassigned
    /// deposit carries no power) and keeps every exit and every lock:
    /// unassign after the cooldown, withdraw (hold waived), and the burn
    /// claim of an existing lock.
    function testDetachedModuleKeepsExitsAndLocksRefusesEntries() public {
        _cutoverEoa();
        _qualify(ALICE, MINER, MIN + LOCK);
        uint256 id = _win(MINER);
        _detach();

        vm.prank(ALICE);
        vm.expectRevert(PrefundedMiningPower.NotWired.selector);
        module.assign(MINER, 1);
        _deposit(BOB, MIN);
        vm.prank(BOB);
        vm.expectRevert(PrefundedMiningPower.NotWired.selector);
        module.assign(MINER2, MIN);

        uint256 earliest = module.assignTimestamp(ALICE) + COOLDOWN;
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.CooldownNotMet.selector, earliest, block.timestamp));
        module.unassign(MINER, MIN);
        vm.warp(earliest);
        _unassign(ALICE, MINER, MIN);
        _withdraw(ALICE, MIN);
        _withdraw(BOB, MIN);

        // The lock is still there and still pays the burner.
        (uint256 amount,,,,, bool released) = module.committedOf(id);
        assertEq(amount, LOCK);
        assertFalse(released);
        _burn(id);
        _claim(id, MINER);
        assertEq(token.balanceOf(MINER), LOCK);
        assertEq(module.totalCommitted(), 0);
        assertEq(token.balanceOf(address(module)), 0);
        _assertBooks();
    }

    // ------------------------------------------------------------------
    // Re-wire into the same challenge (Task A, carry-over from S5)
    // ------------------------------------------------------------------

    /// @notice A wallet frozen before a detach is re-frozen DOWNWARD when the
    /// module is re-wired into the same challenge: the detach waived the
    /// hold and its backer's removed stake left the module. A wallet whose
    /// stake grew in between is NOT raised — the new stake is pending.
    /// @dev DEVIATION (flagged): the cached freeze is planted with
    /// `vm.prank(address(core))` → `snapshottedLockedAmount`. The real core
    /// cannot leave one: it calls the freezing hook only inside
    /// `submitProof`, and an accepted proof always opens the next challenge
    /// (a rejected one rolls the freeze back). The fix is defence in depth;
    /// everything else here (attach, detach, re-attach, submissions) goes
    /// through the real core. `snapshottedLockedAmount` writes no transient
    /// note, so the plant cannot leak into a later hook.
    function testRewireIntoSameChallengeRefreezesLowerOnly() public {
        _cutoverEoa();
        _qualify(ALICE, MINER, MIN);
        uint256 c = core.activeChallengeId();

        // Plant freezes for challenge c: MINER at MIN, MINER2 at 0.
        vm.prank(address(core));
        assertEq(module.snapshottedLockedAmount(c, MINER), MIN);
        vm.prank(address(core));
        assertEq(module.snapshottedLockedAmount(c, MINER2), 0);

        // ALICE unassigns her matured stake: it still counts for c (held).
        vm.warp(block.timestamp + COOLDOWN);
        _unassign(ALICE, MINER, MIN);
        assertEq(module.withdrawableOf(ALICE), 0);
        _assertStake(MINER, false, MIN); // frozen MIN counts; live 0 (reason 4)
        (, uint8 why,) = module.eligibilityOf(MINER);
        assertEq(why, 4);

        // Detach waives the hold; the removed stake leaves the module.
        _detach();
        assertEq(module.holdWaivedEpoch(), c);
        _withdraw(ALICE, MIN);
        assertEq(module.totalStake(), 0);

        // Re-wire into the SAME challenge.
        _attach(module);
        assertEq(module.latestChallengeId(), c);
        assertEq(module.rewiredEpoch(), c);
        _assertStake(MINER, false, 0); // lowered from the cached MIN

        // New stake after the re-wire is pending: CAROL re-backs MINER (the
        // bug the fix closes: the stale MIN cache would admit MINER and her
        // pending stake would pay its lock); BOB stakes MINER2, whose cached
        // 0 must NOT be raised.
        _deposit(CAROL, MIN);
        _assign(CAROL, MINER, MIN);
        _deposit(BOB, 2 * MIN);
        _assign(BOB, MINER2, 2 * MIN);
        _assertStake(MINER, false, 0);
        _assertStake(MINER2, false, 0);

        _activate();
        (uint256 n,) = _nonce(MINER);
        _expectNotEligible(2);
        _send(MINER, n);
        (n,) = _nonce(MINER2);
        _expectNotEligible(2);
        _send(MINER2, n);
        vm.prank(address(core));
        assertEq(module.snapshottedLockedAmount(c, MINER), 0); // cache overwritten
        vm.prank(address(core));
        assertEq(module.snapshottedLockedAmount(c, MINER2), 0); // never raised
        assertEq(module.totalCommitted(), 0);

        // Next challenge: both count, CAROL pays MINER's lock.
        _nextChallenge();
        _assertStake(MINER, true, MIN);
        _assertStake(MINER2, true, 2 * MIN);
        uint256 id = _win(MINER);
        (uint256 amount,,,, address backer,) = module.committedOf(id);
        assertEq(amount, LOCK);
        assertEq(backer, CAROL);
        _assertBooks();
    }

    // ------------------------------------------------------------------
    // Artefact for S11/S13
    // ------------------------------------------------------------------

    /// @notice Builds and logs the exact cutover calldata with PLACEHOLDER
    /// addresses (core 0x…c0de, new module 0x…dead): the two
    /// `setMiningPower` calls and the Safe `multiSend(bytes)` batch in
    /// MultiSend packed encoding (operation 0 CALL, value 0), detach first.
    /// The Safe sends it as `execTransaction(to = MultiSendCallOnly,
    /// value = 0, data = <multiSend calldata>, operation = 1 DELEGATECALL,
    /// safeTxGas = 0, baseGas = 0, gasPrice = 0, gasToken = 0,
    /// refundReceiver = 0, signatures)`. The same encoder drives
    /// `testSafeStyleBatchLeavesNoUngatedWindow` against the real stack.
    function testCutoverCalldata() public pure {
        address liveCore = address(uint160(0xC0DE));
        address liveModule = address(uint160(0xDEAD));
        bytes4 setSel = bytes4(keccak256("setMiningPower(address)"));
        assertEq(setSel, HunterMiningCore.setMiningPower.selector);

        bytes memory detach = PrefundedCutoverEncoding.detachCalldata();
        bytes memory attach = PrefundedCutoverEncoding.attachCalldata(liveModule);
        assertEq(detach, abi.encodeWithSelector(setSel, address(0)));
        assertEq(attach, abi.encodeWithSelector(setSel, liveModule));
        assertEq(detach.length, 36);
        assertEq(attach.length, 36);

        bytes memory txs = PrefundedCutoverEncoding.cutoverTransactions(liveCore, liveModule);
        assertEq(txs.length, 2 * (85 + 36));
        assertEq(
            txs,
            abi.encodePacked(
                uint8(0), liveCore, uint256(0), uint256(36), detach, uint8(0), liveCore, uint256(0), uint256(36), attach
            )
        );
        bytes memory ms = PrefundedCutoverEncoding.multiSendCalldata(txs);
        assertEq(bytes4(ms), bytes4(0x8d80ff0a)); // Safe MultiSend `multiSend(bytes)`
        assertEq(ms, abi.encodeWithSelector(bytes4(0x8d80ff0a), txs));
        assertEq(ms.length, 4 + 32 + 32 + 256); // 242 bytes padded to 256

        console.log("core placeholder  ", liveCore);
        console.log("module placeholder", liveModule);
        console.log("setMiningPower(address(0)) calldata:");
        console.logBytes(detach);
        console.log("setMiningPower(module) calldata:");
        console.logBytes(attach);
        console.log("MultiSend packed transactions (detach, attach):");
        console.logBytes(txs);
        console.log("multiSend(bytes) calldata (Safe DELEGATECALL to MultiSendCallOnly):");
        console.logBytes(ms);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev The EOA cutover: two transactions by the STOP EOA.
    function _cutoverEoa() private {
        _detach();
        _attach(module);
        assertFalse(oldCustody.wired());
        assertTrue(module.wired());
    }

    function _expectOldDelay(uint256 earliest, uint256 current) private {
        vm.prank(OLD_RECENT);
        vm.expectRevert(abi.encodeWithSelector(MiningPowerCustody.UnlockDelayNotMet.selector, earliest, current));
        oldCustody.unassign(OLD_RECENT_WALLET, OLD_RECENT_STAKE);
    }

    function _assertStake(address wallet, bool eligible, uint256 stake) private view {
        (bool e,, uint256 s) = module.eligibilityOf(wallet);
        assertEq(e, eligible, "eligible");
        assertEq(s, stake, "frozen stake");
    }
}
