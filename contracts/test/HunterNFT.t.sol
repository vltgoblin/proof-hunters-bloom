// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {HunterNFT, IHunterLifecycle} from "../src/bloom/HunterNFT.sol";
import {BasketRegistry} from "../src/bloom/BasketRegistry.sol";
import {LiveHunt} from "../src/LiveHunt.sol";
import {ILiveHuntNFT} from "../src/ILiveHuntNFT.sol";

contract HunterBasketFixture is ERC20 {
    constructor() ERC20("Test basket", "TB") {}
}

/// @dev Test-only callback observer. NOT a vault, loan verifier, or deployable controller.
contract HunterLifecycleFixture is IHunterLifecycle {
    address public immutable nft;
    bool public fail;
    bytes public reentry;
    bool public reentrySucceeded;
    uint256 public mintCalls;
    uint256 public transferCalls;
    uint256 public burnCalls;
    address public lastOwner;
    address public lastBasket;
    uint256 public lastToken;

    constructor(address expectedNFT) {
        nft = expectedNFT;
    }

    function setFail(bool value) external {
        fail = value;
    }

    function setReentry(bytes calldata data) external {
        reentry = data;
    }

    function onMint(uint256 tokenId, address owner, address basket) external {
        _hook();
        require(HunterNFT(nft).ownerOf(tokenId) == owner, "mint owner not visible");
        mintCalls++;
        lastToken = tokenId;
        lastOwner = owner;
        lastBasket = basket;
    }

    function onTransfer(uint256 tokenId, address, address to) external {
        _hook();
        require(HunterNFT(nft).ownerOf(tokenId) == to, "transfer owner not visible");
        transferCalls++;
        lastOwner = to;
    }

    function onBurn(uint256 tokenId, address beneficiary) external {
        _hook();
        (bool exists,) = nft.staticcall(abi.encodeWithSignature("ownerOf(uint256)", tokenId));
        require(!exists, "burn not visible");
        burnCalls++;
        lastToken = tokenId;
        lastOwner = beneficiary;
    }

    function open(uint256 id, address position, address borrower, uint256 nonce) external {
        HunterNFT(nft).lockCredit(id, position, borrower, nonce);
    }

    function close(uint256 id, address position, uint256 nonce) external {
        HunterNFT(nft).unlockCredit(id, position, nonce);
    }

    function _hook() private {
        require(msg.sender == nft, "NFT only");
        require(!fail, "hook failed");
        if (reentry.length != 0) (reentrySucceeded,) = nft.call(reentry);
    }
}

contract HunterEscrowFixture is IERC721Receiver {
    bytes public payload;
    bool public reject;
    address public forwardTo;

    function setForward(address to) external {
        forwardTo = to;
    }

    function setReject(bool value) external {
        reject = value;
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata data) external returns (bytes4) {
        require(!reject, "request failed");
        payload = data;
        if (forwardTo != address(0)) HunterNFT(msg.sender).transferFrom(address(this), forwardTo, tokenId);
        return IERC721Receiver.onERC721Received.selector;
    }

    function release(HunterNFT nft, uint256 tokenId, address to) external {
        nft.transferFrom(address(this), to, tokenId);
    }
}

/// @dev Hostile query implementation with a matching selector. NFT calls it via STATICCALL.
contract HunterStaticRegistryFixture {
    address private immutable _nft;

    constructor(address expectedNFT) {
        _nft = expectedNFT;
    }

    function isEntryEnabled(address) external returns (bool) {
        (bool changed,) =
            _nft.call{gas: 100_000}(abi.encodeWithSignature("setApprovalForAll(address,bool)", address(0x0F), true));
        return !changed;
    }
}

