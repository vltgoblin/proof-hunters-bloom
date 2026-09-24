// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {MiningPowerCustody} from "../src/bloom/MiningPowerCustody.sol";

contract EdgeHunterToken is ERC20 {
    constructor() ERC20("HUNTER", "HUNTER") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev TEST-ONLY fee-on-transfer token. Credits less than `amount` inbound.
contract FeeOnTransferHunter is ERC20 {
    uint256 public feeBps;
    address public custody;

    constructor(uint256 feeBps_) ERC20("Fee HUNTER", "fHUNT") {
        feeBps = feeBps_;
    }

    function setCustody(address custody_) external {
        custody = custody_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to == custody && feeBps != 0) {
            uint256 fee = (value * feeBps) / 10_000;
            if (fee != 0) super._update(from, address(0), fee);
            super._update(from, to, value - fee);
            return;
        }
        super._update(from, to, value);
    }
}

/// @dev TEST-ONLY bonus token: inbound transfer into custody mints 1 extra unit.
contract BonusHunter is ERC20 {
    address public custody;

    constructor() ERC20("Bonus HUNTER", "bHUNT") {}

    function setCustody(address custody_) external {
        custody = custody_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0) && to == custody) super._update(address(0), to, 1);
    }
}

/// @dev TEST-ONLY: re-enters custody during transferFrom/transfer.
contract ReentrantHunter is ERC20 {
    MiningPowerCustody public target;
    bytes public payload;
    bool public callbackAttempted;
    bool public callbackSucceeded;
    bytes4 public callbackError;
    bool private _inside;

    constructor() ERC20("Re HUNTER", "rHUNT") {}

    function configure(MiningPowerCustody target_, bytes memory payload_) external {
        target = target_;
        payload = payload_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (!_inside && payload.length != 0 && (to == address(target) || from == address(target))) {
            _inside = true;
            callbackAttempted = true;
            (bool ok, bytes memory reason) = address(target).call(payload);
            callbackSucceeded = ok;
            if (!ok && reason.length >= 4) {
                bytes4 sel;
                assembly ("memory-safe") {
                    sel := mload(add(reason, 0x20))
                }
                callbackError = sel;
            }
            _inside = false;
        }
        super._update(from, to, value);
    }
}

