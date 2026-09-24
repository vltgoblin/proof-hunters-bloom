// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MiningPowerCustody} from "../src/bloom/MiningPowerCustody.sol";

contract MockHunterTokenInv is ERC20 {
    constructor() ERC20("HUNTER", "HUNTER") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Valid-action handler. Unexpected protocol reverts fail the campaign.
contract MiningPowerCustodyHandler is Test {
    MiningPowerCustody public immutable custody;
    MockHunterTokenInv public immutable hunter;
    address public immutable miningCore;

    address public immutable alice;
    address public immutable bob;
    address public immutable carol;
    address public immutable minerA;
    address public immutable minerB;

    uint256 public calls;
    uint256 public deposits;
    uint256 public assigns;
    uint256 public unassigns;
    uint256 public withdraws;

    constructor(
        MiningPowerCustody custody_,
        MockHunterTokenInv hunter_,
        address miningCore_,
        address alice_,
        address bob_,
        address carol_,
        address minerA_,
        address minerB_
    ) {
        custody = custody_;
        hunter = hunter_;
        miningCore = miningCore_;
        alice = alice_;
        bob = bob_;
        carol = carol_;
        minerA = minerA_;
        minerB = minerB_;
    }

    function deposit(uint256 actorSeed, uint256 amountSeed) public {
        ++calls;
        address actor = _actor(actorSeed);
        uint256 amount = bound(amountSeed, 1, 1e22);
        hunter.mint(actor, amount);
        vm.startPrank(actor);
        hunter.approve(address(custody), amount);
        custody.deposit(amount);
        vm.stopPrank();
        ++deposits;
    }

    function assign(uint256 actorSeed, uint256 minerSeed, uint256 amountSeed) public {
        ++calls;
        address actor = _actor(actorSeed);
        uint256 available = custody.unassignedOf(actor);
        if (available == 0) return;
        address miner = minerSeed % 2 == 0 ? minerA : minerB;
        address current = custody.assigneeOf(actor);
        if (current != address(0) && current != miner) return;
        uint256 amount = bound(amountSeed, 1, available);
        vm.prank(actor);
        custody.assign(miner, amount);
        ++assigns;
    }

    function unassign(uint256 actorSeed, uint256 amountSeed) public {
        ++calls;
        address actor = _actor(actorSeed);
        address miner = custody.assigneeOf(actor);
        uint256 available = custody.assignedBy(actor);
        if (miner == address(0) || available == 0) return;
        uint256 earliest = custody.assignProofIndex(actor) + custody.UNLOCK_DELAY_PROOFS();
        if (custody.lastAcceptedProofs() < earliest) return;
        uint256 amount = bound(amountSeed, 1, available);
        vm.prank(actor);
        custody.unassign(miner, amount);
        ++unassigns;
    }

    function withdraw(uint256 actorSeed, uint256 amountSeed) public {
        ++calls;
        address actor = _actor(actorSeed);
        uint256 available = custody.unassignedOf(actor);
        if (available == 0) return;
        uint256 amount = bound(amountSeed, 1, available);
        vm.prank(actor);
        custody.withdraw(amount);
        ++withdraws;
    }

    function advanceProofs(uint256 countSeed) public {
        ++calls;
        uint256 next = custody.lastAcceptedProofs() + bound(countSeed, 1, 12);
        vm.prank(miningCore);
        custody.onProofAccepted(next);
    }

    function _actor(uint256 seed) private view returns (address) {
        uint256 which = seed % 3;
        if (which == 0) return alice;
        if (which == 1) return bob;
        return carol;
    }
}

contract MiningPowerCustodyInvariantTest is StdInvariant, Test {
    MiningPowerCustody internal custody;
    MockHunterTokenInv internal hunter;
    MiningPowerCustodyHandler internal handler;
    address internal constant CORE = address(0xC0);
    address internal alice;
    address internal bob;
    address internal carol;
    address internal minerA;
    address internal minerB;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        carol = makeAddr("carol");
        minerA = makeAddr("minerA");
        minerB = makeAddr("minerB");
        hunter = new MockHunterTokenInv();
        custody = new MiningPowerCustody(address(hunter), CORE, 1000e18);
        vm.prank(CORE);
        custody.snapshotChallenge(1);
        handler = new MiningPowerCustodyHandler(custody, hunter, CORE, alice, bob, carol, minerA, minerB);
        handler.deposit(0, 1e18);
        targetContract(address(handler));
    }

    function invariant_tokenBalanceMatchesTotalLocked() public view {
        assertEq(hunter.balanceOf(address(custody)), custody.totalLocked(), "locked vs token");
    }

    function invariant_depositorPartsSumToLocked() public view {
        uint256 parts = _parts(alice) + _parts(bob) + _parts(carol);
        assertEq(parts, custody.totalLocked(), "parts vs locked");
        assertEq(_assignedTo(minerA), custody.assignedOf(minerA), "minerA assigned");
        assertEq(_assignedTo(minerB), custody.assignedOf(minerB), "minerB assigned");
        _assertDepositor(alice);
        _assertDepositor(bob);
        _assertDepositor(carol);
    }

    function invariant_multiplierCapHoldsForAssignedWallets() public view {
        assertLe(custody.multiplierFromLockedAmount(custody.assignedOf(minerA)), 3e18);
        assertLe(custody.multiplierFromLockedAmount(custody.assignedOf(minerB)), 3e18);
        assertGe(custody.multiplierFromLockedAmount(0), 1e18);
    }

    function afterInvariant() public view {
        assertGt(handler.calls(), 0, "handler never ran");
        assertGt(handler.deposits(), 0, "no deposits");
    }

    function _parts(address actor) private view returns (uint256) {
        return custody.unassignedOf(actor) + custody.assignedBy(actor);
    }

    function _assignedTo(address miner) private view returns (uint256) {
        uint256 sum;
        if (custody.assigneeOf(alice) == miner) sum += custody.assignedBy(alice);
        if (custody.assigneeOf(bob) == miner) sum += custody.assignedBy(bob);
        if (custody.assigneeOf(carol) == miner) sum += custody.assignedBy(carol);
        return sum;
    }

    function _assertDepositor(address actor) private view {
        if (custody.assignedBy(actor) == 0) {
            assertEq(custody.assigneeOf(actor), address(0), "zero assigned keeps assignee");
        } else {
            assertTrue(custody.assigneeOf(actor) == minerA || custody.assigneeOf(actor) == minerB, "assignee");
        }
    }
}

