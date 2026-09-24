// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {HunterNFT, IHunterLifecycle} from "../src/bloom/HunterNFT.sol";
import {BasketRegistry} from "../src/bloom/BasketRegistry.sol";
import {DirectLoan} from "../src/bloom/DirectLoan.sol";

/// @dev Local forge-only mock loan asset. Not a product token.
contract DirectLoanMoneyInvariantLoanAsset is ERC20 {
    constructor() ERC20("MOCK-LOAN-MONEY-INVARIANT", "mLOAN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DirectLoanMoneyInvariantBasket is ERC20 {
    constructor() ERC20("Mock Basket", "mBASK") {}
}

/// @dev Test-only lifecycle stub. NOT a vault or loan verifier.
contract DirectLoanMoneyInvariantLifecycleStub is IHunterLifecycle {
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

    /// @dev Valid-action handler. Preconditions gate calls; unexpected protocol
    /// reverts must fail the campaign (no broad catch). Tracks ghost escrow set.
    contract DirectLoanMoneyHandler is Test {
        uint256 internal constant MAX_LOANS = 8;
        uint256 internal constant PRINCIPAL = 100 ether;
        uint256 internal constant REPAYMENT = 110 ether;
        uint256 internal constant DURATION = 7 days;

        HunterNFT public immutable nft;
        DirectLoan public immutable module;
        DirectLoanMoneyInvariantLoanAsset public immutable asset;
        address public immutable feeSink;
        address public immutable stopAuth;
        address public immutable basket;

        address public immutable borrower0;
        address public immutable borrower1;
        address public immutable lender0;
        address public immutable lender1;

        uint256 public calls;
        uint256 public requests;
        uint256 public funds;
        uint256 public repays;
        uint256 public defaults;
        uint256 public cancels;

        uint256 public ghostActiveCount;
        mapping(uint256 => bool) public ghostActiveLoan;
        mapping(uint256 => uint256) public ghostTokenOfLoan;

        constructor(
            HunterNFT nft_,
            DirectLoan module_,
            DirectLoanMoneyInvariantLoanAsset asset_,
            address feeSink_,
            address stopAuth_,
            address basket_,
            address borrower0_,
            address borrower1_,
            address lender0_,
            address lender1_
        ) {
            nft = nft_;
            module = module_;
            asset = asset_;
            feeSink = feeSink_;
            stopAuth = stopAuth_;
            basket = basket_;
            borrower0 = borrower0_;
            borrower1 = borrower1_;
            lender0 = lender0_;
            lender1 = lender1_;
        }

        function request(uint256 seed) public {
            ++calls;
            if (module.entryStopped()) return;
            if (ghostActiveCount >= MAX_LOANS) return;
            address borrower = _borrower(seed);
            uint256 challengeId = nft.mintedEver() + 1;
            vm.prank(nft.MINER());
            uint256 tokenId = nft.mint(borrower, bytes32(seed), challengeId, 1, basket);
            bytes memory terms =
                abi.encode(
                DirectLoan.Terms({version: 1, principal: PRINCIPAL, repayment: REPAYMENT, duration: DURATION})
            );
            vm.prank(borrower);
            nft.escrowTo(tokenId, address(module), terms);
            uint256 loanId = module.loanIdByToken(tokenId);
            ghostActiveLoan[loanId] = true;
            ghostTokenOfLoan[loanId] = tokenId;
            ++ghostActiveCount;
            ++requests;
        }

        function cancel(uint256 seed) public {
            ++calls;
            uint256 loanId = _activeLoan(seed);
            if (loanId == 0) return;
            DirectLoan.Loan memory loan = module.getLoan(loanId);
            if (loan.status != DirectLoan.Status.Requested) return;
            vm.prank(loan.borrower);
            module.cancel(loanId);
            _clearGhost(loanId);
            ++cancels;
        }

        function fund(uint256 seed) public {
            ++calls;
            if (module.entryStopped()) return;
            uint256 loanId = _activeLoan(seed);
            if (loanId == 0) return;
            DirectLoan.Loan memory loan = module.getLoan(loanId);
            if (loan.status != DirectLoan.Status.Requested) return;
            (,,,, uint64 requestFundingWindow,) = module.bounds();
            if (block.timestamp > loan.requestedAt + requestFundingWindow) return;
            address lender = _lender(seed);
            if (lender == loan.borrower) return;
            vm.prank(lender);
            module.fund(loanId);
            ++funds;
        }

        function depositRepayment(uint256 seed, uint256 amountSeed) public {
            ++calls;
            uint256 loanId = _activeLoan(seed);
            if (loanId == 0) return;
            DirectLoan.Loan memory loan = module.getLoan(loanId);
            if (loan.status != DirectLoan.Status.Funded) return;
            if (block.timestamp > loan.deadline) return;
            uint256 need = loan.repayment - loan.deposit;
            if (need == 0) return;
            uint256 amount = bound(amountSeed, 1, need + (REPAYMENT / 10));
            // Top up borrower balance so transfer cannot fail for liquidity reasons.
            asset.mint(loan.borrower, amount);
            vm.startPrank(loan.borrower);
            asset.approve(address(module), type(uint256).max);
            module.depositRepayment(loanId, amount);
            vm.stopPrank();
            if (module.getLoan(loanId).status == DirectLoan.Status.Repaid) {
                // Loan still "active" until NFT claimed; keep ghost until claimNft.
                ++repays;
            }
        }

        function withdrawDeposit(uint256 seed, uint256 amountSeed) public {
            ++calls;
            uint256 loanId = _activeLoan(seed);
            if (loanId == 0) return;
            DirectLoan.Loan memory loan = module.getLoan(loanId);
            if (loan.status != DirectLoan.Status.Funded) return;
            if (loan.deposit == 0) return;
            uint256 amount = bound(amountSeed, 1, loan.deposit);
            vm.prank(loan.borrower);
            module.withdrawDeposit(loanId, amount);
        }

        function resolveDefault(uint256 seed) public {
            ++calls;
            uint256 loanId = _activeLoan(seed);
            if (loanId == 0) return;
            DirectLoan.Loan memory loan = module.getLoan(loanId);
            if (loan.status != DirectLoan.Status.Funded) return;
            if (block.timestamp <= loan.deadline) {
                vm.warp(loan.deadline + 1);
            }
            vm.prank(loan.lender);
            module.resolveDefault(loanId);
            ++defaults;
        }

        function claimNft(uint256 seed) public {
            ++calls;
            uint256 loanId = _activeLoan(seed);
            if (loanId == 0) return;
            DirectLoan.Loan memory loan = module.getLoan(loanId);
            if (loan.status != DirectLoan.Status.Repaid && loan.status != DirectLoan.Status.Defaulted) return;
            if (loan.nftClaimed) {
                _clearGhost(loanId);
                return;
            }
            module.claimNft(loanId);
            _clearGhost(loanId);
        }

        function claimLender(uint256 seed) public {
            ++calls;
            address who = _lender(seed);
            if (module.lenderClaimOf(who) == 0) return;
            module.claimLender(who);
        }

        function claimBorrowerRefund(uint256 seed) public {
            ++calls;
            address who = _borrower(seed);
            if (module.borrowerRefundOf(who) == 0) return;
            module.claimBorrowerRefund(who);
        }

        function claimFee(uint256) public {
            ++calls;
            if (module.feeCreditOf(feeSink) == 0) return;
            // May revert Insolvency if user liabilities consume balance — that is a
            // real protocol guard. Only claim when solvent for fee.
            uint256 fee = module.feeCreditOf(feeSink);
            uint256 bal = asset.balanceOf(address(module));
            uint256 userLiab =
                module.totalUncommittedDeposits() + module.totalLenderClaims() + module.totalBorrowerRefunds();
            if (bal < userLiab + fee) return;
            module.claimFee(feeSink);
        }

        function advanceTime(uint256 seed) public {
            ++calls;
            vm.warp(block.timestamp + bound(seed, 0, 3 days));
        }

        function stopEntry(uint256) public {
            ++calls;
            if (module.entryStopped()) return;
            vm.prank(stopAuth);
            module.stopEntry();
        }

        function _clearGhost(uint256 loanId) private {
            if (!ghostActiveLoan[loanId]) return;
            ghostActiveLoan[loanId] = false;
            delete ghostTokenOfLoan[loanId];
            --ghostActiveCount;
        }

        function _activeLoan(uint256 seed) private view returns (uint256) {
            if (ghostActiveCount == 0) return 0;
            // Scan a bounded loan id range (nextLoanId grows from 1).
            uint256 lim = module.nextLoanId();
            if (lim <= 1) return 0;
            uint256 start = 1 + (seed % (lim - 1));
            for (uint256 i; i < lim - 1; ++i) {
                uint256 id = 1 + ((start - 1 + i) % (lim - 1));
                if (ghostActiveLoan[id]) return id;
            }
            return 0;
        }

        function _borrower(uint256 seed) private view returns (address) {
            return seed % 2 == 0 ? borrower0 : borrower1;
        }

        function _lender(uint256 seed) private view returns (address) {
            return seed % 2 == 0 ? lender0 : lender1;
        }
    }

    /// @notice Stateful money-risk campaign over real DirectLoan + HunterNFT escrow.
    /// Proves module solvency and that Requested/Funded loans keep the NFT in module
    /// escrow. Does NOT prove Morpho/M3.3, launch fees, or production rates.
    /// Local Anvil/forge only.
    contract DirectLoanMoneyInvariantTest is StdInvariant, Test {
        // TEST PLACEHOLDER fee — not a launch rate (M3.1 freeze / M3.2).
        uint256 internal constant FEE_BPS = 100;
        uint256 internal constant PRINCIPAL = 100 ether;
        uint256 internal constant REPAYMENT = 110 ether;
        uint256 internal constant DURATION = 7 days;

        HunterNFT internal nft;
        BasketRegistry internal registry;
        DirectLoan internal module;
        DirectLoanMoneyInvariantLoanAsset internal asset;
        address internal basket;
        DirectLoanMoneyInvariantLifecycleStub internal life;
        DirectLoanMoneyHandler internal handler;

        address internal borrower0 = makeAddr("borrower0");
        address internal borrower1 = makeAddr("borrower1");
        address internal lender0 = makeAddr("lender0");
        address internal lender1 = makeAddr("lender1");
        address internal feeSink = makeAddr("feeSink");
        address internal stopAuth = makeAddr("stopAuth");
        address internal royalties = makeAddr("royalties");

        function setUp() public {
            registry = new BasketRegistry(address(this));
            basket = address(new DirectLoanMoneyInvariantBasket());
            registry.admitBasket(basket, keccak256("review"));

            address predictedNft = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
            life = new DirectLoanMoneyInvariantLifecycleStub(predictedNft);
            nft = new HunterNFT(address(registry), address(life), 1, royalties, "ipfs://hunter/");

            asset = new DirectLoanMoneyInvariantLoanAsset();
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

            asset.mint(lender0, 10_000 ether);
            asset.mint(lender1, 10_000 ether);
            asset.mint(borrower0, 10_000 ether);
            asset.mint(borrower1, 10_000 ether);
            vm.prank(lender0);
            asset.approve(address(module), type(uint256).max);
            vm.prank(lender1);
            asset.approve(address(module), type(uint256).max);
            vm.prank(borrower0);
            asset.approve(address(module), type(uint256).max);
            vm.prank(borrower1);
            asset.approve(address(module), type(uint256).max);

            handler = new DirectLoanMoneyHandler(
                nft, module, asset, feeSink, stopAuth, basket, borrower0, borrower1, lender0, lender1
            );
            // Seed one funded loan so invariants see non-empty money state.
            handler.request(1);
            handler.fund(2);

            targetContract(address(handler));
        }

        /// @notice Loan-asset balance never drops below recorded liabilities.
        function invariant_moduleSolvent() public view {
            assertGe(asset.balanceOf(address(module)), module.totalLiabilities(), "insolvent");
        }

        /// @notice Liability buckets sum to totalLiabilities (accounting identity).
        function invariant_liabilityBucketsSum() public view {
            assertEq(
                module.totalUncommittedDeposits() + module.totalLenderClaims() + module.totalBorrowerRefunds()
                    + module.totalFeeCredits(),
                module.totalLiabilities(),
                "liability sum"
            );
        }

        /// @notice Every ghost-active Requested/Funded loan keeps the Hunter NFT in
        /// DirectLoan escrow (token cannot leak while money-risk path is open).
        function invariant_escrowHoldsWhileOpen() public view {
            uint256 lim = module.nextLoanId();
            for (uint256 id = 1; id < lim; ++id) {
                if (!handler.ghostActiveLoan(id)) continue;
                DirectLoan.Loan memory loan = module.getLoan(id);
                if (loan.status == DirectLoan.Status.Requested || loan.status == DirectLoan.Status.Funded) {
                    uint256 tokenId = loan.tokenId;
                    assertEq(nft.ownerOf(tokenId), address(module), "nft left module");
                    assertTrue(nft.isEncumbered(tokenId), "not encumbered");
                    assertEq(nft.escrowedTo(tokenId), address(module), "escrow target");
                    assertEq(module.loanIdByToken(tokenId), id, "loanIdByToken");
                }
            }
        }

        /// @notice Fee credit never exceeds principal paid in on funded loans (placeholder bps).
        function invariant_feeCreditBoundedByFunds() public view {
            // Each fund credits at most quoteFee(PRINCIPAL); funds counter is a soft upper bound.
            (uint256 fee,) = module.quoteFee(PRINCIPAL);
            assertLe(module.totalFeeCredits(), fee * (handler.funds() + 1), "fee runaway");
        }
    }

    /// @notice Targeted fuzz / accounting unit proofs (Anvil/forge). Complements the
    /// stateful invariant campaign with explicit fee / repay / default paths.
    contract DirectLoanMoneyAccountingFuzzTest is Test {
        uint256 internal constant FEE_BPS = 100;
        uint256 internal constant DURATION = 7 days;

        HunterNFT internal nft;
        BasketRegistry internal registry;
        DirectLoan internal module;
        DirectLoanMoneyInvariantLoanAsset internal asset;
        address internal basket;
        DirectLoanMoneyInvariantLifecycleStub internal life;

        address internal borrower = makeAddr("borrower");
        address internal lender = makeAddr("lender");
        address internal feeSink = makeAddr("feeSink");
        address internal stopAuth = makeAddr("stopAuth");
        address internal royalties = makeAddr("royalties");

        function setUp() public {
            registry = new BasketRegistry(address(this));
            basket = address(new DirectLoanMoneyInvariantBasket());
            registry.admitBasket(basket, keccak256("review"));
            address predictedNft = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
            life = new DirectLoanMoneyInvariantLifecycleStub(predictedNft);
            nft = new HunterNFT(address(registry), address(life), 1, royalties, "ipfs://hunter/");
            asset = new DirectLoanMoneyInvariantLoanAsset();
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
            asset.mint(lender, 100_000 ether);
            asset.mint(borrower, 100_000 ether);
            vm.prank(lender);
            asset.approve(address(module), type(uint256).max);
            vm.prank(borrower);
            asset.approve(address(module), type(uint256).max);
        }

        function _request(uint256 principal, uint256 repayment) internal returns (uint256 tokenId, uint256 loanId) {
            tokenId = nft.mint(borrower, bytes32(uint256(tokenId) ^ principal), nft.mintedEver() + 1, 1, basket);
            bytes memory terms =
                abi.encode(
                DirectLoan.Terms({version: 1, principal: principal, repayment: repayment, duration: DURATION})
            );
            vm.prank(borrower);
            nft.escrowTo(tokenId, address(module), terms);
            loanId = module.loanIdByToken(tokenId);
        }

        function testFuzz_quoteFeeSplitsPrincipal(uint256 principalSeed) public view {
            uint256 principal = bound(principalSeed, 1 ether, 1_000 ether);
            (uint256 fee, uint256 net) = module.quoteFee(principal);
            assertEq(fee + net, principal, "fee+net");
            assertGt(net, 0, "net");
            assertLe(fee, principal * FEE_BPS / 10_000, "fee bps");
        }

        function testFuzz_fundCreditsFeeNetAndKeepsEscrow(uint256 principalSeed) public {
            uint256 principal = bound(principalSeed, 1 ether, 500 ether);
            uint256 repayment = principal + (principal / 10) + 1;
            (uint256 tokenId, uint256 loanId) = _request(principal, repayment);
            (uint256 fee, uint256 net) = module.quoteFee(principal);
            uint256 borrowerBefore = asset.balanceOf(borrower);
            vm.prank(lender);
            module.fund(loanId);
            assertEq(asset.balanceOf(borrower), borrowerBefore + net, "borrower net");
            assertEq(module.feeCreditOf(feeSink), fee, "fee credit");
            assertEq(asset.balanceOf(address(module)), fee, "module holds fee");
            assertGe(asset.balanceOf(address(module)), module.totalLiabilities(), "solvent after fund");
            assertEq(nft.ownerOf(tokenId), address(module), "escrow after fund");
            assertTrue(nft.isEncumbered(tokenId), "encumbered after fund");
        }

        function testFuzz_repayAccountingLenderAndExcess(uint256 extraSeed) public {
            uint256 principal = 100 ether;
            uint256 repayment = 110 ether;
            (, uint256 loanId) = _request(principal, repayment);
            vm.prank(lender);
            module.fund(loanId);
            uint256 extra = bound(extraSeed, 0, 50 ether);
            uint256 pay = repayment + extra;
            vm.prank(borrower);
            module.depositRepayment(loanId, pay);
            DirectLoan.Loan memory loan = module.getLoan(loanId);
            assertEq(uint8(loan.status), uint8(DirectLoan.Status.Repaid), "repaid");
            assertEq(module.lenderClaimOf(lender), repayment, "lender claim");
            assertEq(module.borrowerRefundOf(borrower), extra, "excess refund");
            assertEq(module.totalUncommittedDeposits(), 0, "uncommitted cleared");
            assertGe(asset.balanceOf(address(module)), module.totalLiabilities(), "solvent after repay");
        }

        function testFuzz_defaultRefundsPartialDeposit(uint256 partialSeed) public {
            uint256 principal = 100 ether;
            uint256 repayment = 110 ether;
            (uint256 tokenId, uint256 loanId) = _request(principal, repayment);
            vm.prank(lender);
            module.fund(loanId);
            uint256 partialAmt = bound(partialSeed, 1, repayment - 1);
            vm.prank(borrower);
            module.depositRepayment(loanId, partialAmt);
            DirectLoan.Loan memory loan = module.getLoan(loanId);
            vm.warp(loan.deadline + 1);
            vm.prank(lender);
            module.resolveDefault(loanId);
            assertEq(uint8(module.getLoan(loanId).status), uint8(DirectLoan.Status.Defaulted), "defaulted");
            assertEq(module.borrowerRefundOf(borrower), partialAmt, "deposit refunded");
            assertEq(module.lenderClaimOf(lender), 0, "lender gets NFT not cash");
            assertEq(module.totalUncommittedDeposits(), 0, "uncommitted cleared");
            assertGe(asset.balanceOf(address(module)), module.totalLiabilities(), "solvent after default");
            module.claimNft(loanId);
            assertEq(nft.ownerOf(tokenId), lender, "nft to lender");
        }

        function testFuzz_partialWithdrawPreservesSolvency(uint256 firstSeed, uint256 withdrawSeed) public {
            uint256 principal = 100 ether;
            uint256 repayment = 110 ether;
            (, uint256 loanId) = _request(principal, repayment);
            vm.prank(lender);
            module.fund(loanId);
            uint256 first = bound(firstSeed, 2, repayment - 1);
            vm.prank(borrower);
            module.depositRepayment(loanId, first);
            uint256 withdraw = bound(withdrawSeed, 1, first - 1);
            uint256 beforeBal = asset.balanceOf(borrower);
            vm.prank(borrower);
            module.withdrawDeposit(loanId, withdraw);
            assertEq(asset.balanceOf(borrower), beforeBal + withdraw, "withdrawn");
            assertEq(module.getLoan(loanId).deposit, first - withdraw, "deposit left");
            assertEq(module.totalUncommittedDeposits(), first - withdraw, "liability");
            assertGe(asset.balanceOf(address(module)), module.totalLiabilities(), "solvent");
        }
    }