contract MiningPowerCustodyEdgesTest is Test {
    address private constant CORE = address(0xC0);
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant MINER = address(0x111E);
    address private constant OTHER = address(0x222E);
    uint256 private constant CURVE_UNIT = 1000e18;

    EdgeHunterToken private hunter;
    MiningPowerCustody private custody;

    function setUp() public {
        hunter = new EdgeHunterToken();
        custody = new MiningPowerCustody(address(hunter), CORE, CURVE_UNIT);
        // Assignments require a wired module; open a far-off epoch so the
        // tests' own snapshot calls keep working.
        vm.prank(CORE);
        custody.snapshotChallenge(999);
        hunter.mint(ALICE, 100_000e18);
        vm.prank(ALICE);
        hunter.approve(address(custody), type(uint256).max);
    }

    function testConstructorRejectsZeroAddressesAndZeroCurve() public {
        vm.expectRevert(MiningPowerCustody.ZeroAddress.selector);
        new MiningPowerCustody(address(0), CORE, CURVE_UNIT);
        vm.expectRevert(MiningPowerCustody.ZeroAddress.selector);
        new MiningPowerCustody(address(hunter), address(0), CURVE_UNIT);
        vm.expectRevert(MiningPowerCustody.InvalidCurveConfig.selector);
        new MiningPowerCustody(address(hunter), CORE, 0);
    }

    function testZeroAmountsAndZeroWalletsRevert() public {
        vm.startPrank(ALICE);
        vm.expectRevert(MiningPowerCustody.ZeroAmount.selector);
        custody.deposit(0);
        custody.deposit(1_000e18);
        vm.expectRevert(MiningPowerCustody.ZeroAddress.selector);
        custody.assign(address(0), 1);
        vm.expectRevert(MiningPowerCustody.ZeroAmount.selector);
        custody.assign(MINER, 0);
        custody.assign(MINER, 500e18);
        vm.expectRevert(MiningPowerCustody.ZeroAddress.selector);
        custody.unassign(address(0), 1);
        vm.expectRevert(MiningPowerCustody.ZeroAmount.selector);
        custody.unassign(MINER, 0);
        vm.expectRevert(MiningPowerCustody.ZeroAmount.selector);
        custody.withdraw(0);
        vm.stopPrank();
    }

    function testAssignUnassignWithdrawBoundaries() public {
        vm.startPrank(ALICE);
        custody.deposit(1_000e18);
        vm.expectRevert(abi.encodeWithSelector(MiningPowerCustody.InsufficientUnassigned.selector, 1_000e18, 1_001e18));
        custody.assign(MINER, 1_001e18);
        custody.assign(MINER, 400e18);
        vm.expectRevert(abi.encodeWithSelector(MiningPowerCustody.MustUnassignFirst.selector, MINER));
        custody.assign(OTHER, 1);
        custody.assign(MINER, 100e18); // same wallet top-up is allowed
        assertEq(custody.assignedBy(ALICE), 500e18);
        assertEq(custody.assigneeOf(ALICE), MINER);
        vm.expectRevert(abi.encodeWithSelector(MiningPowerCustody.WrongAssignee.selector, MINER, OTHER));
        custody.unassign(OTHER, 1);
        vm.expectRevert(abi.encodeWithSelector(MiningPowerCustody.InsufficientUnassigned.selector, 500e18, 501e18));
        custody.withdraw(501e18);
        vm.stopPrank();

        vm.prank(CORE);
        custody.onProofAccepted(11);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MiningPowerCustody.UnlockDelayNotMet.selector, 12, 11));
        custody.unassign(MINER, 1);

        vm.prank(CORE);
        custody.onProofAccepted(12);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MiningPowerCustody.InsufficientAssigned.selector, 500e18, 501e18));
        custody.unassign(MINER, 501e18);

        vm.prank(ALICE);
        custody.unassign(MINER, 200e18);
        assertEq(custody.assigneeOf(ALICE), MINER);
        assertEq(custody.assignedBy(ALICE), 300e18);

        vm.prank(ALICE);
        custody.unassign(MINER, 300e18);
        assertEq(custody.assigneeOf(ALICE), address(0));
        assertEq(custody.assignedOf(MINER), 0);

        vm.prank(ALICE);
        custody.withdraw(1_000e18);
        assertEq(hunter.balanceOf(ALICE), 100_000e18);
        assertEq(custody.totalLocked(), 0);
    }

    function testTopUpAssignResetsThisDepositorsUnlockClockOnly() public {
        hunter.mint(BOB, 1_000e18);
        vm.prank(BOB);
        hunter.approve(address(custody), type(uint256).max);

        vm.prank(ALICE);
        custody.deposit(1_000e18);
        vm.prank(ALICE);
        custody.assign(MINER, 500e18);

        vm.prank(CORE);
        custody.onProofAccepted(12);

        vm.prank(ALICE);
        custody.assign(MINER, 500e18); // resets Alice's clock to 12
        vm.prank(BOB);
        custody.deposit(1_000e18);
        vm.prank(BOB);
        custody.assign(MINER, 1_000e18); // Bob's clock is also 12

        vm.prank(CORE);
        custody.onProofAccepted(24);

        vm.prank(ALICE);
        custody.unassign(MINER, 1_000e18);
        vm.prank(BOB);
        custody.unassign(MINER, 1_000e18);
        assertEq(custody.assignedOf(MINER), 0);
        assertEq(custody.assignedBy(ALICE), 0);
        assertEq(custody.assignedBy(BOB), 0);
    }

    /// @dev Regression: a top-up assign must reset the depositor's unlock clock.
    /// Distinguishes reset from no-reset: Bob's untouched index-0 clock unlocks
    /// at 20 >= 12 while Alice's topped-up clock (reset to 12) still reverts.
    function testTopUpAssignResetBlocksExitUntilNewDelay() public {
        hunter.mint(BOB, 1_000e18);
        vm.prank(BOB);
        hunter.approve(address(custody), type(uint256).max);

        vm.prank(ALICE);
        custody.deposit(1_000e18);
        vm.prank(ALICE);
        custody.assign(MINER, 500e18); // Alice clock 0 -> earliest 12
        vm.prank(BOB);
        custody.deposit(1_000e18);
        vm.prank(BOB);
        custody.assign(MINER, 500e18); // Bob clock 0 -> earliest 12 (control)

        vm.prank(CORE);
        custody.onProofAccepted(12);
        vm.prank(ALICE);
        custody.assign(MINER, 500e18); // top-up resets Alice clock -> earliest 24

        vm.prank(CORE);
        custody.onProofAccepted(20);

        vm.prank(BOB);
        custody.unassign(MINER, 100e18); // control: index-0 clock unlocks
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(MiningPowerCustody.UnlockDelayNotMet.selector, 24, 20));
        custody.unassign(MINER, 1);

        vm.prank(CORE);
        custody.onProofAccepted(24);
        vm.prank(ALICE);
        custody.unassign(MINER, 1_000e18);
        assertEq(custody.assigneeOf(ALICE), address(0));
        assertEq(custody.assignedOf(MINER), 400e18);
    }

    function testOnlyMiningCoreMaySnapshotOrAdvanceProofs() public {
        vm.expectRevert(abi.encodeWithSelector(MiningPowerCustody.UnauthorizedCaller.selector, address(this)));
        custody.snapshotChallenge(1);
        vm.expectRevert(abi.encodeWithSelector(MiningPowerCustody.UnauthorizedCaller.selector, ALICE));
        vm.prank(ALICE);
        custody.onProofAccepted(1);

        vm.prank(CORE);
        custody.snapshotChallenge(1);
        vm.prank(CORE);
        vm.expectRevert(abi.encodeWithSelector(MiningPowerCustody.AlreadySnapshotted.selector, 1));
        custody.snapshotChallenge(1);

        vm.expectRevert(abi.encodeWithSelector(MiningPowerCustody.ChallengeNotOpen.selector, 99));
        custody.powerMultiplierWad(99, MINER);
        vm.expectRevert(abi.encodeWithSelector(MiningPowerCustody.ChallengeNotOpen.selector, 99));
        custody.snapshottedLockedAmount(99, MINER);
    }

    function testSnapshotFreezesLockedAmountAndIgnoresLaterAssign() public {
        vm.prank(CORE);
        custody.snapshotChallenge(7);
        assertEq(custody.snapshottedLockedAmount(7, MINER), 0);
        assertEq(custody.powerMultiplierWad(7, MINER), 1e18);

        vm.prank(ALICE);
        custody.deposit(50_000e18);
        vm.prank(ALICE);
        custody.assign(MINER, 50_000e18);

        assertEq(custody.snapshottedLockedAmount(7, MINER), 0);
        assertEq(custody.powerMultiplierWad(7, MINER), 1e18);

        vm.prank(CORE);
        custody.snapshotChallenge(8);
        uint256 locked = custody.snapshottedLockedAmount(8, MINER);
        uint256 mult = custody.powerMultiplierWad(8, MINER);
        assertEq(locked, 50_000e18);
        assertGt(mult, 1e18);
        assertLe(mult, 3e18);
        assertEq(mult, custody.multiplierFromLockedAmount(50_000e18));
    }

    function testMultiplierFloorBelowCurveUnitAndCap() public view {
        assertEq(custody.multiplierFromLockedAmount(0), 1e18);
        assertEq(custody.multiplierFromLockedAmount(CURVE_UNIT - 1), 1e18);
        assertGt(custody.multiplierFromLockedAmount(CURVE_UNIT), 1e18);
        uint256 capped = custody.multiplierFromLockedAmount(1_000_000e18);
        assertEq(capped, 3e18);
        assertEq(custody.multiplierFromLockedAmount(type(uint256).max), 3e18);
    }

    function testFeeOnTransferCreditsReceivedNotRequested() public {
        FeeOnTransferHunter token = new FeeOnTransferHunter(1_000); // 10%
        MiningPowerCustody feeCustody = new MiningPowerCustody(address(token), CORE, CURVE_UNIT);
        token.setCustody(address(feeCustody));
        token.mint(ALICE, 1_000e18);
        vm.startPrank(ALICE);
        token.approve(address(feeCustody), type(uint256).max);
        feeCustody.deposit(1_000e18);
        vm.stopPrank();
        assertEq(feeCustody.totalLocked(), 900e18);
        assertEq(feeCustody.unassignedOf(ALICE), 900e18);
        assertEq(token.balanceOf(address(feeCustody)), 900e18);
    }

    function testFullFeeOnTransferDepositRevertsZeroReceived() public {
        FeeOnTransferHunter token = new FeeOnTransferHunter(10_000);
        MiningPowerCustody feeCustody = new MiningPowerCustody(address(token), CORE, CURVE_UNIT);
        token.setCustody(address(feeCustody));
        token.mint(ALICE, 1_000e18);
        vm.startPrank(ALICE);
        token.approve(address(feeCustody), type(uint256).max);
        vm.expectRevert(MiningPowerCustody.ZeroAmount.selector);
        feeCustody.deposit(1_000e18);
        vm.stopPrank();
        assertEq(feeCustody.totalLocked(), 0);
        assertEq(token.balanceOf(address(feeCustody)), 0);
    }

    function testBonusOnTransferCreditsActualBalanceIncrease() public {
        BonusHunter token = new BonusHunter();
        MiningPowerCustody bonusCustody = new MiningPowerCustody(address(token), CORE, CURVE_UNIT);
        token.setCustody(address(bonusCustody));
        token.mint(ALICE, 1_000e18);
        vm.startPrank(ALICE);
        token.approve(address(bonusCustody), type(uint256).max);
        bonusCustody.deposit(1_000e18);
        vm.stopPrank();
        assertEq(bonusCustody.totalLocked(), 1_000e18 + 1);
        assertEq(token.balanceOf(address(bonusCustody)), 1_000e18 + 1);
    }

    function testDepositCallbackCannotReenter() public {
        ReentrantHunter token = new ReentrantHunter();
        MiningPowerCustody reCustody = new MiningPowerCustody(address(token), CORE, CURVE_UNIT);
        token.configure(reCustody, abi.encodeCall(MiningPowerCustody.deposit, (1)));
        token.mint(ALICE, 1_000e18);
        vm.startPrank(ALICE);
        token.approve(address(reCustody), type(uint256).max);
        reCustody.deposit(100e18);
        vm.stopPrank();
        assertTrue(token.callbackAttempted());
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackError(), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(reCustody.totalLocked(), 100e18);
        assertEq(reCustody.unassignedOf(ALICE), 100e18);
    }

    function testWithdrawCallbackCannotReenter() public {
        ReentrantHunter token = new ReentrantHunter();
        MiningPowerCustody reCustody = new MiningPowerCustody(address(token), CORE, CURVE_UNIT);
        token.mint(ALICE, 1_000e18);
        vm.startPrank(ALICE);
        token.approve(address(reCustody), type(uint256).max);
        reCustody.deposit(100e18);
        vm.stopPrank();
        token.configure(reCustody, abi.encodeCall(MiningPowerCustody.withdraw, (1)));
        vm.prank(ALICE);
        reCustody.withdraw(50e18);
        assertTrue(token.callbackAttempted());
        assertFalse(token.callbackSucceeded());
        assertEq(token.callbackError(), bytes4(keccak256("ReentrancyGuardReentrantCall()")));
        assertEq(reCustody.totalLocked(), 50e18);
        assertEq(token.balanceOf(ALICE), 1_000e18 - 50e18);
    }
}
