// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {WeightedRoundLedger} from "../src/bloom/WeightedRoundLedger.sol";
import {WeightedHistory} from "../src/bloom/libraries/WeightedHistory.sol";

/// @dev Mock lifecycle exposing only the reads the ledger makes. Snapshot
/// contents are settable so malformed member data can reach `memberSnapshot`.
contract LedgerMockLifecycle {
    address public nftAddr = address(0xBEEF);
    address public reserveAddr = address(0xCAFE);
    WeightedHistory.Totals public global;
    WeightedHistory.Totals public basket;
    WeightedHistory.Member public member;

    function setNft(address a) external {
        nftAddr = a;
    }

    function setReserve(address a) external {
        reserveAddr = a;
    }

    function setGlobal(uint64 rarity, uint256 hunter, uint32 count) external {
        global = WeightedHistory.Totals({rarity: rarity, hunter: hunter, count: count});
    }

    function setBasketTotals(uint64 rarity, uint256 hunter, uint32 count) external {
        basket = WeightedHistory.Totals({rarity: rarity, hunter: hunter, count: count});
    }

    function setMember(WeightedHistory.Member memory m) external {
        member = m;
    }

    function nft() external view returns (address) {
        return nftAddr;
    }

    function reserve() external view returns (address) {
        return reserveAddr;
    }

    function globalBefore(uint256) external view returns (WeightedHistory.Totals memory) {
        return global;
    }

    function basketBefore(address, uint256) external view returns (WeightedHistory.Totals memory) {
        return basket;
    }

    function memberBefore(uint256, uint256) external view returns (WeightedHistory.Member memory) {
        return member;
    }
}

/// @notice VLT-38 Stage 2: WeightedRoundLedger constructor guards, the
/// `freezeGroup`/`group` basket validations, and the member-snapshot
/// consistency check against malformed lifecycle data.
contract WeightedRoundLedgerEdgesTest is Test {
    LedgerMockLifecycle private lc;
    WeightedRoundLedger private ledger;

    function setUp() public {
        lc = new LedgerMockLifecycle();
        ledger = new WeightedRoundLedger(address(lc), address(this), 7, 10);
    }

    function testConstructorRejectsBadLifecyclePointers() public {
        LedgerMockLifecycle zero = new LedgerMockLifecycle();
        zero.setNft(address(0));
        vm.expectRevert(WeightedRoundLedger.InvalidConfiguration.selector);
        new WeightedRoundLedger(address(zero), address(this), 7, 10);

        LedgerMockLifecycle noRes = new LedgerMockLifecycle();
        noRes.setReserve(address(0));
        vm.expectRevert(WeightedRoundLedger.InvalidConfiguration.selector);
        new WeightedRoundLedger(address(noRes), address(this), 7, 10);

        LedgerMockLifecycle same = new LedgerMockLifecycle();
        same.setReserve(same.nftAddr());
        vm.expectRevert(WeightedRoundLedger.InvalidConfiguration.selector);
        new WeightedRoundLedger(address(same), address(this), 7, 10);
    }

    function testFreezeGroupRejectsZeroBasketAndGroupGetterGuards() public {
        vm.warp(86_400);
        lc.setGlobal(100, 1_000e18, 2);
        ledger.recordRound(1, bytes32(uint256(1)), 2_000);

        vm.expectRevert(WeightedRoundLedger.InvalidBasket.selector);
        ledger.freezeGroup(1, address(0));

        // A recorded day with no frozen group is not a defaulted record.
        vm.expectRevert(abi.encodeWithSelector(WeightedRoundLedger.GroupNotFrozen.selector, 1, address(0xBA5C)));
        ledger.group(1, address(0xBA5C));
        vm.expectRevert(WeightedRoundLedger.InvalidBasket.selector);
        ledger.group(1, address(0));
    }

    function testMemberSnapshotRejectsMalformedLifecycleData() public {
        vm.warp(86_400);
        lc.setGlobal(100, 1_000e18, 2);
        lc.setBasketTotals(60, 600e18, 1);
        ledger.recordRound(1, bytes32(uint256(1)), 2_000);
        ledger.freezeGroup(1, address(0xBA5C));

        // Eligible member whose basket reads zero is malformed.
        lc.setMember(
            WeightedHistory.Member({basket: address(0), rarity: 50, hunter: 100e18, alive: true, eligible: true})
        );
        vm.expectRevert(WeightedRoundLedger.InconsistentSnapshot.selector);
        ledger.memberSnapshot(1, 7);

        // Eligible member with zero rarity is malformed.
        lc.setMember(
            WeightedHistory.Member({basket: address(0xBA5C), rarity: 0, hunter: 100e18, alive: true, eligible: true})
        );
        vm.expectRevert(WeightedRoundLedger.InconsistentSnapshot.selector);
        ledger.memberSnapshot(1, 7);

        // Member rarity above the frozen global is malformed.
        lc.setMember(
            WeightedHistory.Member({basket: address(0xBA5C), rarity: 101, hunter: 100e18, alive: true, eligible: true})
        );
        vm.expectRevert(WeightedRoundLedger.InconsistentSnapshot.selector);
        ledger.memberSnapshot(1, 7);

        // Member HUNTER above the frozen global is malformed.
        lc.setMember(
            WeightedHistory.Member({basket: address(0xBA5C), rarity: 50, hunter: 1_001e18, alive: true, eligible: true})
        );
        vm.expectRevert(WeightedRoundLedger.InconsistentSnapshot.selector);
        ledger.memberSnapshot(1, 7);

        // A consistent member resolves normally.
        lc.setMember(
            WeightedHistory.Member({basket: address(0xBA5C), rarity: 50, hunter: 100e18, alive: true, eligible: true})
        );
        assertEq(ledger.memberSnapshot(1, 7).rarity, 50);
    }
}
