// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {PrefundedMiningPower} from "../src/bloom/PrefundedMiningPower.sol";
import {PrefundedMiningStack} from "./helpers/PrefundedMiningStack.sol";

/// @dev TEST-ONLY fee-on-transfer token (adapted from MiningPowerCustodyEdges):
/// inbound transfers into `module` burn `feeBps` of the amount.
contract PrefundedFeeHunter is ERC20 {
    uint256 public feeBps;
    address public module;

    constructor(uint256 feeBps_) ERC20("Fee HUNTER", "fHUNT") {
        feeBps = feeBps_;
    }

    function setModule(address module_) external {
        module = module_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to == module && feeBps != 0) {
            uint256 fee = (value * feeBps) / 10_000;
            if (fee != 0) super._update(from, address(0), fee);
            super._update(from, to, value - fee);
            return;
        }
        super._update(from, to, value);
    }
}

/// @dev TEST-ONLY bonus token: an inbound transfer into `module` mints 1 extra
/// unit to it, so the measured receipt exceeds the requested amount.
contract PrefundedBonusHunter is ERC20 {
    address public module;

    constructor() ERC20("Bonus HUNTER", "bHUNT") {}

    function setModule(address module_) external {
        module = module_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from != address(0) && to == module) super._update(address(0), to, 1);
    }
}

/// @dev TEST-ONLY token whose `transfer` / `transferFrom` can be switched to
/// return false without moving anything (SafeERC20 must revert).
contract PrefundedFalseHunter is ERC20 {
    bool public returnFalse;

    constructor() ERC20("False HUNTER", "xHUNT") {}

    function setReturnFalse(bool on) external {
        returnFalse = on;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (returnFalse) return false;
        return super.transfer(to, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (returnFalse) return false;
        return super.transferFrom(from, to, value);
    }
}

/// @dev TEST-ONLY token that mis-debits outbound transfers from `module`:
/// mode 1 burns one extra unit from the module (over-debit), mode 2 delivers
/// and debits one unit less (under-debit).
contract PrefundedMisDebitHunter is ERC20 {
    address public module;
    uint256 public mode;

    constructor() ERC20("MisDebit HUNTER", "mHUNT") {}

    function configure(address module_, uint256 mode_) external {
        module = module_;
        mode = mode_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == module && from != address(0) && to != address(0) && mode != 0) {
            if (mode == 1) {
                super._update(from, to, value);
                super._update(from, address(0), 1);
            } else {
                super._update(from, to, value - 1);
            }
            return;
        }
        super._update(from, to, value);
    }
}