contract MiningPowerCustodyAccountingFuzzTest is Test {
    MiningPowerCustody internal custody;
    MockHunterTokenInv internal hunter;
    address internal constant CORE = address(0xC0);
    address internal alice;
    address internal bob;
    address internal miner;

    function setUp() public {
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        miner = makeAddr("miner");
        hunter = new MockHunterTokenInv();
        custody = new MiningPowerCustody(address(hunter), CORE, 1000e18);
        vm.prank(CORE);
        custody.snapshotChallenge(1);
    }

    function testFuzz_twoDepositorsConserveThroughUnassign(uint256 aSeed, uint256 bSeed) public {
        uint256 aAmt = bound(aSeed, 1, 1e24);
        uint256 bAmt = bound(bSeed, 1, 1e24);
        hunter.mint(alice, aAmt);
        hunter.mint(bob, bAmt);
        vm.startPrank(alice);
        hunter.approve(address(custody), aAmt);
        custody.deposit(aAmt);
        custody.assign(miner, aAmt);
        vm.stopPrank();
        vm.startPrank(bob);
        hunter.approve(address(custody), bAmt);
        custody.deposit(bAmt);
        custody.assign(miner, bAmt);
        vm.stopPrank();
        assertEq(custody.assignedOf(miner), aAmt + bAmt);
        assertEq(custody.totalLocked(), aAmt + bAmt);
        vm.prank(CORE);
        custody.onProofAccepted(12);
        vm.prank(alice);
        custody.unassign(miner, aAmt);
        vm.prank(alice);
        custody.withdraw(aAmt);
        assertEq(hunter.balanceOf(alice), aAmt);
        assertEq(custody.assignedOf(miner), bAmt);
        assertEq(custody.assignedBy(bob), bAmt);
        assertEq(custody.totalLocked(), bAmt);
        assertEq(hunter.balanceOf(address(custody)), bAmt);
    }
}
