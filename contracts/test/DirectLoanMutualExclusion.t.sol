// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";
import {DirectLoan} from "../src/bloom/DirectLoan.sol";
import {HunterLifecycle} from "../src/bloom/HunterLifecycle.sol";
import {HunterNFT} from "../src/bloom/HunterNFT.sol";
import {LiveHunt} from "../src/LiveHunt.sol";
import {ILiveHuntNFT} from "../src/ILiveHuntNFT.sol";

/// @dev Local forge-only mock loan asset. Not a product token.
contract DirectLoanMutualExclusionLoanAsset is ERC20 {
    constructor() ERC20("MOCK-LOAN-MUTUAL-EXCLUSION", "mLOAN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice M3.2 optional remaining checklist: while a Hunter is escrowed in
/// DirectLoan (or credit-locked), conflicting paths cannot double-commit the
/// same NFT — Live Hunt fill, basket switch, and basket credit lock.
///
/// Local forge only. No Morpho, no Robinhood broadcast, no launch or yield claims.
/// Fee bps here are TEST PLACEHOLDERS — not launch rates.
contract DirectLoanMutualExclusionTest is LifecycleTestBase {
    // TEST PLACEHOLDER fee — not a launch rate (M3.1 freeze / M3.2 kickoff).
    uint256 internal constant FEE_BPS = 100;
    uint256 internal constant PRINCIPAL = 100 ether;
    uint256 internal constant REPAYMENT = 110 ether;
    uint256 internal constant DURATION = 7 days;

    // TEST-ONLY Live Hunt constructor fixtures (inside accepted ranges).
    uint256 private constant TEST_ONLY_MIN_OFFER = 0.005 ether;
    uint256 private constant TEST_ONLY_MIN_DURATION = 1 days;
    uint256 private constant TEST_ONLY_MAX_DURATION = 90 days;
    uint256 private constant TEST_ONLY_FEE_BPS = 250;
    uint256 private constant TEST_ONLY_MAX_FEE_BPS = 500;
    address private constant TEST_ONLY_FEE_RECIPIENT = address(0xFEE5);
    address private constant TEST_ONLY_STOP_MULTISIG = address(0x5709);
    uint256 private constant TEST_ONLY_OFFER = 0.01 ether + 3;

    DirectLoan internal module;
    DirectLoanMutualExclusionLoanAsset internal loanAsset;

    address internal borrower = makeAddr("borrower");
    address internal lender = makeAddr("lender");
    address internal feeSink = makeAddr("feeSink");
    address internal stopAuth = makeAddr("stopAuth");

    function setUp() public override {
        super.setUp();

        loanAsset = new DirectLoanMutualExclusionLoanAsset();
        module = new DirectLoan(
            DirectLoan.Config({
                nft: address(nft),
                loanAsset: address(loanAsset),
                feeRecipient: feeSink,
                stopAuthority: stopAuth,
                feeBps: FEE_BPS,
                feeCap: 0,
                minPrincipal: 1 ether,
                maxPrincipal: 1_000 ether,
                minDuration: 1 days,
                maxDuration: 90 days,
                requestFundingWindow: 3 days,
                defaultResolutionWindow: 1 days
            })
        );

        loanAsset.mint(lender, 1_000 ether);
        loanAsset.mint(borrower, 1_000 ether);
        vm.prank(lender);
        loanAsset.approve(address(module), type(uint256).max);
        vm.prank(borrower);
        loanAsset.approve(address(module), type(uint256).max);
    }

    function _terms() internal pure returns (bytes memory) {
        return
            abi.encode(DirectLoan.Terms({version: 1, principal: PRINCIPAL, repayment: REPAYMENT, duration: DURATION}));
    }

    function _mintAndPledgeFunded() internal returns (uint256 tokenId, uint256 loanId) {
        tokenId = _mint(borrower, 1, basketA);
        vm.prank(borrower);
        nft.escrowTo(tokenId, address(module), _terms());
        loanId = module.loanIdByToken(tokenId);
        assertTrue(nft.isEncumbered(tokenId));
        assertEq(nft.ownerOf(tokenId), address(module));
        assertEq(uint256(nft.custody(tokenId)), uint256(HunterNFT.Custody.Escrowed));
        vm.prank(lender);
        module.fund(loanId);
        assertEq(uint8(module.getLoan(loanId).status), uint8(DirectLoan.Status.Funded));
    }

    function _deployHunt() internal returns (LiveHunt hunt) {
        hunt = new LiveHunt(
            ILiveHuntNFT(address(nft)),
            TEST_ONLY_MIN_OFFER,
            TEST_ONLY_MIN_DURATION,
            TEST_ONLY_MAX_DURATION,
            TEST_ONLY_FEE_BPS,
            TEST_ONLY_MAX_FEE_BPS,
            TEST_ONLY_FEE_RECIPIENT,
            TEST_ONLY_STOP_MULTISIG,
            block.timestamp + 360 days
        );
        assertEq(address(hunt.PROOF_NFT()), address(nft));
    }

    function _postOffer(LiveHunt hunt, address collector, uint256 offer) internal returns (uint256 huntId) {
        LiveHunt.Criteria memory criteria;
        criteria.artVersion = 1;
        uint256 escrowedBefore = hunt.totalEscrowed();
        vm.deal(collector, offer);
        vm.prank(collector);
        huntId = hunt.createHunt{value: offer}(criteria, TEST_ONLY_MIN_DURATION);
        assertEq(hunt.totalEscrowed(), escrowedBefore + offer);
    }

    /// @notice DirectLoan escrow blocks Live Hunt fill: borrower is not owner,
    /// transfer reverts, NFT stays with the module, and the open offer is untouched.
    function testDirectLoanEscrowBlocksLiveHuntFill() public {
        (uint256 tokenId,) = _mintAndPledgeFunded();
        LiveHunt hunt = _deployHunt();
        uint256 huntId = _postOffer(hunt, BOB, TEST_ONLY_OFFER);
        uint256 escrowed = hunt.totalEscrowed();

        // Borrower is not owner and has no approval from DirectLoan — fill cannot start.
        // OZ checks operator approval against the real owner before the `from` match.
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, borrower, tokenId));
        nft.safeTransferFrom(borrower, address(hunt), tokenId, abi.encode(huntId));

        assertEq(nft.ownerOf(tokenId), address(module));
        assertEq(nft.escrowedTo(tokenId), address(module));
        assertTrue(nft.isEncumbered(tokenId));
        assertEq(hunt.totalEscrowed(), escrowed);
        assertEq(module.loanIdByToken(tokenId), module.loanIdByToken(tokenId));
    }

    /// @notice DirectLoan escrow blocks basket switch: borrower is not owner;
    /// even the escrow holder cannot requestSwitch while encumbered.
    function testDirectLoanEscrowBlocksBasketSwitch() public {
        (uint256 tokenId,) = _mintAndPledgeFunded();

        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.NotTokenOwner.selector, tokenId));
        lc.requestSwitch(tokenId, basketB);

        // Module is ownerOf but token remains encumbered — switch still refused.
        vm.prank(address(module));
        vm.expectRevert(abi.encodeWithSelector(HunterLifecycle.TokenNotOwnerHeld.selector, tokenId));
        lc.requestSwitch(tokenId, basketB);

        HunterLifecycle.SwitchRequest memory req = lc.switchRequestOf(tokenId);
        assertEq(req.target, address(0));
        assertEq(nft.basketOf(tokenId), basketA);
        assertTrue(nft.isEncumbered(tokenId));
        assertEq(nft.ownerOf(tokenId), address(module));
    }

    /// @notice DirectLoan escrow blocks basket credit lock via the lifecycle-only
    /// lockCredit entry (the production credit-entry surface on main today).
    function testDirectLoanEscrowBlocksCreditLock() public {
        (uint256 tokenId,) = _mintAndPledgeFunded();
        uint256 nonce = nft.authorizationNonce(tokenId);
        address fakePosition = address(uint160(uint256(keccak256("credit-position"))));
        vm.etch(fakePosition, hex"00");

        // ownerOf is DirectLoan; pass the module as "borrower" so the ownership
        // check is satisfied and the encumbrance guard (TokenNotOwnerHeld) fires.
        vm.prank(address(lc));
        vm.expectRevert(HunterNFT.TokenNotOwnerHeld.selector);
        nft.lockCredit(tokenId, fakePosition, address(module), nonce);

        assertEq(nft.creditPositionOf(tokenId), address(0));
        assertEq(nft.authorizationNonce(tokenId), nonce);
        assertEq(nft.ownerOf(tokenId), address(module));
        assertTrue(nft.isEncumbered(tokenId));
        assertEq(uint256(nft.custody(tokenId)), uint256(HunterNFT.Custody.Escrowed));
    }

    /// @notice Reverse exclusion: credit lock blocks DirectLoan escrowTo so the
    /// same NFT cannot be whole-loan pledged while basket-credit locked.
    function testCreditLockBlocksDirectLoanEscrow() public {
        uint256 tokenId = _mint(borrower, 1, basketA);
        address fakePosition = address(uint160(uint256(keccak256("credit-position-2"))));
        vm.etch(fakePosition, hex"00");

        uint256 nonce = nft.authorizationNonce(tokenId);
        vm.prank(address(lc));
        nft.lockCredit(tokenId, fakePosition, borrower, nonce);
        assertTrue(nft.isEncumbered(tokenId));
        assertEq(uint256(nft.custody(tokenId)), uint256(HunterNFT.Custody.CreditLocked));

        vm.prank(borrower);
        vm.expectRevert(HunterNFT.TokenNotOwnerHeld.selector);
        nft.escrowTo(tokenId, address(module), _terms());

        assertEq(module.loanIdByToken(tokenId), 0);
        assertEq(nft.ownerOf(tokenId), borrower);
        assertEq(nft.creditPositionOf(tokenId), fakePosition);
        assertTrue(nft.isEncumbered(tokenId));
    }

    /// @notice Entering DirectLoan escrow invalidates a pending basket switch
    /// (same custody-transfer invalidation as M2.2 generic escrow).
    function testDirectLoanEscrowClearsPendingSwitch() public {
        uint256 tokenId = _mint(borrower, 1, basketA);
        vm.prank(borrower);
        uint256 switchNonceBefore = lc.requestSwitch(tokenId, basketB);
        assertEq(switchNonceBefore, 1);
        assertEq(lc.switchRequestOf(tokenId).target, basketB);

        vm.prank(borrower);
        nft.escrowTo(tokenId, address(module), _terms());

        assertEq(nft.ownerOf(tokenId), address(module));
        assertTrue(nft.isEncumbered(tokenId));
        assertEq(lc.switchRequestOf(tokenId).target, address(0));
        // Invalidation consumes exactly one additional switch nonce.
        assertEq(lc.switchNonce(tokenId), switchNonceBefore + 1);
        assertEq(module.loanIdByToken(tokenId), 1);
    }
}
