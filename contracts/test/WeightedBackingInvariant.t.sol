// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";
import {MaterialisationHarness} from "./WeightedRoundMaterialisationCore.t.sol";
import {WeightedRoundMaterialisation} from "../src/bloom/WeightedRoundMaterialisation.sol";
import {WeightedRoundLedger} from "../src/bloom/WeightedRoundLedger.sol";
import {HunterNFT} from "../src/bloom/HunterNFT.sol";
import {ReserveTokenFixture} from "./helpers/HunterReserveFixtures.sol";

/// @dev TEST ONLY. Eight frozen daily cohorts, three NFTs, one basket asset.
/// Model shares use small exact integer arithmetic, never production math helpers.
contract WeightedBackingHandler is Test {
    HunterNFT public immutable nft;
    MaterialisationHarness public immutable backing;
    ReserveTokenFixture public immutable asset;
    address public immutable funder;
    uint256 public received;
    uint256 public donations;
    uint256 public calls;
    uint256 public materialisations;
    uint256 public replayChecks;
    uint256 public burns;
    uint256 public sales;
    mapping(uint32 => uint256) public roundReceived;
    mapping(uint32 => bool) public funded;
    mapping(uint32 => mapping(uint256 => bool)) public consumed;
    mapping(uint256 => uint256) public credited;
    mapping(uint256 => address) public owner;

    constructor(HunterNFT n, MaterialisationHarness b, ReserveTokenFixture a, address f, address initialOwner) {
        nft = n;
        backing = b;
        asset = a;
        funder = f;
        for (uint256 id = 1; id <= 3; ++id) {
            owner[id] = initialOwner;
        }
    }

    function fund(uint256 daySeed, uint256 amountSeed, uint256 taxSeed) public {
        ++calls;
        uint32 day = uint32(daySeed % 8 + 1);
        if (funded[day]) return;
        uint256 amount = bound(amountSeed, 1, 1e18);
        uint256 tax = taxSeed % 5_001;
        uint256 net = amount - amount * tax / 10_000;
        asset.setBehavior(tax, false, false, false);
        asset.mint(funder, amount);
        vm.startPrank(funder);
        asset.approve(address(backing), amount);
        backing.fund(day, address(asset), amount);
        vm.stopPrank();
        funded[day] = true;
        roundReceived[day] = net;
        received += net;
    }

    function donate(uint256 seed) public {
        ++calls;
        uint256 amount = bound(seed, 1, 1e18);
        asset.mint(address(backing), amount);
        donations += amount;
    }

    function materialise(uint256 daySeed, uint256 idSeed) public {
        ++calls;
        uint32 day = uint32(daySeed % 8 + 1);
        uint256 id = idSeed % 3 + 1;
        if (!funded[day] || owner[id] == address(0)) return;
        if (consumed[day][id]) {
            // An explicit expected error, not a swallowed arbitrary revert.
            vm.expectRevert(abi.encodeWithSelector(WeightedRoundMaterialisation.AlreadyConsumed.selector, day, id));
            backing.materialise(day, id);
            ++replayChecks;
            return;
        }
        backing.materialise(day, id);
        consumed[day][id] = true;
        credited[id] += share(day, id);
        ++materialisations;
    }

    function sell(uint256 idSeed, uint256 recipientSeed) public {
        ++calls;
        uint256 id = idSeed % 3 + 1;
        if (owner[id] == address(0)) return;
        address to = address(uint160(0x20000 + recipientSeed % 4));
        vm.prank(owner[id]);
        nft.transferFrom(owner[id], to, id);
        owner[id] = to;
        ++sales;
    }

    function burn(uint256 idSeed) public {
        ++calls;
        uint256 id = idSeed % 3 + 1;
        if (owner[id] == address(0)) return;
        vm.prank(owner[id]);
        nft.redeemAndDestroy(id);
        owner[id] = address(0);
        ++burns;
        // This abstract-custody fixture has NO payout hook. Both already
        // credited backing and unconsumed historical shares remain liabilities.
    }

    function share(uint32 day, uint256 id) public view returns (uint256) {
        uint256 rarity = id == 1 ? 100 : id == 2 ? 125 : 150;
        uint256 hunter = id == 1 ? 100 : id == 2 ? 200 : 0;
        // Fixed TEST scenario 70/30, totals R=375, H=300. One basket.
        // Floor only once, after combining both reward components.
        return roundReceived[day] * (7 * rarity * 300 + 3 * hunter * 375) / (10 * 375 * 300);
    }
}