contract HunterNFTTest is Test {
    using stdStorage for StdStorage;
    event EscrowEntered(uint256 indexed tokenId, address indexed owner, address indexed holder);
    event EscrowReleased(uint256 indexed tokenId, address indexed holder, address indexed recipient);
    HunterNFT private nft;
    BasketRegistry private registry;
    HunterLifecycleFixture private lifecycle;
    HunterEscrowFixture private position;
    address private asset;
    address private constant ALICE = address(0xA11CE);
    address private constant BOB = address(0xB0B);
    address private constant OPERATOR = address(0x0F);
    address private constant ROYALTIES = address(0x123);

    function setUp() public {
        registry = new BasketRegistry(address(this));
        asset = address(new HunterBasketFixture());
        registry.admitBasket(asset, keccak256("review"));
        address expected = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        lifecycle = new HunterLifecycleFixture(expected);
        nft = new HunterNFT(address(registry), address(lifecycle), 1, ROYALTIES, "ipfs://hunters/");
        position = new HunterEscrowFixture();
    }

    function testMintSetsBasketBirthAndLifecycle() public {
        uint256 id = _mint(ALICE);
        assertEq(nft.ownerOf(id), ALICE);
        assertEq(nft.basketOf(id), asset);
        assertEq(nft.mintedEver(), 1);
        assertEq(nft.authorizationNonce(id), 1);
        assertEq(lifecycle.mintCalls(), 1);
        assertEq(lifecycle.lastBasket(), asset);
        (uint32 version, bytes32 digest, uint256 challenge, uint8 tier) = nft.birthData(id);
        assertEq(version, 1);
        assertEq(digest, bytes32(uint256(123)));
        assertEq(challenge, 7);
        assertEq(tier, 2);
        assertEq(nft.tokenURI(id), "ipfs://hunters/1");
        (bool hasReserve,) = address(nft).staticcall(abi.encodeWithSignature("PROJECT_TOKEN()"));
        assertFalse(hasReserve);
    }

    function testOnlyMinterAndValidTier() public {
        vm.prank(ALICE);
        vm.expectRevert(HunterNFT.UnauthorizedMinter.selector);
        nft.mint(ALICE, bytes32(0), 1, 1, asset);
        vm.expectRevert(HunterNFT.InvalidConfiguration.selector);
        nft.mint(ALICE, bytes32(0), 1, 0, asset);
        vm.expectRevert(HunterNFT.InvalidConfiguration.selector);
        nft.mint(ALICE, bytes32(0), 1, 5, asset);
        assertEq(nft.mintedEver(), 0);
    }

    function testUnknownAndDisabledBasketCannotMint() public {
        vm.expectRevert(abi.encodeWithSelector(HunterNFT.InvalidBasket.selector, BOB));
        nft.mint(ALICE, bytes32(0), 1, 1, BOB);
        registry.setEntryEnabled(asset, false);
        vm.expectRevert(abi.encodeWithSelector(HunterNFT.InvalidBasket.selector, asset));
        _mint(ALICE);
        assertEq(nft.mintedEver(), 0);
        assertEq(lifecycle.mintCalls(), 0);
    }

    function testLaterBasketDoesNotChangeExistingNFT() public {
        uint256 first = _mint(ALICE);
        address secondAsset = address(new HunterBasketFixture());
        registry.admitBasket(secondAsset, keccak256("review2"));
        uint256 second = nft.mint(ALICE, bytes32(0), 8, 1, secondAsset);
        assertEq(nft.basketOf(first), asset);
        assertEq(nft.basketOf(second), secondAsset);
    }

    function testTransferCarriesBasketAndCallsLifecycleEvenAfterDisable() public {
        uint256 id = _mint(ALICE);
        registry.setEntryEnabled(asset, false);
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, id);
        assertEq(nft.basketOf(id), asset);
        assertEq(lifecycle.lastOwner(), BOB);
        assertEq(lifecycle.transferCalls(), 1);
        assertEq(nft.authorizationNonce(id), 2);
        vm.prank(BOB);
        nft.redeemAndDestroy(id);
        assertEq(lifecycle.lastOwner(), BOB);
        assertEq(lifecycle.burnCalls(), 1);
        assertEq(nft.mintedEver(), 1);
        assertEq(nft.basketOf(id), asset);
    }

    function testRevertingMintHookRollsBackIdentityAndSupply() public {
        lifecycle.setFail(true);
        vm.expectRevert(bytes("hook failed"));
        _mint(ALICE);
        assertEq(nft.mintedEver(), 0);
        assertEq(nft.basketOf(1), address(0));
        assertEq(nft.balanceOf(ALICE), 0);
        assertEq(nft.authorizationNonce(1), 0);
        lifecycle.setFail(false);
        assertEq(_mint(ALICE), 1);
    }

    function testRevertingTransferAndBurnHooksRollBack() public {
        uint256 id = _mint(ALICE);
        vm.prank(ALICE);
        nft.approve(OPERATOR, id);
        lifecycle.setFail(true);
        vm.prank(OPERATOR);
        vm.expectRevert(bytes("hook failed"));
        nft.transferFrom(ALICE, BOB, id);
        assertEq(nft.ownerOf(id), ALICE);
        assertEq(nft.getApproved(id), OPERATOR);
        assertEq(nft.authorizationNonce(id), 1);
        vm.prank(ALICE);
        vm.expectRevert(bytes("hook failed"));
        nft.redeemAndDestroy(id);
        assertEq(nft.ownerOf(id), ALICE);
        assertEq(lifecycle.burnCalls(), 0);
    }

    function testEscrowPayloadAndReleasePreserveRights() public {
        uint256 id = _mint(ALICE);
        vm.prank(ALICE);
        nft.escrowTo(id, address(position), hex"123456");
        assertEq(position.payload(), hex"123456");
        assertEq(nft.ownerOf(id), address(position));
        assertEq(uint256(nft.custody(id)), uint256(HunterNFT.Custody.Escrowed));
        vm.prank(address(position));
        vm.expectRevert(HunterNFT.TokenNotOwnerHeld.selector);
        nft.redeemAndDestroy(id);
        address otherPosition = address(new HunterEscrowFixture());
        uint256 nonce = nft.authorizationNonce(id);
        vm.expectRevert(HunterNFT.TokenNotOwnerHeld.selector);
        lifecycle.open(id, otherPosition, address(position), nonce);
        registry.setEntryEnabled(asset, false);
        position.release(nft, id, BOB);
        assertFalse(nft.isEncumbered(id));
        assertTrue(nft.wasReleasedThisTransaction(id));
        assertEq(nft.basketOf(id), asset);
        assertEq(lifecycle.lastOwner(), BOB);
    }

    function testRejectedEscrowRequestRollsBackEverything() public {
        uint256 id = _mint(ALICE);
        position.setReject(true);
        vm.prank(ALICE);
        vm.expectRevert(bytes("request failed"));
        nft.escrowTo(id, address(position), hex"ff");
        assertEq(nft.ownerOf(id), ALICE);
        assertEq(nft.escrowedTo(id), address(0));
        assertEq(nft.authorizationNonce(id), 1);
        assertEq(lifecycle.transferCalls(), 0);
    }

    function testCreditBlocksAllERC721TransferAndApprovalPaths() public {
        uint256 id = _mint(ALICE);
        vm.startPrank(ALICE);
        nft.approve(OPERATOR, id);
        nft.setApprovalForAll(OPERATOR, true);
        vm.stopPrank();
        lifecycle.open(id, address(position), ALICE, 1);
        assertEq(nft.getApproved(id), address(0));
        assertEq(nft.activeCreditCount(ALICE), 1);
        assertEq(uint256(nft.custody(id)), uint256(HunterNFT.Custody.CreditLocked));
        bytes memory locked = abi.encodeWithSelector(HunterNFT.CreditLocked.selector, id);
        vm.startPrank(OPERATOR);
        vm.expectRevert(locked);
        nft.transferFrom(ALICE, BOB, id);
        vm.expectRevert(locked);
        nft.safeTransferFrom(ALICE, BOB, id);
        vm.expectRevert(locked);
        nft.safeTransferFrom(ALICE, BOB, id, hex"01");
        vm.expectRevert(locked);
        nft.approve(BOB, id);
        vm.stopPrank();
        vm.startPrank(ALICE);
        vm.expectRevert(HunterNFT.TokenNotOwnerHeld.selector);
        nft.redeemAndDestroy(id);
        vm.expectRevert(HunterNFT.TokenNotOwnerHeld.selector);
        nft.escrowTo(id, address(position), "");
        vm.expectRevert(HunterNFT.OwnerHasCreditLock.selector);
        nft.setApprovalForAll(BOB, true);
        nft.setApprovalForAll(OPERATOR, false);
        vm.stopPrank();
        assertEq(nft.ownerOf(id), ALICE);
    }

    function testOnlyLifecycleCanLockOrUnlock() public {
        uint256 id = _mint(ALICE);
        vm.expectRevert(HunterNFT.UnauthorizedLifecycle.selector);
        nft.lockCredit(id, address(position), ALICE, 1);
        lifecycle.open(id, address(position), ALICE, 1);
        vm.prank(address(position));
        vm.expectRevert(HunterNFT.UnauthorizedLifecycle.selector);
        nft.unlockCredit(id, address(position), 2);
        vm.prank(ALICE);
        vm.expectRevert(HunterNFT.UnauthorizedLifecycle.selector);
        nft.unlockCredit(id, address(position), 2);
    }

    function testStaleOwnerNonceDoubleLockAndInvalidPositionsFail() public {
        uint256 id = _mint(ALICE);
        vm.expectRevert(HunterNFT.StaleAuthorization.selector);
        lifecycle.open(id, address(position), BOB, 1);
        vm.expectRevert(HunterNFT.StaleAuthorization.selector);
        lifecycle.open(id, address(position), ALICE, 0);
        address[3] memory bad = [BOB, address(nft), address(lifecycle)];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(HunterNFT.InvalidPosition.selector);
            lifecycle.open(id, bad[i], ALICE, 1);
        }
        lifecycle.open(id, address(position), ALICE, 1);
        vm.expectRevert(HunterNFT.TokenNotOwnerHeld.selector);
        lifecycle.open(id, address(position), ALICE, 2);
        vm.expectRevert(HunterNFT.InvalidPosition.selector);
        lifecycle.close(id, BOB, 2);
        vm.expectRevert(HunterNFT.StaleAuthorization.selector);
        lifecycle.close(id, address(position), 1);
    }

    function testCloseAfterDisableDoesNotEraseBasketOrSupply() public {
        uint256 id = _mint(ALICE);
        lifecycle.open(id, address(position), ALICE, 1);
        registry.setEntryEnabled(asset, false);
        lifecycle.close(id, address(position), 2);
        assertFalse(nft.isEncumbered(id));
        assertEq(uint256(nft.custody(id)), uint256(HunterNFT.Custody.OwnerHeld));
        assertEq(nft.activeCreditCount(ALICE), 0);
        assertEq(nft.authorizationNonce(id), 3);
        assertEq(nft.basketOf(id), asset);
        vm.expectRevert(HunterNFT.InvalidPosition.selector);
        lifecycle.close(id, address(position), 2);
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, id);
        vm.prank(BOB);
        nft.redeemAndDestroy(id);
        assertEq(nft.mintedEver(), 1);
        assertEq(lifecycle.lastOwner(), BOB);
    }

    function testOldCloseCannotUnlockNewPositionAtSameAddress() public {
        uint256 id = _mint(ALICE);
        lifecycle.open(id, address(position), ALICE, 1);
        lifecycle.close(id, address(position), 2);
        lifecycle.open(id, address(position), ALICE, 3);
        vm.expectRevert(HunterNFT.StaleAuthorization.selector);
        lifecycle.close(id, address(position), 2);
        assertEq(nft.creditPositionOf(id), address(position));
        lifecycle.close(id, address(position), 4);
    }

    function testCreditOnOneNFTDoesNotFreezeOtherNFTTransfers() public {
        uint256 first = _mint(ALICE);
        uint256 second = _mint(ALICE);
        lifecycle.open(first, address(position), ALICE, 1);
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, second);
        assertEq(nft.ownerOf(second), BOB);
        assertEq(nft.ownerOf(first), ALICE);
    }

    function testLifecycleCannotReenterEvenWithOperatorPermission() public {
        uint256 id = _mint(ALICE);
        vm.prank(ALICE);
        nft.setApprovalForAll(address(lifecycle), true);
        vm.prank(BOB);
        nft.setApprovalForAll(address(lifecycle), true);
        lifecycle.setReentry(abi.encodeWithSignature("transferFrom(address,address,uint256)", BOB, ALICE, id));
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, id);
        assertFalse(lifecycle.reentrySucceeded());
        assertEq(nft.ownerOf(id), BOB);
        lifecycle.setReentry(abi.encodeCall(nft.lockCredit, (id, address(position), ALICE, 3)));
        vm.prank(BOB);
        nft.transferFrom(BOB, ALICE, id);
        assertFalse(lifecycle.reentrySucceeded());
        assertFalse(nft.isEncumbered(id));
        lifecycle.setReentry(abi.encodeCall(nft.setApprovalForAll, (OPERATOR, true)));
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, id);
        assertFalse(lifecycle.reentrySucceeded());
    }

    function testHostileRegistryQueryCannotMutateNFTUnderStaticCall() public {
        address expected = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 2);
        HunterStaticRegistryFixture hostile = new HunterStaticRegistryFixture(expected);
        HunterLifecycleFixture hooks = new HunterLifecycleFixture(expected);
        HunterNFT target = new HunterNFT(address(hostile), address(hooks), 1, ROYALTIES, "");
        target.mint(ALICE, bytes32(0), 1, 1, asset);
        assertFalse(target.isApprovedForAll(address(hostile), OPERATOR));
        // Positive control: the same query under an ordinary CALL can mutate NFT state.
        assertFalse(hostile.isEntryEnabled(asset));
        assertTrue(target.isApprovedForAll(address(hostile), OPERATOR));
    }

    function testZeroRecipientAlreadyRejectedByOpenZeppelin() public {
        vm.expectRevert(abi.encodeWithSignature("ERC721InvalidReceiver(address)", address(0)));
        _mint(address(0));
        assertEq(nft.mintedEver(), 0);
        assertEq(nft.basketOf(1), address(0));
        assertEq(lifecycle.mintCalls(), 0);
    }

    function testEscrowReceiverCanReleaseDuringRequestWithBothEvents() public {
        uint256 id = _mint(ALICE);
        position.setForward(BOB);
        vm.prank(ALICE);
        nft.approve(OPERATOR, id);
        vm.expectEmit(true, true, true, true, address(nft));
        emit EscrowEntered(id, ALICE, address(position));
        vm.expectEmit(true, true, true, true, address(nft));
        emit EscrowReleased(id, address(position), BOB);
        vm.prank(ALICE);
        nft.escrowTo(id, address(position), hex"1234");
        assertEq(nft.ownerOf(id), BOB);
        assertFalse(nft.isEncumbered(id));
        assertEq(nft.getApproved(id), address(0));
        assertTrue(nft.wasReleasedThisTransaction(id));
        assertEq(lifecycle.transferCalls(), 2);
    }

    function testRoyaltyAndInterfacesPreserved() public view {
        (address recipient, uint256 amount) = nft.royaltyInfo(999, 10_000);
        assertEq(recipient, ROYALTIES);
        assertEq(amount, 333);
        assertTrue(nft.supportsInterface(0x2a55205a));
        assertTrue(nft.supportsInterface(0x80ac58cd));
        assertFalse(nft.supportsInterface(0xffffffff));
    }

    function testExistingLiveHuntFillCarriesNFTAndBasket() public {
        uint256 id = _mint(ALICE);
        LiveHunt hunt = _hunt();
        uint256 huntId = _offer(hunt);
        vm.prank(ALICE);
        nft.safeTransferFrom(ALICE, address(hunt), id, abi.encode(huntId));
        assertEq(nft.ownerOf(id), BOB);
        assertEq(nft.basketOf(id), asset);
        assertEq(lifecycle.lastOwner(), BOB);
        assertEq(hunt.credit(ALICE), 0.005 ether);
        assertEq(hunt.totalEscrowed(), 0);
        assertEq(hunt.totalCredited(), 0.005 ether);
    }

    function testLiveHuntCannotBypassCreditOrSameTransactionEscrowRelease() public {
        uint256 id = _mint(ALICE);
        LiveHunt hunt = _hunt();
        uint256 huntId = _offer(hunt);
        lifecycle.open(id, address(position), ALICE, 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterNFT.CreditLocked.selector, id));
        nft.safeTransferFrom(ALICE, address(hunt), id, abi.encode(huntId));
        lifecycle.close(id, address(position), 2);
        vm.prank(ALICE);
        nft.escrowTo(id, address(position), "");
        position.release(nft, id, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(LiveHunt.TokenReleasedThisTransaction.selector, id));
        nft.safeTransferFrom(ALICE, address(hunt), id, abi.encode(huntId));
        assertEq(nft.ownerOf(id), ALICE);
        assertEq(hunt.totalEscrowed(), 0.005 ether);
    }

    function _hunt() private returns (LiveHunt) {
        // Existing fee-range fixtures only; this does not choose future loan fees.
        return new LiveHunt(
            ILiveHuntNFT(address(nft)),
            0.005 ether,
            1 days,
            90 days,
            0,
            500,
            ROYALTIES,
            address(0x5709),
            block.timestamp + 360 days
        );
    }

    function _offer(LiveHunt hunt) private returns (uint256) {
        LiveHunt.Criteria memory criteria;
        criteria.artVersion = 1;
        vm.deal(BOB, 0.005 ether);
        vm.prank(BOB);
        return hunt.createHunt{value: 0.005 ether}(criteria, 1 days);
    }

    function testConstructorRejectsWrongLifecycleBinding() public {
        vm.expectRevert(HunterNFT.InvalidConfiguration.selector);
        new HunterNFT(address(registry), address(lifecycle), 1, ROYALTIES, "");
    }

    function testLifetimeCapCannotBeReopenedByBurn() public {
        // Boundary fixture, not a production setter: skip 4,999 historical mints.
        stdstore.target(address(nft)).sig("mintedEver()").checked_write(4_999);
        uint256 id = _mint(ALICE);
        assertEq(id, 5_000);
        vm.prank(ALICE);
        nft.redeemAndDestroy(id);
        assertEq(nft.mintedEver(), 5_000);
        vm.expectRevert(HunterNFT.LifetimeCapReached.selector);
        _mint(ALICE);
    }

    function testInvalidEscrowAndNonOwnerActionsFail() public {
        uint256 id = _mint(ALICE);
        vm.prank(BOB);
        vm.expectRevert(HunterNFT.NotTokenOwner.selector);
        nft.redeemAndDestroy(id);
        vm.prank(BOB);
        vm.expectRevert(HunterNFT.NotTokenOwner.selector);
        nft.escrowTo(id, address(position), "");
        address[3] memory invalid = [ALICE, address(nft), BOB];
        for (uint256 i; i < invalid.length; ++i) {
            vm.prank(ALICE);
            vm.expectRevert(HunterNFT.InvalidEscrow.selector);
            nft.escrowTo(id, invalid[i], "");
        }
    }

    function testConstructorRejectsInvalidConfiguration() public {
        vm.expectRevert(HunterNFT.InvalidConfiguration.selector);
        new HunterNFT(BOB, address(lifecycle), 1, ROYALTIES, "");
        vm.expectRevert(HunterNFT.InvalidConfiguration.selector);
        new HunterNFT(address(registry), BOB, 1, ROYALTIES, "");
        vm.expectRevert(HunterNFT.InvalidConfiguration.selector);
        new HunterNFT(address(registry), address(lifecycle), 2, ROYALTIES, "");
        vm.expectRevert(HunterNFT.InvalidConfiguration.selector);
        new HunterNFT(address(registry), address(lifecycle), 1, address(0), "");
        vm.expectRevert(HunterNFT.InvalidConfiguration.selector);
        new HunterNFT(address(registry), address(lifecycle), 1, address(this), "");
    }

    function testFuzzTransfersInvalidatePriorAuthorization(uint8 count) public {
        uint256 id = _mint(ALICE);
        address owner = ALICE;
        for (uint256 i; i < count; ++i) {
            address to = owner == ALICE ? BOB : ALICE;
            vm.prank(owner);
            nft.transferFrom(owner, to, id);
            owner = to;
        }
        assertEq(nft.authorizationNonce(id), uint256(count) + 1);
        assertEq(nft.basketOf(id), asset);
    }

    function _mint(address owner) private returns (uint256) {
        return nft.mint(owner, bytes32(uint256(123)), 7, 2, asset);
    }
}