/// @dev TEST-ONLY token that re-enters the module from inside every transfer
/// touching it (adapted from MiningPowerCustodyEdges.ReentrantHunter).
contract PrefundedReentrantHunter is ERC20 {
    address public target;
    bytes public payload;
    bool public callbackAttempted;
    bool public callbackSucceeded;
    bytes4 public callbackError;
    bool private _inside;

    constructor() ERC20("Re HUNTER", "rHUNT") {}

    function configure(address target_, bytes memory payload_) external {
        target = target_;
        payload = payload_;
        callbackAttempted = false;
        callbackSucceeded = false;
        callbackError = bytes4(0);
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (!_inside && payload.length != 0 && (to == target || from == target)) {
            _inside = true;
            callbackAttempted = true;
            (bool ok, bytes memory reason) = target.call(payload);
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

/// @notice S4 (VLT-55) stake-ledger and S6 (VLT-57) mint-funds hostile-token
/// and fail-closed suite.
/// Hostile tokens back separately constructed modules bound to the REAL core
/// (the core never touches the token); `token` / `module` are the harness's
/// token-bound fixture. All amounts are TEST-ONLY fixture values.
contract PrefundedMiningPowerHostileTest is PrefundedMiningStack {
    using stdStorage for StdStorage;

    uint256 private constant LOCK = 100e18;
    uint256 private constant COOLDOWN = 1 hours;

    function setUp() public override {
        super.setUp();
        _deployModule(0, LOCK, COOLDOWN, 0, address(0));
        _attach(module);
    }

    // ------------------------------------------------------------------
    // Measured receipts
    // ------------------------------------------------------------------

    function testFeeOnTransferCreditsMeasuredReceipt() public {
        PrefundedFeeHunter fee = new PrefundedFeeHunter(1_000); // 10%
        PrefundedMiningPower m = _hostileModule(address(fee));
        fee.setModule(address(m));
        fee.mint(ALICE, 1_000e18);
        vm.startPrank(ALICE);
        fee.approve(address(m), type(uint256).max);
        vm.expectEmit(true, false, false, true, address(m));
        emit PrefundedMiningPower.Deposited(ALICE, 900e18);
        m.deposit(1_000e18);
        vm.stopPrank();
        assertEq(m.unassignedOf(ALICE), 900e18);
        assertEq(m.totalStake(), 900e18);
        assertEq(fee.balanceOf(address(m)), 900e18);

        // Only what was credited can leave, and it leaves in full.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.InsufficientUnassigned.selector, 900e18, 1_000e18));
        m.withdraw(1_000e18);
        vm.prank(ALICE);
        m.withdraw(900e18);
        assertEq(fee.balanceOf(ALICE), 900e18);
        assertEq(fee.balanceOf(address(m)), 0);
        assertEq(m.totalStake(), 0);
    }

    function testZeroReceiptReverts() public {
        PrefundedFeeHunter fee = new PrefundedFeeHunter(10_000); // full tax
        PrefundedMiningPower m = _hostileModule(address(fee));
        fee.setModule(address(m));
        fee.mint(ALICE, 1_000e18);
        vm.startPrank(ALICE);
        fee.approve(address(m), type(uint256).max);
        vm.expectRevert(PrefundedMiningPower.UnsupportedTokenReceipt.selector);
        m.deposit(1_000e18);
        vm.stopPrank();
        assertEq(m.totalStake(), 0);
        assertEq(m.unassignedOf(ALICE), 0);
        assertEq(fee.balanceOf(ALICE), 1_000e18);
        assertEq(fee.balanceOf(address(m)), 0);
    }

    function testFalseReturningTokenRollsBack() public {
        PrefundedFalseHunter bad = new PrefundedFalseHunter();
        PrefundedMiningPower m = _hostileModule(address(bad));
        bad.mint(ALICE, 1_000e18);
        vm.prank(ALICE);
        bad.approve(address(m), type(uint256).max);

        // Inbound: transferFrom returns false → SafeERC20 reverts, nothing credited.
        bad.setReturnFalse(true);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad)));
        m.deposit(500e18);
        assertEq(m.unassignedOf(ALICE), 0);
        assertEq(m.totalStake(), 0);
        assertEq(bad.balanceOf(ALICE), 1_000e18);

        // Outbound: transfer returns false → the debit is rolled back.
        bad.setReturnFalse(false);
        vm.prank(ALICE);
        m.deposit(500e18);
        bad.setReturnFalse(true);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(bad)));
        m.withdraw(200e18);
        assertEq(m.unassignedOf(ALICE), 500e18);
        assertEq(m.totalStake(), 500e18);
        assertEq(bad.balanceOf(address(m)), 500e18);
        assertEq(bad.balanceOf(ALICE), 500e18);

        bad.setReturnFalse(false);
        vm.prank(ALICE);
        m.withdraw(500e18);
        assertEq(bad.balanceOf(ALICE), 1_000e18);
        assertEq(m.totalStake(), 0);
    }

    /// @dev Outbound debit that differs from `amount` in either direction
    /// reverts DebitMismatch and rolls the withdrawal back.
    function testOutboundDebitMismatchReverts() public {
        PrefundedMisDebitHunter bad = new PrefundedMisDebitHunter();
        PrefundedMiningPower m = _hostileModule(address(bad));
        bad.mint(ALICE, 1_000e18);
        vm.startPrank(ALICE);
        bad.approve(address(m), type(uint256).max);
        m.deposit(1_000e18);
        vm.stopPrank();
        // Surplus so an over-debit is not also an insolvency.
        bad.mint(address(m), 10);

        for (uint256 mode = 1; mode <= 2; mode++) {
            bad.configure(address(m), mode);
            vm.prank(ALICE);
            vm.expectRevert(PrefundedMiningPower.DebitMismatch.selector);
            m.withdraw(400e18);
            assertEq(m.unassignedOf(ALICE), 1_000e18);
            assertEq(m.totalStake(), 1_000e18);
            assertEq(bad.balanceOf(address(m)), 1_000e18 + 10);
        }
        bad.configure(address(m), 0);
        vm.prank(ALICE);
        m.withdraw(1_000e18);
        assertEq(bad.balanceOf(ALICE), 1_000e18);
    }

    // ------------------------------------------------------------------
    // Reentrancy
    // ------------------------------------------------------------------

    function testReentrantTokenCannotReenterModule() public {
        PrefundedReentrantHunter re = new PrefundedReentrantHunter();
        PrefundedMiningPower m = _hostileModule(address(re));
        // Wire it so a missing guard would get past the state checks.
        _detach();
        _attach(m);
        assertTrue(m.wired());

        // The token contract itself holds stake and an assignment, so each
        // re-entrant payload (sent with msg.sender == token) would otherwise
        // be a valid call.
        re.mint(address(re), 1_000e18);
        vm.startPrank(address(re));
        re.approve(address(m), type(uint256).max);
        m.deposit(600e18);
        m.assign(MINER, 200e18);
        vm.stopPrank();
        vm.warp(block.timestamp + COOLDOWN);

        re.mint(ALICE, 1_000e18);
        vm.prank(ALICE);
        re.approve(address(m), type(uint256).max);

        bytes[4] memory payloads = [
            abi.encodeCall(PrefundedMiningPower.deposit, (1)),
            abi.encodeCall(PrefundedMiningPower.assign, (MINER, 1)),
            abi.encodeCall(PrefundedMiningPower.unassign, (MINER, 1)),
            abi.encodeCall(PrefundedMiningPower.withdraw, (1))
        ];
        bytes4 guardErr = ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
        uint256 aliceStake;
        for (uint256 i = 0; i < payloads.length; i++) {
            // During deposit.
            re.configure(address(m), payloads[i]);
            vm.prank(ALICE);
            m.deposit(100e18);
            aliceStake += 100e18;
            _assertReentryBlocked(re, guardErr);
            _assertReentrantBooks(m, re, aliceStake);

            // During withdraw.
            re.configure(address(m), payloads[i]);
            vm.prank(ALICE);
            m.withdraw(40e18);
            aliceStake -= 40e18;
            _assertReentryBlocked(re, guardErr);
            _assertReentrantBooks(m, re, aliceStake);
        }
    }

    // ------------------------------------------------------------------
    // Donations and corrupted totals
    // ------------------------------------------------------------------

    function testDonationsNeverCreditedOrPayable() public {
        _deposit(ALICE, 1_000e18);
        _assign(ALICE, MINER, 300e18);

        // FUNDER donates straight to the module.
        token.mint(FUNDER, 500e18);
        vm.prank(FUNDER);
        token.transfer(address(module), 500e18);
        _trackDepositor(FUNDER);

        assertEq(token.balanceOf(address(module)), 1_500e18);
        assertEq(module.totalStake(), 1_000e18);
        assertEq(module.totalAssigned(), 300e18);
        assertEq(module.unassignedOf(FUNDER), 0);
        assertEq(module.unassignedOf(ALICE), 700e18);
        assertEq(module.assignedOf(MINER), 300e18);
        _assertBooks();

        // The donor has no claim; nobody can withdraw beyond their credit.
        vm.prank(FUNDER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.InsufficientUnassigned.selector, 0, 1));
        module.withdraw(1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.InsufficientUnassigned.selector, 700e18, 701e18));
        module.withdraw(701e18);
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.InsufficientUnassigned.selector, 0, 1));
        module.withdraw(1);

        // Full exit returns exactly the deposit; the donation stays stranded.
        vm.warp(block.timestamp + COOLDOWN);
        _unassign(ALICE, MINER, 300e18);
        _withdraw(ALICE, 1_000e18);
        assertEq(token.balanceOf(ALICE), 1_000e18);
        assertEq(token.balanceOf(address(module)), 500e18);
        assertEq(module.totalStake(), 0);
        _assertBooks();
    }

    function testCorruptedTotalsBlockEveryExit() public {
        _deposit(ALICE, 1_000e18);
        _assign(ALICE, MINER, 400e18);
        vm.warp(block.timestamp + COOLDOWN);
        uint256 bal = token.balanceOf(address(module));
        token.mint(BOB, 10e18);
        vm.prank(BOB);
        token.approve(address(module), type(uint256).max);

        string[3] memory totals = ["totalStake()", "totalFunds()", "totalCommitted()"];
        for (uint256 i = 0; i < totals.length; i++) {
            uint256 original = i == 0 ? 1_000e18 : 0;
            uint256 corrupted = i == 0 ? bal + 1 : 1;
            stdstore.target(address(module)).sig(totals[i]).checked_write(corrupted);

            vm.prank(ALICE);
            vm.expectRevert(PrefundedMiningPower.Insolvency.selector);
            module.withdraw(600e18);
            vm.prank(ALICE);
            vm.expectRevert(PrefundedMiningPower.Insolvency.selector);
            module.unassign(MINER, 400e18);
            vm.prank(BOB);
            vm.expectRevert(PrefundedMiningPower.Insolvency.selector);
            module.deposit(10e18);

            // Nothing moved and no ledger entry changed.
            assertEq(token.balanceOf(address(module)), bal);
            assertEq(module.unassignedOf(ALICE), 600e18);
            assertEq(module.assignedBy(ALICE), 400e18);
            assertEq(module.assignedOf(MINER), 400e18);
            assertEq(module.totalAssigned(), 400e18);
            assertEq(module.unassignedOf(BOB), 0);
            assertEq(token.balanceOf(ALICE), 0);

            stdstore.target(address(module)).sig(totals[i]).checked_write(original);
        }

        // With honest totals every exit works again.
        _unassign(ALICE, MINER, 400e18);
        _withdraw(ALICE, 1_000e18);
        assertEq(token.balanceOf(ALICE), 1_000e18);
        _assertBooks();
    }

    // ------------------------------------------------------------------
    // S6: mint funds under hostile tokens and corrupted totals
    // ------------------------------------------------------------------

    function testFundFeeOnTransferCreditsMeasuredReceipt() public {
        PrefundedFeeHunter fee = new PrefundedFeeHunter(1_000); // 10%
        PrefundedMiningPower m = _hostileModule(address(fee));
        fee.setModule(address(m));
        fee.mint(FUNDER, 1_000e18);
        vm.startPrank(FUNDER);
        fee.approve(address(m), type(uint256).max);
        vm.expectEmit(true, true, false, true, address(m));
        emit PrefundedMiningPower.Funded(FUNDER, MINER, 900e18);
        m.fund(MINER, 1_000e18);
        vm.stopPrank();
        assertEq(m.fundsOf(MINER), 900e18);
        assertEq(m.pendingFunds(MINER), 900e18);
        assertEq(m.totalFunds(), 900e18);
        assertEq(m.fundsOf(FUNDER), 0);
        assertEq(fee.balanceOf(address(m)), 900e18);

        // Only the credited amount can leave, only to the wallet, in full.
        vm.prank(FUNDER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.InsufficientFunds.selector, 0, 1));
        m.withdrawFunds(1);
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.InsufficientFunds.selector, 900e18, 1_000e18));
        m.withdrawFunds(1_000e18);
        vm.prank(MINER);
        m.withdrawFunds(900e18);
        assertEq(fee.balanceOf(MINER), 900e18);
        assertEq(fee.balanceOf(address(m)), 0);
        assertEq(m.totalFunds(), 0);
        assertEq(m.pendingFunds(MINER), 0);
    }

    function testFundZeroReceiptReverts() public {
        PrefundedFeeHunter fee = new PrefundedFeeHunter(10_000); // full tax
        PrefundedMiningPower m = _hostileModule(address(fee));
        fee.setModule(address(m));
        fee.mint(FUNDER, 1_000e18);
        vm.startPrank(FUNDER);
        fee.approve(address(m), type(uint256).max);
        vm.expectRevert(PrefundedMiningPower.UnsupportedTokenReceipt.selector);
        m.fund(MINER, 1_000e18);
        vm.stopPrank();
        assertEq(m.totalFunds(), 0);
        assertEq(m.fundsOf(MINER), 0);
        assertEq(m.pendingFunds(MINER), 0);
        assertEq(fee.balanceOf(FUNDER), 1_000e18);

        // Over-receipt (S0 default 5) reverts too.
        PrefundedBonusHunter bonus = new PrefundedBonusHunter();
        PrefundedMiningPower mb = _hostileModule(address(bonus));
        bonus.setModule(address(mb));
        bonus.mint(FUNDER, 1_000e18);
        vm.startPrank(FUNDER);
        bonus.approve(address(mb), type(uint256).max);
        vm.expectRevert(PrefundedMiningPower.UnsupportedTokenReceipt.selector);
        mb.fund(MINER, 1_000e18);
        vm.stopPrank();
        assertEq(mb.totalFunds(), 0);
        assertEq(bonus.balanceOf(address(mb)), 0);
    }

    function testFundInputValidationAndStateGates() public {
        token.mint(FUNDER, 10e18);
        vm.startPrank(FUNDER);
        token.approve(address(module), type(uint256).max);
        vm.expectRevert(PrefundedMiningPower.ZeroAddress.selector);
        module.fund(address(0), 1);
        vm.expectRevert(PrefundedMiningPower.ZeroAmount.selector);
        module.fund(MINER, 0);
        vm.stopPrank();
        vm.prank(MINER);
        vm.expectRevert(PrefundedMiningPower.ZeroAmount.selector);
        module.withdrawFunds(0);

        // Allowed on an unattached module (counts from the attach snapshot on).
        PrefundedMiningPower fresh = new PrefundedMiningPower(address(token), address(core), 0, LOCK, 0, 0, address(0));
        vm.startPrank(FUNDER);
        token.approve(address(fresh), type(uint256).max);
        fresh.fund(MINER, 1e18);
        vm.stopPrank();
        assertEq(fresh.fundsOf(MINER), 1e18);
        assertEq(fresh.eligibleFundsOf(MINER), 0);

        // Failsafe fired: refused (S8 lands `disableRequirement`; injected).
        uint256 slot = stdstore.enable_packed_slots().target(address(module)).sig("gateDisabled()").find();
        bytes32 raw = vm.load(address(module), bytes32(slot));
        stdstore.enable_packed_slots().target(address(module)).sig("gateDisabled()").checked_write(true);
        vm.prank(FUNDER);
        vm.expectRevert(PrefundedMiningPower.GateDisabled.selector);
        module.fund(MINER, 1);
        vm.store(address(module), bytes32(slot), raw);
        assertFalse(module.gateDisabled());

        // Retired (terminal stop): refused; withdrawal still works.
        _fund(MINER, 5e18);
        vm.prank(STOP);
        core.stopMining();
        assertTrue(module.retired());
        vm.prank(FUNDER);
        vm.expectRevert(PrefundedMiningPower.Retired.selector);
        module.fund(MINER, 1);
        vm.prank(MINER);
        module.withdrawFunds(5e18);
        assertEq(token.balanceOf(MINER), 5e18);
        _assertBooks();
    }

    function testWithdrawFundsExactDebitAndSolvency() public {
        PrefundedMisDebitHunter bad = new PrefundedMisDebitHunter();
        PrefundedMiningPower m = _hostileModule(address(bad));
        bad.mint(FUNDER, 1_000e18);
        vm.startPrank(FUNDER);
        bad.approve(address(m), type(uint256).max);
        m.fund(MINER, 1_000e18);
        vm.stopPrank();
        // Surplus so an over-debit is not also an insolvency.
        bad.mint(address(m), 10);

        for (uint256 mode = 1; mode <= 2; mode++) {
            bad.configure(address(m), mode);
            vm.prank(MINER);
            vm.expectRevert(PrefundedMiningPower.DebitMismatch.selector);
            m.withdrawFunds(400e18);
            assertEq(m.fundsOf(MINER), 1_000e18);
            assertEq(m.pendingFunds(MINER), 1_000e18);
            assertEq(m.totalFunds(), 1_000e18);
            assertEq(bad.balanceOf(address(m)), 1_000e18 + 10);
            assertEq(bad.balanceOf(MINER), 0);
        }
        bad.configure(address(m), 0);
        vm.expectEmit(true, false, false, true, address(m));
        emit PrefundedMiningPower.FundsWithdrawn(MINER, 1_000e18);
        vm.prank(MINER);
        m.withdrawFunds(1_000e18);
        assertEq(bad.balanceOf(MINER), 1_000e18);
        assertEq(m.totalFunds(), 0);
        assertEq(bad.balanceOf(address(m)), 10);
    }

    function testReentrantTokenCannotReenterFundPaths() public {
        PrefundedReentrantHunter re = new PrefundedReentrantHunter();
        PrefundedMiningPower m = _hostileModule(address(re));
        _detach();
        _attach(m);

        // The token contract holds stake and mint funds of its own, so every
        // re-entrant payload (msg.sender == token) would otherwise succeed.
        re.mint(address(re), 1_000e18);
        vm.startPrank(address(re));
        re.approve(address(m), type(uint256).max);
        m.deposit(300e18);
        m.fund(address(re), 300e18);
        vm.stopPrank();

        re.mint(FUNDER, 1_000e18);
        vm.prank(FUNDER);
        re.approve(address(m), type(uint256).max);

        bytes[5] memory payloads = [
            abi.encodeCall(PrefundedMiningPower.fund, (MINER, 1)),
            abi.encodeCall(PrefundedMiningPower.fund, (address(re), 1)),
            abi.encodeCall(PrefundedMiningPower.withdrawFunds, (1)),
            abi.encodeCall(PrefundedMiningPower.deposit, (1)),
            abi.encodeCall(PrefundedMiningPower.withdraw, (1))
        ];
        bytes4 guardErr = ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
        uint256 minerFunds;
        for (uint256 i = 0; i < payloads.length; i++) {
            // During fund.
            re.configure(address(m), payloads[i]);
            vm.prank(FUNDER);
            m.fund(MINER, 100e18);
            minerFunds += 100e18;
            _assertReentryBlocked(re, guardErr);
            _assertReentrantFundBooks(m, re, minerFunds);

            // During withdrawFunds.
            re.configure(address(m), payloads[i]);
            vm.prank(MINER);
            m.withdrawFunds(40e18);
            minerFunds -= 40e18;
            _assertReentryBlocked(re, guardErr);
            _assertReentrantFundBooks(m, re, minerFunds);
        }
    }

    function testCorruptedTotalFundsBlocksExits() public {
        _deposit(ALICE, 1_000e18);
        _fund(MINER, 500e18);
        uint256 bal = token.balanceOf(address(module));
        assertEq(bal, 1_500e18);
        token.mint(BOB, 10e18);
        vm.prank(BOB);
        token.approve(address(module), type(uint256).max);

        string[2] memory totals = ["totalFunds()", "totalCommitted()"];
        uint256[2] memory originals = [uint256(500e18), 0];
        for (uint256 i = 0; i < totals.length; i++) {
            // One unit more than the balance covers.
            uint256 corrupted = originals[i] + 1;
            stdstore.target(address(module)).sig(totals[i]).checked_write(corrupted);

            vm.prank(MINER);
            vm.expectRevert(PrefundedMiningPower.Insolvency.selector);
            module.withdrawFunds(100e18);
            vm.prank(ALICE);
            vm.expectRevert(PrefundedMiningPower.Insolvency.selector);
            module.withdraw(100e18);
            vm.prank(BOB);
            vm.expectRevert(PrefundedMiningPower.Insolvency.selector);
            module.fund(MINER, 10e18);
            vm.prank(BOB);
            vm.expectRevert(PrefundedMiningPower.Insolvency.selector);
            module.deposit(10e18);

            assertEq(token.balanceOf(address(module)), bal);
            assertEq(module.fundsOf(MINER), 500e18);
            assertEq(module.unassignedOf(ALICE), 1_000e18);
            assertEq(token.balanceOf(MINER), 0);
            assertEq(token.balanceOf(ALICE), 0);

            stdstore.target(address(module)).sig(totals[i]).checked_write(originals[i]);
        }

        vm.prank(MINER);
        module.withdrawFunds(500e18);
        _withdraw(ALICE, 1_000e18);
        assertEq(token.balanceOf(MINER), 500e18);
        assertEq(token.balanceOf(ALICE), 1_000e18);
        assertEq(token.balanceOf(address(module)), 0);
        _assertBooks();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Only the outer call's effect is visible: the token contract's
    /// own stake (300) and funds (300) are untouched.
    function _assertReentrantFundBooks(PrefundedMiningPower m, PrefundedReentrantHunter re, uint256 minerFunds)
        private
        view
    {
        assertEq(m.fundsOf(MINER), minerFunds);
        assertEq(m.fundsOf(address(re)), 300e18);
        assertEq(m.unassignedOf(address(re)), 300e18);
        assertEq(m.totalStake(), 300e18);
        assertEq(m.totalFunds(), 300e18 + minerFunds);
        assertEq(re.balanceOf(address(m)), 600e18 + minerFunds);
    }

    function _hostileModule(address hunter) private returns (PrefundedMiningPower) {
        return new PrefundedMiningPower(hunter, address(core), 0, LOCK, COOLDOWN, 0, address(0));
    }

    function _assertReentryBlocked(PrefundedReentrantHunter re, bytes4 guardErr) private view {
        assertTrue(re.callbackAttempted(), "callback not attempted");
        assertFalse(re.callbackSucceeded(), "re-entry succeeded");
        assertEq(re.callbackError(), guardErr, "not the reentrancy guard");
    }

    /// @dev Only the outer call's effect is visible: the token contract's own
    /// position (deposit 600, assigned 200 to MINER) is untouched.
    function _assertReentrantBooks(PrefundedMiningPower m, PrefundedReentrantHunter re, uint256 aliceStake)
        private
        view
    {
        assertEq(m.unassignedOf(ALICE), aliceStake);
        assertEq(m.unassignedOf(address(re)), 400e18);
        assertEq(m.assignedBy(address(re)), 200e18);
        assertEq(m.assignedOf(MINER), 200e18);
        assertEq(m.totalAssigned(), 200e18);
        assertEq(m.totalStake(), 600e18 + aliceStake);
        assertEq(re.balanceOf(address(m)), 600e18 + aliceStake);
        assertEq(re.balanceOf(ALICE), 1_000e18 - aliceStake);
    }
}