/// @notice Tests accounting relabels in the existing abstract custody fixture,
/// NOT completed payout, basket switching, loan integration, or asset approval.
contract WeightedBackingInvariantTest is StdInvariant, LifecycleTestBase {
    WeightedRoundLedger internal ledger;
    MaterialisationHarness internal backing;
    WeightedBackingHandler internal handler;
    uint256 internal bootstrapCalls;

    function setUp() public override {
        super.setUp();
        vm.warp(86_399);
        _mint(ALICE, 1, basketA);
        _mint(ALICE, 3, basketA);
        _mint(ALICE, 4, basketA);
        vm.startPrank(ALICE);
        vault.deposit(1, 100);
        vault.deposit(2, 200);
        vm.stopPrank();
        ledger = new WeightedRoundLedger(address(lc), address(this), 7, 10);
        backing = new MaterialisationHarness(address(ledger), address(this));
        ReserveTokenFixture asset = ReserveTokenFixture(basketA);
        asset.setVault(address(backing));
        // All snapshots precede any randomized sale/burn. Funding order remains random.
        for (uint32 day = 1; day <= 8; ++day) {
            vm.warp(uint256(day) * 86_400);
            ledger.recordRound(day, bytes32(uint256(day)), 2_000);
            ledger.freezeGroup(day, basketA);
        }
        vm.warp(8 * 86_400 + 1);
        handler = new WeightedBackingHandler(nft, backing, asset, address(this), ALICE);
        handler.fund(0, 101, 1_000);
        handler.donate(50);
        handler.materialise(0, 0);
        handler.materialise(0, 0); // known replay must reject
        handler.sell(0, 2);
        handler.burn(0); // retain both credited and other-day historical rights
        bootstrapCalls = handler.calls();
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.fund.selector;
        selectors[1] = handler.donate.selector;
        selectors[2] = handler.materialise.selector;
        selectors[3] = handler.sell.selector;
        selectors[4] = handler.burn.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_custodyMatchesActualReceiptModel() public view {
        assertEq(backing.totalReceived(basketA), handler.received());
        assertEq(backing.totalReleased(basketA), 0);
        assertEq(ReserveTokenFixture(basketA).balanceOf(address(backing)), handler.received() + handler.donations());
        assertEq(backing.unaccountedBalance(basketA), handler.donations());
        assertEq(backing.totalReceived(basketB), 0);
    }

    function invariant_partitionAndFrozenSharesConserveEveryUnit() public view {
        uint256 unconsumed;
        uint256 dust;
        uint256 credited;
        for (uint32 day = 1; day <= 8; ++day) {
            assertEq(backing.isFunded(day, basketA), handler.funded(day));
            if (!handler.funded(day)) continue;
            assertEq(backing.funding(day, basketA).received, handler.roundReceived(day));
            uint256 allocated;
            for (uint256 id = 1; id <= 3; ++id) {
                uint256 expected = handler.share(day, id);
                (address asset, uint256 actual) = backing.memberReceivedShare(day, id);
                assertEq(asset, basketA);
                assertEq(actual, expected);
                assertEq(backing.consumed(day, id), handler.consumed(day, id));
                allocated += expected;
                if (!handler.consumed(day, id)) unconsumed += expected;
            }
            dust += handler.roundReceived(day) - allocated;
        }
        for (uint256 id = 1; id <= 3; ++id) {
            assertEq(backing.backingOf(id), handler.credited(id));
            credited += handler.credited(id);
        }
        assertEq(credited + unconsumed + dust, handler.received());
    }

    function afterInvariant() public view {
        assertGt(handler.calls(), bootstrapCalls, "randomized handler never ran");
        assertGt(handler.received(), 0);
        assertGt(handler.materialisations(), 0);
        assertGt(handler.replayChecks(), 0);
        assertGt(handler.sales(), 0);
        assertGt(handler.burns(), 0);
    }
}
