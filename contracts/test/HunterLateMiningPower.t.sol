// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BasketRegistry} from "../src/bloom/BasketRegistry.sol";
import {HunterNFT} from "../src/bloom/HunterNFT.sol";
import {HunterLifecycle} from "../src/bloom/HunterLifecycle.sol";
import {HunterReserveVault} from "../src/bloom/HunterReserveVault.sol";
import {HunterBackingVault} from "../src/bloom/HunterBackingVault.sol";
import {WeightedRoundLedger} from "../src/bloom/WeightedRoundLedger.sol";
import {HunterMiningCore} from "../src/bloom/HunterMiningCore.sol";
import {MiningPowerCustody} from "../src/bloom/MiningPowerCustody.sol";
import {IMiningPower} from "../src/bloom/IMiningPower.sol";
import {HunterBasketFixture, HunterLifecycleFixture} from "./HunterNFT.t.sol";
import {DummyMiningPower} from "./HunterMiningCore.t.sol";
import {ReserveTokenFixture} from "./helpers/HunterReserveFixtures.sol";

/// @notice Late Mining Power attachment on the REAL assembled stack: the
/// mining core deploys its own HunterNFT wired into the canonical
/// lifecycle/ledger/backing/reserve chain, so `attachMiningPowerLate` derives
/// the token and its launch authority from immutable wiring — never from a
/// caller-supplied source. All amounts are TEST-ONLY values.
contract HunterLateMiningPowerTest is Test {
    using stdStorage for StdStorage;

    BasketRegistry internal registry;
    HunterLifecycle internal lc;
    WeightedRoundLedger internal ledger;
    HunterBackingVault internal backing;
    HunterReserveVault internal vault;
    HunterNFT internal nft;
    HunterMiningCore internal core;
    ReserveTokenFixture internal token;
    address internal basket;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant MINER = address(0x111E);
    address internal constant FUNDER = address(0xF0);
    address internal constant LAUNCH = address(0x1A04C);
    address internal constant STOP = address(0x5709);

    uint256 internal constant CURVE_UNIT = 1_000e18;

    uint256 internal cid;
    uint256 internal seed;

    function setUp() public virtual {
        vm.roll(1_000);
        vm.warp(100);
        registry = new BasketRegistry(address(this));
        basket = address(new HunterBasketFixture());
        registry.admitBasket(basket, keccak256("review"));

        // Real stack: the mining core lands LAST and deploys its own NFT, so
        // the lifecycle/reserve/backing predictions wrap around it.
        uint64 n = vm.getNonce(address(this));
        address wantCore = vm.computeCreateAddress(address(this), n + 4);
        address wantNft = vm.computeCreateAddress(wantCore, 1);
        address wantReserve = vm.computeCreateAddress(address(this), n + 3);
        address wantBacking = vm.computeCreateAddress(address(this), n + 2);
        lc = new HunterLifecycle(
            wantNft, wantReserve, wantBacking, [uint64(100), uint64(110), uint64(125), uint64(150)]
        );
        ledger = new WeightedRoundLedger(address(lc), address(this), 7, 10);
        backing = new HunterBackingVault(address(ledger), address(this));
        vault = new HunterReserveVault(wantNft, address(lc), LAUNCH);
        core = new HunterMiningCore(
            type(uint256).max / 4,
            type(uint256).max - type(uint256).max / 4,
            type(uint256).max / 2,
            block.number + 3,
            3,
            STOP,
            block.timestamp + 30 days,
            HunterMiningCore.ProofNftDeploymentData(address(registry), address(lc), 1, address(this), "ipfs://hunters/")
        );
        nft = core.PROOF_NFT();
        assertEq(address(nft), wantNft);
        assertEq(address(core), wantCore);
        assertEq(address(vault), wantReserve);
        assertEq(address(backing), wantBacking);
        assertEq(nft.MINER(), address(core));
        assertEq(address(nft.LIFECYCLE()), address(lc));
    }

    /// @dev Deploys the token late and records it through the launch authority.
    function _launchToken() internal returns (ReserveTokenFixture t) {
        t = new ReserveTokenFixture();
        t.setVault(address(vault));
        vm.prank(LAUNCH);
        vault.activateToken(address(t));
    }

    function _activate() internal {
        cid = core.activeChallengeId();
        seed = core.activeSeedParentBlock();
        vm.roll(seed + 1);
        vm.setBlockhash(seed, keccak256(abi.encode("seed", cid, seed)));
    }

    /// @dev Any nonce whose proof digest clears the current (base) target.
    function _nonce(address miner) internal view returns (uint256 nonce, bytes32 digest) {
        bytes32 challenge = core.currentChallenge();
        uint256 target = core.currentTarget();
        for (; nonce < 4_096; nonce++) {
            digest = core.deriveProofDigest(cid, challenge, miner, nonce);
            if (uint256(digest) <= target) return (nonce, digest);
        }
        revert("nonce not found");
    }

    /// @dev A nonce whose digest lands strictly ABOVE `lo` and at or below `hi`
    /// — the band that only a boosted effective target would accept.
    function _nonceInBand(address miner, uint256 lo, uint256 hi) internal view returns (uint256 nonce, bytes32 digest) {
        bytes32 challenge = core.currentChallenge();
        uint256 challengeId = core.activeChallengeId();
        for (; nonce < 4_096; nonce++) {
            digest = core.deriveProofDigest(challengeId, challenge, miner, nonce);
            if (uint256(digest) > lo && uint256(digest) <= hi) return (nonce, digest);
        }
        revert("nonce not found");
    }

    function _send(address miner, uint256 nonce) internal returns (bytes32) {
        vm.prank(miner);
        return core.submitProof(cid, seed, nonce, basket);
    }

    /// @notice THE acceptance path: mine real proofs with no token and no
    /// module, let the old setter sunset expire, launch the token, record it
    /// once, then attach the canonical custody through the dedicated path.
    function testPostSunsetAttachBindsCanonicalTokenAndCore() public {
        _activate();
        (uint256 nonce,) = _nonce(ALICE);
        _send(ALICE, nonce); // real pre-token, pre-module mint
        assertEq(nft.ownerOf(1), ALICE);
        assertEq(core.acceptedProofs(), 1);
        assertFalse(core.miningPowerWasAttached());
        assertEq(address(vault.HUNTER()), address(0));

        // The old wiring surface is dead after its sunset — even for the
        // multisig that owned it.
        uint256 sunset = core.MINING_STOP_SUNSET();
        vm.warp(sunset + 1);
        DummyMiningPower stale = new DummyMiningPower();
        vm.prank(STOP);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.MiningStopSunsetPassed.selector, sunset, sunset + 1));
        core.setMiningPower(stale);

        // Token launches later, gets recorded once, then the module attaches.
        token = _launchToken();
        MiningPowerCustody custody = new MiningPowerCustody(address(token), address(core), CURVE_UNIT);
        vm.prank(LAUNCH);
        vm.expectEmit(true, true, false, true, address(core));
        emit HunterMiningCore.MiningPowerSet(address(custody), LAUNCH);
        core.attachMiningPowerLate(custody);

        assertEq(address(core.miningPower()), address(custody));
        assertTrue(core.miningPowerWasAttached());
        assertTrue(custody.wired());
        assertFalse(custody.retired());
        assertEq(custody.latestChallengeId(), core.activeChallengeId()); // open challenge snapshotted at attach
        assertEq(custody.lastAcceptedProofs(), core.acceptedProofs()); // unlock clock synced
    }

    /// @notice Every wrong caller, source and module shape fails. The expired
    /// stop multisig holds NO power on this path — only the reserve's recorded
    /// launch authority does.
    function testLateAttachGuardMatrix() public {
        _activate();
        ReserveTokenFixture premature = new ReserveTokenFixture();
        MiningPowerCustody early = new MiningPowerCustody(address(premature), address(core), CURVE_UNIT);
        vm.prank(LAUNCH);
        vm.expectRevert(HunterMiningCore.CanonicalTokenNotActivated.selector);
        core.attachMiningPowerLate(early);

        token = _launchToken();
        MiningPowerCustody custody = new MiningPowerCustody(address(token), address(core), CURVE_UNIT);

        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.UnauthorizedMiningPowerActivation.selector, BOB));
        core.attachMiningPowerLate(custody);
        vm.prank(STOP); // the sunsetted multisig is not the launch authority
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.UnauthorizedMiningPowerActivation.selector, STOP));
        core.attachMiningPowerLate(custody);

        vm.prank(LAUNCH);
        vm.expectRevert(HunterMiningCore.InvalidMiningPowerModule.selector);
        core.attachMiningPowerLate(MiningPowerCustody(address(0)));

        address eoa = address(0xBEE5);
        assertEq(eoa.code.length, 0);
        vm.prank(LAUNCH);
        vm.expectRevert(HunterMiningCore.InvalidMiningPowerModule.selector);
        core.attachMiningPowerLate(MiningPowerCustody(eoa));

        // Module bound to a different mining core.
        MiningPowerCustody wrongCore = new MiningPowerCustody(address(token), address(this), CURVE_UNIT);
        vm.prank(LAUNCH);
        vm.expectRevert(
            abi.encodeWithSelector(HunterMiningCore.MiningPowerCoreMismatch.selector, address(core), address(this))
        );
        core.attachMiningPowerLate(wrongCore);

        // Module bound to a different token.
        ReserveTokenFixture otherToken = new ReserveTokenFixture();
        MiningPowerCustody wrongToken = new MiningPowerCustody(address(otherToken), address(core), CURVE_UNIT);
        vm.prank(LAUNCH);
        vm.expectRevert(
            abi.encodeWithSelector(
                HunterMiningCore.MiningPowerTokenMismatch.selector, address(token), address(otherToken)
            )
        );
        core.attachMiningPowerLate(wrongToken);

        // Success — then the one-time slot is consumed for every caller.
        vm.prank(LAUNCH);
        core.attachMiningPowerLate(custody);
        MiningPowerCustody second = new MiningPowerCustody(address(token), address(core), CURVE_UNIT);
        vm.prank(LAUNCH);
        vm.expectRevert(HunterMiningCore.MiningPowerAlreadyAttached.selector);
        core.attachMiningPowerLate(second);
        vm.prank(LAUNCH);
        vm.expectRevert(HunterMiningCore.MiningPowerAlreadyAttached.selector);
        core.attachMiningPowerLate(custody); // even the same module
    }

    /// @notice A module wired and detached through the OLD path consumes the
    /// one-time slot — the late path is never a post-sunset replacement
    /// surface for a second module.
    function testPriorAttachConsumesTheOneTimeSlot() public {
        _activate();
        DummyMiningPower first = new DummyMiningPower();
        vm.prank(STOP);
        core.setMiningPower(first);
        assertTrue(core.miningPowerWasAttached());
        vm.prank(STOP);
        core.setMiningPower(IMiningPower(address(0)));
        assertEq(address(core.miningPower()), address(0));
        assertTrue(core.miningPowerWasAttached()); // detach never clears it

        uint256 sunset = core.MINING_STOP_SUNSET();
        vm.warp(sunset + 1);
        token = _launchToken();
        MiningPowerCustody custody = new MiningPowerCustody(address(token), address(core), CURVE_UNIT);
        vm.prank(LAUNCH);
        vm.expectRevert(HunterMiningCore.MiningPowerAlreadyAttached.selector);
        core.attachMiningPowerLate(custody);
    }

    /// @notice Terminal states refuse late attach: a stopped core keeps its
    /// module permanently absent, and a minted-out core rejects a useless
    /// module — while NFT reserve deposits still work after mint-out.
    function testLateAttachRefusedAfterStopAndAfterMintOut() public {
        _activate();
        (uint256 nonce,) = _nonce(ALICE);
        _send(ALICE, nonce);
        uint256 mined = nft.mintedEver();
        assertEq(mined, 1);

        token = _launchToken();

        // Stopped: the module can never arrive to revive mining.
        MiningPowerCustody stoppedCustody = new MiningPowerCustody(address(token), address(core), CURVE_UNIT);
        vm.prank(STOP);
        core.stopMining();
        assertTrue(core.miningStopped());
        vm.prank(LAUNCH);
        vm.expectRevert(HunterMiningCore.MiningAlreadyStopped.selector);
        core.attachMiningPowerLate(stoppedCustody);
    }

    function testLateAttachRefusedAtMintOutButReservesStillWork() public {
        _activate();
        (uint256 nonce,) = _nonce(ALICE);
        _send(ALICE, nonce);
        assertEq(nft.ownerOf(1), ALICE);

        // TEST-ONLY mint-out: force consistent counters on the real contracts.
        stdstore.target(address(core)).sig("acceptedProofs()").checked_write(5_000);
        stdstore.target(address(core)).sig("nftsMintedEver()").checked_write(5_000);
        stdstore.target(address(nft)).sig("mintedEver()").checked_write(5_000);
        assertEq(uint256(core.challengeState()), uint256(HunterMiningCore.ChallengeState.ENDED));

        token = _launchToken();
        MiningPowerCustody custody = new MiningPowerCustody(address(token), address(core), CURVE_UNIT);
        vm.prank(LAUNCH);
        vm.expectRevert(
            abi.encodeWithSelector(HunterMiningCore.ChallengeNotActive.selector, HunterMiningCore.ChallengeState.ENDED)
        );
        core.attachMiningPowerLate(custody);
        assertEq(address(core.miningPower()), address(0));

        // NFT reserves still accept deposits and pay out at burn — mint-out
        // ends mining, never the token lifecycle.
        token.mint(ALICE, 300);
        vm.prank(ALICE);
        token.approve(address(vault), type(uint256).max);
        vm.prank(ALICE);
        assertEq(vault.deposit(1, 300), 300);
        assertEq(vault.reserveOf(1), 300);
        vm.prank(ALICE);
        nft.redeemAndDestroy(1);
        assertEq(token.balanceOf(ALICE), 300);
        assertTrue(vault.settled(1));
    }

    /// @notice The bonus can never reach the challenge that was already open:
    /// assignments are pending for the attach-time snapshot, so an over-target
    /// digest still fails on the open challenge, and the matured multiplier
    /// only applies from the NEXT challenge onward.
    function testNoRetroactiveBonusOnAlreadyOpenChallenge() public {
        _activate();
        token = _launchToken();
        MiningPowerCustody custody = new MiningPowerCustody(address(token), address(core), CURVE_UNIT);
        vm.prank(LAUNCH);
        core.attachMiningPowerLate(custody);
        assertEq(custody.latestChallengeId(), cid);

        token.mint(FUNDER, 10_000e18);
        vm.startPrank(FUNDER);
        token.approve(address(custody), type(uint256).max);
        custody.deposit(10_000e18);
        custody.assign(MINER, 3_000e18); // 3*unit -> 2x once matured
        vm.stopPrank();

        // Open-challenge freeze: zero locked, 1x multiplier.
        assertEq(custody.snapshottedLockedAmount(cid, MINER), 0);
        assertEq(custody.powerMultiplierWad(cid, MINER), 1e18);

        // A digest above the base target cannot settle while the challenge is
        // open — the pending assignment contributes nothing to it.
        uint256 base = core.currentTarget();
        (uint256 badNonce, bytes32 badDigest) = _nonceInBand(MINER, base, core.MAX_TARGET());
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.InvalidProof.selector, badDigest, base));
        core.submitProof(cid, seed, badNonce, basket);

        // An ordinary proof opens the next challenge (the seed rolls 3 blocks
        // forward — wait it out), then the assignment matures.
        (uint256 okNonce,) = _nonce(ALICE);
        _send(ALICE, okNonce);
        _activate(); // roll the post-proof seed window open, sync cid/seed
        uint256 cid2 = cid;
        assertEq(cid2, 2);
        assertEq(custody.latestChallengeId(), cid2);
        assertEq(custody.snapshottedLockedAmount(cid2, MINER), 3_000e18);
        assertEq(custody.powerMultiplierWad(cid2, MINER), 2e18); // log2(3+1)*0.5 + 1

        // Now the same wallet DOES get the widened band — next challenge only.
        uint256 base2 = core.currentTarget();
        uint256 widened = Math.mulDiv(base2, 2e18, 1e18);
        if (widened > core.MAX_TARGET()) widened = core.MAX_TARGET();
        assertGt(widened, base2);
        (uint256 goodNonce, bytes32 goodDigest) = _nonceInBand(MINER, base2, widened);
        assertGt(uint256(goodDigest), base2);
        vm.prank(MINER);
        core.submitProof(cid2, seed, goodNonce, basket);
        assertEq(nft.ownerOf(2), MINER);
    }

    /// @notice The unlock delay and separate withdrawal rules survive late
    /// attachment: the module clock is synced to the real proof count, and a
    /// terminal stop still releases all stake through the custody's own rules.
    function testUnlockDelaySyncAndTerminalRelease() public {
        _activate();
        (uint256 nonce,) = _nonce(ALICE);
        _send(ALICE, nonce); // acceptedProofs == 1

        token = _launchToken();
        MiningPowerCustody custody = new MiningPowerCustody(address(token), address(core), CURVE_UNIT);
        vm.prank(LAUNCH);
        core.attachMiningPowerLate(custody);
        assertEq(custody.lastAcceptedProofs(), 1); // synced, not zero

        token.mint(FUNDER, 10_000e18);
        vm.startPrank(FUNDER);
        token.approve(address(custody), type(uint256).max);
        custody.deposit(10_000e18);
        custody.assign(MINER, 3_000e18);

        // The delay runs off the synced clock: earliest = 1 + 12 = 13.
        vm.expectRevert(abi.encodeWithSelector(MiningPowerCustody.UnlockDelayNotMet.selector, 13, 1));
        custody.unassign(MINER, 3_000e18);

        stdstore.target(address(core)).sig("acceptedProofs()").checked_write(13);
        custody.unassign(MINER, 3_000e18);
        assertEq(custody.assignedOf(MINER), 0);
        custody.withdraw(10_000e18);
        assertEq(token.balanceOf(FUNDER), 10_000e18);
        assertEq(custody.totalLocked(), 0);
        vm.stopPrank();
    }

    /// @notice A terminal stop after late attachment still releases stake: the
    /// retired module answers its own withdrawal rules, never the core's.
    function testStopAfterLateAttachReleasesStake() public {
        _activate();
        token = _launchToken();
        MiningPowerCustody custody = new MiningPowerCustody(address(token), address(core), CURVE_UNIT);
        vm.prank(LAUNCH);
        core.attachMiningPowerLate(custody);

        token.mint(FUNDER, 10_000e18);
        vm.startPrank(FUNDER);
        token.approve(address(custody), type(uint256).max);
        custody.deposit(10_000e18);
        custody.assign(MINER, 3_000e18);
        vm.stopPrank();

        vm.prank(STOP);
        core.stopMining();
        assertTrue(custody.retired());
        assertFalse(custody.wired());

        vm.prank(FUNDER);
        custody.unassign(MINER, 3_000e18); // terminal: no delay
        vm.prank(FUNDER);
        custody.withdraw(10_000e18);
        assertEq(token.balanceOf(FUNDER), 10_000e18);
        assertEq(custody.totalAssigned(), 0);
        assertEq(custody.totalLocked(), 0);
    }

    /// @notice A mining core whose NFT lifecycle exposes no `reserve()` (the
    /// mining-only dry-run wiring) has no canonical token source at all — the
    /// derived chain fails closed instead of trusting a supplied address.
    function testAttachWithoutCanonicalReserveChainFailsClosed() public {
        address predictedCore = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        address predictedNFT = vm.computeCreateAddress(predictedCore, 1);
        HunterLifecycleFixture dry = new HunterLifecycleFixture(predictedNFT);
        HunterMiningCore dryCore = new HunterMiningCore(
            type(uint256).max / 4,
            type(uint256).max - type(uint256).max / 4,
            type(uint256).max / 2,
            block.number + 3,
            3,
            STOP,
            block.timestamp + 30 days,
            HunterMiningCore.ProofNftDeploymentData(address(registry), address(dry), 1, address(this), "ipfs://d/")
        );
        assertEq(address(dryCore.PROOF_NFT()), predictedNFT);

        ReserveTokenFixture anyToken = new ReserveTokenFixture();
        MiningPowerCustody custody = new MiningPowerCustody(address(anyToken), address(dryCore), CURVE_UNIT);
        vm.prank(LAUNCH);
        vm.expectRevert(HunterMiningCore.InvalidCanonicalReserve.selector);
        dryCore.attachMiningPowerLate(custody);
        assertEq(address(dryCore.miningPower()), address(0));
    }

    /// @notice Boundary fault injection: failed canonical reads cannot consume
    /// the one-time slot or substitute a token. Production wiring stays fixed.
    function testCanonicalReadFailuresLeaveLateAttachmentUnchanged() public {
        token = _launchToken();
        MiningPowerCustody custody = new MiningPowerCustody(address(token), address(core), CURVE_UNIT);
        bytes[3] memory reads = [
            abi.encodeWithSignature("HUNTER()"),
            abi.encodeWithSignature("TOKEN_AUTHORITY()"),
            abi.encodeWithSignature("NFT()")
        ];
        for (uint256 i; i < reads.length; ++i) {
            vm.mockCallRevert(address(vault), reads[i], "unavailable");
            vm.prank(LAUNCH);
            vm.expectRevert(HunterMiningCore.InvalidCanonicalReserve.selector);
            core.attachMiningPowerLate(custody);
            assertFalse(core.miningPowerWasAttached());
            assertEq(address(core.miningPower()), address(0));
            vm.clearMockedCalls();
        }
        vm.prank(LAUNCH);
        core.attachMiningPowerLate(custody);
        assertEq(address(core.miningPower()), address(custody));
    }

    /// @notice A broken detach hook cannot stop the emergency guardian from
    /// ending mining. The hook failure is emitted, not silently treated as success.
    function testRevertingDetachHookCannotBlockEmergencyStop() public {
        DummyMiningPower power = new DummyMiningPower();
        vm.prank(STOP);
        core.setMiningPower(power);
        vm.mockCallRevert(address(power), abi.encodeWithSignature("onMiningPowerDetached(bool)", true), "hook failed");
        vm.expectEmit(true, false, false, false, address(core));
        emit HunterMiningCore.MiningPowerDetachHookFailed(address(power));
        vm.prank(STOP);
        core.stopMining();
        assertTrue(core.miningStopped());
        assertEq(uint256(core.challengeState()), uint256(HunterMiningCore.ChallengeState.STOPPED));
        assertEq(core.acceptedProofs(), 0);
        assertEq(nft.mintedEver(), 0);
    }
}
