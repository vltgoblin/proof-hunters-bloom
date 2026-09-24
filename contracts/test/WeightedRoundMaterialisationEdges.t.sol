// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {WeightedRoundMaterialisation} from "../src/bloom/WeightedRoundMaterialisation.sol";
import {WeightedRoundFunding} from "../src/bloom/WeightedRoundFunding.sol";

/// @dev Concrete harness: the abstract materialisation needs a derived contract.
contract MatHarness is WeightedRoundMaterialisation {
    constructor(address ledger_, address funder_) WeightedRoundMaterialisation(ledger_, funder_) {}
}

/// @dev Mock ledger exposing only what the materialisation constructor reads.
contract MatMockLedger {
    address private _lc;

    constructor(address lc_) {
        _lc = lc_;
    }

    function lifecycle() external view returns (address) {
        return _lc;
    }
}

/// @dev Mock lifecycle exposing only `nft()`/`reserve()`.
contract MatMockLifecycle {
    address public nftAddr;
    address public reserveAddr = address(0xBEEF);

    function setNft(address a) external {
        nftAddr = a;
    }

    function nft() external view returns (address) {
        return nftAddr;
    }

    function reserve() external view returns (address) {
        return reserveAddr;
    }
}

/// @dev Mock NFT with a controllable LIFECYCLE backpointer.
contract MatMockNft {
    address public immutable bound;

    constructor(address bound_) {
        bound = bound_;
    }

    function LIFECYCLE() external view returns (address) {
        return bound;
    }
}

/// @dev NFT-shaped contract without any LIFECYCLE getter.
contract MatBareNft {}

/// @notice VLT-38 Stage 2: WeightedRoundMaterialisation constructor
/// configuration guards and the `_custodyWired` deployment checks.
contract WeightedRoundMaterialisationEdgesTest is Test {
    address private constant FUNDER = address(0xF00D);

    function _mocked(address nftAddr) internal returns (MatMockLedger led, MatMockLifecycle lc) {
        lc = new MatMockLifecycle();
        lc.setNft(nftAddr);
        led = new MatMockLedger(address(lc));
    }

    function testConstructorRejectsZeroDerivedNft() public {
        (MatMockLedger led,) = _mocked(address(0));
        vm.expectRevert(WeightedRoundFunding.InvalidConfiguration.selector);
        new MatHarness(address(led), FUNDER);
    }

    function testConstructorRejectsNftBoundToFunder() public {
        (MatMockLedger led,) = _mocked(FUNDER);
        vm.expectRevert(WeightedRoundFunding.InvalidConfiguration.selector);
        new MatHarness(address(led), FUNDER);
    }

    function testConstructorRejectsNftBoundToLedger() public {
        MatMockLifecycle lc = new MatMockLifecycle();
        MatMockLedger led = new MatMockLedger(address(lc));
        lc.setNft(address(led));
        vm.expectRevert(WeightedRoundFunding.InvalidConfiguration.selector);
        new MatHarness(address(led), FUNDER);
    }

    function testConstructorRejectsLifecycleBoundToFunder() public {
        MatMockLifecycle lc = new MatMockLifecycle();
        lc.setNft(address(new MatMockNft(address(0))));
        MatMockLedger led = new MatMockLedger(address(lc));
        vm.expectRevert(WeightedRoundFunding.InvalidConfiguration.selector);
        new MatHarness(address(led), address(lc));
    }

    function testConstructorRejectsNftBoundToSelf() public {
        MatMockLifecycle lc = new MatMockLifecycle();
        MatMockLedger led = new MatMockLedger(address(lc));
        lc.setNft(vm.computeCreateAddress(address(this), vm.getNonce(address(this))));
        vm.expectRevert(WeightedRoundFunding.InvalidConfiguration.selector);
        new MatHarness(address(led), FUNDER);
    }

    function testMaterialiseRejectsUndeployedNft() public {
        (MatMockLedger led, MatMockLifecycle lc) = _mocked(address(0));
        lc.setNft(vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 64));
        MatHarness m = new MatHarness(address(led), FUNDER);
        vm.expectRevert(WeightedRoundMaterialisation.WiringMismatch.selector);
        m.materialise(1, 1);
    }

    function testMaterialiseRejectsMisboundNftBackpointer() public {
        (MatMockLedger led, MatMockLifecycle lc) = _mocked(address(0));
        lc.setNft(address(new MatMockNft(address(0xDEAD))));
        MatHarness m = new MatHarness(address(led), FUNDER);
        vm.expectRevert(WeightedRoundMaterialisation.WiringMismatch.selector);
        m.materialise(1, 1);
    }

    function testMaterialiseRejectsNftWithoutBackpointer() public {
        (MatMockLedger led, MatMockLifecycle lc) = _mocked(address(0));
        lc.setNft(address(new MatBareNft()));
        MatHarness m = new MatHarness(address(led), FUNDER);
        vm.expectRevert(WeightedRoundMaterialisation.WiringMismatch.selector);
        m.materialise(1, 1);
    }
}
