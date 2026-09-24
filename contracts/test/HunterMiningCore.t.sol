// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {HunterMiningCore} from "../src/bloom/HunterMiningCore.sol";
import {HunterNFT} from "../src/bloom/HunterNFT.sol";
import {BasketRegistry} from "../src/bloom/BasketRegistry.sol";
import {IMiningPower} from "../src/bloom/IMiningPower.sol";
import {HunterLifecycleFixture, HunterBasketFixture} from "./HunterNFT.t.sol";

contract DummyMiningPower is IMiningPower {
    uint256 public snapshots;
    uint256 public detaches;
    bool public lastDetachTerminal;

    function powerMultiplierWad(uint256, address) external pure returns (uint256) {
        return 1e18;
    }

    function snapshottedLockedAmount(uint256, address) external pure returns (uint256) {
        return 0;
    }

    function snapshotChallenge(uint256) external {
        snapshots += 1;
    }

    function onProofAccepted(uint256) external {}

    function onMiningPowerDetached(bool terminal) external {
        detaches += 1;
        lastDetachTerminal = terminal;
    }
}

contract HunterMiningHarness is HunterMiningCore {
    constructor(ProofNftDeploymentData memory d)
        HunterMiningCore(
            type(uint256).max / 4,
            type(uint256).max - type(uint256).max / 4,
            type(uint256).max / 2,
            block.number + 3,
            3,
            address(0x5709),
            block.timestamp + 30 days,
            d
        )
    {}

    function setCounts(uint256 proofs, uint256 nfts) external {
        acceptedProofs = proofs;
        nftsMintedEver = nfts;
    }

    function setWindow(uint256 count, uint256 start) external {
        retargetWindowProofs = count;
        retargetWindowStartBlock = start;
    }

    function setTarget(uint256 target) external {
        currentTarget = target;
    }

    function classify(bytes32 digest, uint256 target) external pure returns (bool, uint8) {
        return _classifyProof(digest, target);
    }

    function retarget(uint256 target, uint256 elapsed) external view returns (uint256, uint256) {
        return _calculateRetarget(target, elapsed);
    }

    function effective(uint256 accepted, uint256 multiplierWad) external view returns (uint256) {
        return _effectiveTarget(accepted, multiplierWad);
    }
}

