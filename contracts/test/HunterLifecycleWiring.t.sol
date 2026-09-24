// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {HunterLifecycle} from "../src/bloom/HunterLifecycle.sol";
import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";

contract HunterLifecycleWiringTest is LifecycleTestBase {
    /// @notice Constructor bounds: zero, aliased or self-referential module
    /// addresses revert, as does a zero weight or one above
    /// `type(uint64).max / 5000` (the representability bound for a full
    /// 5000-NFT cohort) in ANY tier slot. The highest representable weight
    /// constructs and reads back exactly; out-of-range tiers revert with the
    /// exact InvalidTier payload. The fixture weights 100/110/125/150 are
    /// not launch parameters — these cases use their own values.
    function testConstructorBoundsAndTierWeights() public {
        uint64[4] memory w = [uint64(1), uint64(2), uint64(3), uint64(4)];
        uint64 maxW = type(uint64).max / 5_000;

        vm.expectRevert(HunterLifecycle.InvalidConfiguration.selector);
        new HunterLifecycle(address(0), address(0xCAFE), address(0xBACC), w);
        vm.expectRevert(HunterLifecycle.InvalidConfiguration.selector);
        new HunterLifecycle(address(0xF00D), address(0), address(0xBACC), w);

        vm.expectRevert(HunterLifecycle.InvalidConfiguration.selector);
        new HunterLifecycle(address(0xF00D), address(0xF00D), address(0xBACC), w);

        // A module may never be the lifecycle's own address; the prediction
        // must be computed BEFORE the (reverting) deploy consumes the nonce.
        address self = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(HunterLifecycle.InvalidConfiguration.selector);
        new HunterLifecycle(self, address(0xCAFE), address(0xBACC), w);
        self = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(HunterLifecycle.InvalidConfiguration.selector);
        new HunterLifecycle(address(0xF00D), self, address(0xBACC), w);

        // Zero and just-over-the-bound weights rejected in every tier slot.
        for (uint256 i; i < 4; ++i) {
            uint64[4] memory bad = [uint64(1), uint64(2), uint64(3), uint64(4)];
            bad[i] = 0;
            for (uint256 j; j < 4; ++j) {
                if (j != i) assertEq(bad[j], w[j]);
            }
            vm.expectRevert(HunterLifecycle.InvalidConfiguration.selector);
            new HunterLifecycle(address(0xF00D), address(0xCAFE), address(0xBACC), bad);
            bad = [uint64(1), uint64(2), uint64(3), uint64(4)];
            bad[i] = maxW + 1;
            for (uint256 j; j < 4; ++j) {
                if (j != i) assertEq(bad[j], w[j]);
            }
            vm.expectRevert(HunterLifecycle.InvalidConfiguration.selector);
            new HunterLifecycle(address(0xF00D), address(0xCAFE), address(0xBACC), bad);
        }

        // Highest representable weight in every slot constructs cleanly.
        HunterLifecycle maxed =
            new HunterLifecycle(address(0xF00D), address(0xCAFE), address(0xBACC), [maxW, maxW, maxW, maxW]);
        assertEq(maxed.nft(), address(0xF00D));
        assertEq(maxed.reserve(), address(0xCAFE));
        assertEq(maxed.rarityWeight(1), maxW);
        assertEq(maxed.rarityWeight(2), maxW);
        assertEq(maxed.rarityWeight(3), maxW);
        assertEq(maxed.rarityWeight(4), maxW);

        // Out-of-range tiers revert with the exact InvalidTier payload.
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.InvalidTier.selector, uint8(0)));
        lc.rarityWeight(0);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.InvalidTier.selector, uint8(5)));
        lc.rarityWeight(5);
    }

    /// @notice The wiring guard revalidates the reciprocal pointers on every
    /// hook. Predicted, still-codeless module addresses may construct (the
    /// lifecycle -> reserve -> NFT build order requires it) but an
    /// authenticated onMint fails; so does a fresh lifecycle pointed at the
    /// real NFT/vault, whose reciprocal LIFECYCLE is the base lc. On the real
    /// triple, corrupting EACH reciprocal getter one at a time trips
    /// WiringMismatch on an NFT-pranked onMint before any duplicate-id logic
    /// (the id below is already a live member, so an unguarded path would
    /// otherwise reach IdAlreadyKnown). Test-only mock corruption; each mock
    /// is cleared before the next case.
    function testWiringMismatchOnUnwiredAlienAndCorruptedReciprocals() public {
        vm.warp(100);
        uint256 id = _mint(ALICE, 1, basketA);
        uint64[4] memory w = [uint64(1), uint64(2), uint64(3), uint64(4)];

        // Predicted distinct no-code addresses: construction is legal, the
        // authenticated mint hook is not.
        uint64 n = vm.getNonce(address(this));
        address ghostNft = vm.computeCreateAddress(address(this), n + 10);
        address ghostReserve = vm.computeCreateAddress(address(this), n + 11);
        HunterLifecycle pending = new HunterLifecycle(ghostNft, ghostReserve, address(0xBACC), w);
        assertEq(pending.nft(), ghostNft);
        assertEq(pending.reserve(), ghostReserve);
        vm.prank(ghostNft);
        vm.expectRevert(HunterLifecycle.WiringMismatch.selector);
        pending.onMint(id, ALICE, basketA);

        // Real module addresses, wrong reciprocal lifecycle: NFT.LIFECYCLE()
        // still names the base lc, not this alien deployment.
        HunterLifecycle alien = new HunterLifecycle(address(nft), address(vault), address(canonicalBacking), w);
        vm.prank(address(nft));
        vm.expectRevert(HunterLifecycle.WiringMismatch.selector);
        alien.onMint(id, ALICE, basketA);

        vm.mockCall(address(nft), abi.encodeWithSelector(bytes4(keccak256("LIFECYCLE()"))), abi.encode(address(0xDEAD)));
        vm.prank(address(nft));
        vm.expectRevert(HunterLifecycle.WiringMismatch.selector);
        lc.onMint(id, ALICE, basketA);
        vm.clearMockedCalls();

        vm.mockCall(address(vault), abi.encodeWithSelector(bytes4(keccak256("NFT()"))), abi.encode(address(0xDEAD)));
        vm.prank(address(nft));
        vm.expectRevert(HunterLifecycle.WiringMismatch.selector);
        lc.onMint(id, ALICE, basketA);
        vm.clearMockedCalls();

        vm.mockCall(
            address(vault), abi.encodeWithSelector(bytes4(keccak256("LIFECYCLE()"))), abi.encode(address(0xDEAD))
        );
        vm.prank(address(nft));
        vm.expectRevert(HunterLifecycle.WiringMismatch.selector);
        lc.onMint(id, ALICE, basketA);
        vm.clearMockedCalls();

        vm.mockCall(
            address(nft), abi.encodeWithSelector(bytes4(keccak256("MAX_NFTS_EVER()"))), abi.encode(uint256(4_999))
        );
        vm.prank(address(nft));
        vm.expectRevert(HunterLifecycle.WiringMismatch.selector);
        lc.onMint(id, ALICE, basketA);
        vm.clearMockedCalls();

        // Guard is clean again: the live member's wiring still validates.
        _assertMemberEq(lc.currentMember(id), basketA, 100, 0, true, true);
        assertEq(nft.ownerOf(id), ALICE);
    }
}
