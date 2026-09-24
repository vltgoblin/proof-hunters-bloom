// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BasketRegistry} from "../src/bloom/BasketRegistry.sol";

contract RegistryBasketFixture is ERC20 {
    constructor() ERC20("Basket", "BASKET") {}
}

/// @dev Models an authorized contract wallet executing registry calls.
/// This fixture does not implement or claim to test multisig signatures.
contract RegistryAdminWalletFixture {
    BasketRegistry private immutable _registry;

    constructor(BasketRegistry registry) {
        _registry = registry;
    }

    function accept() external {
        _registry.acceptOwnership();
    }

    function admit(address asset, bytes32 reviewHash) external {
        _registry.admitBasket(asset, reviewHash);
    }

    function disable(address asset) external {
        _registry.setEntryEnabled(asset, false);
    }
}

contract BasketRegistryTest is Test {
    BasketRegistry private registry;
    address private asset;
    address private outsider = address(0xBAD);
    bytes32 private constant REVIEW = keccak256("published basket review v1");

    event BasketAdmitted(address indexed asset, uint256 chainId, bytes32 codeHash, bytes32 indexed reviewHash);
    event BasketEntryStatusChanged(address indexed asset, bool enabled);
    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    function setUp() public {
        registry = new BasketRegistry(address(this));
        asset = address(new RegistryBasketFixture());
    }

    function testAdmissionRecordsIdentityAndEmitsEvents() public {
        vm.expectEmit(true, true, false, true, address(registry));
        emit BasketAdmitted(asset, block.chainid, asset.codehash, REVIEW);
        vm.expectEmit(true, false, false, true, address(registry));
        emit BasketEntryStatusChanged(asset, true);
        registry.admitBasket(asset, REVIEW);
        _assertIdentity(asset, REVIEW);
        assertTrue(registry.isEntryEnabled(asset));
        assertTrue(registry.basket(asset).entryEnabled);
    }

    function testRejectsZeroAdmin() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new BasketRegistry(address(0));
    }

    function testRejectsRegistryAsInitialAdmin() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, predicted));
        new BasketRegistry(predicted);
    }

    function testRepeatedEntryStatusDoesNotEmitChange() public {
        registry.admitBasket(asset, REVIEW);
        vm.recordLogs();
        registry.setEntryEnabled(asset, true);
        assertEq(vm.getRecordedLogs().length, 0);
        registry.setEntryEnabled(asset, false);
        assertFalse(registry.basket(asset).entryEnabled);
        vm.recordLogs();
        registry.setEntryEnabled(asset, false);
        assertEq(vm.getRecordedLogs().length, 0);
    }

    function testCannotReplaceEnabledRecord() public {
        registry.admitBasket(asset, REVIEW);
        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.AlreadyAdmitted.selector, asset));
        registry.admitBasket(asset, keccak256("replacement"));
        _assertIdentity(asset, REVIEW);
        assertTrue(registry.isEntryEnabled(asset));
    }

    function testCurrentOwnerNominationUsesStandardTwoStepSemantics() public {
        registry.transferOwnership(outsider);
        registry.transferOwnership(address(this));
        _assertCannotAccept(outsider);
        registry.acceptOwnership();
        assertEq(registry.owner(), address(this));
        assertEq(registry.pendingOwner(), address(0));
    }

    function testRejectsInvalidAssets() public {
        address[3] memory invalid = [address(0), outsider, address(registry)];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(BasketRegistry.InvalidBasket.selector, invalid[i]));
            registry.admitBasket(invalid[i], REVIEW);
        }
    }

    function testRejectsEmptyReview() public {
        vm.expectRevert(BasketRegistry.EmptyReview.selector);
        registry.admitBasket(asset, bytes32(0));
        assertFalse(registry.isEntryEnabled(asset));
    }

    function testCannotReplaceDisabledRecord() public {
        registry.admitBasket(asset, REVIEW);
        registry.setEntryEnabled(asset, false);
        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.AlreadyAdmitted.selector, asset));
        registry.admitBasket(asset, keccak256("replacement"));
        _assertIdentity(asset, REVIEW);
        assertFalse(registry.isEntryEnabled(asset));
    }

    function testUnknownAssetReadAndStatusFail() public {
        assertFalse(registry.isEntryEnabled(asset));
        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.UnknownBasket.selector, asset));
        registry.basket(asset);
        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.UnknownBasket.selector, asset));
        registry.setEntryEnabled(asset, true);
    }

    function testDisableKeepsRecordAndEmitsStatus() public {
        registry.admitBasket(asset, REVIEW);
        vm.expectEmit(true, false, false, true, address(registry));
        emit BasketEntryStatusChanged(asset, false);
        registry.setEntryEnabled(asset, false);
        assertFalse(registry.isEntryEnabled(asset));
        _assertIdentity(asset, REVIEW);
        registry.setEntryEnabled(asset, true);
        assertTrue(registry.isEntryEnabled(asset));
        _assertIdentity(asset, REVIEW);
    }

    function testAddBasketLaterDoesNotChangeExistingBasket() public {
        registry.admitBasket(asset, REVIEW);
        bytes32 beforeHash = keccak256(abi.encode(registry.basket(asset)));
        address laterAsset = address(new RegistryBasketFixture());
        vm.warp(block.timestamp + 365 days);
        registry.admitBasket(laterAsset, keccak256("later review"));
        assertTrue(registry.isEntryEnabled(laterAsset));
        assertEq(keccak256(abi.encode(registry.basket(asset))), beforeHash);
    }

    function testUnauthorizedWritesAllFail() public {
        registry.admitBasket(asset, REVIEW);
        _assertNoAdminPowers(outsider);
    }

    function testNominationDoesNotTransferPowersUntilAcceptance() public {
        registry.transferOwnership(outsider);
        assertEq(registry.owner(), address(this));
        assertEq(registry.pendingOwner(), outsider);
        _assertNoAdminPowers(outsider);
        registry.admitBasket(asset, REVIEW);
        vm.prank(outsider);
        registry.acceptOwnership();
        assertEq(registry.owner(), outsider);
        assertEq(registry.pendingOwner(), address(0));
        _assertNoAdminPowers(address(this));
    }

    function testOnlyPendingOwnerCanAccept() public {
        registry.transferOwnership(outsider);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        registry.acceptOwnership();
    }

    function testNominationCanBeCancelledOrReplaced() public {
        vm.expectEmit(true, true, false, true, address(registry));
        emit OwnershipTransferStarted(address(this), outsider);
        registry.transferOwnership(outsider);
        vm.expectEmit(true, true, false, true, address(registry));
        emit OwnershipTransferStarted(address(this), address(0));
        registry.transferOwnership(address(0));
        assertEq(registry.owner(), address(this));
        assertEq(registry.pendingOwner(), address(0));
        _assertCannotAccept(outsider);
        registry.transferOwnership(outsider);
        address successor = address(0x123);
        registry.transferOwnership(successor);
        _assertCannotAccept(outsider);
        vm.expectEmit(true, true, false, true, address(registry));
        emit OwnershipTransferred(address(this), successor);
        vm.prank(successor);
        registry.acceptOwnership();
        assertEq(registry.owner(), successor);
    }

    function testContractWalletCanAcceptAndManage() public {
        registry.admitBasket(asset, REVIEW);
        RegistryAdminWalletFixture wallet = new RegistryAdminWalletFixture(registry);
        registry.transferOwnership(address(wallet));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(wallet)));
        wallet.admit(asset, REVIEW);
        wallet.accept();
        _assertIdentity(asset, REVIEW);
        address laterAsset = address(new RegistryBasketFixture());
        wallet.admit(laterAsset, REVIEW);
        assertTrue(registry.isEntryEnabled(laterAsset));
        wallet.disable(asset);
        assertEq(registry.owner(), address(wallet));
        assertEq(registry.pendingOwner(), address(0));
        assertFalse(registry.isEntryEnabled(asset));
        _assertIdentity(asset, REVIEW);
        _assertNoAdminPowers(address(this));
    }

    function testCannotNominateRegistryOrRenounce() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(registry)));
        registry.transferOwnership(address(registry));
        vm.expectRevert(BasketRegistry.RenunciationDisabled.selector);
        registry.renounceOwnership();
        assertEq(registry.owner(), address(this));
    }

    function testFuzzEntryTogglesNeverRewriteIdentity(bytes32 review, uint8 changes) public {
        vm.assume(review != bytes32(0));
        registry.admitBasket(asset, review);
        for (uint256 i; i < changes; ++i) {
            bool enabled = i % 2 == 0;
            registry.setEntryEnabled(asset, enabled);
            _assertIdentity(asset, review);
            assertEq(registry.isEntryEnabled(asset), enabled);
            assertEq(registry.basket(asset).entryEnabled, enabled);
        }
    }

    function testAdmissionDoesNotCallUntrustedAsset() public {
        // Deliberately reverting runtime: admission observes code only. This also
        // proves that admission must not be advertised as ERC-20 verification.
        address hostile = address(0xBEEF);
        vm.etch(hostile, hex"60006000fd");
        registry.admitBasket(hostile, REVIEW);
        _assertIdentity(hostile, REVIEW);
    }

    function _assertIdentity(address token, bytes32 review) private view {
        BasketRegistry.Basket memory record = registry.basket(token);
        assertEq(record.chainId, block.chainid);
        assertEq(record.codeHashAtAdmission, token.codehash);
        assertEq(record.reviewHash, review);
    }

    function _assertCannotAccept(address account) private {
        vm.prank(account);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, account));
        registry.acceptOwnership();
    }

    function _assertNoAdminPowers(address account) private {
        bytes memory reason = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, account);
        vm.startPrank(account);
        vm.expectRevert(reason);
        registry.admitBasket(asset, REVIEW);
        vm.expectRevert(reason);
        registry.setEntryEnabled(asset, false);
        vm.expectRevert(reason);
        registry.transferOwnership(account);
        vm.expectRevert(reason);
        registry.renounceOwnership();
        vm.stopPrank();
    }
}
