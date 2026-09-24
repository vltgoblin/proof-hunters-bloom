// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {WeightedRoundLedger} from "../src/bloom/WeightedRoundLedger.sol";
import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";

contract WeightedRoundLedgerReceiptsTest is LifecycleTestBase {
    /// @notice The recorder gate fires before every other check, days must be
    /// nonzero and started, receipts must be nonzero and unique across days,
    /// and a recorded round is never rewritable: receipt1 stays bound to day 1
    /// after a failed reuse, and receipt3 is unknown while day 1's frozen
    /// income/cutoff and day 2's receipt2 binding hold.
    function testRecorderDayAndReceiptGuards() public {
        bytes32 receipt1 = bytes32(uint256(1));
        bytes32 receipt2 = bytes32(uint256(2));
        bytes32 receipt3 = bytes32(uint256(3));

        vm.warp(86_399);
        _mint(ALICE, 1, basketA);
        WeightedRoundLedger ledger = new WeightedRoundLedger(address(lc), address(this), 7, 10);
        vm.warp(86_400);

        vm.prank(OP);
        vm.expectRevert(WeightedRoundLedger.UnauthorizedRecorder.selector);
        ledger.recordRound(1, receipt1, 2_000);

        vm.expectRevert(WeightedRoundLedger.InvalidDay.selector);
        ledger.recordRound(0, receipt1, 2_000);

        vm.expectRevert(abi.encodeWithSelector(WeightedRoundLedger.DayNotStarted.selector, uint32(2)));
        ledger.recordRound(2, receipt2, 2_000);

        vm.expectRevert(WeightedRoundLedger.InvalidReceipt.selector);
        ledger.recordRound(1, bytes32(0), 2_000);

        ledger.recordRound(1, receipt1, 2_000);

        vm.expectRevert(abi.encodeWithSelector(WeightedRoundLedger.RoundAlreadyRecorded.selector, uint32(1)));
        ledger.recordRound(1, receipt2, 2_000);

        vm.warp(172_800);
        vm.expectRevert(abi.encodeWithSelector(WeightedRoundLedger.ReceiptAlreadyUsed.selector, receipt1));
        ledger.recordRound(2, receipt1, 3_000);

        vm.expectRevert(abi.encodeWithSelector(WeightedRoundLedger.RoundNotRecorded.selector, uint32(2)));
        ledger.round(2);
        assertEq(ledger.receiptDay(receipt1), 1);

        ledger.recordRound(2, receipt2, 3_000);

        vm.expectRevert(abi.encodeWithSelector(WeightedRoundLedger.UnknownReceipt.selector, receipt3));
        ledger.receiptDay(receipt3);

        WeightedRoundLedger.Round memory r1 = ledger.round(1);
        assertEq(r1.assertedIncome, 2_000);
        assertEq(r1.cutoff, 86_400);
        assertEq(ledger.receiptDay(receipt2), 2);
    }
}
