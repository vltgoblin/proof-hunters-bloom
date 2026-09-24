// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";
import {HunterBackingVault} from "../src/bloom/HunterBackingVault.sol";
import {DirectLoan} from "../src/bloom/DirectLoan.sol";
import {ReserveTokenFixture} from "./helpers/HunterReserveFixtures.sol";

/// @dev Local forge-only mock loan asset. Not a product token.
contract DirectLoanBackingLoanAsset is ERC20 {
    constructor() ERC20("MOCK-LOAN-BACKING-ESCROW", "mLOAN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice M3.2 remaining checklist: daily / attached backing stays on the tokenId
/// while the Hunter is in DirectLoan escrow; the exit party (borrower on repay,
/// lender on default) receives that attached position on burn.
///
/// Local forge only. No Morpho, no Robinhood broadcast, no launch or yield claims.
/// Fee bps here are TEST PLACEHOLDERS — not launch rates.
contract DirectLoanBackingInEscrowTest is LifecycleTestBase {
    // TEST PLACEHOLDER fee — not a launch rate (M3.1 freeze / M3.2 kickoff).
    uint256 internal constant FEE_BPS = 100;
    uint256 internal constant PRINCIPAL = 100 ether;
    uint256 internal constant REPAYMENT = 110 ether;
    uint256 internal constant DURATION = 7 days;

    uint256 internal constant OWNER_DEPOSIT = 30;
    uint256 internal constant ROUND_FUND = 40;
    // Sole tier-1 member → floor(40 * 100/100) = 40.
    uint256 internal constant ROUND_SHARE = 40;

    DirectLoan internal module;
    DirectLoanBackingLoanAsset internal loanAsset;

    address internal borrower = makeAddr("borrower");
    address internal lender = makeAddr("lender");
    address internal feeSink = makeAddr("feeSink");
    address internal stopAuth = makeAddr("stopAuth");

    function setUp() public override {
        super.setUp();

        loanAsset = new DirectLoanBackingLoanAsset();
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

        ReserveTokenFixture(basketA).setVault(address(canonicalBacking));
        ReserveTokenFixture(basketA).mint(borrower, 1_000);
        ReserveTokenFixture(basketA).mint(address(this), 1_000);
        vm.prank(borrower);
        ReserveTokenFixture(basketA).approve(address(canonicalBacking), type(uint256).max);
        ReserveTokenFixture(basketA).approve(address(canonicalBacking), type(uint256).max);
    }

    function _terms() internal pure returns (bytes memory) {
        return
            abi.encode(DirectLoan.Terms({version: 1, principal: PRINCIPAL, repayment: REPAYMENT, duration: DURATION}));
    }

    /// @dev Mint just before day-1 cutoff so the Hunter is eligible in round 1.
    function _mintEligibleHunter() internal returns (uint256 tokenId) {
        vm.warp(86_399);
        tokenId = _mint(borrower, 1, basketA);
    }

    function _ownerDeposit(uint256 tokenId, uint256 amount) internal {
        vm.prank(borrower);
        assertEq(canonicalBacking.depositOwnerBacking(tokenId, amount), amount);
    }

    function _pledgeAndFund(uint256 tokenId) internal returns (uint256 loanId) {
        vm.prank(borrower);
        nft.escrowTo(tokenId, address(module), _terms());
        loanId = module.loanIdByToken(tokenId);
        assertTrue(nft.isEncumbered(tokenId));
        assertEq(nft.ownerOf(tokenId), address(module));
        vm.prank(lender);
        module.fund(loanId);
        DirectLoan.Loan memory loan = module.getLoan(loanId);
        assertEq(uint8(loan.status), uint8(DirectLoan.Status.Funded));
    }

    /// @dev Fund + materialise day `day` for the sole basketA member while NFT may be escrowed.
    function _materialiseRoundWhilePossiblyEscrowed(uint32 day, uint256 tokenId) internal {
        uint256 cutoff = uint256(day) * 1 days;
        vm.warp(cutoff);
        canonicalLedger.recordRound(day, bytes32(uint256(day) << 8 | 0xDA), 80);
        canonicalLedger.freezeGroup(day, basketA);
        canonicalBacking.fund(day, basketA, ROUND_FUND);
        // Permissionless; credits tokenId even if DirectLoan holds the NFT.
        canonicalBacking.materialise(day, tokenId);
        assertTrue(canonicalBacking.consumed(day, tokenId));
    }

    /// @notice Owner deposit before escrow + round materialise during DirectLoan
    /// custody stay on the same tokenId; after full repay the borrower burns and
    /// receives both attached sources.
    function testBackingAttachesInEscrowBorrowerReceivesOnRepayBurn() public {
        uint256 tokenId = _mintEligibleHunter();
        _ownerDeposit(tokenId, OWNER_DEPOSIT);
        assertEq(canonicalBacking.ownerBackingOf(tokenId), OWNER_DEPOSIT);
        assertEq(canonicalBacking.backingOf(tokenId), 0);

        uint256 loanId = _pledgeAndFund(tokenId);

        // While escrowed, DirectLoan is ownerOf — owner deposits revert NotTokenOwner.
        // (TokenEncumbered would also apply if ownership matched.) Daily path is materialise.
        vm.prank(borrower);
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.NotTokenOwner.selector, tokenId));
        canonicalBacking.depositOwnerBacking(tokenId, 1);

        _materialiseRoundWhilePossiblyEscrowed(1, tokenId);
        assertEq(canonicalBacking.backingOf(tokenId), ROUND_SHARE);
        assertEq(canonicalBacking.ownerBackingOf(tokenId), OWNER_DEPOSIT);
        assertEq(canonicalBacking.totalBackingOf(tokenId), OWNER_DEPOSIT + ROUND_SHARE);
        // Still escrowed to DirectLoan — backing never moved out of the vault.
        assertEq(nft.ownerOf(tokenId), address(module));
        assertTrue(nft.isEncumbered(tokenId));

        vm.prank(borrower);
        module.depositRepayment(loanId, REPAYMENT);
        assertEq(uint8(module.getLoan(loanId).status), uint8(DirectLoan.Status.Repaid));

        module.claimNft(loanId);
        assertEq(nft.ownerOf(tokenId), borrower);
        assertFalse(nft.isEncumbered(tokenId));

        ReserveTokenFixture asset = ReserveTokenFixture(basketA);
        uint256 beforeBal = asset.balanceOf(borrower);
        uint256 expected = OWNER_DEPOSIT + ROUND_SHARE;
        vm.prank(borrower);
        nft.redeemAndDestroy(tokenId);
        assertEq(asset.balanceOf(borrower), beforeBal + expected);
        assertEq(canonicalBacking.totalBackingOf(tokenId), 0);
        assertTrue(canonicalBacking.burnSettled(tokenId));
    }

    /// @notice Same attached backing; on default the lender claims the NFT and
    /// receives every attached unit on burn — borrower does not.
    function testBackingAttachesInEscrowLenderReceivesOnDefaultBurn() public {
        uint256 tokenId = _mintEligibleHunter();
        _ownerDeposit(tokenId, OWNER_DEPOSIT);
        uint256 loanId = _pledgeAndFund(tokenId);
        _materialiseRoundWhilePossiblyEscrowed(1, tokenId);
        assertEq(canonicalBacking.totalBackingOf(tokenId), OWNER_DEPOSIT + ROUND_SHARE);

        DirectLoan.Loan memory loan = module.getLoan(loanId);
        vm.warp(loan.deadline + 1);
        vm.prank(lender);
        module.resolveDefault(loanId);
        assertEq(uint8(module.getLoan(loanId).status), uint8(DirectLoan.Status.Defaulted));

        module.claimNft(loanId);
        assertEq(nft.ownerOf(tokenId), lender);
        assertFalse(nft.isEncumbered(tokenId));

        ReserveTokenFixture asset = ReserveTokenFixture(basketA);
        uint256 lenderBefore = asset.balanceOf(lender);
        uint256 borrowerBefore = asset.balanceOf(borrower);
        uint256 expected = OWNER_DEPOSIT + ROUND_SHARE;
        vm.prank(lender);
        nft.redeemAndDestroy(tokenId);
        assertEq(asset.balanceOf(lender), lenderBefore + expected);
        assertEq(asset.balanceOf(borrower), borrowerBefore);
        assertTrue(canonicalBacking.burnSettled(tokenId));
    }
}
