// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HunterNFT} from "../src/bloom/HunterNFT.sol";
import {HunterBackingVault} from "../src/bloom/HunterBackingVault.sol";
import {HunterLifecycle} from "../src/bloom/HunterLifecycle.sol";
import {HunterReserveVault} from "../src/bloom/HunterReserveVault.sol";
import {WeightedRoundLedger} from "../src/bloom/WeightedRoundLedger.sol";
import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";
import {MaterialisationHarness} from "./WeightedRoundMaterialisationCore.t.sol";

/// @dev Test-only token/NFT owner that attacks during its reserve payout.
contract OutboundCallbackToken is ERC20 {
    HunterReserveVault public reserve;
    HunterNFT public nft;
    uint256 public liveId;
    bool public armed;
    bool public propagate;
    uint256 public callbackCount;
    bytes4[4] public errors;
    bool[4] public succeeded;

    constructor() ERC20("Callback HUNTER", "CBH") {}

    function configure(HunterReserveVault reserve_, HunterNFT nft_, uint256 liveId_, bool armed_, bool propagate_)
        external
    {
        reserve = reserve_;
        nft = nft_;
        liveId = liveId_;
        armed = armed_;
        propagate = propagate_;
    }

    function seedAndDeposit(uint256 id, uint256 amount) external {
        _mint(address(this), amount);
        _approve(address(this), address(reserve), amount);
        reserve.deposit(id, amount);
    }

    function burn(uint256 id) external {
        nft.redeemAndDestroy(id);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        bool result = super.transfer(to, value);
        if (armed && msg.sender == address(reserve)) {
            callbackCount++;
            _attempt(0, address(reserve), abi.encodeCall(reserve.deposit, (liveId, 1)));
            _attempt(1, address(reserve), abi.encodeCall(reserve.settleBurn, (liveId, address(this))));
            _attempt(2, address(nft), abi.encodeCall(nft.transferFrom, (address(this), address(0xB0B), liveId)));
            _attempt(3, address(nft), abi.encodeCall(nft.approve, (address(0xB0B), liveId)));
        }
        return result;
    }

    function _attempt(uint256 index, address target, bytes memory callData) private {
        (bool ok, bytes memory reason) = target.call(callData);
        succeeded[index] = ok;
        if (reason.length >= 4) errors[index] = bytes4(reason);
        if (propagate && !ok) {
            assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
        }
    }
}

/// @dev Test-only basket token and authorized funder; attacks its same custody.
contract FundingMaterialiseCallbackToken is ERC20 {
    MaterialisationHarness public custody;
    uint256 public tokenId;
    bool public armed;
    bool public succeeded;
    bytes4 public error;

    constructor() ERC20("Callback basket", "CBB") {}

    function configure(MaterialisationHarness custody_, uint256 id) external {
        custody = custody_;
        tokenId = id;
    }

    function beginFund() external {
        _mint(address(this), 100);
        _approve(address(this), address(custody), 100);
        armed = true;
        custody.fund(1, address(this), 100);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        bool result = super.transferFrom(from, to, amount);
        if (armed) {
            armed = false;
            (bool ok, bytes memory reason) = address(custody).call(abi.encodeCall(custody.materialise, (1, tokenId)));
            succeeded = ok;
            if (reason.length >= 4) error = bytes4(reason);
        }
        return result;
    }
}

