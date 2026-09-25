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

/// @notice S4 (VLT-55) stake-ledger, S6 (VLT-57) per-mint lock and S7
/// (VLT-58) release hostile-token and fail-closed suite. Single bucket (owner
/// decision 2026-09-25): every lock is paid from assigned stake.
/// Hostile tokens back separately constructed modules bound to the REAL core
/// (the core never touches the token); `token` / `module` are the harness's
/// token-bound fixture. All amounts are TEST-ONLY fixture values.
contract PrefundedMiningPowerHostileTest is PrefundedMiningStack {
    using stdStorage for StdStorage;

    uint256 private constant LOCK = 100e18;
    uint256 private constant COOLDOWN = 1 hours;
    address private constant GUARDIAN = address(0x6A2D);

    function setUp() public override {
        super.setUp();
        // Smallest legal floor: MIN_STAKE == LOCK_PER_MINT.
        _deployModule(LOCK, LOCK, COOLDOWN, 0, address(0));
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
        vm.prank(MINER);
        m.approveBacker(address(re));
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
        _approve(MINER, ALICE);
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

    /// @dev S8: the module carries a failsafe guardian, and firing the
    /// failsafe on a corrupted module does not unblock anything — it waives
    /// the cooldown and hold, never the solvency check.
    function testCorruptedTotalsBlockEveryExit() public {
        _detach();
        _deployModule(LOCK, LOCK, COOLDOWN, 0, GUARDIAN);
        _attach(module);
        _approve(MINER, ALICE);
        _deposit(ALICE, 1_000e18);
        _assign(ALICE, MINER, 400e18);
        vm.warp(block.timestamp + COOLDOWN);
        uint256 bal = token.balanceOf(address(module));
        token.mint(BOB, 10e18);
        vm.prank(BOB);
        token.approve(address(module), type(uint256).max);

        string[2] memory totals = ["totalStake()", "totalCommitted()"];
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

        // S8: the failsafe fires on a corrupted module (it moves no funds and
        // reads no balance), but exits stay blocked by the solvency check
        // and new stake is refused by the failsafe itself.
        stdstore.target(address(module)).sig("totalStake()").checked_write(bal + 1);
        vm.prank(GUARDIAN);
        module.disableRequirement();
        assertTrue(module.gateDisabled());
        assertEq(token.balanceOf(address(module)), bal);
        vm.prank(ALICE);
        vm.expectRevert(PrefundedMiningPower.Insolvency.selector);
        module.unassign(MINER, 400e18);
        vm.prank(ALICE);
        vm.expectRevert(PrefundedMiningPower.Insolvency.selector);
        module.withdraw(600e18);
        vm.prank(BOB);
        vm.expectRevert(PrefundedMiningPower.GateDisabled.selector);
        module.deposit(10e18);
        assertEq(token.balanceOf(address(module)), bal);
        assertEq(module.assignedBy(ALICE), 400e18);
        assertEq(module.unassignedOf(ALICE), 600e18);
        assertEq(token.balanceOf(ALICE), 0);
        stdstore.target(address(module)).sig("totalStake()").checked_write(uint256(1_000e18));

        // With honest totals every exit works again.
        _unassign(ALICE, MINER, 400e18);
        _withdraw(ALICE, 1_000e18);
        assertEq(token.balanceOf(ALICE), 1_000e18);
        _assertBooks();
    }

    // ------------------------------------------------------------------
    // S7: release under hostile tokens and corrupted totals
    // ------------------------------------------------------------------

    /// @dev The token contract itself is the final beneficiary of a burned,
    /// locked NFT and holds unassigned stake, so every re-entrant payload
    /// (msg.sender == token) would otherwise succeed. Each is fired from
    /// inside the claim transfer of another beneficiary's lock. ALICE backs
    /// the token contract's single win and FUNDER backs BOB's six; each
    /// backer's stake is exactly consumed by those locks.
    function testReentrantTokenCannotReenterClaim() public {
        PrefundedReentrantHunter re = new PrefundedReentrantHunter();
        PrefundedMiningPower m = _hostileModule(address(re));
        _detach();
        _attach(m);

        vm.prank(address(re));
        m.approveBacker(ALICE);
        vm.prank(BOB);
        m.approveBacker(FUNDER);
        re.mint(address(re), 1_000e18);
        vm.startPrank(address(re));
        re.approve(address(m), type(uint256).max);
        m.deposit(300e18);
        vm.stopPrank();
        re.mint(ALICE, LOCK);
        vm.startPrank(ALICE);
        re.approve(address(m), type(uint256).max);
        m.deposit(LOCK);
        m.assign(address(re), LOCK);
        vm.stopPrank();
        re.mint(FUNDER, 6 * LOCK);
        vm.startPrank(FUNDER);
        re.approve(address(m), type(uint256).max);
        m.deposit(6 * LOCK);
        m.assign(BOB, 6 * LOCK);
        vm.stopPrank();
        _nextChallenge();

        uint256 own = _win(address(re));
        uint256[6] memory ids;
        for (uint256 i = 0; i < ids.length; i++) {
            ids[i] = _win(BOB);
        }
        _burn(own);
        for (uint256 i = 0; i < ids.length; i++) {
            _burn(ids[i]);
        }
        assertEq(m.totalCommitted(), 7 * LOCK);
        assertEq(m.totalAssigned(), 0);

        bytes[6] memory payloads = [
            abi.encodeCall(PrefundedMiningPower.claimCommitted, (own)),
            abi.encodeCall(PrefundedMiningPower.claimCommittedTo, (own, address(re))),
            abi.encodeCall(PrefundedMiningPower.withdraw, (1)),
            abi.encodeCall(PrefundedMiningPower.assign, (MINER, 1)),
            abi.encodeCall(PrefundedMiningPower.unassign, (MINER, 1)),
            abi.encodeCall(PrefundedMiningPower.deposit, (1))
        ];
        bytes4 guardErr = ReentrancyGuard.ReentrancyGuardReentrantCall.selector;
        for (uint256 i = 0; i < payloads.length; i++) {
            re.configure(address(m), payloads[i]);
            vm.prank(BOB);
            m.claimCommitted(ids[i]);
            _assertReentryBlocked(re, guardErr);
            // Only the outer claim took effect.
            assertEq(re.balanceOf(BOB), (i + 1) * LOCK);
            assertEq(m.totalCommitted(), (6 - i) * LOCK);
            (,,,,, bool ownReleased) = m.committedOf(own);
            assertFalse(ownReleased);
            assertEq(m.unassignedOf(address(re)), 300e18);
            assertEq(m.assignedOf(MINER), 0);
            assertEq(m.totalStake(), 300e18);
            assertEq(re.balanceOf(address(m)), 300e18 + (6 - i) * LOCK);
        }

        // Without a payload the token contract claims its own lock normally.
        re.configure(address(m), "");
        uint256 before = re.balanceOf(address(re));
        vm.prank(address(re));
        m.claimCommitted(own);
        assertEq(re.balanceOf(address(re)), before + LOCK);
        assertEq(m.totalCommitted(), 0);
        assertEq(re.balanceOf(address(m)), 300e18);
    }

    /// @dev Any total bumped past the balance blocks the claim (Insolvency)
    /// and leaves the lock claimable; honest totals let it pay.
    function testCorruptedTotalCommittedBlocksClaim() public {
        _approve(MINER, ALICE);
        _deposit(ALICE, 1_000e18);
        _assign(ALICE, MINER, LOCK + 5e18);
        _nextChallenge();
        uint256 id = _win(MINER);
        _burn(id);
        uint256 bal = token.balanceOf(address(module));
        assertEq(bal, 1_000e18);
        assertEq(module.totalCommitted(), LOCK);
        assertEq(module.totalStake(), 1_000e18 - LOCK);

        string[2] memory totals = ["totalCommitted()", "totalStake()"];
        uint256[2] memory originals = [LOCK, 1_000e18 - LOCK];
        for (uint256 i = 0; i < totals.length; i++) {
            stdstore.target(address(module)).sig(totals[i]).checked_write(originals[i] + 1);
            vm.prank(MINER);
            vm.expectRevert(PrefundedMiningPower.Insolvency.selector);
            module.claimCommitted(id);
            vm.prank(MINER);
            vm.expectRevert(PrefundedMiningPower.Insolvency.selector);
            module.claimCommittedTo(id, BOB);
            (,,,,, bool released) = module.committedOf(id);
            assertFalse(released);
            assertEq(token.balanceOf(address(module)), bal);
            assertEq(token.balanceOf(MINER), 0);
            assertEq(token.balanceOf(BOB), 0);
            stdstore.target(address(module)).sig(totals[i]).checked_write(originals[i]);
        }

        _claim(id, MINER);
        assertEq(token.balanceOf(MINER), LOCK);
        assertEq(module.totalCommitted(), 0);
        _assertBooks();
    }

    /// @dev An outbound debit that differs from the lock in either direction
    /// reverts DebitMismatch and leaves the lock claimable.
    function testClaimDebitMismatchReverts() public {
        PrefundedMisDebitHunter bad = new PrefundedMisDebitHunter();
        PrefundedMiningPower m = _hostileModule(address(bad));
        _detach();
        _attach(m);
        vm.prank(MINER);
        m.approveBacker(ALICE);
        bad.mint(ALICE, LOCK);
        vm.startPrank(ALICE);
        bad.approve(address(m), LOCK);
        m.deposit(LOCK);
        m.assign(MINER, LOCK);
        vm.stopPrank();
        _nextChallenge();
        uint256 id = _win(MINER);
        _burn(id);
        // Surplus so an over-debit is not also an insolvency.
        bad.mint(address(m), 10);

        for (uint256 mode = 1; mode <= 2; mode++) {
            bad.configure(address(m), mode);
            vm.prank(MINER);
            vm.expectRevert(PrefundedMiningPower.DebitMismatch.selector);
            m.claimCommitted(id);
            (,,,,, bool released) = m.committedOf(id);
            assertFalse(released);
            assertEq(m.totalCommitted(), LOCK);
            assertEq(m.totalStake(), 0);
            assertEq(bad.balanceOf(address(m)), LOCK + 10);
            assertEq(bad.balanceOf(MINER), 0);
        }
        bad.configure(address(m), 0);
        vm.prank(MINER);
        m.claimCommitted(id);
        assertEq(bad.balanceOf(MINER), LOCK);
        assertEq(m.totalCommitted(), 0);
        assertEq(bad.balanceOf(address(m)), 10);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _hostileModule(address hunter) private returns (PrefundedMiningPower) {
        return new PrefundedMiningPower(hunter, address(core), LOCK, LOCK, COOLDOWN, 0, address(0));
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
