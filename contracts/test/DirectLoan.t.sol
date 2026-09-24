// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HunterNFT, IHunterLifecycle} from "../src/bloom/HunterNFT.sol";
import {BasketRegistry} from "../src/bloom/BasketRegistry.sol";
import {DirectLoan} from "../src/bloom/DirectLoan.sol";

contract MockLoanAsset is ERC20 {
    constructor() ERC20("Mock Loan Asset", "mLOAN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MockBasket is ERC20 {
    constructor() ERC20("Mock Basket", "mBASK") {}
}

/// @dev Test-only lifecycle stub. NOT a vault or loan verifier.
contract LifecycleStub is IHunterLifecycle {
    address public immutable override nft;

    constructor(address expected) {
        nft = expected;
    }

    function onMint(uint256, address, address) external view {
        require(msg.sender == nft, "nft");
    }

    function onTransfer(uint256, address, address) external view {
        require(msg.sender == nft, "nft");
    }

    function onBurn(uint256, address) external view {
        require(msg.sender == nft, "nft");
    }

    function lockCredit(uint256 tokenId, address position, address borrower, uint256 expectedNonce) external {
        HunterNFT(nft).lockCredit(tokenId, position, borrower, expectedNonce);
    }
}

    contract DirectLoanTest is Test {
        // TEST PLACEHOLDER fee — not a launch rate (M3.1 freeze).
        uint256 constant FEE_BPS = 100;
        uint256 constant PRINCIPAL = 100 ether;
        uint256 constant REPAYMENT = 110 ether;
        uint256 constant DURATION = 7 days;

        HunterNFT internal nft;
        BasketRegistry internal registry;
        DirectLoan internal module;
        MockLoanAsset internal asset;
        address internal basket;
        LifecycleStub internal life;

        address internal borrower = makeAddr("borrower");
        address internal lender = makeAddr("lender");
        address internal feeSink = makeAddr("feeSink");
        address internal stopAuth = makeAddr("stopAuth");
        address internal royalties = makeAddr("royalties");
        address internal stranger = makeAddr("stranger");

        function setUp() public {
            registry = new BasketRegistry(address(this));
            basket = address(new MockBasket());
            registry.admitBasket(basket, keccak256("review"));

            address predictedNft = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
            life = new LifecycleStub(predictedNft);
            nft = new HunterNFT(address(registry), address(life), 1, royalties, "ipfs://hunter/");

            asset = new MockLoanAsset();

            module = new DirectLoan(
                DirectLoan.Config({
                    nft: address(nft),
                    loanAsset: address(asset),
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

            asset.mint(lender, 1_000 ether);
            asset.mint(borrower, 1_000 ether);
            asset.mint(stranger, 1_000 ether);
            vm.prank(lender);
            asset.approve(address(module), type(uint256).max);
            vm.prank(borrower);
            asset.approve(address(module), type(uint256).max);
            vm.prank(stranger);
            asset.approve(address(module), type(uint256).max);
        }

        function _mintTo(address to) internal returns (uint256 tokenId) {
            tokenId = nft.mint(to, bytes32(uint256(1)), 1, 1, basket);
        }

        function _terms() internal pure returns (bytes memory) {
            return
                abi.encode(
                    DirectLoan.Terms({version: 1, principal: PRINCIPAL, repayment: REPAYMENT, duration: DURATION})
                );
        }

        function _termsCustom(uint256 principal, uint256 repayment, uint256 duration)
            internal
            pure
            returns (bytes memory)
        {
            return abi.encode(
                DirectLoan.Terms({version: 1, principal: principal, repayment: repayment, duration: duration})
            );
        }

        function _request(address who) internal returns (uint256 tokenId, uint256 loanId) {
            tokenId = _mintTo(who);
            vm.prank(who);
            nft.escrowTo(tokenId, address(module), _terms());
            loanId = module.loanIdByToken(tokenId);
        }

        function _deployCapped(uint256 feeBps, uint256 feeCap) internal returns (DirectLoan capped) {
            capped = new DirectLoan(
                DirectLoan.Config({
                    nft: address(nft),
                    loanAsset: address(asset),
                    feeRecipient: feeSink,
                    stopAuthority: stopAuth,
                    feeBps: feeBps,
                    feeCap: feeCap,
                    minPrincipal: 1 ether,
                    maxPrincipal: 1_000 ether,
                    minDuration: 1 days,
                    maxDuration: 90 days,
                    requestFundingWindow: 3 days,
                    defaultResolutionWindow: 1 days
                })
            );
            vm.prank(lender);
            asset.approve(address(capped), type(uint256).max);
            vm.prank(borrower);
            asset.approve(address(capped), type(uint256).max);
        }

        // --- Kickoff happy / cancel / double-pledge / default ---

        function testHappyPathFundRepayClaim() public {
            (uint256 tokenId, uint256 loanId) = _request(borrower);
            assertEq(nft.ownerOf(tokenId), address(module));
            assertTrue(nft.isEncumbered(tokenId));

            uint256 borrowerBefore = asset.balanceOf(borrower);
            vm.prank(lender);
            module.fund(loanId);

            (uint256 fee, uint256 net) = module.quoteFee(PRINCIPAL);
            assertEq(fee, PRINCIPAL * FEE_BPS / 10_000);
            assertEq(asset.balanceOf(borrower), borrowerBefore + net);
            assertEq(module.feeCreditOf(feeSink), fee);

            vm.prank(borrower);
            module.depositRepayment(loanId, REPAYMENT);

            DirectLoan.Status status = module.getLoan(loanId).status;
            assertEq(uint8(status), uint8(DirectLoan.Status.Repaid));

            uint256 lenderBefore = asset.balanceOf(lender);
            module.claimLender(lender);
            assertEq(asset.balanceOf(lender), lenderBefore + REPAYMENT);

            module.claimNft(loanId);
            assertEq(nft.ownerOf(tokenId), borrower);
            assertFalse(nft.isEncumbered(tokenId));

            module.claimFee(feeSink);
            assertEq(asset.balanceOf(feeSink), fee);
        }

        function testDoublePledgeReverts() public {
            (uint256 tokenId,) = _request(borrower);
            vm.prank(borrower);
            vm.expectRevert();
            nft.escrowTo(tokenId, address(module), _terms());

            uint256 tokenId2 = _mintTo(borrower);
            vm.prank(borrower);
            nft.escrowTo(tokenId2, address(module), _terms());
            vm.prank(borrower);
            vm.expectRevert();
            nft.escrowTo(tokenId2, address(module), _terms());
        }

        function testDefaultRefundsPartialDepositToBorrower() public {
            (uint256 tokenId, uint256 loanId) = _request(borrower);
            vm.prank(lender);
            module.fund(loanId);

            uint256 partialAmt = 30 ether;
            vm.prank(borrower);
            module.depositRepayment(loanId, partialAmt);

            vm.warp(block.timestamp + DURATION + 1);
            vm.prank(lender);
            module.resolveDefault(loanId);

            module.claimNft(loanId);
            assertEq(nft.ownerOf(tokenId), lender);

            uint256 beforeBal = asset.balanceOf(borrower);
            module.claimBorrowerRefund(borrower);
            assertEq(asset.balanceOf(borrower), beforeBal + partialAmt);
            assertEq(module.lenderClaimOf(lender), 0);
        }

        function testCancelReturnsNft() public {
            (uint256 tokenId, uint256 loanId) = _request(borrower);
            vm.prank(borrower);
            module.cancel(loanId);
            assertEq(nft.ownerOf(tokenId), borrower);
            assertFalse(nft.isEncumbered(tokenId));
        }

        // --- Partial repay / withdraw / excess ---

        function testPartialDepositThenWithdrawThenFullRepay() public {
            (, uint256 loanId) = _request(borrower);
            vm.prank(lender);
            module.fund(loanId);

            vm.prank(borrower);
            module.depositRepayment(loanId, 40 ether);
            assertEq(module.getLoan(loanId).deposit, 40 ether);

            uint256 before = asset.balanceOf(borrower);
            vm.prank(borrower);
            module.withdrawDeposit(loanId, 15 ether);
            assertEq(asset.balanceOf(borrower), before + 15 ether);
            assertEq(module.getLoan(loanId).deposit, 25 ether);

            vm.prank(borrower);
            module.depositRepayment(loanId, 85 ether);
            assertEq(uint8(module.getLoan(loanId).status), uint8(DirectLoan.Status.Repaid));
            assertEq(module.lenderClaimOf(lender), REPAYMENT);
            assertEq(module.borrowerRefundOf(borrower), 0);
        }

        function testExcessRepaymentCreditsBorrowerRefund() public {
            (, uint256 loanId) = _request(borrower);
            vm.prank(lender);
            module.fund(loanId);

            vm.prank(borrower);
            module.depositRepayment(loanId, REPAYMENT + 5 ether);

            assertEq(uint8(module.getLoan(loanId).status), uint8(DirectLoan.Status.Repaid));
            assertEq(module.lenderClaimOf(lender), REPAYMENT);
            assertEq(module.borrowerRefundOf(borrower), 5 ether);

            uint256 before = asset.balanceOf(borrower);
            module.claimBorrowerRefund(borrower);
            assertEq(asset.balanceOf(borrower), before + 5 ether);
        }

        function testClaimIndependenceLenderWithoutNft() public {
            (uint256 tokenId, uint256 loanId) = _request(borrower);
            vm.prank(lender);
            module.fund(loanId);
            vm.prank(borrower);
            module.depositRepayment(loanId, REPAYMENT);

            module.claimLender(lender);
            assertEq(nft.ownerOf(tokenId), address(module));
            assertEq(module.lenderClaimOf(lender), 0);

            module.claimNft(loanId);
            assertEq(nft.ownerOf(tokenId), borrower);
        }

        function testClaimIndependenceNftWithoutLender() public {
            (uint256 tokenId, uint256 loanId) = _request(borrower);
            vm.prank(lender);
            module.fund(loanId);
            vm.prank(borrower);
            module.depositRepayment(loanId, REPAYMENT);

            module.claimNft(loanId);
            assertEq(nft.ownerOf(tokenId), borrower);
            assertEq(module.lenderClaimOf(lender), REPAYMENT);
        }

        // --- Time boundaries ---

        function testFundAtInclusiveFundingWindowEnd() public {
            (, uint256 loanId) = _request(borrower);
            uint256 requestedAt = module.getLoan(loanId).requestedAt;
            vm.warp(requestedAt + 3 days);
            vm.prank(lender);
            module.fund(loanId);
            assertEq(uint8(module.getLoan(loanId).status), uint8(DirectLoan.Status.Funded));
        }

        function testFundAfterFundingWindowReverts() public {
            (, uint256 loanId) = _request(borrower);
            uint256 requestedAt = module.getLoan(loanId).requestedAt;
            vm.warp(requestedAt + 3 days + 1);
            vm.prank(lender);
            vm.expectRevert(abi.encodeWithSelector(DirectLoan.FundingWindowClosed.selector, loanId));
            module.fund(loanId);
        }

        function testRepayAtExactDeadlineSucceeds() public {
            (, uint256 loanId) = _request(borrower);
            vm.prank(lender);
            module.fund(loanId);
            uint256 deadline = module.getLoan(loanId).deadline;
            vm.warp(deadline);
            vm.prank(borrower);
            module.depositRepayment(loanId, REPAYMENT);
            assertEq(uint8(module.getLoan(loanId).status), uint8(DirectLoan.Status.Repaid));
        }

        function testRepayAfterDeadlineReverts() public {
            (, uint256 loanId) = _request(borrower);
            vm.prank(lender);
            module.fund(loanId);
            uint256 deadline = module.getLoan(loanId).deadline;
            vm.warp(deadline + 1);
            vm.prank(borrower);
            vm.expectRevert(abi.encodeWithSelector(DirectLoan.RepaymentWindowClosed.selector, loanId));
            module.depositRepayment(loanId, REPAYMENT);
        }

        function testDefaultAtDeadlinePlusOne() public {
            (uint256 tokenId, uint256 loanId) = _request(borrower);
            vm.prank(lender);
            module.fund(loanId);
            uint256 deadline = module.getLoan(loanId).deadline;

            vm.warp(deadline);
            vm.prank(lender);
            vm.expectRevert(abi.encodeWithSelector(DirectLoan.DefaultNotReady.selector, loanId));
            module.resolveDefault(loanId);

            vm.warp(deadline + 1);
            vm.prank(lender);
            module.resolveDefault(loanId);
            assertEq(uint8(module.getLoan(loanId).status), uint8(DirectLoan.Status.Defaulted));

            module.claimNft(loanId);
            assertEq(nft.ownerOf(tokenId), lender);
        }

        function testPublicDefaultAfterResolutionWindow() public {
            (, uint256 loanId) = _request(borrower);
            vm.prank(lender);
            module.fund(loanId);
            uint256 deadline = module.getLoan(loanId).deadline;

            vm.warp(deadline + 1);
            vm.prank(stranger);
            vm.expectRevert(abi.encodeWithSelector(DirectLoan.UnauthorizedDefaultResolver.selector, stranger));
            module.resolveDefault(loanId);

            vm.warp(deadline + 1 days + 1);
            vm.prank(stranger);
            module.resolveDefault(loanId);
            assertEq(uint8(module.getLoan(loanId).status), uint8(DirectLoan.Status.Defaulted));
        }

        // --- Authority / stop / self-fund ---

        function testSelfFundingReverts() public {
            (, uint256 loanId) = _request(borrower);
            vm.prank(borrower);
            vm.expectRevert(abi.encodeWithSelector(DirectLoan.SelfFunding.selector, borrower));
            module.fund(loanId);
        }

        function testCancelOnlyBorrower() public {
            (, uint256 loanId) = _request(borrower);
            vm.prank(stranger);
            vm.expectRevert(abi.encodeWithSelector(DirectLoan.NotBorrower.selector, stranger, borrower));
            module.cancel(loanId);
        }

        function testUnauthorizedStopCallerReverts() public {
            vm.prank(stranger);
            vm.expectRevert(abi.encodeWithSelector(DirectLoan.UnauthorizedStopCaller.selector, stranger));
            module.stopEntry();
        }

        function testEntryStopBlocksNewRequestAndFund() public {
            (uint256 tokenId, uint256 loanId) = _request(borrower);

            vm.prank(stopAuth);
            module.stopEntry();
            assertTrue(module.entryStopped());

            vm.prank(lender);
            vm.expectRevert(DirectLoan.EntryStopped.selector);
            module.fund(loanId);

            uint256 tokenId2 = _mintTo(borrower);
            vm.prank(borrower);
            vm.expectRevert(DirectLoan.EntryStopped.selector);
            nft.escrowTo(tokenId2, address(module), _terms());

            // Cancel still works for the pre-stop request.
            vm.prank(borrower);
            module.cancel(loanId);
            assertEq(nft.ownerOf(tokenId), borrower);
        }

        function testEntryStopAllowsRepayAndClaims() public {
            (uint256 tokenId, uint256 loanId) = _request(borrower);
            vm.prank(lender);
            module.fund(loanId);

            vm.prank(stopAuth);
            module.stopEntry();

            vm.prank(borrower);
            module.depositRepayment(loanId, REPAYMENT);
            module.claimLender(lender);
            module.claimFee(feeSink);
            module.claimNft(loanId);
            assertEq(nft.ownerOf(tokenId), borrower);
        }

        function testEntryStopAllowsDefaultPath() public {
            DirectLoan local = _deployCapped(FEE_BPS, 0);
            uint256 tokenId = _mintTo(borrower);
            vm.prank(borrower);
            nft.escrowTo(tokenId, address(local), _terms());
            uint256 loanId = local.loanIdByToken(tokenId);

            vm.prank(lender);
            local.fund(loanId);

            vm.prank(borrower);
            local.depositRepayment(loanId, 20 ether);

            vm.prank(stopAuth);
            local.stopEntry();

            vm.warp(block.timestamp + DURATION + 1);
            vm.prank(lender);
            local.resolveDefault(loanId);

            local.claimNft(loanId);
            assertEq(nft.ownerOf(tokenId), lender);

            uint256 before = asset.balanceOf(borrower);
            local.claimBorrowerRefund(borrower);
            assertEq(asset.balanceOf(borrower), before + 20 ether);
        }

        function testEntryAlreadyStoppedReverts() public {
            vm.prank(stopAuth);
            module.stopEntry();
            vm.prank(stopAuth);
            vm.expectRevert(DirectLoan.EntryAlreadyStopped.selector);
            module.stopEntry();
        }

        // --- Fee / origination edges ---

        function testQuoteFeeAndCap() public {
            DirectLoan capped = _deployCapped(500, 2 ether); // 5% would be 5 ether on 100; cap 2
            (uint256 fee, uint256 net) = capped.quoteFee(PRINCIPAL);
            assertEq(fee, 2 ether);
            assertEq(net, PRINCIPAL - 2 ether);

            uint256 tokenId = _mintTo(borrower);
            vm.prank(borrower);
            nft.escrowTo(tokenId, address(capped), _terms());
            uint256 loanId = capped.loanIdByToken(tokenId);

            uint256 borrowerBefore = asset.balanceOf(borrower);
            vm.prank(lender);
            capped.fund(loanId);
            assertEq(asset.balanceOf(borrower), borrowerBefore + net);
            assertEq(capped.feeCreditOf(feeSink), fee);
        }

        function testZeroFeeConfig() public {
            DirectLoan free = _deployCapped(0, 0);
            (uint256 fee, uint256 net) = free.quoteFee(PRINCIPAL);
            assertEq(fee, 0);
            assertEq(net, PRINCIPAL);

            uint256 tokenId = _mintTo(borrower);
            vm.prank(borrower);
            nft.escrowTo(tokenId, address(free), _terms());
            uint256 loanId = free.loanIdByToken(tokenId);
            uint256 borrowerBefore = asset.balanceOf(borrower);
            vm.prank(lender);
            free.fund(loanId);
            assertEq(asset.balanceOf(borrower), borrowerBefore + PRINCIPAL);
            assertEq(free.feeCreditOf(feeSink), 0);
        }

        function testInvalidTermsRevertOnEscrow() public {
            uint256 tokenId = _mintTo(borrower);

            // Bad version
            vm.prank(borrower);
            vm.expectRevert(abi.encodeWithSelector(DirectLoan.UnsupportedTermsVersion.selector, uint256(99)));
            nft.escrowTo(
                tokenId,
                address(module),
                abi.encode(
                    DirectLoan.Terms({version: 99, principal: PRINCIPAL, repayment: REPAYMENT, duration: DURATION})
                )
            );

            // Repayment < principal
            vm.prank(borrower);
            vm.expectRevert(DirectLoan.InvalidTerms.selector);
            nft.escrowTo(tokenId, address(module), _termsCustom(PRINCIPAL, PRINCIPAL - 1, DURATION));

            // Principal below min
            vm.prank(borrower);
            vm.expectRevert(abi.encodeWithSelector(DirectLoan.PrincipalOutOfBounds.selector, uint256(0.5 ether)));
            nft.escrowTo(tokenId, address(module), _termsCustom(0.5 ether, 1 ether, DURATION));

            // Duration below min
            vm.prank(borrower);
            vm.expectRevert(abi.encodeWithSelector(DirectLoan.DurationOutOfBounds.selector, uint256(1 hours)));
            nft.escrowTo(tokenId, address(module), _termsCustom(PRINCIPAL, REPAYMENT, 1 hours));
        }

        // --- Non-escrow transfer / credit lock / double claim ---

        function testNonEscrowSafeTransferReverts() public {
            uint256 tokenId = _mintTo(borrower);
            vm.prank(borrower);
            vm.expectRevert();
            nft.safeTransferFrom(borrower, address(module), tokenId, _terms());
        }

        function testCreditLockBlocksEscrow() public {
            uint256 tokenId = _mintTo(borrower);
            address fakePosition = address(uint160(uint256(keccak256("position"))));
            // Give the fake position code so lockCredit accepts it.
            vm.etch(fakePosition, hex"00");

            life.lockCredit(tokenId, fakePosition, borrower, nft.authorizationNonce(tokenId));
            assertTrue(nft.isEncumbered(tokenId));

            vm.prank(borrower);
            vm.expectRevert();
            nft.escrowTo(tokenId, address(module), _terms());
        }

        function testDoubleNftClaimReverts() public {
            (uint256 tokenId, uint256 loanId) = _request(borrower);
            vm.prank(lender);
            module.fund(loanId);
            vm.prank(borrower);
            module.depositRepayment(loanId, REPAYMENT);

            module.claimNft(loanId);
            assertEq(nft.ownerOf(tokenId), borrower);

            vm.expectRevert(abi.encodeWithSelector(DirectLoan.NftAlreadyClaimed.selector, loanId));
            module.claimNft(loanId);
        }

        function testFundAfterCancelReverts() public {
            (, uint256 loanId) = _request(borrower);
            vm.prank(borrower);
            module.cancel(loanId);
            vm.prank(lender);
            vm.expectRevert(
                abi.encodeWithSelector(DirectLoan.InvalidLoanStatus.selector, loanId, DirectLoan.Status.Cancelled)
            );
            module.fund(loanId);
        }

        function testZeroDepositReverts() public {
            (, uint256 loanId) = _request(borrower);
            vm.prank(lender);
            module.fund(loanId);
            vm.prank(borrower);
            vm.expectRevert(DirectLoan.InvalidTerms.selector);
            module.depositRepayment(loanId, 0);
        }

        function testWithdrawMoreThanDepositReverts() public {
            (, uint256 loanId) = _request(borrower);
            vm.prank(lender);
            module.fund(loanId);
            vm.prank(borrower);
            module.depositRepayment(loanId, 10 ether);
            vm.prank(borrower);
            vm.expectRevert(abi.encodeWithSelector(DirectLoan.NothingToWithdraw.selector, loanId));
            module.withdrawDeposit(loanId, 11 ether);
        }

        function testCancelClearsLoanIdByToken() public {
            (uint256 tokenId, uint256 loanId) = _request(borrower);
            vm.prank(borrower);
            module.cancel(loanId);
            assertEq(module.loanIdByToken(tokenId), 0);
            assertEq(nft.ownerOf(tokenId), borrower);
            assertFalse(nft.isEncumbered(tokenId));
        }

        /// @dev Same-tx release+re-escrow is blocked by HunterNFT transient release marker.
        function testSameTxReEscrowAfterCancelReverts() public {
            (uint256 tokenId, uint256 loanId) = _request(borrower);
            vm.prank(borrower);
            module.cancel(loanId);
            vm.prank(borrower);
            vm.expectRevert(abi.encodeWithSelector(DirectLoan.TokenReleasedThisTransaction.selector, tokenId));
            nft.escrowTo(tokenId, address(module), _terms());
        }

        function testFreshTokenPledgeAfterCancelSucceeds() public {
            (, uint256 loanId) = _request(borrower);
            vm.prank(borrower);
            module.cancel(loanId);

            uint256 tokenId2 = _mintTo(borrower);
            vm.prank(borrower);
            nft.escrowTo(tokenId2, address(module), _terms());
            assertEq(module.loanIdByToken(tokenId2), loanId + 1);
        }

        function testLiabilitiesCoveredAfterFund() public {
            (, uint256 loanId) = _request(borrower);
            vm.prank(lender);
            module.fund(loanId);
            (uint256 fee,) = module.quoteFee(PRINCIPAL);
            assertEq(module.totalFeeCredits(), fee);
            assertEq(module.totalLiabilities(), fee);
            assertGe(asset.balanceOf(address(module)), module.totalLiabilities());
        }
    }
