// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MiningPowerCustody} from "../src/bloom/MiningPowerCustody.sol";
import {IMiningPower} from "../src/bloom/IMiningPower.sol";
import {HunterMiningCore} from "../src/bloom/HunterMiningCore.sol";
import {HunterNFT} from "../src/bloom/HunterNFT.sol";
import {BasketRegistry} from "../src/bloom/BasketRegistry.sol";
import {HunterLifecycleFixture, HunterBasketFixture} from "./HunterNFT.t.sol";

contract MockHunterToken is ERC20 {
    constructor() ERC20("HUNTER", "HUNTER") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract HunterMiningHarnessMP is HunterMiningCore {
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
}

contract MiningPowerCustodyTest is Test {
    MockHunterToken private hunter;
    MiningPowerCustody private custody;
    HunterMiningHarnessMP private core;
    HunterNFT private nft;
    BasketRegistry private registry;
    address private basket;
    address private constant STOP = address(0x5709);
    address private constant ALICE = address(0xA11CE);
    address private constant MINER = address(0x111E);
    address private constant OTHER = address(0xB0B);

    uint256 private constant CURVE_UNIT = 1000e18;

    function setUp() public {
        vm.roll(1_000);
        hunter = new MockHunterToken();
        registry = new BasketRegistry(address(this));
        basket = address(new HunterBasketFixture());
        registry.admitBasket(basket, keccak256("review"));
        address predictedCore = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        address predictedNFT = vm.computeCreateAddress(predictedCore, 1);
        HunterLifecycleFixture lifecycle = new HunterLifecycleFixture(predictedNFT);
        core = new HunterMiningHarnessMP(
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
        assertEq(uint256(core.TARGET_CADENCE_PARENT_BLOCKS()), 50);

        custody = new MiningPowerCustody(address(hunter), address(core), CURVE_UNIT);
        vm.prank(STOP);
        core.setMiningPower(custody);

        hunter.mint(ALICE, 100_000e18);
        vm.prank(ALICE);
        hunter.approve(address(custody), type(uint256).max);
    }

    function testDepositAssignWithdrawConservation() public {
        vm.startPrank(ALICE);
        custody.deposit(5_000e18);
        assertEq(custody.totalLocked(), 5_000e18);
        custody.assign(MINER, 2_000e18);
        assertEq(custody.assignedOf(MINER), 2_000e18);
        assertEq(custody.unassignedOf(ALICE), 3_000e18);
        // unlock delay blocks unassign
        vm.expectRevert();
        custody.unassign(MINER, 1_000e18);
        vm.stopPrank();

        // advance proofs via core hook simulation
        vm.prank(address(core));
        custody.onProofAccepted(12);
        vm.startPrank(ALICE);
        custody.unassign(MINER, 1_000e18);
        custody.withdraw(4_000e18);
        assertEq(custody.totalLocked(), 1_000e18);
        assertEq(hunter.balanceOf(ALICE), 100_000e18 - 1_000e18);
        vm.stopPrank();
    }

    function testSnapshotIgnoresLaterAssignment() public {
        uint256 cid = core.activeChallengeId();
        vm.prank(ALICE);
        custody.deposit(10_000e18);
        // freeze zero for miner first
        uint256 m0 = custody.powerMultiplierWad(cid, MINER);
        assertEq(m0, 1e18);

        vm.prank(ALICE);
        custody.assign(MINER, 10_000e18);
        // same challenge still frozen at 1.0x
        assertEq(custody.powerMultiplierWad(cid, MINER), 1e18);
        assertEq(custody.snapshottedLockedAmount(cid, MINER), 0);

        // open next challenge
        vm.prank(address(core));
        custody.snapshotChallenge(cid + 1);
        uint256 m1 = custody.powerMultiplierWad(cid + 1, MINER);
        assertGt(m1, 1e18);
        assertLe(m1, 3e18);
    }

    function testFlashLoanAfterSnapshotDoesNotHelp() public {
        uint256 cid = core.activeChallengeId();
        // freeze miner at zero
        assertEq(custody.powerMultiplierWad(cid, MINER), 1e18);

        vm.prank(ALICE);
        custody.deposit(50_000e18);
        vm.prank(ALICE);
        custody.assign(MINER, 50_000e18);
        // still frozen
        assertEq(custody.powerMultiplierWad(cid, MINER), 1e18);
    }

    function testCurveCapHolds() public {
        // huge lock
        uint256 huge = 1_000_000e18;
        hunter.mint(ALICE, huge);
        vm.startPrank(ALICE);
        hunter.approve(address(custody), type(uint256).max);
        custody.deposit(huge);
        custody.assign(OTHER, huge);
        vm.stopPrank();
        vm.prank(address(core));
        custody.snapshotChallenge(99);
        uint256 m = custody.powerMultiplierWad(99, OTHER);
        assertEq(m, 3e18);
    }

    function testZeroLockStillBaseChance() public {
        assertEq(custody.multiplierFromLockedAmount(0), 1e18);
    }

    function testCannotReuseSameDepositAcrossTwoWalletsWithoutUnassign() public {
        vm.startPrank(ALICE);
        custody.deposit(1_000e18);
        custody.assign(MINER, 1_000e18);
        vm.expectRevert();
        custody.assign(OTHER, 1); // no unassigned left + wrong assignee path
        vm.stopPrank();
    }

    function testCannotSnapshotTheSameChallengeTwice() public {
        uint256 cid = core.activeChallengeId();
        vm.prank(address(core));
        vm.expectRevert(abi.encodeWithSelector(MiningPowerCustody.AlreadySnapshotted.selector, cid));
        custody.snapshotChallenge(cid);
    }

    /// @dev Regression (devin-review rounds 2/5): a non-terminal detach must
    /// not waive the unlock delay — otherwise stake hops to a replacement
    /// custody early. The delay still completes against the live core clock,
    /// which keeps advancing on the replacement module. New assigns are
    /// refused, and a clean custody can be rewired for the same challenge.
    function testDetachedModuleKeepsDelayOnLiveClockAndRefusesNewAssigns() public {
        vm.prank(ALICE);
        custody.deposit(1_000e18);
        vm.prank(ALICE);
        custody.assign(MINER, 1_000e18);

        vm.prank(STOP);
        core.setMiningPower(IMiningPower(address(0)));
        assertFalse(custody.wired());
        assertFalse(custody.retired());

        vm.prank(ALICE);
        custody.deposit(1e18);
        vm.prank(ALICE);
        vm.expectRevert(MiningPowerCustody.NotWired.selector);
        custody.assign(MINER, 1e18);

        // The delay is still enforced — but the live core clock can satisfy it.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MiningPowerCustody.UnlockDelayNotMet.selector, 12, 0));
        custody.unassign(MINER, 1_000e18);
        core.setCounts(12, 12);
        vm.prank(ALICE);
        custody.unassign(MINER, 1_000e18);
        vm.prank(ALICE);
        custody.withdraw(1_001e18);
        assertEq(custody.assignedOf(MINER), 0);
        assertEq(custody.totalLocked(), 0);

        // A clean custody can be rewired even for the same open challenge.
        vm.prank(STOP);
        core.setMiningPower(custody);
        assertTrue(custody.wired());
        vm.prank(ALICE);
        custody.deposit(10e18);
        vm.prank(ALICE);
        custody.assign(MINER, 10e18);
        assertEq(custody.assignedOf(MINER), 10e18);
    }

    /// @dev Regression (devin-review round 6): a custody detached before a
    /// terminal transition never receives the retire notice — its flag stays
    /// false while the proof clock freezes forever. The live challengeState
    /// read must release the delay or the stake is permanently locked.
    function testTerminalAfterDetachReleasesDetachedStake() public {
        vm.prank(ALICE);
        custody.deposit(1_000e18);
        vm.prank(ALICE);
        custody.assign(MINER, 1_000e18);

        vm.prank(STOP);
        core.setMiningPower(IMiningPower(address(0)));
        assertFalse(custody.retired());

        // Non-terminal: delay still enforced.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MiningPowerCustody.UnlockDelayNotMet.selector, 12, 0));
        custody.unassign(MINER, 1_000e18);

        // Terminal stop arrives while nothing is wired — the retire hook went
        // to the zero module, so only the live read can release the delay.
        vm.prank(STOP);
        core.stopMining();
        assertFalse(custody.retired());
        vm.prank(ALICE);
        custody.unassign(MINER, 1_000e18);
        assertEq(custody.assignedOf(MINER), 0);
    }

    /// @dev Regression (devin-review round 5 BUG-0001): a custody retaining
    /// assignments must not be rewired — its stale epochs would count as
    /// matured for a challenge whose digest is already derivable.
    function testRewireWithRetainedAssignmentsReverts() public {
        vm.prank(ALICE);
        custody.deposit(1_000e18);
        vm.prank(ALICE);
        custody.assign(MINER, 1_000e18);

        vm.prank(STOP);
        core.setMiningPower(IMiningPower(address(0)));

        vm.prank(STOP);
        vm.expectRevert(abi.encodeWithSelector(MiningPowerCustody.RetainedAssignments.selector, 1_000e18));
        core.setMiningPower(custody);

        // After a full exit the custody can serve again.
        core.setCounts(12, 12);
        vm.prank(ALICE);
        custody.unassign(MINER, 1_000e18);
        vm.prank(STOP);
        core.setMiningPower(custody);
        assertTrue(custody.wired());
    }

    /// @dev Regression (devin-review BUG-0002): assignments to a never-wired
    /// custody kept epoch zero and would count as matured at the first
    /// snapshot — a prepared replacement could bypass the challenge bind.
    /// Assignments must be refused until the first snapshot opens an epoch.
    function testAssignBeforeFirstSnapshotReverts() public {
        MiningPowerCustody unwired = new MiningPowerCustody(address(hunter), address(core), CURVE_UNIT);
        hunter.mint(ALICE, 1_000e18);
        vm.prank(ALICE);
        hunter.approve(address(unwired), type(uint256).max);
        vm.prank(ALICE);
        unwired.deposit(1_000e18);
        vm.prank(ALICE);
        vm.expectRevert(MiningPowerCustody.NotWired.selector);
        unwired.assign(MINER, 1_000e18);

        // After wiring, assignments land — but only as pending for the open epoch.
        vm.prank(STOP);
        core.setMiningPower(IMiningPower(address(0)));
        vm.prank(STOP);
        core.setMiningPower(IMiningPower(address(unwired)));
        assertTrue(unwired.wired());
        vm.prank(ALICE);
        unwired.assign(MINER, 1_000e18);
        assertEq(unwired.assignedOf(MINER), 1_000e18);
        assertEq(unwired.powerMultiplierWad(core.activeChallengeId(), MINER), 1e18);
    }

    /// @dev Regression (devin-review round 3): a matured unassign after the
    /// challenge opened but before the wallet's first freeze must not shrink
    /// that challenge's snapshot — removals take effect from the next
    /// challenge, same as additions.
    function testMaturedUnassignAfterOpenKeepsOpeningFreeze() public {
        uint256 cid = core.activeChallengeId();
        vm.prank(ALICE);
        custody.deposit(4_000e18);
        vm.prank(ALICE);
        custody.assign(MINER, 4_000e18); // pending for cid

        vm.prank(address(core));
        custody.snapshotChallenge(cid + 1); // matured for cid+1
        vm.prank(address(core));
        custody.onProofAccepted(12);

        vm.prank(ALICE);
        custody.unassign(MINER, 4_000e18); // matured exit during cid+1

        // cid+1 still freezes the opening 4,000; the removal lands at cid+2.
        assertEq(custody.assignedOf(MINER), 0);
        assertEq(custody.snapshottedLockedAmount(cid + 1, MINER), 4_000e18);
        assertEq(custody.powerMultiplierWad(cid + 1, MINER), custody.multiplierFromLockedAmount(4_000e18));

        vm.prank(address(core));
        custody.snapshotChallenge(cid + 2);
        assertEq(custody.snapshottedLockedAmount(cid + 2, MINER), 0);
        assertEq(custody.powerMultiplierWad(cid + 2, MINER), 1e18);
    }

    /// @dev Regression (devin-review round 3): a terminal mining stop ends all
    /// proof callbacks, so the unlock delay can never be satisfied again. The
    /// stop must retire the module — stake exits despite the frozen clock and
    /// new assignments are refused.
    function testMiningStopRetiresModuleAndReleasesStake() public {
        vm.prank(ALICE);
        custody.deposit(1_000e18);
        vm.prank(ALICE);
        custody.assign(MINER, 1_000e18);
        assertTrue(custody.wired());

        vm.prank(STOP);
        core.stopMining();
        assertFalse(custody.wired());

        vm.prank(ALICE);
        custody.deposit(1e18);
        vm.prank(ALICE);
        vm.expectRevert(MiningPowerCustody.NotWired.selector);
        custody.assign(MINER, 1e18);

        vm.prank(ALICE);
        custody.unassign(MINER, 1_000e18);
        assertEq(custody.unassignedOf(ALICE), 1_001e18);
    }

    /// @dev Regression (devin-review round 4): a never-frozen challenge can
    /// only be reconstructed for the latest epoch — once a newer challenge
    /// opens, older balances are no longer derivable. A first query for the
    /// old challenge must refuse instead of permanently recording wrong data;
    /// snapshots already materialized while active stay readable.
    function testStaleUnfrozenChallengeRefusesFirstQuery() public {
        uint256 cid = core.activeChallengeId();
        // Freeze OTHER for cid while cid is the latest epoch.
        assertEq(custody.powerMultiplierWad(cid, OTHER), 1e18);

        vm.prank(ALICE);
        custody.deposit(4_000e18);
        vm.prank(ALICE);
        custody.assign(MINER, 4_000e18);

        vm.prank(address(core));
        custody.snapshotChallenge(cid + 1);

        // First freeze for cid after advancing must refuse — its opening
        // balance can no longer be reconstructed.
        vm.expectRevert(abi.encodeWithSelector(MiningPowerCustody.StaleChallengeId.selector, cid, cid + 1));
        custody.powerMultiplierWad(cid, MINER);
        vm.expectRevert(abi.encodeWithSelector(MiningPowerCustody.StaleChallengeId.selector, cid, cid + 1));
        custody.snapshottedLockedAmount(cid, MINER);

        // The already-materialized snapshot stays readable.
        assertEq(custody.powerMultiplierWad(cid, OTHER), 1e18);
    }

    /// @dev Regression (devin-review BUG-0001): pending is tracked per wallet,
    /// but unassign is authorized per depositor. A matured depositor exiting a
    /// shared wallet must not drain another depositor's pending share — that
    /// would let post-open stake pass as matured for the open challenge.
    function testMaturedUnassignDoesNotLaunderPendingAssignment() public {
        uint256 cid = core.activeChallengeId();
        address bob = OTHER;
        hunter.mint(bob, 4_000e18);
        vm.prank(bob);
        hunter.approve(address(custody), type(uint256).max);

        vm.prank(ALICE);
        custody.deposit(4_000e18);
        vm.prank(ALICE);
        custody.assign(MINER, 4_000e18); // pending for challenge cid

        vm.prank(address(core));
        custody.snapshotChallenge(cid + 1); // Alice's 4,000 matures into cid+1

        vm.prank(bob);
        custody.deposit(4_000e18);
        vm.prank(bob);
        custody.assign(MINER, 4_000e18); // pending for challenge cid+1

        vm.prank(address(core));
        custody.onProofAccepted(12); // satisfy Alice's unlock delay
        vm.prank(ALICE);
        custody.unassign(MINER, 4_000e18); // matured stake exits; Bob's pending untouched

        // Alice's matured exit is deferred to the next challenge, so cid+1
        // still freezes her 4,000 opening power — but Bob's post-open stake
        // must NOT be counted. The freeze records Alice's matured share only.
        assertEq(custody.assignedOf(MINER), 4_000e18);
        assertEq(custody.snapshottedLockedAmount(cid + 1, MINER), 4_000e18);
        assertEq(custody.powerMultiplierWad(cid + 1, MINER), custody.multiplierFromLockedAmount(4_000e18));
    }

    function testTwoDepositorsCannotStealSharedAssignment() public {
        address bob = OTHER;
        hunter.mint(bob, 2_000e18);
        vm.prank(bob);
        hunter.approve(address(custody), type(uint256).max);

        vm.prank(ALICE);
        custody.deposit(1_000e18);
        vm.prank(ALICE);
        custody.assign(MINER, 1_000e18);
        vm.prank(bob);
        custody.deposit(2_000e18);
        vm.prank(bob);
        custody.assign(MINER, 2_000e18);

        assertEq(custody.assignedOf(MINER), 3_000e18);
        assertEq(custody.assignedBy(ALICE), 1_000e18);
        assertEq(custody.assignedBy(bob), 2_000e18);

        vm.prank(address(core));
        custody.onProofAccepted(12);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MiningPowerCustody.InsufficientAssigned.selector, 1_000e18, 3_000e18));
        custody.unassign(MINER, 3_000e18);

        vm.prank(ALICE);
        custody.unassign(MINER, 1_000e18);
        assertEq(custody.assignedOf(MINER), 2_000e18);
        assertEq(custody.assignedBy(ALICE), 0);
        assertEq(custody.assignedBy(bob), 2_000e18);
        assertEq(custody.assigneeOf(ALICE), address(0));
        assertEq(custody.assigneeOf(bob), MINER);
        assertEq(custody.unassignedOf(ALICE), 1_000e18);
        assertEq(custody.totalLocked(), 3_000e18);
    }

    function testUnlockDelayIsPerDepositorNotSharedWallet() public {
        address bob = OTHER;
        hunter.mint(bob, 1_000e18);
        vm.prank(bob);
        hunter.approve(address(custody), type(uint256).max);

        vm.prank(ALICE);
        custody.deposit(1_000e18);
        vm.prank(ALICE);
        custody.assign(MINER, 1_000e18);

        vm.prank(address(core));
        custody.onProofAccepted(5);

        vm.prank(bob);
        custody.deposit(1_000e18);
        vm.prank(bob);
        custody.assign(MINER, 1_000e18);

        vm.prank(address(core));
        custody.onProofAccepted(12);

        vm.prank(ALICE);
        custody.unassign(MINER, 1_000e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(MiningPowerCustody.UnlockDelayNotMet.selector, 17, 12));
        custody.unassign(MINER, 1_000e18);
    }

    function testFuzzMultiplierNeverExceedsPublishedCap(uint256 locked) public view {
        uint256 m = custody.multiplierFromLockedAmount(locked);
        assertGe(m, 1e18);
        assertLe(m, 3e18);
    }

    /// @dev Regression B1: the digest is derivable once the seed blockhash is
    /// readable, so an assignment made after `snapshotChallenge` but before the
    /// wallet's first freeze must NOT count for that challenge — otherwise a
    /// miner can compute a bonus-band digest and only then buy the multiplier.
    function testAssignAfterChallengeOpenCountsFromNextChallenge() public {
        uint256 cid = core.activeChallengeId();
        vm.prank(ALICE);
        custody.deposit(10_000e18);
        vm.prank(ALICE);
        custody.assign(MINER, 10_000e18); // after snapshotChallenge(cid), before any freeze

        // First freeze for MINER on cid must see zero locked.
        assertEq(custody.powerMultiplierWad(cid, MINER), 1e18);
        assertEq(custody.snapshottedLockedAmount(cid, MINER), 0);

        // The assignment matures into the next challenge.
        vm.prank(address(core));
        custody.snapshotChallenge(cid + 1);
        assertGt(custody.powerMultiplierWad(cid + 1, MINER), 1e18);
        assertEq(custody.snapshottedLockedAmount(cid + 1, MINER), 10_000e18);
    }

    /// @dev Regression B1 accounting: unassigning during the pending challenge
    /// drains the pending bucket first, so the matured freeze base is preserved.
    function testUnassignDuringPendingPreservesMaturedFreeze() public {
        uint256 cid = core.activeChallengeId();
        vm.prank(ALICE);
        custody.deposit(10_000e18);
        vm.prank(ALICE);
        custody.assign(MINER, 4_000e18); // matures for cid + 1
        vm.prank(address(core));
        custody.snapshotChallenge(cid + 1);
        assertEq(custody.snapshottedLockedAmount(cid + 1, MINER), 4_000e18);

        vm.prank(ALICE);
        custody.assign(MINER, 6_000e18); // pending for cid + 1
        vm.prank(address(core));
        custody.onProofAccepted(12); // satisfy unlock delay
        vm.prank(ALICE);
        custody.unassign(MINER, 6_000e18); // should eat the pending part only

        assertEq(custody.assignedOf(MINER), 4_000e18);
        assertEq(custody.snapshottedLockedAmount(cid + 1, MINER), 4_000e18);
        vm.prank(address(core));
        custody.snapshotChallenge(cid + 2);
        assertEq(custody.snapshottedLockedAmount(cid + 2, MINER), 4_000e18);
    }

    /// @dev Regression B2: a module wired mid-flight must start its unlock clock
    /// at core's real proof count, not zero — otherwise the first assigners
    /// bypass UNLOCK_DELAY_PROOFS entirely.
    function testWiringMidFlightSyncsUnlockClock() public {
        core.setCounts(500, 500);
        MiningPowerCustody late = new MiningPowerCustody(address(hunter), address(core), CURVE_UNIT);
        vm.prank(STOP);
        core.setMiningPower(IMiningPower(address(0))); // explicit detach first
        vm.prank(STOP);
        core.setMiningPower(late);
        assertEq(late.lastAcceptedProofs(), 500);

        vm.prank(ALICE);
        hunter.approve(address(late), type(uint256).max);
        vm.prank(ALICE);
        late.deposit(1_000e18);
        vm.prank(ALICE);
        late.assign(MINER, 1_000e18); // stamped at index 500

        vm.prank(address(core));
        late.onProofAccepted(501);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MiningPowerCustody.UnlockDelayNotMet.selector, 512, 501));
        late.unassign(MINER, 1_000e18);

        vm.prank(address(core));
        late.onProofAccepted(512);
        vm.prank(ALICE);
        late.unassign(MINER, 1_000e18);
        assertEq(late.assignedBy(ALICE), 0);
    }

    /// @dev Regression B4: MP.4 separation is a contract rule, not a UI hint.
    /// The funding wallet must not be its own mining wallet.
    function testAssignToSelfReverts() public {
        vm.prank(ALICE);
        custody.deposit(1_000e18);
        vm.prank(ALICE);
        vm.expectRevert(MiningPowerCustody.SelfAssignment.selector);
        custody.assign(ALICE, 1_000e18);
    }
}
