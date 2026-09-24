// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HunterMiningCore} from "../src/bloom/HunterMiningCore.sol";
import {HunterNFT} from "../src/bloom/HunterNFT.sol";
import {BasketRegistry} from "../src/bloom/BasketRegistry.sol";
import {IMiningPower} from "../src/bloom/IMiningPower.sol";
import {MiningPowerCustody} from "../src/bloom/MiningPowerCustody.sol";
import {PrefundedMiningPower} from "../src/bloom/PrefundedMiningPower.sol";
import {HunterLifecycleFixture, HunterBasketFixture} from "./HunterNFT.t.sol";
import {DummyMiningPower, HunterMiningHarness} from "./HunterMiningCore.t.sol";

contract PrefundedDifficultyToken is ERC20 {
    constructor() ERC20("HUNTER", "HUNTER") {}
}

/// @dev S3 (VLT-54): the pass-through PrefundedMiningPower must leave the
/// core's difficulty, seed and counter state machine bit-for-bit identical to
/// a core wired to an ungated 1.0x module, and must only answer its own core.
contract PrefundedMiningPowerDifficultyTest is Test {
    using stdStorage for StdStorage;

    address private constant STOP = address(0x5709);
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant CAROL = address(0xCA201);
    uint256 private constant LOCK = 100e18;
    uint256 private constant CURVE_UNIT = 1_000e18;
    uint256 private constant STEPS = 300;

    BasketRegistry private registry;
    address private basket;
    PrefundedDifficultyToken private token;

    /// @dev Core wired to the PrefundedMiningPower under test.
    HunterMiningHarness private coreP;
    HunterNFT private nftP;
    /// @dev Twin core wired to the ungated DummyMiningPower (reference).
    HunterMiningHarness private coreD;
    HunterNFT private nftD;

    PrefundedMiningPower private module;
    DummyMiningPower private dummy;

    /// @dev Schedule coverage counters for the parity fuzz.
    uint256 private _eases;
    uint256 private _refreshes;
    uint256 private _retargets;

    function setUp() public {
        vm.roll(1_000);
        registry = new BasketRegistry(address(this));
        basket = address(new HunterBasketFixture());
        registry.admitBasket(basket, keccak256("review"));
        token = new PrefundedDifficultyToken();
        // Both cores are deployed in the same block, so they share genesis seed
        // block, deployment block (retarget/stall origin) and stop sunset.
        (coreP, nftP) = _deployCore();
        (coreD, nftD) = _deployCore();
        module = _module(address(coreP), 0);
        dummy = new DummyMiningPower();
    }

    // ------------------------------------------------------------------
    // 1. Difficulty parity with an ungated core
    // ------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 24
    /// forge-config: release.fuzz.runs = 24
    function testFuzz_DifficultyMatchesUngatedCore(uint256 seed) public {
        // S6: every accepted proof locks LOCK of the miner's mint funds;
        // funded before attach so the funds count from the first challenge.
        _fundBeforeAttach(module, ALICE, STEPS * LOCK);
        _fundBeforeAttach(module, BOB, STEPS * LOCK);
        _fundBeforeAttach(module, CAROL, STEPS * LOCK);
        _attach(coreP, module);
        _attach(coreD, dummy);
        _assertTwins();

        address[3] memory miners = [ALICE, BOB, CAROL];
        for (uint256 i = 0; i < STEPS; i++) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 op = r % 100;
            if (op < 45) {
                _acceptOnBoth(miners[(r >> 8) % 3]);
            } else if (op < 70) {
                vm.roll(block.number + 1 + ((r >> 16) % 300));
                _syncSeedHash();
            } else if (op < 80) {
                _refreshOnBoth();
            } else if (op < 92) {
                _easeOnBoth();
            } else {
                // Push a retarget quickly: the next few accepted proofs close
                // the 144-proof window over a seed-chosen observed span.
                uint256 count = 140 + ((r >> 24) % 4);
                uint256 span = (r >> 32) % 40_000;
                uint256 start = span >= block.number ? 0 : block.number - span;
                coreP.setWindow(count, start);
                coreD.setWindow(count, start);
            }
            _assertTwins();
        }
        // The schedule must actually exercise every difficulty transition.
        assertGt(coreP.acceptedProofs(), 50, "too few proofs");
        assertGt(_retargets, 0, "no retarget");
        assertGt(_eases, 0, "no ease");
        assertGt(_refreshes, 0, "no refresh");
    }

    // ------------------------------------------------------------------
    // 2. Only the bound core may call hooks
    // ------------------------------------------------------------------

    function testNonCoreCallersRejectedOnEveryHook() public {
        address contractCaller = address(new HunterBasketFixture());
        address[4] memory callers = [address(0xE0A), contractCaller, address(coreD), address(this)];
        for (uint256 i = 0; i < callers.length; i++) {
            _expectAllHooksRejected(callers[i]);
        }

        // A second real core driving its own attach flow is refused too, and
        // the module's bookkeeping is untouched.
        vm.prank(STOP);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.UnauthorizedCaller.selector, address(coreD)));
        coreD.setMiningPower(module);
        assertFalse(module.wired());
        assertEq(module.latestChallengeId(), 0);
        assertEq(module.lastAcceptedProofs(), 0);

        // Its own core still attaches cleanly afterwards.
        _attach(coreP, module);
        assertTrue(module.wired());
    }

    // ------------------------------------------------------------------
    // 3. Attach / detach / retire bookkeeping
    // ------------------------------------------------------------------

    function testAttachDetachBookkeeping() public {
        // Advance the core first so the attach-time sync is non-trivial.
        _mineOne(coreP, ALICE);
        _mineOne(coreP, BOB);
        _activate(coreP);
        assertEq(coreP.acceptedProofs(), 2);
        assertEq(coreP.activeChallengeId(), 3);

        _fundBeforeAttach(module, CAROL, LOCK); // S6 mint funds
        _attach(coreP, module);
        assertTrue(module.wired());
        assertFalse(module.retired());
        assertEq(module.latestChallengeId(), coreP.activeChallengeId());
        assertEq(module.lastAcceptedProofs(), coreP.acceptedProofs());
        assertFalse(module.gateDisabled());

        // A proof through the real path advances both counters in lockstep.
        _mineOne(coreP, CAROL);
        assertEq(module.lastAcceptedProofs(), 3);
        assertEq(module.latestChallengeId(), coreP.activeChallengeId());
        assertEq(module.latestChallengeId(), 4);

        // Non-terminal detach.
        vm.prank(STOP);
        coreP.setMiningPower(IMiningPower(address(0)));
        assertFalse(module.wired());
        assertFalse(module.retired());

        // Re-attaching the same module during a challenge it already opened is
        // allowed (epoch data intact), exactly like the old custody.
        _attach(coreP, module);
        assertTrue(module.wired());
        assertEq(module.latestChallengeId(), 4);
        vm.prank(STOP);
        coreP.setMiningPower(IMiningPower(address(0)));

        // Fresh module, then a keyed stop retires it.
        PrefundedMiningPower stopped = _module(address(coreP), 0);
        _attach(coreP, stopped);
        assertTrue(stopped.wired());
        assertEq(stopped.latestChallengeId(), coreP.activeChallengeId());
        assertEq(stopped.lastAcceptedProofs(), 3);
        vm.prank(STOP);
        coreP.stopMining();
        assertFalse(stopped.wired());
        assertTrue(stopped.retired());
        // The earlier (detached) module never hears about the stop.
        assertFalse(module.retired());

        // Fresh module on the twin core, then mint-out retires it.
        PrefundedMiningPower mintedOut = _module(address(coreD), 0);
        _fundBeforeAttach(mintedOut, ALICE, LOCK); // S6 mint funds
        _attach(coreD, mintedOut);
        // Boundary fixture skips prior history; no production setter exists.
        coreD.setCounts(4_999, 4_999);
        stdstore.target(address(nftD)).sig("mintedEver()").checked_write(4_999);
        _mineOne(coreD, ALICE);
        assertEq(uint256(coreD.challengeState()), uint256(HunterMiningCore.ChallengeState.ENDED));
        assertEq(mintedOut.lastAcceptedProofs(), 5_000);
        (uint256 locked,,,,) = mintedOut.committedOf(5_000);
        assertEq(locked, LOCK);
        assertFalse(mintedOut.wired());
        assertTrue(mintedOut.retired());
    }

    // ------------------------------------------------------------------
    // 4. Constructor validation
    // ------------------------------------------------------------------

    function testConstructorRejectsBadConfig() public {
        address core = address(coreP);
        address hunter = address(token);
        vm.expectRevert(PrefundedMiningPower.InvalidConfiguration.selector);
        new PrefundedMiningPower(address(0), core, 1, LOCK, 1 days, 0, address(0));
        vm.expectRevert(PrefundedMiningPower.InvalidConfiguration.selector);
        new PrefundedMiningPower(address(0xDEAD), core, 1, LOCK, 1 days, 0, address(0));
        vm.expectRevert(PrefundedMiningPower.InvalidConfiguration.selector);
        new PrefundedMiningPower(hunter, address(0), 1, LOCK, 1 days, 0, address(0));
        vm.expectRevert(PrefundedMiningPower.InvalidConfiguration.selector);
        new PrefundedMiningPower(hunter, address(0xC0DE), 1, LOCK, 1 days, 0, address(0));
        vm.expectRevert(PrefundedMiningPower.InvalidConfiguration.selector);
        new PrefundedMiningPower(hunter, core, 1, 0, 1 days, 0, address(0));

        // Zero minStake, zero cooldown and no guardian are valid test configs.
        PrefundedMiningPower ok = new PrefundedMiningPower(hunter, core, 0, 1, 0, CURVE_UNIT, address(0));
        assertEq(address(ok.HUNTER()), hunter);
        assertEq(ok.miningCore(), core);
        assertEq(ok.MIN_STAKE(), 0);
        assertEq(ok.LOCK_PER_MINT(), 1);
        assertEq(ok.EXIT_COOLDOWN(), 0);
        assertEq(ok.CURVE_UNIT(), CURVE_UNIT);
        assertEq(ok.FAILSAFE_GUARDIAN(), address(0));
        assertFalse(ok.wired());
        assertFalse(ok.retired());
        assertFalse(ok.gateDisabled());
        assertEq(ok.totalStake(), 0);
        assertEq(ok.totalAssigned(), 0);
        assertEq(ok.totalFunds(), 0);
        assertEq(ok.totalCommitted(), 0);
    }

    // ------------------------------------------------------------------
    // 5. Multiplier: base when the curve is disabled, old curve otherwise
    // ------------------------------------------------------------------

    function testMultiplierIsBaseWithCurveDisabledAndCurveWhenEnabled() public {
        // CURVE_UNIT == 0 → exactly 1.0x through the real submitProof path:
        // a digest just above the base target is rejected against the base
        // target itself (no widening), one inside it mints.
        _fundBeforeAttach(module, ALICE, LOCK); // S6 mint funds
        _attach(coreP, module);
        _activate(coreP);
        uint256 baseTarget = coreP.currentTarget();
        uint256 id = coreP.activeChallengeId();
        uint256 seedBlock = coreP.activeSeedParentBlock();
        (uint256 above, bytes32 aboveDigest) = _findNonce(coreP, ALICE, false);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.InvalidProof.selector, aboveDigest, baseTarget));
        coreP.submitProof(id, seedBlock, above, basket);
        (uint256 inside, bytes32 insideDigest) = _findNonce(coreP, ALICE, true);
        assertLe(uint256(insideDigest), baseTarget);
        vm.prank(ALICE);
        coreP.submitProof(id, seedBlock, inside, basket);
        assertEq(nftP.ownerOf(1), ALICE);
        assertEq(module.lastAcceptedProofs(), 1);

        uint256[9] memory xs =
            [uint256(0), 1, 999e18, 1_000e18, 3_000e18, 7_000e18, 1e30, 1e40, type(uint256).max];
        for (uint256 i = 0; i < xs.length; i++) {
            assertEq(module.multiplierFromLockedAmount(xs[i]), 1e18, "curve disabled");
        }

        // CURVE_UNIT != 0 → the old custody's curve, value for value.
        PrefundedMiningPower curved = _module(address(coreD), CURVE_UNIT);
        MiningPowerCustody old = new MiningPowerCustody(address(token), address(coreD), CURVE_UNIT);
        for (uint256 i = 0; i < xs.length; i++) {
            assertEq(curved.multiplierFromLockedAmount(xs[i]), old.multiplierFromLockedAmount(xs[i]), "curve");
        }
        assertEq(curved.multiplierFromLockedAmount(3_000e18), 2e18);
        assertEq(curved.multiplierFromLockedAmount(1e40), 3e18);

        // With no stake ledger yet, even a curve-enabled module feeds the core
        // the 1.0x base: an above-target digest still fails at the base target.
        _fundBeforeAttach(curved, ALICE, LOCK); // S6 mint funds
        _attach(coreD, curved);
        _activate(coreD);
        uint256 baseD = coreD.currentTarget();
        id = coreD.activeChallengeId();
        seedBlock = coreD.activeSeedParentBlock();
        (above, aboveDigest) = _findNonce(coreD, ALICE, false);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.InvalidProof.selector, aboveDigest, baseD));
        coreD.submitProof(id, seedBlock, above, basket);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _deployCore() private returns (HunterMiningHarness core, HunterNFT nft) {
        address predictedCore = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        address predictedNFT = vm.computeCreateAddress(predictedCore, 1);
        HunterLifecycleFixture lifecycle = new HunterLifecycleFixture(predictedNFT);
        core = new HunterMiningHarness(
            HunterMiningCore.ProofNftDeploymentData(
                address(registry), address(lifecycle), 1, address(0x123), "ipfs://hunters/"
            )
        );
        nft = core.PROOF_NFT();
        assertEq(address(nft), predictedNFT);
    }

    function _module(address core, uint256 curveUnit) private returns (PrefundedMiningPower) {
        return new PrefundedMiningPower(address(token), core, 0, LOCK, 1 days, curveUnit, address(0));
    }

    /// @dev S6: fixture HUNTER (dealt; the token has no mint) funds `wallet`
    /// on `m` before it is attached, so the funds count from the attach
    /// challenge on.
    function _fundBeforeAttach(PrefundedMiningPower m, address wallet, uint256 amount) private {
        deal(address(token), address(this), amount, true);
        token.approve(address(m), amount);
        m.fund(wallet, amount);
    }

    function _attach(HunterMiningHarness core, IMiningPower power) private {
        vm.prank(STOP);
        core.setMiningPower(power);
    }

    function _expectAllHooksRejected(address caller) private {
        bytes memory err = abi.encodeWithSelector(PrefundedMiningPower.UnauthorizedCaller.selector, caller);
        vm.prank(caller);
        vm.expectRevert(err);
        module.powerMultiplierWad(1, ALICE);
        vm.prank(caller);
        vm.expectRevert(err);
        module.snapshottedLockedAmount(1, ALICE);
        vm.prank(caller);
        vm.expectRevert(err);
        module.snapshotChallenge(1);
        vm.prank(caller);
        vm.expectRevert(err);
        module.onProofAccepted(1);
        vm.prank(caller);
        vm.expectRevert(err);
        module.onMiningPowerDetached(true);
    }

    /// @dev Make the core's current seed readable (blockhash set) when it is in
    /// its readable window. Both cores always share the same seed block.
    function _syncSeedHash() private {
        uint256 seedBlock = coreP.activeSeedParentBlock();
        if (block.number > seedBlock && block.number - seedBlock <= 256) {
            vm.setBlockhash(seedBlock, keccak256(abi.encode("seed", seedBlock)));
        }
    }

    function _activate(HunterMiningHarness core) private {
        uint256 seedBlock = core.activeSeedParentBlock();
        if (block.number <= seedBlock) vm.roll(seedBlock + 1);
        vm.setBlockhash(seedBlock, keccak256(abi.encode("seed", seedBlock)));
        assertEq(uint256(core.challengeState()), uint256(HunterMiningCore.ChallengeState.ACTIVE));
    }

    function _mineOne(HunterMiningHarness core, address miner) private {
        _activate(core);
        (uint256 nonce,) = _findNonce(core, miner, true);
        uint256 id = core.activeChallengeId();
        uint256 seedBlock = core.activeSeedParentBlock();
        vm.prank(miner);
        core.submitProof(id, seedBlock, nonce, basket);
    }

    function _findNonce(HunterMiningHarness core, address miner, bool valid)
        private
        view
        returns (uint256 nonce, bytes32 digest)
    {
        bytes32 challenge = core.currentChallenge();
        uint256 id = core.activeChallengeId();
        uint256 target = core.currentTarget();
        for (; nonce < 4096; nonce++) {
            digest = core.deriveProofDigest(id, challenge, miner, nonce);
            if ((uint256(digest) <= target) == valid) return (nonce, digest);
        }
        revert("nonce not found");
    }

    /// @dev Accept one proof from `miner` on both cores in the same block.
    /// Digests differ per core address; difficulty state never depends on them.
    function _acceptOnBoth(address miner) private {
        HunterMiningCore.ChallengeState state = coreP.challengeState();
        if (state == HunterMiningCore.ChallengeState.EXPIRED) {
            coreP.refreshExpiredSeed();
            coreD.refreshExpiredSeed();
            _refreshes++;
        }
        _activate(coreP);
        assertEq(uint256(coreD.challengeState()), uint256(HunterMiningCore.ChallengeState.ACTIVE));
        (uint256 nonceP,) = _findNonce(coreP, miner, true);
        (uint256 nonceD,) = _findNonce(coreD, miner, true);
        uint256 id = coreP.activeChallengeId();
        uint256 seedBlock = coreP.activeSeedParentBlock();
        if (coreP.retargetWindowProofs() + 1 == coreP.RETARGET_WINDOW_PROOFS()) _retargets++;
        vm.prank(miner);
        coreP.submitProof(id, seedBlock, nonceP, basket);
        vm.prank(miner);
        coreD.submitProof(id, seedBlock, nonceD, basket);
    }

    function _refreshOnBoth() private {
        if (_callBoth(abi.encodeCall(HunterMiningCore.refreshExpiredSeed, ()))) _refreshes++;
    }

    /// @dev When the stall interval can elapse inside the current seed life,
    /// roll to it so the ease actually lands; otherwise just prove both cores
    /// agree on the outcome (success or identical revert).
    function _easeOnBoth() private {
        if (coreP.challengeState() == HunterMiningCore.ChallengeState.ACTIVE) {
            uint256 ref = coreP.lastProofBlock() > coreP.lastEaseBlock() ? coreP.lastProofBlock() : coreP.lastEaseBlock();
            uint256 earliest = ref + coreP.STALL_INTERVAL_PARENT_BLOCKS();
            uint256 seedBlock = coreP.activeSeedParentBlock();
            if (earliest > block.number && earliest <= seedBlock + 256) vm.roll(earliest);
        }
        if (_callBoth(abi.encodeCall(HunterMiningCore.easeDifficulty, ()))) _eases++;
    }

    function _callBoth(bytes memory data) private returns (bool ok) {
        (bool okP, bytes memory retP) = address(coreP).call(data);
        (bool okD, bytes memory retD) = address(coreD).call(data);
        assertEq(okP, okD, "outcome diverged");
        assertEq(retP, retD, "return/revert data diverged");
        return okP;
    }

    function _assertTwins() private view {
        assertEq(coreP.currentTarget(), coreD.currentTarget(), "currentTarget");
        assertEq(coreP.retargetWindowProofs(), coreD.retargetWindowProofs(), "retargetWindowProofs");
        assertEq(coreP.retargetWindowStartBlock(), coreD.retargetWindowStartBlock(), "retargetWindowStartBlock");
        assertEq(coreP.lastProofBlock(), coreD.lastProofBlock(), "lastProofBlock");
        assertEq(coreP.lastEaseBlock(), coreD.lastEaseBlock(), "lastEaseBlock");
        assertEq(coreP.activeChallengeId(), coreD.activeChallengeId(), "activeChallengeId");
        assertEq(coreP.activeSeedParentBlock(), coreD.activeSeedParentBlock(), "activeSeedParentBlock");
        assertEq(coreP.acceptedProofs(), coreD.acceptedProofs(), "acceptedProofs");
        assertEq(coreP.nftsMintedEver(), coreD.nftsMintedEver(), "nftsMintedEver");
        assertEq(uint256(coreP.challengeState()), uint256(coreD.challengeState()), "challengeState");
        assertEq(nftP.mintedEver(), nftD.mintedEver(), "nft mintedEver");
        // The module's own bookkeeping tracks its core exactly.
        assertEq(module.latestChallengeId(), coreP.activeChallengeId(), "module latestChallengeId");
        assertEq(module.lastAcceptedProofs(), coreP.acceptedProofs(), "module lastAcceptedProofs");
        assertTrue(module.wired());
        assertFalse(module.retired());
    }
}
