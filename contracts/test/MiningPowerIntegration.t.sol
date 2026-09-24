// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MiningPowerCustody} from "../src/bloom/MiningPowerCustody.sol";
import {HunterMiningCore} from "../src/bloom/HunterMiningCore.sol";
import {HunterNFT} from "../src/bloom/HunterNFT.sol";
import {BasketRegistry} from "../src/bloom/BasketRegistry.sol";
import {HunterLifecycleFixture, HunterBasketFixture} from "./HunterNFT.t.sol";

contract MockHunterTokenInt is ERC20 {
    constructor() ERC20("HUNTER", "HUNTER") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract HunterMiningHarnessInt is HunterMiningCore {
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

    function effective(uint256 accepted, uint256 multiplierWad) external view returns (uint256) {
        return _effectiveTarget(accepted, multiplierWad);
    }
}

contract MiningPowerIntegrationTest is Test {
    MockHunterTokenInt private hunter;
    MiningPowerCustody private custody;
    HunterMiningHarnessInt private core;
    HunterNFT private nft;
    BasketRegistry private registry;
    address private basket;

    address private constant STOP = address(0x5709);
    address private constant OWNER = address(0xA11CE);
    address private constant MINER = address(0x111E);
    uint256 private constant CURVE_UNIT = 1000e18;

    uint256 private challengeId;
    uint256 private seedBlock;

    function setUp() public {
        vm.roll(1_000);
        hunter = new MockHunterTokenInt();
        registry = new BasketRegistry(address(this));
        basket = address(new HunterBasketFixture());
        registry.admitBasket(basket, keccak256("review"));
        address predictedCore = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        address predictedNFT = vm.computeCreateAddress(predictedCore, 1);
        HunterLifecycleFixture lifecycle = new HunterLifecycleFixture(predictedNFT);
        core = new HunterMiningHarnessInt(
            HunterMiningCore.ProofNftDeploymentData({
                registry: address(registry),
                lifecycle: address(lifecycle),
                artVersion: 1,
                royaltyRecipient: address(this),
                baseURI: "ipfs://test/"
            })
        );
        nft = core.PROOF_NFT();
        assertEq(address(nft), predictedNFT);

        custody = new MiningPowerCustody(address(hunter), address(core), CURVE_UNIT);
        vm.prank(STOP);
        core.setMiningPower(custody);

        hunter.mint(OWNER, 100_000e18);
        vm.prank(OWNER);
        hunter.approve(address(custody), type(uint256).max);

        _activate();
    }

    function testZeroLockMinerStillMintsOneNft() public {
        (uint256 nonce,) = _findNonce(MINER, true);
        uint256 before = nft.mintedEver();
        vm.prank(MINER);
        core.submitProof(challengeId, seedBlock, nonce, basket);
        assertEq(nft.mintedEver(), before + 1);
        assertEq(nft.ownerOf(1), MINER);
    }

    function testAssignedPowerAppliesOnNextChallengeAndMints() public {
        uint256 cid = core.activeChallengeId();
        assertEq(custody.powerMultiplierWad(cid, MINER), 1e18);

        vm.startPrank(OWNER);
        custody.deposit(50_000e18);
        custody.assign(MINER, 50_000e18);
        vm.stopPrank();

        // Current challenge still frozen at 1.0x
        assertEq(custody.powerMultiplierWad(cid, MINER), 1e18);

        // Open next challenge via another miner
        address other = address(0xB0B);
        (uint256 nonce0,) = _findNonce(other, true);
        vm.prank(other);
        core.submitProof(challengeId, seedBlock, nonce0, basket);

        _activate();
        uint256 cid2 = core.activeChallengeId();
        uint256 mult = custody.powerMultiplierWad(cid2, MINER);
        assertGt(mult, 1e18);
        assertLe(mult, 3e18);

        // With power wired, a normal valid proof from MINER still mints exactly one NFT
        (uint256 nonce,) = _findNonce(MINER, true);
        uint256 before = nft.mintedEver();
        vm.prank(MINER);
        core.submitProof(challengeId, seedBlock, nonce, basket);
        assertEq(nft.mintedEver(), before + 1);
        assertEq(nft.ownerOf(before + 1), MINER);
    }

    function testFlashAssignAfterSnapshotDoesNotHelpCurrentChallenge() public {
        uint256 cid = core.activeChallengeId();
        // Freeze zero
        assertEq(custody.powerMultiplierWad(cid, MINER), 1e18);

        vm.startPrank(OWNER);
        custody.deposit(80_000e18);
        custody.assign(MINER, 80_000e18);
        vm.stopPrank();

        // Still 1.0x for this challenge
        assertEq(custody.powerMultiplierWad(cid, MINER), 1e18);

        // A digest harder than base target must still fail
        uint256 target = core.currentTarget();
        (uint256 nonce, bytes32 digest) = _findNonceAbove(MINER, target);
        assertGt(uint256(digest), target);
        vm.prank(MINER);
        vm.expectRevert();
        core.submitProof(challengeId, seedBlock, nonce, basket);
    }

    function testPowerBonusWindowMintsExactlyOneCommonNft() public {
        uint256 cid = core.activeChallengeId();
        assertEq(custody.powerMultiplierWad(cid, MINER), 1e18);

        vm.startPrank(OWNER);
        custody.deposit(50_000e18);
        custody.assign(MINER, 50_000e18);
        vm.stopPrank();

        address other = address(0xB0B);
        (uint256 nonce0,) = _findNonce(other, true);
        vm.prank(other);
        core.submitProof(challengeId, seedBlock, nonce0, basket);

        _activate();
        uint256 baseTarget = core.currentTarget();
        uint256 mult = custody.powerMultiplierWad(core.activeChallengeId(), MINER);
        assertEq(mult, 3e18);
        uint256 effective = core.effective(baseTarget, mult);
        assertGt(effective, baseTarget);

        (uint256 nonce, bytes32 digest) = _findBonusNonce(MINER, baseTarget, effective);
        assertGt(uint256(digest), baseTarget);
        assertLe(uint256(digest), effective);

        uint256 before = nft.mintedEver();
        vm.prank(MINER);
        core.submitProof(challengeId, seedBlock, nonce, basket);
        assertEq(nft.mintedEver(), before + 1);
        assertEq(nft.ownerOf(before + 1), MINER);
        (,,, uint8 tier) = nft.birthData(before + 1);
        assertEq(tier, 1);
        assertEq(core.acceptedProofs(), core.nftsMintedEver());
    }

    function testExpiredSeedRefreshOpensMiningPowerSnapshot() public {
        uint256 oldSeed = core.activeSeedParentBlock();
        uint256 oldId = core.activeChallengeId();
        vm.roll(oldSeed + 257);
        core.refreshExpiredSeed();
        uint256 cid = core.activeChallengeId();
        assertEq(cid, oldId + 1);
        assertTrue(custody.challengeOpen(cid));
        _activate();
        (uint256 nonce,) = _findNonce(MINER, true);
        vm.prank(MINER);
        core.submitProof(challengeId, seedBlock, nonce, basket);
        assertEq(nft.mintedEver(), 1);
        assertEq(nft.ownerOf(1), MINER);
    }

    function _deployment() private view returns (HunterMiningCore.ProofNftDeploymentData memory) {
        return HunterMiningCore.ProofNftDeploymentData({
            registry: address(registry),
            lifecycle: address(0),
            artVersion: 1,
            royaltyRecipient: address(this),
            baseURI: "ipfs://test/"
        });
    }

    function _activate() private {
        seedBlock = core.activeSeedParentBlock();
        vm.roll(seedBlock + 1);
        vm.setBlockhash(seedBlock, keccak256(abi.encodePacked("seed", seedBlock, block.number)));
        challengeId = core.activeChallengeId();
        assertEq(uint256(core.challengeState()), uint256(HunterMiningCore.ChallengeState.ACTIVE));
    }

    function _challenge() private view returns (bytes32) {
        return core.deriveChallenge(challengeId, core.previousAcceptedDigest(), seedBlock, blockhash(seedBlock));
    }

    function _findNonce(address miner, bool valid) private view returns (uint256 nonce, bytes32 digest) {
        bytes32 ch = _challenge();
        uint256 target = core.currentTarget();
        for (nonce = 0; nonce < 200_000; nonce++) {
            digest = core.deriveProofDigest(challengeId, ch, miner, nonce);
            bool ok = uint256(digest) <= target;
            if (ok == valid) return (nonce, digest);
        }
        revert("nonce not found");
    }

    function _findNonceAbove(address miner, uint256 target) private view returns (uint256 nonce, bytes32 digest) {
        bytes32 ch = _challenge();
        for (nonce = 0; nonce < 200_000; nonce++) {
            digest = core.deriveProofDigest(challengeId, ch, miner, nonce);
            if (uint256(digest) > target) return (nonce, digest);
        }
        revert("above-target nonce not found");
    }

    function _findBonusNonce(address miner, uint256 baseTarget, uint256 effectiveTarget)
        private
        view
        returns (uint256 nonce, bytes32 digest)
    {
        bytes32 ch = _challenge();
        for (nonce = 0; nonce < 400_000; nonce++) {
            digest = core.deriveProofDigest(challengeId, ch, miner, nonce);
            uint256 value = uint256(digest);
            if (value > baseTarget && value <= effectiveTarget) return (nonce, digest);
        }
        revert("bonus-window nonce not found");
    }
}
