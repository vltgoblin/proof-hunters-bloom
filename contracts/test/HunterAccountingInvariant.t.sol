// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";
import {HunterNFT} from "../src/bloom/HunterNFT.sol";
import {HunterReserveVault} from "../src/bloom/HunterReserveVault.sol";
import {HunterLifecycle} from "../src/bloom/HunterLifecycle.sol";
import {WeightedHistory} from "../src/bloom/libraries/WeightedHistory.sol";
import {ReserveTokenFixture} from "./helpers/HunterReserveFixtures.sol";

/// @dev TEST ONLY. Valid-action handler with an independent input-based model.
/// No catches: unexpected protocol reverts must fail the invariant campaign.
/// Pranks represent the actual owner/minter; no production storage is overwritten.
contract HunterAccountingHandler is Test {
    HunterNFT public immutable nft;
    HunterReserveVault public immutable vault;
    ReserveTokenFixture public immutable token;
    address public immutable basketA;
    address public immutable basketB;
    uint256 public constant MAX_MODELED_MINTS = 64;
    uint256 public minted;
    uint256 public received;
    uint256 public released;
    uint256 public donations;
    uint256 public calls;
    uint256 public deposits;
    uint256 public transfers;
    uint256 public burns;
    mapping(uint256 => address) public owner;
    mapping(uint256 => address) public beneficiary;
    mapping(uint256 => address) public basket;
    mapping(uint256 => uint64) public rarity;
    mapping(uint256 => uint256) public reserve;

    constructor(HunterNFT n, HunterReserveVault v, ReserveTokenFixture t, address a, address b) {
        nft = n;
        vault = v;
        token = t;
        basketA = a;
        basketB = b;
    }

    function mint(uint256 seed) public {
        ++calls;
        if (minted == MAX_MODELED_MINTS) return;
        address who = _actor(seed);
        uint8 tier = uint8((seed / 4) % 4 + 1);
        address asset = seed % 2 == 0 ? basketA : basketB;
        uint256 expected = minted + 1;
        vm.prank(nft.MINER());
        uint256 id = nft.mint(who, bytes32(seed), expected, tier, asset);
        assertEq(id, expected, "lifetime id reuse");
        minted = expected;
        owner[id] = who;
        basket[id] = asset;
        // Test configuration values, independent of lifecycle getters.
        rarity[id] = tier == 1 ? 100 : tier == 2 ? 110 : tier == 3 ? 125 : 150;
    }

    function deposit(uint256 seed, uint256 amountSeed, uint256 taxSeed) public {
        ++calls;
        uint256 id = _live(seed);
        if (id == 0) return;
        uint256 amount = bound(amountSeed, 1, 1e24);
        uint256 tax = taxSeed % 5_001;
        uint256 net = amount - amount * tax / 10_000;
        token.setBehavior(tax, false, false, false);
        token.mint(owner[id], amount);
        vm.startPrank(owner[id]);
        token.approve(address(vault), amount);
        assertEq(vault.deposit(id, amount), net, "receipt differs from input model");
        vm.stopPrank();
        reserve[id] += net;
        received += net;
        ++deposits;
    }

    function donate(uint256 seed) public {
        ++calls;
        uint256 amount = bound(seed, 1, 1e24);
        // Unsolicited issuance has no transfer tax in this adversarial fixture.
        token.mint(address(vault), amount);
        donations += amount;
    }

    function transfer(uint256 seed, uint256 recipientSeed) public {
        ++calls;
        uint256 id = _live(seed);
        if (id == 0) return;
        address to = _actor(recipientSeed);
        vm.prank(owner[id]);
        nft.transferFrom(owner[id], to, id);
        owner[id] = to;
        ++transfers;
    }

    function burn(uint256 seed) public {
        ++calls;
        uint256 id = _live(seed);
        if (id == 0) return;
        address who = owner[id];
        uint256 beforeBalance = token.balanceOf(who);
        vm.prank(who);
        nft.redeemAndDestroy(id);
        assertEq(token.balanceOf(who) - beforeBalance, reserve[id], "wrong burn recipient or amount");
        released += reserve[id];
        reserve[id] = 0;
        beneficiary[id] = who;
        owner[id] = address(0);
        ++burns;
    }

    function advanceTime(uint256 seed) public {
        ++calls;
        // Includes same-timestamp actions and crossing daily boundaries.
        vm.warp(block.timestamp + seed % 172_801);
    }

    function _live(uint256 seed) private view returns (uint256) {
        if (minted == 0) return 0;
        uint256 start = seed % minted;
        for (uint256 i; i < minted; ++i) {
            uint256 id = (start + i) % minted + 1;
            if (owner[id] != address(0)) return id;
        }
        return 0;
    }

    function _actor(uint256 seed) private pure returns (address) {
        return address(uint160(0x10000 + seed % 4));
    }
}

