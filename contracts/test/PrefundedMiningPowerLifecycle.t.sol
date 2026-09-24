// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HunterMiningCore} from "../src/bloom/HunterMiningCore.sol";
import {IMiningPower} from "../src/bloom/IMiningPower.sol";
import {PrefundedMiningPower} from "../src/bloom/PrefundedMiningPower.sol";
import {PrefundedMiningStack} from "./helpers/PrefundedMiningStack.sol";

/// @notice S8 (VLT-59): exits, terminal states, the failsafe and the stop
/// sunset of PrefundedMiningPower, plus the backer-slot hygiene decided for
/// this slice (first assign >= MIN_STAKE, wallet-side eviction of a
/// sub-minimum backer, no new backer while removed stake still counts) and
/// eligibility reason 4. Everything runs on the REAL stack: every hook call
/// comes from the real `HunterMiningCore` (attach, submitProof, refresh,
/// ease, stopMining, tripMining, mint-out). The module under test enforces
/// MIN_STAKE 1,000 with a 100 lock and a one-hour exit cooldown and carries
/// a failsafe guardian. All amounts are TEST-ONLY fixture values.
contract PrefundedMiningPowerLifecycleTest is PrefundedMiningStack {
    using stdStorage for StdStorage;

    address internal constant CAROL = address(0xCA201);
    address internal constant MINER2 = address(0x222E);
    address internal constant GUARDIAN = address(0x6A2D);

    uint256 private constant MIN_STAKE = 1_000e18;
    uint256 private constant LOCK = 100e18;
    uint256 private constant COOLDOWN = 1 hours;

    /// @dev Every external function of PrefundedMiningPower — the approved
    /// ABI (S8 candidate). Anything else must not exist.
    string[] private _approved;

    function setUp() public override {
        super.setUp();
        _deployModule(MIN_STAKE, LOCK, COOLDOWN, 0, GUARDIAN);
        _attach(module);
        assertTrue(module.wired());
        assertEq(module.FAILSAFE_GUARDIAN(), GUARDIAN);
    }

    // ------------------------------------------------------------------
    // Core transitions that are not proofs
    // ------------------------------------------------------------------

    /// @dev An expired-seed refresh opens the next challenge on the module
    /// (stake matures, holds lift) without any lock, note or proof count.
    function testSeedRefreshOpensEpochWithoutLock() public {
        _deposit(ALICE, MIN_STAKE);
        _assign(ALICE, MINER, MIN_STAKE);
        uint256 open = module.latestChallengeId();
        _assertEligibility(MINER, false, 2, 0);
        uint256 bal = token.balanceOf(address(module));

        uint256 expiry = core.activeSeedParentBlock() + core.SEED_READABLE_PARENT_BLOCKS() + 1;
        vm.roll(expiry);
        vm.expectEmit(true, false, false, true, address(module));
        emit PrefundedMiningPower.ChallengeSnapshotted(open + 1);
        core.refreshExpiredSeed();

        assertEq(core.activeChallengeId(), open + 1);
        assertEq(module.latestChallengeId(), open + 1);
        assertEq(core.acceptedProofs(), 0);
        assertEq(module.lastAcceptedProofs(), 0);
        assertEq(module.totalCommitted(), 0);
        assertEq(module.totalStake(), MIN_STAKE);
        assertEq(module.assignedOf(MINER), MIN_STAKE);
        assertEq(token.balanceOf(address(module)), bal);
        _assertNoLock(1);
        _assertNoteEmpty();
        // The refresh matured ALICE's stake: MINER qualifies now.
        _assertEligibility(MINER, true, 0, MIN_STAKE);

        // The first proof in the refreshed challenge is the first lock.
        uint256 tokenId = _win(MINER);
        assertEq(tokenId, 1);
        (uint256 amount, uint256 c,,,,) = module.committedOf(1);
        assertEq(amount, LOCK);
        assertEq(c, open + 1);
        _assertBooks();
    }

    /// @dev `easeDifficulty` never calls the module: with it attached the
    /// ease is bit-for-bit what the same core does with the module detached,
    /// and the module's state is untouched.
    function testEaseUnaffectedByModule() public {
        _qualify(ALICE, MINER, MIN_STAKE + LOCK);
        uint256 earliest = _max(core.lastProofBlock(), core.lastEaseBlock()) + core.STALL_INTERVAL_PARENT_BLOCKS();
        if (block.number < earliest) vm.roll(earliest);
        assertEq(uint8(core.challengeState()), uint8(HunterMiningCore.ChallengeState.ACTIVE));
        ModuleView memory m0 = _moduleView(MINER);
        uint256 oldTarget = core.currentTarget();
        uint256 expected = Math.mulDiv(oldTarget, 5, 4);
        assertLt(expected, core.MAX_TARGET());
        uint256 base = vm.snapshotState();

        // With the module attached.
        vm.expectEmit(true, false, false, true, address(core));
        emit HunterMiningCore.DifficultyEased(BOB, oldTarget, expected, block.number);
        vm.prank(BOB);
        core.easeDifficulty();
        CoreView memory withModule = _coreView();
        assertEq(withModule.target, expected);
        _assertModuleView(m0, MINER);
        _assertNoteEmpty();

        // Same block, module detached: identical outcome.
        vm.revertToState(base);
        _detach();
        vm.prank(BOB);
        core.easeDifficulty();
        CoreView memory without = _coreView();
        assertEq(keccak256(abi.encode(withModule)), keccak256(abi.encode(without)), "ease differs with module");

        // Back to the attached run: the eased challenge still gates and locks.
        vm.revertToState(base);
        vm.prank(BOB);
        core.easeDifficulty();
        uint256 tokenId = _win(MINER);
        (uint256 amount,,,,,) = module.committedOf(tokenId);
        assertEq(amount, LOCK);
        _assertBooks();
    }

    // ------------------------------------------------------------------
    // Terminal detach: mint-out, keyed stop, counter trip
    // ------------------------------------------------------------------

    /// @dev The real core is rewound to 4,999 minted with stdstore (its
    /// counters and the NFT's), exactly as HunterMiningCore.t.sol does with
    /// its harness. The 5,000th win records its lock, then the core retires
    /// the module in the same transaction: exits open at once (same
    /// timestamp, cooldown not elapsed), new entries are refused, and the
    /// final NFT's lock is claimable after its burn.
    function testMintOutLocksFinalNftThenOpensExits() public {
        _qualify(ALICE, MINER, MIN_STAKE + LOCK);
        _deposit(BOB, 300e18);
        stdstore.target(address(core)).sig("nftsMintedEver()").checked_write(uint256(4_999));
        stdstore.target(address(core)).sig("acceptedProofs()").checked_write(uint256(4_999));
        stdstore.target(address(nft)).sig("mintedEver()").checked_write(uint256(4_999));
        uint256 t0 = block.timestamp;
        assertEq(module.assignTimestamp(ALICE), t0);

        uint256 id = cid;
        (uint256 nonce, bytes32 digest) = _nonce(MINER);
        vm.expectEmit(true, true, true, true, address(module));
        emit PrefundedMiningPower.Committed(5_000, MINER, id, ALICE, digest, LOCK);
        _send(MINER, nonce);

        assertEq(nft.ownerOf(5_000), MINER);
        assertEq(uint8(core.challengeState()), uint8(HunterMiningCore.ChallengeState.ENDED));
        assertTrue(module.retired());
        assertFalse(module.wired());
        assertEq(module.lastAcceptedProofs(), 5_000);
        (uint256 amount, uint256 c, bytes32 d, address miner, address backer, bool released) = module.committedOf(5_000);
        assertEq(amount, LOCK);
        assertEq(c, id);
        assertEq(d, digest);
        assertEq(miner, MINER);
        assertEq(backer, ALICE);
        assertFalse(released);
        assertEq(module.assignedOf(MINER), MIN_STAKE);
        // Not the live module any more; the frozen value of the final
        // challenge is what it was when the gate admitted the proof.
        _assertEligibility(MINER, false, 1, MIN_STAKE + LOCK);

        // Exits open immediately — still t0, cooldown not elapsed.
        assertEq(block.timestamp, t0);
        _unassign(ALICE, MINER, MIN_STAKE);
        assertEq(module.withdrawableOf(ALICE), MIN_STAKE);
        _withdraw(ALICE, MIN_STAKE);
        _withdraw(BOB, 300e18);
        assertEq(token.balanceOf(ALICE), MIN_STAKE);
        assertEq(token.balanceOf(BOB), 300e18);

        // Nothing new can enter.
        _expectDepositReverts(CAROL, 1e18, abi.encodeWithSelector(PrefundedMiningPower.Retired.selector));
        vm.prank(ALICE);
        vm.expectRevert(PrefundedMiningPower.Retired.selector);
        module.assign(MINER, MIN_STAKE);

        // The final NFT's lock is released on its burn.
        _burn(5_000);
        _claim(5_000, MINER);
        assertEq(token.balanceOf(MINER), LOCK);
        assertEq(token.balanceOf(address(module)), 0);
        assertEq(module.totalStake(), 0);
        assertEq(module.totalCommitted(), 0);
    }

    /// @dev A keyed stop and, separately (same starting state), a counter
    /// divergence tripped by anyone both retire the module and open every
    /// exit at once — cooldown and hold waived — while existing locks stay
    /// claimable.
    function testStopMiningAndTripMiningOpenExits() public {
        _qualify(ALICE, MINER, MIN_STAKE + LOCK);
        uint256 tokenId = _win(MINER);
        _activate();
        _deposit(BOB, MIN_STAKE);
        _assign(BOB, MINER2, MIN_STAKE);
        vm.warp(block.timestamp + COOLDOWN);
        // A matured partial exit is held (it still counts this challenge).
        _unassign(ALICE, MINER, 100e18);
        assertEq(module.withdrawableOf(ALICE), 0);
        uint256 t = block.timestamp;
        _deposit(BOB, 1); // BOB's clock restarts below
        _assign(BOB, MINER2, 1);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.CooldownNotMet.selector, t + COOLDOWN, t));
        module.unassign(MINER2, 1);
        uint256 base = vm.snapshotState();

        // (a) Keyed stop.
        vm.prank(STOP);
        core.stopMining();
        _assertTerminalExitsOpen(tokenId);

        // (b) Counter divergence, tripped by a stranger.
        vm.revertToState(base);
        assertFalse(module.retired());
        stdstore.target(address(nft)).sig("mintedEver()").checked_write(uint256(7));
        vm.prank(CAROL);
        core.tripMining();
        assertTrue(core.miningStopped());
        _assertTerminalExitsOpen(tokenId);
    }

    // ------------------------------------------------------------------
    // Stop sunset
    // ------------------------------------------------------------------

    /// @dev `setMiningPower` (and `stopMining`) work up to and including
    /// MINING_STOP_SUNSET and revert one second later. The module keeps
    /// gating and settling after the sunset, and the failsafe still works.
    function testSunsetBoundary() public {
        _qualify(ALICE, MINER, MIN_STAKE + 2 * LOCK);
        uint256 sunset = core.MINING_STOP_SUNSET();

        // Exactly at the sunset: detach and a fresh attach still work.
        vm.warp(sunset);
        uint256 base = vm.snapshotState();
        _detach();
        assertFalse(module.wired());
        PrefundedMiningPower other =
            new PrefundedMiningPower(address(token), address(core), MIN_STAKE, LOCK, COOLDOWN, 0, GUARDIAN);
        _attach(other);
        vm.revertToState(base);
        assertEq(address(core.miningPower()), address(module));
        assertTrue(module.wired());

        // One second later every stop-multisig path is closed.
        vm.warp(sunset + 1);
        bytes memory passed =
            abi.encodeWithSelector(HunterMiningCore.MiningStopSunsetPassed.selector, sunset, sunset + 1);
        vm.prank(STOP);
        vm.expectRevert(passed);
        core.setMiningPower(IMiningPower(address(0)));
        vm.prank(STOP);
        vm.expectRevert(passed);
        core.stopMining();
        assertEq(address(core.miningPower()), address(module));

        // The module keeps gating and settling.
        _activate();
        (uint256 n2,) = _nonce(MINER2);
        _expectNotEligible(2);
        _send(MINER2, n2);
        uint256 tokenId = _win(MINER);
        (uint256 amount,,,,,) = module.committedOf(tokenId);
        assertEq(amount, LOCK);
        assertEq(module.assignedOf(MINER), MIN_STAKE + LOCK);

        // The failsafe has no time limit.
        vm.warp(sunset + 365 days);
        vm.prank(GUARDIAN);
        module.disableRequirement();
        assertTrue(module.gateDisabled());
        uint256 free = _win(MINER2);
        _assertNoLock(free);
        _assertBooks();
    }

    /// @notice LIMITATION (documented): after MINING_STOP_SUNSET the stop
    /// multisig can neither detach nor replace the module, and `stopMining`
    /// is closed too, so the module is the core's gate for the rest of
    /// mining. Only the failsafe guardian can relieve the requirement — and
    /// a module deployed without a guardian has no relief at all. Staker
    /// exits are unaffected: the wall-clock cooldown still releases them.
    function testLimitation_PostSunsetModuleIsPermanent() public {
        // A guardian-less module attached before the sunset.
        _detach();
        _deployModule(MIN_STAKE, LOCK, COOLDOWN, 0, address(0));
        _attach(module);
        _qualify(ALICE, MINER, MIN_STAKE);
        uint256 sunset = core.MINING_STOP_SUNSET();
        vm.warp(sunset + 1);

        vm.prank(STOP);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.MiningStopSunsetPassed.selector, sunset, sunset + 1));
        core.setMiningPower(IMiningPower(address(0)));
        // No counter violation: the permissionless trip is not a way out.
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.NoMiningCounterViolation.selector, 0, 0, 0));
        core.tripMining();
        // No failsafe on this module.
        vm.prank(STOP);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.UnauthorizedCaller.selector, STOP));
        module.disableRequirement();

        // The requirement stands for good: an unstaked wallet cannot mine.
        _activate();
        (uint256 n,) = _nonce(MINER2);
        _expectNotEligible(2);
        _send(MINER2, n);
        assertTrue(module.wired());
        assertFalse(module.gateDisabled());

        // Stakers are never trapped: the cooldown releases them by time.
        _unassign(ALICE, MINER, MIN_STAKE);
        _nextChallenge(); // permissionless: lifts the hold without a proof
        _withdraw(ALICE, MIN_STAKE);
        assertEq(token.balanceOf(ALICE), MIN_STAKE);
        _assertBooks();
    }

    // ------------------------------------------------------------------
    // Exits in every state
    // ------------------------------------------------------------------

    /// @dev No proof is ever accepted: the cooldown elapses on the clock
    /// alone. Pending stake leaves at once; matured stake is held until the
    /// next snapshot, which a permissionless `refreshExpiredSeed` opens — no
    /// proof, no miner, no admin needed.
    function testNoMinerStallNewModuleExitsOpen() public {
        _qualify(BOB, MINER2, MIN_STAKE); // matured by a refresh
        uint256 tB = module.assignTimestamp(BOB);
        uint256 t0 = block.timestamp;
        _deposit(ALICE, MIN_STAKE);
        _assign(ALICE, MINER, MIN_STAKE); // pending in the open challenge

        // Weeks of nothing: no proofs, the seed expires, nobody refreshes.
        vm.roll(block.number + 100_000);
        vm.warp(t0 + COOLDOWN - 1);
        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(PrefundedMiningPower.CooldownNotMet.selector, t0 + COOLDOWN, t0 + COOLDOWN - 1)
        );
        module.unassign(MINER, MIN_STAKE);
        vm.warp(t0 + 21 days);
        assertEq(core.acceptedProofs(), 0);
        assertEq(module.lastAcceptedProofs(), 0);
        assertEq(uint8(core.challengeState()), uint8(HunterMiningCore.ChallengeState.EXPIRED));

        _unassign(ALICE, MINER, MIN_STAKE);
        _withdraw(ALICE, MIN_STAKE);
        assertEq(token.balanceOf(ALICE), MIN_STAKE);

        assertGe(block.timestamp, tB + COOLDOWN);
        _unassign(BOB, MINER2, MIN_STAKE);
        bytes memory held = abi.encodeWithSelector(
            PrefundedMiningPower.StakeHeldUntilNextChallenge.selector, MIN_STAKE, module.latestChallengeId()
        );
        vm.prank(BOB);
        vm.expectRevert(held);
        module.withdraw(MIN_STAKE);
        vm.prank(BOB);
        core.refreshExpiredSeed();
        _withdraw(BOB, MIN_STAKE);
        assertEq(token.balanceOf(BOB), MIN_STAKE);
        assertEq(core.acceptedProofs(), 0);
        assertEq(module.totalStake(), 0);
        _assertBooks();
    }

    /// @dev Never attached, detached (non-terminal) and retired: deposits
    /// and exits work where they should, assigns never do off the live
    /// module, and only a terminal detach waives the cooldown.
    function testExitsWorkUnwiredDetachedAndRetired() public {
        // (1) A fresh module that was never attached: prefunding works.
        PrefundedMiningPower live = module;
        PrefundedMiningPower fresh = _deployModule(MIN_STAKE, LOCK, COOLDOWN, 0, GUARDIAN);
        _deposit(CAROL, MIN_STAKE);
        vm.prank(CAROL);
        vm.expectRevert(PrefundedMiningPower.NotWired.selector);
        fresh.assign(MINER, MIN_STAKE);
        _withdraw(CAROL, 400e18);
        assertEq(fresh.unassignedOf(CAROL), 600e18);
        _assertBooks();

        // (2) The live module: ALICE pending, BOB matured, then a
        // non-terminal detach.
        module = live;
        _deposit(ALICE, MIN_STAKE);
        _assign(ALICE, MINER, MIN_STAKE);
        _qualify(BOB, MINER2, MIN_STAKE);
        uint256 t = block.timestamp;
        _detach();
        assertFalse(module.wired());
        assertFalse(module.retired());
        vm.prank(BOB);
        vm.expectRevert(PrefundedMiningPower.NotWired.selector);
        module.assign(MINER2, 1);
        // The cooldown still binds (no early hop to a replacement module).
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.CooldownNotMet.selector, t + COOLDOWN, t));
        module.unassign(MINER2, MIN_STAKE);
        // Deposits stay open while detached.
        _deposit(BOB, 5e18);
        vm.warp(t + COOLDOWN);
        _unassign(ALICE, MINER, MIN_STAKE);
        _unassign(BOB, MINER2, MIN_STAKE);
        // Detach waived the hold: BOB's matured exit leaves at once.
        assertEq(module.heldStakeOf(BOB), 0);
        _withdraw(ALICE, MIN_STAKE);
        _withdraw(BOB, MIN_STAKE + 5e18);
        assertEq(module.totalStake(), 0);
        _assertBooks();

        // (3) Re-attached (clean), backed, then retired by a keyed stop.
        _attach(module);
        _deposit(ALICE, MIN_STAKE);
        _assign(ALICE, MINER, MIN_STAKE);
        vm.prank(STOP);
        core.stopMining();
        assertTrue(module.retired());
        _unassign(ALICE, MINER, MIN_STAKE); // same timestamp: cooldown waived
        _withdraw(ALICE, MIN_STAKE);
        assertEq(token.balanceOf(ALICE), 2 * MIN_STAKE);
        assertEq(token.balanceOf(BOB), MIN_STAKE + 5e18);
        _assertBooks();
    }

    /// @dev After retirement nothing can enter (deposit and assign revert
    /// `Retired`, for newcomers and existing stakers alike) while every way
    /// out stays open: unassign, eviction of a sub-minimum backer, withdraw
    /// and the claim of an existing lock.
    function testNoNewEntriesAfterRetirement() public {
        _qualify(ALICE, MINER, MIN_STAKE);
        uint256 tokenId = _win(MINER);
        _qualify(BOB, MINER2, MIN_STAKE);
        _deposit(BOB, 50e18);
        vm.prank(STOP);
        core.stopMining();
        assertTrue(module.retired());
        _assertEligibility(MINER2, false, 1, MIN_STAKE);

        _expectDepositReverts(CAROL, 1e18, abi.encodeWithSelector(PrefundedMiningPower.Retired.selector));
        _expectDepositReverts(BOB, 1e18, abi.encodeWithSelector(PrefundedMiningPower.Retired.selector));
        vm.prank(BOB);
        vm.expectRevert(PrefundedMiningPower.Retired.selector);
        module.assign(MINER2, 50e18);
        vm.prank(CAROL);
        vm.expectRevert(PrefundedMiningPower.Retired.selector);
        module.assign(MINER, MIN_STAKE);

        // Ways out: the wallet evicts its sub-minimum backer, the others exit.
        assertEq(module.assignedOf(MINER), MIN_STAKE - LOCK);
        vm.prank(MINER);
        module.evictBacker(MINER);
        assertEq(module.unassignedOf(ALICE), MIN_STAKE - LOCK);
        _withdraw(ALICE, MIN_STAKE - LOCK);
        _unassign(BOB, MINER2, MIN_STAKE);
        _withdraw(BOB, MIN_STAKE + 50e18);
        _burn(tokenId);
        _claim(tokenId, MINER);
        assertEq(token.balanceOf(MINER), LOCK);
        assertEq(token.balanceOf(address(module)), 0);
        _assertBooks();
    }

    // ------------------------------------------------------------------
    // Failsafe
    // ------------------------------------------------------------------

    /// @dev One way, guardian only, moves no funds; afterwards mining is
    /// free (no lock), exits open, entries are refused and existing locks
    /// still pay on burn.
    function test_FailsafeOneWayMovesNoFunds() public {
        _qualify(ALICE, MINER, MIN_STAKE + LOCK);
        uint256 locked = _win(MINER);
        _activate();
        _deposit(BOB, 250e18);
        vm.warp(block.timestamp + COOLDOWN);
        _unassign(ALICE, MINER, 100e18); // matured: held this challenge
        assertEq(module.withdrawableOf(ALICE), 0);
        _deposit(ALICE, 1);
        _assign(ALICE, MINER, 1); // restarts ALICE's cooldown

        address[5] memory strangers = [ALICE, MINER, STOP, address(this), address(core)];
        for (uint256 i = 0; i < strangers.length; i++) {
            vm.prank(strangers[i]);
            vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.UnauthorizedCaller.selector, strangers[i]));
            module.disableRequirement();
        }
        assertFalse(module.gateDisabled());

        ModuleView memory m0 = _moduleView(MINER);
        uint256 bal = token.balanceOf(address(module));
        vm.expectEmit(true, false, false, true, address(module));
        emit PrefundedMiningPower.RequirementDisabled(GUARDIAN);
        vm.prank(GUARDIAN);
        module.disableRequirement();
        assertTrue(module.gateDisabled());
        assertEq(token.balanceOf(address(module)), bal);
        assertEq(module.totalStake(), m0.totalStake);
        assertEq(module.totalAssigned(), m0.totalAssigned);
        assertEq(module.totalCommitted(), m0.totalCommitted);
        assertEq(module.assignedOf(MINER), m0.walletStake);
        assertTrue(module.wired());

        vm.prank(GUARDIAN);
        vm.expectRevert(PrefundedMiningPower.GateDisabled.selector);
        module.disableRequirement();

        // Mining is free: a zero-stake wallet mines and no lock is taken.
        _assertEligibility(MINER2, true, 0, 0);
        uint256 freeId = _win(MINER2);
        assertEq(nft.ownerOf(freeId), MINER2);
        _assertNoLock(freeId);
        uint256 alsoFree = _win(MINER);
        _assertNoLock(alsoFree);
        assertEq(module.totalCommitted(), LOCK);
        assertEq(module.assignedOf(MINER), 900e18 + 1);
        _assertNoteEmpty();

        // Exits open at once (cooldown and hold waived); entries refused.
        uint256 t = module.assignTimestamp(ALICE);
        assertEq(block.timestamp, t);
        assertEq(module.withdrawableOf(ALICE), 100e18);
        _unassign(ALICE, MINER, 900e18 + 1);
        _withdraw(ALICE, MIN_STAKE + 1);
        _withdraw(BOB, 250e18);
        _expectDepositReverts(CAROL, 1e18, abi.encodeWithSelector(PrefundedMiningPower.GateDisabled.selector));
        vm.prank(BOB);
        vm.expectRevert(PrefundedMiningPower.GateDisabled.selector);
        module.assign(MINER2, 1);

        // The pre-failsafe lock still pays, and only on burn.
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.TokenNotBurned.selector, locked));
        module.claimCommitted(locked);
        _burn(locked);
        _claim(locked, MINER);
        assertEq(token.balanceOf(MINER), LOCK);
        assertEq(token.balanceOf(address(module)), 0);
        _assertBooks();
    }

    /// @dev Guardian address(0) means no failsafe: nobody — not even a
    /// call from address(0) — can disable the requirement.
    function test_FailsafeAbsentWhenGuardianZero() public {
        _detach();
        _deployModule(MIN_STAKE, LOCK, COOLDOWN, 0, address(0));
        _attach(module);
        assertEq(module.FAILSAFE_GUARDIAN(), address(0));
        address[5] memory callers = [address(0), GUARDIAN, STOP, ALICE, address(this)];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.UnauthorizedCaller.selector, callers[i]));
            module.disableRequirement();
        }
        assertFalse(module.gateDisabled());
    }

    // ------------------------------------------------------------------
    // Backer slot hygiene (decisions 8 and 9)
    // ------------------------------------------------------------------

    function testFirstAssignMustReachMinStake() public {
        _deposit(BOB, 2 * MIN_STAKE);
        uint256[3] memory tooSmall = [uint256(1), LOCK, MIN_STAKE - 1];
        for (uint256 i = 0; i < tooSmall.length; i++) {
            vm.prank(BOB);
            vm.expectRevert(
                abi.encodeWithSelector(PrefundedMiningPower.FirstAssignBelowMinimum.selector, tooSmall[i], MIN_STAKE)
            );
            module.assign(MINER, tooSmall[i]);
        }
        assertEq(module.backerOf(MINER), address(0));
        _assign(BOB, MINER, MIN_STAKE);
        assertEq(module.backerOf(MINER), BOB);

        // Once the slot is empty again, re-entry needs MIN_STAKE again —
        // also for the previous backer.
        vm.warp(block.timestamp + COOLDOWN);
        _unassign(BOB, MINER, MIN_STAKE); // pending: no counting removal
        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(PrefundedMiningPower.FirstAssignBelowMinimum.selector, MIN_STAKE - 1, MIN_STAKE)
        );
        module.assign(MINER, MIN_STAKE - 1);
        _assign(BOB, MINER, MIN_STAKE + 1);
        assertEq(module.assignedOf(MINER), MIN_STAKE + 1);
        _assertBooks();
    }

    function testTopUpBelowMinIsFineForExistingBacker() public {
        _qualify(ALICE, MINER, MIN_STAKE);
        _deposit(ALICE, 2 * LOCK);
        _assign(ALICE, MINER, 1);
        assertEq(module.assignedOf(MINER), MIN_STAKE + 1);
        _win(MINER);
        // Below the floor after the win; the backer tops back up with less
        // than MIN_STAKE — allowed, it is not a first assign.
        assertEq(module.assignedOf(MINER), MIN_STAKE + 1 - LOCK);
        _assign(ALICE, MINER, LOCK);
        assertEq(module.assignedOf(MINER), MIN_STAKE + 1);
        assertEq(module.backerOf(MINER), ALICE);
        _nextChallenge();
        _activate();
        _assertEligibility(MINER, true, 0, MIN_STAKE + 1);
        _assertBooks();
    }

    /// @dev CAROL squats MINER's slot with one matured wei (after a MIN_STAKE
    /// first assign and a partial exit) plus one pending wei that also
    /// restarts her cooldown. MINER evicts her: exactly `unassign`'s
    /// bookkeeping for CAROL (pending part free at once, matured part held
    /// and still counting), no cooldown check. A new backer must wait for
    /// the next snapshot (the evicted stake still counts), then backs and
    /// pays the wallet's next win.
    function testWalletEvictsSubMinimumBacker() public {
        _qualify(CAROL, MINER, MIN_STAKE);
        uint256 c = cid;
        vm.warp(block.timestamp + COOLDOWN);
        _unassign(CAROL, MINER, MIN_STAKE - 1);
        _deposit(CAROL, 1);
        _assign(CAROL, MINER, 1);
        assertEq(module.assignedOf(MINER), 2);
        assertEq(module.pendingOf(MINER), 1);
        assertEq(module.removingOf(MINER), MIN_STAKE - 1);
        assertEq(module.heldBy(CAROL), MIN_STAKE - 1);
        _deposit(ALICE, MIN_STAKE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.WalletAlreadyBacked.selector, CAROL));
        module.assign(MINER, MIN_STAKE);
        // CAROL's own exit is on cooldown again; the eviction ignores it.
        uint256 t = block.timestamp;
        vm.prank(CAROL);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.CooldownNotMet.selector, t + COOLDOWN, t));
        module.unassign(MINER, 2);

        // Corrupted totals block the eviction like any other exit.
        stdstore.target(address(module)).sig("totalStake()").checked_write(token.balanceOf(address(module)) + 1);
        vm.prank(MINER);
        vm.expectRevert(PrefundedMiningPower.Insolvency.selector);
        module.evictBacker(MINER);
        stdstore.target(address(module)).sig("totalStake()").checked_write(MIN_STAKE + 1 + MIN_STAKE);

        vm.expectEmit(true, true, false, true, address(module));
        emit PrefundedMiningPower.Unassigned(CAROL, MINER, 2, t);
        vm.expectEmit(true, true, false, true, address(module));
        emit PrefundedMiningPower.BackerEvicted(MINER, CAROL, 2);
        vm.prank(MINER);
        module.evictBacker(MINER);

        assertEq(module.assignedOf(MINER), 0);
        assertEq(module.assignedBy(CAROL), 0);
        assertEq(module.backerOf(MINER), address(0));
        assertEq(module.assigneeOf(CAROL), address(0));
        assertEq(module.totalAssigned(), 0);
        assertEq(module.pendingOf(MINER), 0);
        assertEq(module.pendingBy(CAROL), 0);
        assertEq(module.removingOf(MINER), MIN_STAKE);
        assertEq(module.unassignedOf(CAROL), MIN_STAKE + 1);
        assertEq(module.heldBy(CAROL), MIN_STAKE);
        assertEq(module.heldStakeOf(CAROL), MIN_STAKE);
        assertEq(module.withdrawableOf(CAROL), 1);
        // The evicted matured stake still counts this challenge (frozen), but
        // nothing live is left to pay a lock: reason 4.
        _assertEligibility(MINER, false, 4, MIN_STAKE);
        _assertBooks();

        // Same challenge: no new backer while that removal counts.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.WalletHasCountingRemoval.selector, MIN_STAKE));
        module.assign(MINER, MIN_STAKE);

        // Next snapshot: the hold lifts and the slot is free.
        _nextChallenge();
        _activate();
        assertEq(cid, c + 1);
        _withdraw(CAROL, MIN_STAKE + 1);
        _assign(ALICE, MINER, MIN_STAKE);
        assertEq(module.backerOf(MINER), ALICE);
        _nextChallenge();
        uint256 tokenId = _win(MINER);
        (,,,, address backer,) = module.committedOf(tokenId);
        assertEq(backer, ALICE);
        assertEq(token.balanceOf(CAROL), MIN_STAKE + 1);
        _assertBooks();
    }

    function testEvictRefusedWhenBackerAtOrAboveMin() public {
        // No backer at all.
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.BackerNotEvictable.selector, 0, MIN_STAKE));
        module.evictBacker(MINER);

        // Exactly MIN_STAKE, then above it.
        _qualify(ALICE, MINER, MIN_STAKE);
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.BackerNotEvictable.selector, MIN_STAKE, MIN_STAKE));
        module.evictBacker(MINER);
        _deposit(ALICE, 1);
        _assign(ALICE, MINER, 1);
        vm.prank(MINER);
        vm.expectRevert(
            abi.encodeWithSelector(PrefundedMiningPower.BackerNotEvictable.selector, MIN_STAKE + 1, MIN_STAKE)
        );
        module.evictBacker(MINER);

        // A win takes the stake below the floor: now evictable.
        _win(MINER);
        assertEq(module.assignedOf(MINER), MIN_STAKE + 1 - LOCK);
        vm.prank(MINER);
        module.evictBacker(MINER);
        assertEq(module.backerOf(MINER), address(0));
        assertEq(module.unassignedOf(ALICE), MIN_STAKE + 1 - LOCK);
        _assertBooks();
    }

    function testOnlyWalletCanEvict() public {
        _qualify(ALICE, MINER, MIN_STAKE);
        vm.warp(block.timestamp + COOLDOWN);
        _unassign(ALICE, MINER, MIN_STAKE - 1);
        _deposit(BOB, MIN_STAKE);
        _assign(BOB, MINER2, MIN_STAKE);

        address[6] memory others = [ALICE, BOB, MINER2, GUARDIAN, STOP, address(core)];
        for (uint256 i = 0; i < others.length; i++) {
            vm.prank(others[i]);
            vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.UnauthorizedCaller.selector, others[i]));
            module.evictBacker(MINER);
        }
        // A wallet cannot evict another wallet's backer either.
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.UnauthorizedCaller.selector, MINER));
        module.evictBacker(MINER2);
        assertEq(module.backerOf(MINER), ALICE);
        assertEq(module.backerOf(MINER2), BOB);

        vm.prank(MINER);
        module.evictBacker(MINER);
        assertEq(module.backerOf(MINER), address(0));
        assertEq(module.backerOf(MINER2), BOB);
        _assertBooks();
    }

    /// @dev Decision 9 (replaces S6's limitation test): ALICE's matured
    /// stake removed mid-challenge still qualifies MINER, but no new backer
    /// — nor ALICE herself — can refill the empty slot this challenge, so
    /// nobody's pending stake can pay a win admitted on removed stake: the
    /// admitted proof fails settlement instead. The slot reopens at the
    /// next snapshot, or at once if a detach waived the epoch.
    function testNewBackerRefusedWhileRemovedStakeCounts() public {
        _qualify(ALICE, MINER, MIN_STAKE);
        uint256 c = cid;
        vm.warp(block.timestamp + COOLDOWN);
        _unassign(ALICE, MINER, MIN_STAKE);
        assertEq(module.removingOf(MINER), MIN_STAKE);
        _assertEligibility(MINER, false, 4, MIN_STAKE);

        _deposit(BOB, MIN_STAKE);
        bytes memory counting =
            abi.encodeWithSelector(PrefundedMiningPower.WalletHasCountingRemoval.selector, MIN_STAKE);
        vm.prank(BOB);
        vm.expectRevert(counting);
        module.assign(MINER, MIN_STAKE);
        vm.prank(ALICE);
        vm.expectRevert(counting);
        module.assign(MINER, MIN_STAKE);
        // Another wallet is unaffected.
        _assign(BOB, MINER2, MIN_STAKE);
        vm.warp(block.timestamp + COOLDOWN);
        _unassign(BOB, MINER2, MIN_STAKE); // pending: nothing counts
        assertEq(module.removingOf(MINER2), 0);

        // MINER is admitted on the removed stake but nobody pays: rejected.
        (uint256 n,) = _nonce(MINER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.InsufficientFunds.selector, 0, LOCK));
        _send(MINER, n);
        assertEq(module.totalCommitted(), 0);

        // Next snapshot: the removal landed, BOB backs MINER and pays for
        // MINER's wins from the challenge after.
        _nextChallenge();
        _activate();
        assertEq(cid, c + 1);
        _assign(BOB, MINER, MIN_STAKE);
        assertEq(module.backerOf(MINER), BOB);
        _nextChallenge();
        uint256 tokenId = _win(MINER);
        (,,,, address backer,) = module.committedOf(tokenId);
        assertEq(backer, BOB);
        _assertBooks();

        // A detach waives the epoch: re-wired into it, the removal no longer
        // counts and the slot is free at once.
        _activate();
        _qualify(CAROL, MINER2, MIN_STAKE);
        vm.warp(block.timestamp + COOLDOWN);
        _unassign(CAROL, MINER2, MIN_STAKE);
        _unassign(BOB, MINER, MIN_STAKE - LOCK);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.WalletHasCountingRemoval.selector, MIN_STAKE));
        module.assign(MINER2, MIN_STAKE);
        _detach();
        _attach(module);
        assertEq(module.holdWaivedEpoch(), module.latestChallengeId());
        _assign(ALICE, MINER2, MIN_STAKE);
        assertEq(module.backerOf(MINER2), ALICE);
        _assertBooks();
    }

    // ------------------------------------------------------------------
    // Eligibility reason 4
    // ------------------------------------------------------------------

    /// @dev Reason 4: frozen stake passes, the live stake the lock is paid
    /// from is below LOCK. The GATE is unchanged — it still admits, and
    /// settlement fails closed — reason 4 only previews that failure.
    function testEligibilityReasonFourWhenLiveStakeBelowLock() public {
        _qualify(ALICE, MINER, MIN_STAKE + LOCK - 1);
        vm.warp(block.timestamp + COOLDOWN);
        _unassign(ALICE, MINER, MIN_STAKE);
        assertEq(module.assignedOf(MINER), LOCK - 1);
        _assertEligibility(MINER, false, 4, MIN_STAKE + LOCK - 1);

        // The gate admits (no NotEligible); settlement rejects.
        (uint256 n,) = _nonce(MINER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.InsufficientFunds.selector, LOCK - 1, LOCK));
        _send(MINER, n);

        // Exactly LOCK live: eligible again, and the win settles.
        _deposit(ALICE, 1);
        _assign(ALICE, MINER, 1);
        _assertEligibility(MINER, true, 0, MIN_STAKE + LOCK - 1);
        uint256 tokenId = _win(MINER);
        (uint256 amount,,,,,) = module.committedOf(tokenId);
        assertEq(amount, LOCK);

        // Reason 2 takes precedence (frozen below MIN_STAKE and live 0).
        _activate();
        _assertEligibility(MINER, false, 2, 0);

        // A wallet with no backer but a counting removal: live 0 → reason 4.
        _qualify(BOB, MINER2, MIN_STAKE);
        vm.warp(block.timestamp + COOLDOWN);
        _unassign(BOB, MINER2, MIN_STAKE);
        assertEq(module.backerOf(MINER2), address(0));
        _assertEligibility(MINER2, false, 4, MIN_STAKE);

        // After the failsafe no lock is taken, so reason 4 no longer applies.
        vm.prank(GUARDIAN);
        module.disableRequirement();
        _assertEligibility(MINER2, true, 0, MIN_STAKE);
        _assertBooks();
    }

    // ------------------------------------------------------------------
    // ABI: no admin surface
    // ------------------------------------------------------------------

    /// @dev Admin-style selectors do not exist (no fallback, no receive, so
    /// each call reverts), none of them is in the approved ABI, and ETH is
    /// refused. The approved list below is the whole external ABI (the
    /// orchestrator diffs it against `forge inspect ... methodIdentifiers`).
    function testNoAdminWithdrawalSelectors() public {
        _qualify(ALICE, MINER, MIN_STAKE);
        _deposit(BOB, 500e18);
        uint256 bal = token.balanceOf(address(module));
        _loadApproved();

        string[20] memory probes = [
            "sweep(address)",
            "rescue(address,uint256)",
            "withdrawTo(address,uint256)",
            "setToken(address)",
            "upgradeTo(address)",
            "transferOwnership(address)",
            "pause()",
            "setMinStake(uint256)",
            "owner()",
            "renounceOwnership()",
            "unpause()",
            "emergencyWithdraw()",
            "skim(address)",
            "setGuardian(address)",
            "setLockPerMint(uint256)",
            "setExitCooldown(uint256)",
            "setMiningCore(address)",
            "upgradeToAndCall(address,bytes)",
            "multicall(bytes[])",
            "enableRequirement()"
        ];
        for (uint256 i = 0; i < probes.length; i++) {
            bytes4 sel = bytes4(keccak256(bytes(probes[i])));
            assertFalse(_isApproved(sel), probes[i]);
            (bool ok,) = address(module).call(abi.encodePacked(sel, abi.encode(ALICE, uint256(bal), uint256(0))));
            assertFalse(ok, probes[i]);
            vm.prank(GUARDIAN);
            (ok,) = address(module).call(abi.encodePacked(sel, abi.encode(GUARDIAN, uint256(bal), uint256(0))));
            assertFalse(ok, probes[i]);
        }
        (bool sent,) = address(module).call{value: 1}("");
        assertFalse(sent, "module accepts ETH");
        (sent,) = address(module).call{value: 1}(abi.encodeWithSignature("deposit(uint256)", 1));
        assertFalse(sent, "payable deposit");

        // Approved selectors are distinct, and the list contains exactly the
        // user entry points that move tokens.
        for (uint256 i = 0; i < _approved.length; i++) {
            for (uint256 j = i + 1; j < _approved.length; j++) {
                assertTrue(
                    bytes4(keccak256(bytes(_approved[i]))) != bytes4(keccak256(bytes(_approved[j]))), _approved[i]
                );
            }
        }
        assertTrue(_isApproved(PrefundedMiningPower.withdraw.selector));
        assertTrue(_isApproved(PrefundedMiningPower.claimCommitted.selector));
        assertTrue(_isApproved(PrefundedMiningPower.claimCommittedTo.selector));
        assertTrue(_isApproved(PrefundedMiningPower.disableRequirement.selector));
        assertTrue(_isApproved(PrefundedMiningPower.evictBacker.selector));
        assertEq(token.balanceOf(address(module)), bal);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    struct ModuleView {
        uint256 latest;
        uint256 lastAccepted;
        uint256 totalStake;
        uint256 totalAssigned;
        uint256 totalCommitted;
        uint256 walletStake;
        uint256 frozen;
        uint256 balance;
        bool wired;
        bool retired;
        bool gateDisabled;
    }

    struct CoreView {
        uint256 target;
        uint256 lastEase;
        uint256 lastProof;
        uint256 windowProofs;
        uint256 windowStart;
        uint256 activeId;
        uint256 seedBlock;
        uint256 accepted;
    }

    function _moduleView(address wallet) private view returns (ModuleView memory v) {
        v.latest = module.latestChallengeId();
        v.lastAccepted = module.lastAcceptedProofs();
        v.totalStake = module.totalStake();
        v.totalAssigned = module.totalAssigned();
        v.totalCommitted = module.totalCommitted();
        v.walletStake = module.assignedOf(wallet);
        (,, v.frozen) = module.eligibilityOf(wallet);
        v.balance = token.balanceOf(address(module));
        v.wired = module.wired();
        v.retired = module.retired();
        v.gateDisabled = module.gateDisabled();
    }

    function _assertModuleView(ModuleView memory v, address wallet) private view {
        assertEq(keccak256(abi.encode(_moduleView(wallet))), keccak256(abi.encode(v)), "module state moved");
    }

    function _coreView() private view returns (CoreView memory v) {
        v.target = core.currentTarget();
        v.lastEase = core.lastEaseBlock();
        v.lastProof = core.lastProofBlock();
        v.windowProofs = core.retargetWindowProofs();
        v.windowStart = core.retargetWindowStartBlock();
        v.activeId = core.activeChallengeId();
        v.seedBlock = core.activeSeedParentBlock();
        v.accepted = core.acceptedProofs();
    }

    /// @dev After a terminal detach: exits open at once (cooldown and hold
    /// waived), entries refused, `tokenId`'s lock still pays after burn.
    function _assertTerminalExitsOpen(uint256 tokenId) private {
        assertTrue(module.retired());
        assertFalse(module.wired());
        assertEq(module.heldStakeOf(ALICE), 0);
        uint256 aliceAssigned = module.assignedBy(ALICE);
        _unassign(ALICE, MINER, aliceAssigned);
        _unassign(BOB, MINER2, MIN_STAKE + 1);
        uint256 aliceFree = module.unassignedOf(ALICE);
        _withdraw(ALICE, aliceFree);
        _withdraw(BOB, MIN_STAKE + 1);
        _expectDepositReverts(CAROL, 1e18, abi.encodeWithSelector(PrefundedMiningPower.Retired.selector));
        vm.prank(BOB);
        vm.expectRevert(PrefundedMiningPower.Retired.selector);
        module.assign(MINER2, 1);
        assertEq(module.totalStake(), 0);
        assertEq(module.totalAssigned(), 0);
        _burn(tokenId);
        _claim(tokenId, MINER);
        assertEq(token.balanceOf(MINER), LOCK);
        assertEq(token.balanceOf(address(module)), 0);
        _assertBooks();
    }

    /// @dev `who` holds `amount` fixture HUNTER, approves, and its deposit
    /// reverts with `err`; nothing is credited.
    function _expectDepositReverts(address who, uint256 amount, bytes memory err) private {
        token.mint(who, amount);
        uint256 before = module.unassignedOf(who);
        vm.startPrank(who);
        token.approve(address(module), amount);
        vm.expectRevert(err);
        module.deposit(amount);
        vm.stopPrank();
        assertEq(module.unassignedOf(who), before);
    }

    function _assertEligibility(address wallet, bool eligible, uint8 reason, uint256 stake) private view {
        (bool e, uint8 r, uint256 s) = module.eligibilityOf(wallet);
        assertEq(e, eligible, "eligible");
        assertEq(r, reason, "reason");
        assertEq(s, stake, "stake");
    }

    function _assertNoLock(uint256 tokenId) private view {
        (uint256 amount,,, address miner, address backer,) = module.committedOf(tokenId);
        assertEq(amount, 0, "unexpected lock");
        assertEq(miner, address(0));
        assertEq(backer, address(0));
    }

    function _assertNoteEmpty() private view {
        (uint256 note, address noteMiner) = module.pendingEligibleNote();
        assertEq(note, 0, "note survived");
        assertEq(noteMiner, address(0), "note miner survived");
    }

    function _max(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a : b;
    }

    function _isApproved(bytes4 sel) private view returns (bool) {
        for (uint256 i = 0; i < _approved.length; i++) {
            if (bytes4(keccak256(bytes(_approved[i]))) == sel) return true;
        }
        return false;
    }

    /// @dev The approved external ABI of PrefundedMiningPower (S8).
    function _loadApproved() private {
        string[50] memory sigs = [
            // immutables
            "HUNTER()",
            "miningCore()",
            "MIN_STAKE()",
            "LOCK_PER_MINT()",
            "EXIT_COOLDOWN()",
            "CURVE_UNIT()",
            "FAILSAFE_GUARDIAN()",
            // totals and flags
            "totalStake()",
            "totalAssigned()",
            "totalCommitted()",
            "lastAcceptedProofs()",
            "latestChallengeId()",
            "wired()",
            "retired()",
            "gateDisabled()",
            "holdWaivedEpoch()",
            // per-account ledger
            "unassignedOf(address)",
            "assignedOf(address)",
            "assignedBy(address)",
            "assigneeOf(address)",
            "backerOf(address)",
            "assignTimestamp(address)",
            "pendingOf(address)",
            "pendingEpoch(address)",
            "pendingBy(address)",
            "pendingEpochBy(address)",
            "removingOf(address)",
            "heldBy(address)",
            "heldEpochBy(address)",
            // Mining Core hooks (core only)
            "powerMultiplierWad(uint256,address)",
            "snapshottedLockedAmount(uint256,address)",
            "snapshotChallenge(uint256)",
            "onProofAccepted(uint256)",
            "onMiningPowerDetached(bool)",
            // user entry points
            "deposit(uint256)",
            "assign(address,uint256)",
            "unassign(address,uint256)",
            "evictBacker(address)",
            "withdraw(uint256)",
            "claimCommitted(uint256)",
            "claimCommittedTo(uint256,address)",
            // failsafe (guardian only, one way)
            "disableRequirement()",
            // views
            "eligibilityOf(address)",
            "committedOf(uint256)",
            "claimableOf(uint256)",
            "previewSubmit(address)",
            "heldStakeOf(address)",
            "withdrawableOf(address)",
            "pendingEligibleNote()",
            "multiplierFromLockedAmount(uint256)"
        ];
        delete _approved;
        for (uint256 i = 0; i < sigs.length; i++) {
            _approved.push(sigs[i]);
        }
    }
}
