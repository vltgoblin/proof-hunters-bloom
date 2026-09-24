// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {HunterMiningCore} from "../src/bloom/HunterMiningCore.sol";
import {HunterNFT} from "../src/bloom/HunterNFT.sol";
import {BasketRegistry} from "../src/bloom/BasketRegistry.sol";
import {IMiningPower} from "../src/bloom/IMiningPower.sol";
import {HunterLifecycleFixture, HunterBasketFixture} from "./HunterNFT.t.sol";

contract HugeMultiplierPower is IMiningPower {
    function powerMultiplierWad(uint256, address) external pure returns (uint256) {
        return type(uint256).max;
    }

    function snapshottedLockedAmount(uint256, address) external pure returns (uint256) {
        return 0;
    }

    function snapshotChallenge(uint256) external {}

    function onProofAccepted(uint256) external {}

    function onMiningPowerDetached(bool) external {}
}

contract ReenteringMiningPower is IMiningPower {
    HunterMiningCore public core;
    uint256 public challengeId;
    uint256 public seedBlock;
    uint256 public nonce;
    address public basket;

    function configure(HunterMiningCore core_, uint256 id, uint256 seed, uint256 nonce_, address basket_) external {
        core = core_;
        challengeId = id;
        seedBlock = seed;
        nonce = nonce_;
        basket = basket_;
    }

    function powerMultiplierWad(uint256, address) external returns (uint256) {
        core.submitProof(challengeId, seedBlock, nonce, basket);
        return 1e18;
    }

    function snapshottedLockedAmount(uint256, address) external pure returns (uint256) {
        return 0;
    }

    function snapshotChallenge(uint256) external {}

    function onProofAccepted(uint256) external {}

    function onMiningPowerDetached(bool) external {}
}

contract HunterMiningHarnessAdv is HunterMiningCore {
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
}

contract HunterMiningPowerAdversarialTest is Test {
    HunterMiningHarnessAdv private core;
    HunterNFT private nft;
    BasketRegistry private registry;
    address private basket;
    address private constant STOP = address(0x5709);
    address private constant MINER = address(0x111E);
    uint256 private challengeId;
    uint256 private seedBlock;

    function setUp() public {
        vm.roll(1_000);
        registry = new BasketRegistry(address(this));
        basket = address(new HunterBasketFixture());
        registry.admitBasket(basket, keccak256("review"));
        address predictedCore = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        address predictedNFT = vm.computeCreateAddress(predictedCore, 1);
        HunterLifecycleFixture lifecycle = new HunterLifecycleFixture(predictedNFT);
        core = new HunterMiningHarnessAdv(
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
        _activate();
    }

    function testHugeMultiplierDoesNotOverflowAndStillMintsOneNft() public {
        HugeMultiplierPower power = new HugeMultiplierPower();
        vm.prank(STOP);
        core.setMiningPower(power);

        (uint256 nonce,) = _findNonce(MINER, true);
        vm.prank(MINER);
        core.submitProof(challengeId, seedBlock, nonce, basket);
        assertEq(nft.mintedEver(), 1);
        assertEq(nft.ownerOf(1), MINER);
        assertEq(core.nftsMintedEver(), 1);
        assertEq(core.acceptedProofs(), 1);
    }

    function testMiningPowerReentryCannotDoubleMint() public {
        (uint256 nonce,) = _findNonce(MINER, true);
        ReenteringMiningPower power = new ReenteringMiningPower();
        power.configure(core, challengeId, seedBlock, nonce, basket);
        vm.prank(STOP);
        core.setMiningPower(power);

        vm.prank(MINER);
        vm.expectRevert(bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        core.submitProof(challengeId, seedBlock, nonce, basket);
        assertEq(nft.mintedEver(), 0);
        assertEq(core.acceptedProofs(), 0);
    }

    function testAcceptedProofCannotReplayAfterChallengeAdvances() public {
        HugeMultiplierPower power = new HugeMultiplierPower();
        vm.prank(STOP);
        core.setMiningPower(power);
        (uint256 nonce,) = _findNonce(MINER, true);
        vm.prank(MINER);
        core.submitProof(challengeId, seedBlock, nonce, basket);
        vm.expectRevert(
            abi.encodeWithSelector(
                HunterMiningCore.ChallengeNotActive.selector, HunterMiningCore.ChallengeState.WAITING_FOR_SEED
            )
        );
        vm.prank(MINER);
        core.submitProof(challengeId, seedBlock, nonce, basket);
        assertEq(nft.mintedEver(), 1);
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
}