contract HunterSecurityCallbackTest is LifecycleTestBase {
    bytes4 private constant REENTRANT = bytes4(keccak256("ReentrancyGuardReentrantCall()"));

    function _outboundSetup() private returns (OutboundCallbackToken asset, uint256 burnedId, uint256 liveId) {
        asset = new OutboundCallbackToken();
        uint64 n = vm.getNonce(address(this));
        address wantNft = vm.computeCreateAddress(address(this), n + 4);
        address wantReserve = vm.computeCreateAddress(address(this), n + 3);
        address wantBacking = vm.computeCreateAddress(address(this), n + 2);
        lc = new HunterLifecycle(
            wantNft, wantReserve, wantBacking, [uint64(100), uint64(110), uint64(125), uint64(150)]
        );
        canonicalLedger = new WeightedRoundLedger(address(lc), address(this), 7, 10);
        canonicalBacking = new HunterBackingVault(address(canonicalLedger), address(this));
        vault = new HunterReserveVault(wantNft, address(lc), address(this));
        nft = new HunterNFT(address(registry), address(lc), 1, ROYALTIES, "");
        vault.activateToken(address(asset)); // this test contract is the launch authority
        burnedId = _mint(address(asset), 1, basketA);
        liveId = _mint(address(asset), 1, basketA);
        asset.configure(vault, nft, liveId, false, false);
        asset.seedAndDeposit(burnedId, 100);
    }

    function testOutboundCallbackGuardsAcrossRealBurnAndSinglePayout() public {
        (OutboundCallbackToken asset, uint256 id, uint256 other) = _outboundSetup();
        asset.configure(vault, nft, other, true, false);
        asset.burn(id);
        assertEq(asset.callbackCount(), 1);
        for (uint256 i; i < 4; ++i) {
            assertFalse(asset.succeeded(i));
            assertEq(asset.errors(i), i < 2 ? REENTRANT : HunterNFT.LifecycleReentry.selector);
        }
        assertEq(asset.balanceOf(address(asset)), 100);
        assertEq(asset.balanceOf(address(vault)), 0);
        assertEq(vault.totalReserved(), 0);
        assertTrue(vault.settled(id));
        assertEq(lc.finalBeneficiary(id), address(asset));
        assertFalse(lc.currentMember(id).alive);
        assertEq(nft.ownerOf(other), address(asset));
        assertEq(nft.getApproved(other), address(0));
        vm.expectRevert();
        asset.burn(id);
        assertEq(asset.balanceOf(address(asset)), 100);
    }

    function testPropagatedOutboundCallbackRollsBackEntireBurnAndRetries() public {
        (OutboundCallbackToken asset, uint256 id, uint256 other) = _outboundSetup();
        uint256 nonce = nft.authorizationNonce(id);
        asset.configure(vault, nft, other, true, true);
        vm.expectRevert(REENTRANT);
        asset.burn(id);
        assertEq(asset.callbackCount(), 0);
        assertEq(asset.balanceOf(address(asset)), 0);
        assertEq(asset.balanceOf(address(vault)), 100);
        assertEq(vault.reserveOf(id), 100);
        assertEq(vault.totalReserved(), 100);
        assertFalse(vault.settled(id));
        assertEq(nft.ownerOf(id), address(asset));
        assertEq(nft.authorizationNonce(id), nonce);
        assertEq(lc.finalBeneficiary(id), address(0));
        assertTrue(lc.currentMember(id).alive);
        assertEq(lc.currentMember(id).hunter, 100);
        asset.configure(vault, nft, other, false, false);
        asset.burn(id);
        assertEq(asset.balanceOf(address(asset)), 100);
        assertTrue(vault.settled(id));
    }

    function testFundCallbackCannotMaterialiseThroughInheritedSharedGuard() public {
        FundingMaterialiseCallbackToken asset = new FundingMaterialiseCallbackToken();
        registry.admitBasket(address(asset), keccak256("callback-basket"));
        vm.warp(86_399);
        uint256 id = _mint(ALICE, 1, address(asset));
        vm.warp(86_400);
        WeightedRoundLedger ledger = new WeightedRoundLedger(address(lc), address(this), 7, 10);
        ledger.recordRound(1, keccak256("callback-receipt"), 200);
        ledger.freezeGroup(1, address(asset));
        MaterialisationHarness custody = new MaterialisationHarness(address(ledger), address(asset));
        asset.configure(custody, id);
        asset.beginFund();
        assertFalse(asset.succeeded());
        assertEq(asset.error(), REENTRANT);
        assertEq(custody.totalReceived(address(asset)), 100);
        assertEq(asset.balanceOf(address(custody)), 100);
        assertFalse(custody.consumed(1, id));
        assertEq(custody.backingOf(id), 0);
        custody.materialise(1, id);
        assertTrue(custody.consumed(1, id));
        assertEq(custody.backingOf(id), 100);
    }
}