/// @notice Stateful conservation over REAL NFT/lifecycle/reserve contracts.
/// Does NOT cover basket payout, switching, lending or actual deployed tokens.
/// The bounded cohort proves no ID reuse in explored sequences, not exhaustion
/// of the full 5000 cap (covered by the separate NFT boundary tests).
contract HunterAccountingInvariantTest is StdInvariant, LifecycleTestBase {
    HunterAccountingHandler internal handler;
    uint256 internal bootstrapCalls;

    function setUp() public override {
        super.setUp();
        handler = new HunterAccountingHandler(nft, vault, token, basketA, basketB);
        // Deterministic non-empty state exercises every money-moving action.
        // Campaign call count separately proves randomized dispatch occurred.
        handler.mint(0);
        handler.mint(15);
        handler.deposit(0, 100, 1_000);
        handler.donate(50);
        handler.transfer(0, 1);
        handler.burn(0);
        handler.deposit(0, 200, 500);
        bootstrapCalls = handler.calls();
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.mint.selector;
        selectors[1] = handler.deposit.selector;
        selectors[2] = handler.donate.selector;
        selectors[3] = handler.transfer.selector;
        selectors[4] = handler.burn.selector;
        selectors[5] = handler.advanceTime.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_reserveConservation() public view {
        uint256 outstanding = handler.received() - handler.released();
        assertEq(vault.totalReserved(), outstanding);
        assertEq(token.balanceOf(address(vault)), outstanding + handler.donations());
        assertEq(vault.unreservedBalance(), handler.donations());
    }

    function invariant_membersAndGlobalTotalsMatchIndependentModel() public {
        uint256 sum;
        uint64 weights;
        uint32 count;
        for (uint256 id = 1; id <= handler.minted(); ++id) {
            bool alive = handler.owner(id) != address(0);
            uint256 amount = handler.reserve(id);
            WeightedHistory.Member memory m = lc.currentMember(id);
            assertEq(m.basket, handler.basket(id));
            assertEq(m.rarity, handler.rarity(id));
            assertEq(m.hunter, amount);
            assertEq(m.alive, alive);
            assertEq(m.eligible, alive);
            assertEq(vault.reserveOf(id), amount);
            assertEq(vault.settled(id), !alive);
            assertEq(lc.finalBeneficiary(id), handler.beneficiary(id));
            if (alive) {
                assertEq(nft.ownerOf(id), handler.owner(id));
                sum += amount;
                weights += handler.rarity(id);
                ++count;
            }
        }
        _assertTotalsEq(lc.currentGlobal(), weights, sum, count);
        assertEq(nft.mintedEver(), handler.minted());
        assertLe(nft.mintedEver(), nft.MAX_NFTS_EVER());
    }

    function invariant_basketsNeverMix() public {
        _checkBasket(basketA);
        _checkBasket(basketB);
    }

    function _checkBasket(address asset) private {
        uint256 sum;
        uint64 weights;
        uint32 count;
        for (uint256 id = 1; id <= handler.minted(); ++id) {
            if (handler.owner(id) != address(0) && handler.basket(id) == asset) {
                sum += handler.reserve(id);
                weights += handler.rarity(id);
                ++count;
            }
        }
        _assertTotalsEq(lc.currentBasket(asset), weights, sum, count);
    }

    function afterInvariant() public view {
        assertGt(handler.calls(), bootstrapCalls, "randomized handler never ran");
        assertGt(handler.received(), 0);
        assertGt(handler.released(), 0);
        assertGt(handler.donations(), 0);
        assertGt(handler.deposits(), 0);
        assertGt(handler.transfers(), 0);
        assertGt(handler.burns(), 0);
    }
}