contract HunterMiningCoreTest is Test {
    using stdStorage for StdStorage;
    HunterMiningHarness private core;
    HunterNFT private nft;
    HunterLifecycleFixture private lifecycle;
    BasketRegistry private registry;
    address private asset;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant STOP = address(0x5709);
    uint256 private id;
    uint256 private seed;

    function setUp() public {
        vm.roll(1_000);
        registry = new BasketRegistry(address(this));
        asset = address(new HunterBasketFixture());
        registry.admitBasket(asset, keccak256("review"));
        address predictedCore = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        address predictedNFT = vm.computeCreateAddress(predictedCore, 1);
        lifecycle = new HunterLifecycleFixture(predictedNFT);
        core = new HunterMiningHarness(_deployment());
        nft = core.PROOF_NFT();
        assertEq(address(nft), predictedNFT);
        assertEq(nft.MINER(), address(core));
    }

    function testEachAcceptedNonLotteryProofMintsSelectedNFTOnly() public {
        _activate();
        (uint256 nonce, bytes32 digest) = _nonce(ALICE, true);
        // Explicitly choose a digest that the old 1/51 scheme would not mint.
        assertGt(uint256(digest), core.currentTarget() / 51);
        assertEq(_send(ALICE, nonce, asset), digest);
        assertEq(nft.ownerOf(1), ALICE);
        assertEq(nft.basketOf(1), asset);
        assertEq(nft.mintedEver(), 1);
        assertEq(core.acceptedProofs(), 1);
        assertEq(core.nftsMintedEver(), 1);
        assertEq(lifecycle.mintCalls(), 1);
        assertEq(core.previousAcceptedDigest(), digest);
        (bool oldTokenGetter,) = address(core).staticcall(abi.encodeWithSignature("PROJECT_TOKEN()"));
        assertFalse(oldTokenGetter);
        assertEq(vm.getNonce(address(core)), 2, "only NFT child created");
    }

    function testBasketSelectionCanUseNewAdmissionAfterCoreDeployment() public {
        _activate();
        (uint256 nonce,) = _nonce(ALICE, true);
        address later = address(new HunterBasketFixture());
        registry.admitBasket(later, keccak256("later review"));
        _send(ALICE, nonce, later);
        assertEq(nft.basketOf(1), later);
    }

    function testUnknownAndDisabledBasketRollBackProofCounters() public {
        _activate();
        (uint256 nonce,) = _nonce(ALICE, true);
        vm.expectRevert(abi.encodeWithSelector(HunterNFT.InvalidBasket.selector, BOB));
        _send(ALICE, nonce, BOB);
        registry.setEntryEnabled(asset, false);
        vm.expectRevert(abi.encodeWithSelector(HunterNFT.InvalidBasket.selector, asset));
        _send(ALICE, nonce, asset);
        _assertNoSettlement();
        registry.setEntryEnabled(asset, true);
        _send(ALICE, nonce, asset);
        assertEq(nft.mintedEver(), 1);
    }

    function testRevertingLifecycleRollsBackWholeMiningTransaction() public {
        _activate();
        (uint256 nonce,) = _nonce(ALICE, true);
        lifecycle.setFail(true);
        vm.expectRevert(bytes("hook failed"));
        _send(ALICE, nonce, asset);
        _assertNoSettlement();
        assertEq(core.activeSeedParentBlock(), seed);
        assertEq(core.retargetWindowProofs(), 0);
        assertEq(nft.basketOf(1), address(0));
        lifecycle.setFail(false);
        _send(ALICE, nonce, asset);
        assertEq(nft.mintedEver(), 1);
    }

    function testInvalidProofAndCopiedWalletProofDoNotSettle() public {
        _activate();
        bytes32 challenge = core.currentChallenge();
        uint256 target = core.currentTarget();
        uint256 nonce;
        bytes32 digest;
        for (; nonce < 1024; nonce++) {
            digest = core.deriveProofDigest(id, challenge, BOB, nonce);
            if (uint256(digest) > target && uint256(core.deriveProofDigest(id, challenge, ALICE, nonce)) <= target) {
                break;
            }
        }
        assertLt(nonce, 1024);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.InvalidProof.selector, digest, target));
        _send(BOB, nonce, asset);
        _assertNoSettlement();
        _send(ALICE, nonce, asset);
        assertEq(nft.ownerOf(1), ALICE);
    }

    function testWaitingStaleSeedStaleChallengeAndReplayFail() public {
        id = core.activeChallengeId();
        seed = core.activeSeedParentBlock();
        vm.expectRevert(
            abi.encodeWithSelector(
                HunterMiningCore.ChallengeNotActive.selector, HunterMiningCore.ChallengeState.WAITING_FOR_SEED
            )
        );
        _send(ALICE, 0, asset);
        _activate();
        (uint256 nonce,) = _nonce(ALICE, true);
        uint256 correct = id;
        id = 0;
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.StaleChallengeId.selector, 0, correct));
        _send(ALICE, nonce, asset);
        id = correct;
        uint256 correctSeed = seed;
        seed = 0;
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.StaleSeedBlock.selector, 0, correctSeed));
        _send(ALICE, nonce, asset);
        seed = correctSeed;
        _send(ALICE, nonce, asset);
        _activate();
        id = correct;
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.StaleChallengeId.selector, correct, correct + 1));
        _send(ALICE, nonce, asset);
        assertEq(nft.mintedEver(), 1);
    }

    function testLifetimeCapacityEndsEvenAfterFinalNFTBurn() public {
        // Boundary fixture skips prior history; no production setter exists.
        core.setCounts(4_999, 4_999);
        stdstore.target(address(nft)).sig("mintedEver()").checked_write(4_999);
        _activate();
        (uint256 nonce,) = _nonce(ALICE, true);
        _send(ALICE, nonce, asset);
        assertEq(uint256(core.challengeState()), uint256(HunterMiningCore.ChallengeState.ENDED));
        assertEq(nft.ownerOf(5_000), ALICE);
        vm.prank(ALICE);
        nft.redeemAndDestroy(5_000);
        assertEq(core.nftsMintedEver(), 5_000);
        assertEq(nft.mintedEver(), 5_000);
        vm.expectRevert(
            abi.encodeWithSelector(HunterMiningCore.ChallengeNotActive.selector, HunterMiningCore.ChallengeState.ENDED)
        );
        _send(ALICE, nonce, asset);
    }

    function testTierBandsUseAcceptedTargetNotLotteryThreshold() public view {
        _assertTier(0, 4);
        _assertTier(10, 4);
        _assertTier(11, 3);
        _assertTier(80, 3);
        _assertTier(81, 2);
        _assertTier(300, 2);
        _assertTier(301, 1);
        _assertTier(1000, 1);
        (bool accepted, uint8 tier) = core.classify(bytes32(uint256(1001)), 1000);
        assertFalse(accepted);
        assertEq(tier, 0);
    }

    function testRetargetUsesSnapshotForBirthTier() public {
        _activate();
        uint256 oldTarget = core.currentTarget();
        core.setWindow(143, block.number - 900);
        (uint256 nonce, bytes32 digest) = _nonce(ALICE, true);
        (, uint8 expectedTier) = core.classify(digest, oldTarget);
        _send(ALICE, nonce, asset);
        assertEq(core.currentTarget(), core.MIN_TARGET());
        assertEq(core.retargetWindowProofs(), 0);
        (,,, uint8 actualTier) = nft.birthData(1);
        assertEq(actualTier, expectedTier);
    }

    function testRetargetClampsBothBoundsAndKeepsExpectedCadence() public view {
        // Cadence 50 → EXPECTED_RETARGET_PARENT_BLOCKS = 50 * 144 = 7200
        (uint256 same, uint256 elapsed) = core.retarget(core.GENESIS_TARGET(), 7200);
        assertEq(same, core.GENESIS_TARGET());
        assertEq(elapsed, 7200);
        (uint256 minimum, uint256 lowElapsed) = core.retarget(core.GENESIS_TARGET(), 1);
        assertEq(minimum, core.MIN_TARGET());
        assertEq(lowElapsed, 1800);
        (uint256 maximum, uint256 highElapsed) = core.retarget(core.GENESIS_TARGET(), 100_000);
        assertEq(maximum, core.MAX_TARGET());
        assertEq(highElapsed, 28_800);
    }

    function testExpiredSeedRefreshDoesNotMintOrChangeTarget() public {
        uint256 oldSeed = core.activeSeedParentBlock();
        vm.roll(oldSeed + 257);
        assertEq(uint256(core.challengeState()), uint256(HunterMiningCore.ChallengeState.EXPIRED));
        vm.prank(BOB);
        core.refreshExpiredSeed();
        assertEq(core.activeChallengeId(), 2);
        assertEq(core.activeSeedParentBlock(), block.number + 3);
        assertEq(core.currentTarget(), core.GENESIS_TARGET());
        assertEq(nft.mintedEver(), 0);
        assertEq(core.acceptedProofs(), 0);
    }

    function testSeedWindowExactEdges() public {
        uint256 s = core.activeSeedParentBlock();
        vm.roll(s);
        assertEq(uint256(core.challengeState()), uint256(HunterMiningCore.ChallengeState.WAITING_FOR_SEED));
        vm.roll(s + 1);
        vm.setBlockhash(s, bytes32(0));
        assertEq(uint256(core.challengeState()), uint256(HunterMiningCore.ChallengeState.WAITING_FOR_SEED));
        vm.setBlockhash(s, bytes32(uint256(7)));
        vm.roll(s + 256);
        assertEq(uint256(core.challengeState()), uint256(HunterMiningCore.ChallengeState.ACTIVE));
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.SeedNotExpired.selector, s, s + 256));
        core.refreshExpiredSeed();
        vm.roll(s + 257);
        core.refreshExpiredSeed();
    }

    function testEasingIsPermissionlessAndBounded() public {
        _activate();
        uint256 earliest = core.lastProofBlock() + 250;
        vm.expectRevert(
            abi.encodeWithSelector(HunterMiningCore.DifficultyStallIntervalNotMet.selector, earliest, block.number)
        );
        core.easeDifficulty();
        vm.roll(earliest);
        vm.setBlockhash(seed, bytes32(uint256(7)));
        vm.prank(BOB);
        core.easeDifficulty();
        assertGt(core.currentTarget(), core.GENESIS_TARGET());
        assertEq(core.lastEaseBlock(), earliest);
        assertEq(core.retargetWindowProofs(), 0);
        core.setTarget(core.MAX_TARGET());
        vm.expectRevert(HunterMiningCore.DifficultyAtMaximum.selector);
        core.easeDifficulty();
    }

    function testStopIsRestrictedAndLeavesNFTExitAvailable() public {
        _activate();
        (uint256 nonce,) = _nonce(ALICE, true);
        _send(ALICE, nonce, asset);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.UnauthorizedMiningStopCaller.selector, address(this)));
        core.stopMining();
        vm.prank(STOP);
        core.stopMining();
        assertTrue(core.miningStopped());
        vm.prank(ALICE);
        nft.redeemAndDestroy(1);
        assertEq(lifecycle.burnCalls(), 1);
        vm.prank(STOP);
        vm.expectRevert(HunterMiningCore.MiningAlreadyStopped.selector);
        core.stopMining();
        vm.expectRevert(
            abi.encodeWithSelector(
                HunterMiningCore.ChallengeNotActive.selector, HunterMiningCore.ChallengeState.STOPPED
            )
        );
        core.refreshExpiredSeed();
    }

    function testUnavailableChallengeViewsAndRecoveryFailClosed() public {
        bytes memory waiting = abi.encodeWithSelector(
            HunterMiningCore.ChallengeNotActive.selector, HunterMiningCore.ChallengeState.WAITING_FOR_SEED
        );
        vm.expectRevert(waiting);
        core.currentChallenge();
        vm.expectRevert(waiting);
        core.easeDifficulty();
        core.setCounts(5_000, 5_000);
        bytes memory ended =
            abi.encodeWithSelector(HunterMiningCore.ChallengeNotActive.selector, HunterMiningCore.ChallengeState.ENDED);
        vm.prank(STOP);
        vm.expectRevert(ended);
        core.stopMining();
        vm.expectRevert(ended);
        core.refreshExpiredSeed();
    }

    function testStopSunsetExpires() public {
        uint256 sunset = core.MINING_STOP_SUNSET();
        vm.warp(sunset + 1);
        vm.prank(STOP);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.MiningStopSunsetPassed.selector, sunset, sunset + 1));
        core.stopMining();
    }

    function testSetMiningPowerUsesStopKeyAndSunset() public {
        DummyMiningPower power = new DummyMiningPower();
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.UnauthorizedMiningStopCaller.selector, address(this)));
        core.setMiningPower(power);
        vm.prank(STOP);
        vm.expectEmit(true, true, false, true, address(core));
        emit HunterMiningCore.MiningPowerSet(address(power), STOP);
        core.setMiningPower(power);
        assertEq(address(core.miningPower()), address(power));
        assertEq(power.snapshots(), 1);

        vm.prank(STOP);
        core.stopMining();
        DummyMiningPower other = new DummyMiningPower();
        vm.prank(STOP);
        vm.expectRevert(HunterMiningCore.MiningAlreadyStopped.selector);
        core.setMiningPower(other);
    }

    function testSetMiningPowerSunsetAndEndedRefuse() public {
        DummyMiningPower power = new DummyMiningPower();
        uint256 sunset = core.MINING_STOP_SUNSET();
        vm.warp(sunset + 1);
        vm.prank(STOP);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.MiningStopSunsetPassed.selector, sunset, sunset + 1));
        core.setMiningPower(power);
        vm.warp(sunset);
        core.setCounts(5_000, 5_000);
        vm.prank(STOP);
        vm.expectRevert(
            abi.encodeWithSelector(HunterMiningCore.ChallengeNotActive.selector, HunterMiningCore.ChallengeState.ENDED)
        );
        core.setMiningPower(power);
        assertEq(address(core.miningPower()), address(0));
    }

    function testPowerMultiplierClampsToPublishedMaximum() public view {
        uint256 accepted = 1_000;
        assertEq(core.effective(accepted, 1e18), accepted);
        assertEq(core.effective(accepted, 0), accepted);
        assertEq(core.effective(accepted, 3e18), 3_000);
        assertEq(core.effective(accepted, type(uint256).max), 3_000);
        assertEq(core.effective(core.MAX_TARGET(), 3e18), core.MAX_TARGET());
    }

    function testCounterTripNeedsRealMismatchAndIsPermissionless() public {
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.NoMiningCounterViolation.selector, 0, 0, 0));
        core.tripMining();
        core.setCounts(1, 0);
        vm.prank(BOB);
        core.tripMining();
        assertTrue(core.miningStopped());
        vm.expectRevert(HunterMiningCore.MiningAlreadyStopped.selector);
        core.tripMining();
    }

    function testCounterTripDetectsIndependentNFTCount() public {
        stdstore.target(address(nft)).sig("mintedEver()").checked_write(1);
        vm.prank(BOB);
        core.tripMining();
        assertTrue(core.miningStopped());
    }

    function testFourArgumentCalldataAndNoOldSelector() public {
        _activate();
        (uint256 nonce,) = _nonce(ALICE, true);
        bytes memory data = abi.encodeWithSelector(
            bytes4(keccak256("submitProof(uint256,uint256,uint256,address)")), id, seed, nonce, asset
        );
        assertEq(data, abi.encodeCall(core.submitProof, (id, seed, nonce, asset)));
        vm.prank(ALICE);
        (bool ok,) = address(core).call(data);
        assertTrue(ok);
        assertEq(nft.ownerOf(1), ALICE);
        (bool old,) =
            address(core).call(abi.encodeWithSignature("submitProof(uint256,uint256,uint256)", id, seed, nonce));
        assertFalse(old);
    }

    function testHistoricalProofAndChallengeVectorsStayExact() public {
        vm.chainId(4663);
        address vectorAddress = 0x102030405060708090A0B0c0d0E0f00112233445;
        vm.etch(vectorAddress, address(core).code);
        HunterMiningCore v = HunterMiningCore(vectorAddress);
        bytes32 prior = bytes32(type(uint256).max / 255 * 0xa5);
        bytes32 blockHash = bytes32(type(uint256).max / 255 * 0x5a);
        bytes32 challenge = v.deriveChallenge(19, prior, 22_345_678, blockHash);
        assertEq(challenge, 0xdbdf9249c8cf0d32528454ed49a5213a12eda397173e41c777459e22631e356a);
        assertEq(
            v.deriveProofDigest(19, challenge, 0x1111111111111111111111111111111111111111, 7),
            0xe0728a02790ebf24be70574538af0f2e326940edc70ae1114a464f9e9adbb6d1
        );
        assertEq(
            v.deriveProofDigest(19, challenge, 0xDeAdbEEf000102030405060708090A0b0c0D0e0f, type(uint256).max),
            0x2d283617f3625a1cb8890a4287050a6ad9e51eb33e98174df059c8a6cf9923f6
        );
        assertEq(
            v.deriveProofDigest(19, challenge, 0x2222222222222222222222222222222222222222, 42),
            0xfcfe7452900c75997e949f87b7eaaaf09743a9f37f2e811badcc21e1aa65fa99
        );
        assertEq(
            v.PROOF_TYPEHASH(),
            keccak256(
                "BondedProofV1(uint256 chainId,address miningCore,uint256 proofVersion,uint256 challengeId,bytes32 challenge,address miner,uint256 nonce)"
            )
        );
        assertEq(
            v.CHALLENGE_TYPEHASH(),
            keccak256(
                "BondedChallengeV1(uint256 chainId,address miningCore,uint256 proofVersion,uint256 challengeId,bytes32 previousAcceptedDigest,uint256 seedParentBlock,bytes32 seedBlockhash)"
            )
        );
    }

    function testInvalidMiningConfigurationRejectedBeforeChildCreation() public {
        HunterMiningCore.ProofNftDeploymentData memory d = _deployment();
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.InvalidTargetConfiguration.selector, 0, 200, 300));
        new HunterMiningCore(0, 300, 200, block.number + 3, 3, STOP, block.timestamp + 30 days, d);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.InvalidTargetConfiguration.selector, 100, 0, 300));
        new HunterMiningCore(100, 300, 0, block.number + 3, 3, STOP, block.timestamp + 30 days, d);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.InvalidTargetConfiguration.selector, 100, 200, 0));
        new HunterMiningCore(100, 0, 200, block.number + 3, 3, STOP, block.timestamp + 30 days, d);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.InvalidTargetConfiguration.selector, 200, 200, 300));
        new HunterMiningCore(200, 300, 200, block.number + 3, 3, STOP, block.timestamp + 30 days, d);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.InvalidTargetConfiguration.selector, 100, 300, 300));
        new HunterMiningCore(100, 300, 300, block.number + 3, 3, STOP, block.timestamp + 30 days, d);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.UnusableMinimumNftThreshold.selector, 1, 0));
        new HunterMiningCore(1, 300, 200, block.number + 3, 3, STOP, block.timestamp + 30 days, d);
        vm.expectRevert(
            abi.encodeWithSelector(HunterMiningCore.InvalidMiningStopMultisig.selector, address(0), address(this))
        );
        new HunterMiningCore(100, 300, 200, block.number + 3, 3, address(0), block.timestamp + 30 days, d);
        vm.expectRevert(
            abi.encodeWithSelector(HunterMiningCore.InvalidMiningStopMultisig.selector, address(this), address(this))
        );
        new HunterMiningCore(100, 300, 200, block.number + 3, 3, address(this), block.timestamp + 30 days, d);
        vm.expectRevert(
            abi.encodeWithSelector(
                HunterMiningCore.InvalidMiningStopSunset.selector,
                block.timestamp,
                block.timestamp + 30 days,
                block.timestamp + 180 days
            )
        );
        new HunterMiningCore(100, 300, 200, block.number + 3, 3, STOP, block.timestamp, d);
        uint256 tooLate = block.timestamp + 180 days + 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                HunterMiningCore.InvalidMiningStopSunset.selector,
                tooLate,
                block.timestamp + 30 days,
                block.timestamp + 180 days
            )
        );
        new HunterMiningCore(100, 300, 200, block.number + 3, 3, STOP, tooLate, d);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.InvalidGenesisSeedMinimumDelay.selector, 2, 3));
        new HunterMiningCore(100, 300, 200, block.number + 3, 2, STOP, block.timestamp + 30 days, d);
        vm.expectRevert(
            abi.encodeWithSelector(HunterMiningCore.GenesisSeedNotFuture.selector, block.number, block.number)
        );
        new HunterMiningCore(100, 300, 200, block.number, 3, STOP, block.timestamp + 30 days, d);
        vm.expectRevert(
            abi.encodeWithSelector(HunterMiningCore.GenesisSeedTooSoon.selector, block.number + 1, block.number + 3)
        );
        new HunterMiningCore(100, 300, 200, block.number + 1, 3, STOP, block.timestamp + 30 days, d);
    }

    function testConstructorAcceptsSunsetAndGenesisDelayBounds() public {
        address predictedCore = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        address predictedNFT = vm.computeCreateAddress(predictedCore, 1);
        HunterLifecycleFixture lc = new HunterLifecycleFixture(predictedNFT);
        HunterMiningCore late = new HunterMiningCore(
            100,
            300,
            200,
            block.number + 4,
            4,
            STOP,
            block.timestamp + 180 days,
            HunterMiningCore.ProofNftDeploymentData(
                address(registry), address(lc), 1, address(0x123), "ipfs://hunters/"
            )
        );
        assertEq(address(late.PROOF_NFT()), predictedNFT);
        assertEq(late.MINING_STOP_SUNSET(), block.timestamp + 180 days);
        assertEq(late.GENESIS_SEED_MINIMUM_DELAY(), 4);
        assertEq(late.GENESIS_SEED_PARENT_BLOCK(), block.number + 4);
    }

    function testSetMiningPowerZeroUnwiresWithoutResnapshot() public {
        DummyMiningPower power = new DummyMiningPower();
        vm.prank(STOP);
        core.setMiningPower(power);
        assertEq(power.snapshots(), 1);
        vm.prank(STOP);
        core.setMiningPower(IMiningPower(address(0)));
        assertEq(address(core.miningPower()), address(0));
        assertEq(power.snapshots(), 1);
    }

    /// @dev Regression B3: rewiring must be explicit. Replacing a live module
    /// silently resets every power snapshot mid-challenge; STOP must detach to
    /// the zero address first so a swap is two deliberate transactions.
    function testSetMiningPowerRequiresDetachBeforeRewire() public {
        DummyMiningPower first = new DummyMiningPower();
        DummyMiningPower second = new DummyMiningPower();
        vm.prank(STOP);
        core.setMiningPower(first);
        assertEq(first.snapshots(), 1);

        vm.prank(STOP);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.MiningPowerAlreadyWired.selector, address(first)));
        core.setMiningPower(second);

        // Re-affirming the same module must not hit the module's snapshot guard.
        vm.prank(STOP);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.MiningPowerAlreadyWired.selector, address(first)));
        core.setMiningPower(first);

        vm.prank(STOP);
        core.setMiningPower(IMiningPower(address(0)));
        assertEq(address(core.miningPower()), address(0));
        assertEq(first.detaches(), 1);

        vm.prank(STOP);
        core.setMiningPower(second);
        assertEq(address(core.miningPower()), address(second));
        assertEq(second.snapshots(), 1);
        assertEq(second.detaches(), 0);
    }

    /// @dev Regression (devin-review round 3): every terminal transition must
    /// retire the wired module — after a stop or mint-out no proof callback can
    /// ever advance its unlock clock, so custody must release assigned stake
    /// instead of locking it forever.
    function testStopMiningRetiresWiredModule() public {
        DummyMiningPower power = new DummyMiningPower();
        vm.prank(STOP);
        core.setMiningPower(power);
        assertEq(power.detaches(), 0);

        vm.prank(STOP);
        core.stopMining();
        assertEq(power.detaches(), 1);
    }

    function testMintOutRetiresWiredModule() public {
        DummyMiningPower power = new DummyMiningPower();
        vm.prank(STOP);
        core.setMiningPower(power);

        // Boundary fixture skips prior history; no production setter exists.
        core.setCounts(4_999, 4_999);
        stdstore.target(address(nft)).sig("mintedEver()").checked_write(4_999);
        _activate();
        (uint256 nonce,) = _nonce(ALICE, true);
        _send(ALICE, nonce, asset);
        assertEq(uint256(core.challengeState()), uint256(HunterMiningCore.ChallengeState.ENDED));
        assertEq(power.detaches(), 1);
    }

    function testEaseSaturatesAtMaximumAndSecondEaseUsesEaseClock() public {
        _activate();
        core.setTarget(core.MAX_TARGET() - 1);
        uint256 first = core.lastProofBlock() + 250;
        vm.roll(first);
        vm.setBlockhash(seed, keccak256(abi.encode("seed", id, seed)));
        vm.prank(BOB);
        core.easeDifficulty();
        assertEq(core.currentTarget(), core.MAX_TARGET());
        assertEq(core.lastEaseBlock(), first);
        assertEq(core.retargetWindowProofs(), 0);

        vm.expectRevert(HunterMiningCore.DifficultyAtMaximum.selector);
        core.easeDifficulty();

        // Seed life is 256 blocks; the next stall tick is 250 after ease, so
        // the expired-seed refresh must open a new window first.
        vm.roll(seed + 257);
        core.refreshExpiredSeed();
        _activate();
        core.setTarget(core.GENESIS_TARGET());
        uint256 tooSoon = first + 249;
        vm.roll(tooSoon);
        vm.setBlockhash(seed, keccak256(abi.encode("seed", id, seed)));
        vm.expectRevert(
            abi.encodeWithSelector(HunterMiningCore.DifficultyStallIntervalNotMet.selector, first + 250, tooSoon)
        );
        core.easeDifficulty();
        vm.roll(first + 250);
        vm.setBlockhash(seed, keccak256(abi.encode("seed", id, seed)));
        core.easeDifficulty();
        assertEq(core.lastEaseBlock(), first + 250);
        assertGt(core.currentTarget(), core.GENESIS_TARGET());
        assertLt(core.currentTarget(), core.MAX_TARGET());
    }

    function testRefreshAndEaseRejectWaitingAndExpiredStates() public {
        uint256 waitingSeed = core.activeSeedParentBlock();
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.SeedNotExpired.selector, waitingSeed, block.number));
        core.refreshExpiredSeed();
        vm.expectRevert(
            abi.encodeWithSelector(
                HunterMiningCore.ChallengeNotActive.selector, HunterMiningCore.ChallengeState.WAITING_FOR_SEED
            )
        );
        core.easeDifficulty();

        _activate();
        vm.roll(seed + 257);
        vm.expectRevert(
            abi.encodeWithSelector(
                HunterMiningCore.ChallengeNotActive.selector, HunterMiningCore.ChallengeState.EXPIRED
            )
        );
        core.easeDifficulty();
        core.refreshExpiredSeed();
        vm.expectRevert(
            abi.encodeWithSelector(HunterMiningCore.SeedNotExpired.selector, core.activeSeedParentBlock(), block.number)
        );
        core.refreshExpiredSeed();
    }

    function testRetargetStaysAtMaxWhenAlreadySaturated() public view {
        (uint256 stillMax, uint256 highElapsed) = core.retarget(core.MAX_TARGET(), 100_000);
        assertEq(stillMax, core.MAX_TARGET());
        assertEq(highElapsed, 28_800);
        (uint256 fromMin,) = core.retarget(core.MIN_TARGET(), 7200);
        assertEq(fromMin, core.MIN_TARGET());
    }

    function _deployment() private view returns (HunterMiningCore.ProofNftDeploymentData memory) {
        return HunterMiningCore.ProofNftDeploymentData(
            address(registry), address(lifecycle), 1, address(0x123), "ipfs://hunters/"
        );
    }

    function _activate() private {
        id = core.activeChallengeId();
        seed = core.activeSeedParentBlock();
        vm.roll(seed + 1);
        vm.setBlockhash(seed, keccak256(abi.encode("seed", id, seed)));
    }

    function _nonce(address miner, bool ordinary) private view returns (uint256 nonce, bytes32 digest) {
        bytes32 challenge = core.currentChallenge();
        uint256 target = core.currentTarget();
        for (; nonce < 1024; nonce++) {
            digest = core.deriveProofDigest(id, challenge, miner, nonce);
            if (uint256(digest) <= target && (!ordinary || uint256(digest) > target / 51)) return (nonce, digest);
        }
        revert("nonce not found");
    }

    function _send(address miner, uint256 nonce, address basket) private returns (bytes32) {
        vm.prank(miner);
        return core.submitProof(id, seed, nonce, basket);
    }

    function _assertNoSettlement() private view {
        assertEq(core.acceptedProofs(), 0);
        assertEq(core.nftsMintedEver(), 0);
        assertEq(nft.mintedEver(), 0);
        assertEq(core.previousAcceptedDigest(), bytes32(0));
        assertEq(lifecycle.mintCalls(), 0);
    }

    function _assertTier(uint256 value, uint8 tier) private view {
        (bool accepted, uint8 result) = core.classify(bytes32(value), 1000);
        assertTrue(accepted);
        assertEq(result, tier);
    }
}
