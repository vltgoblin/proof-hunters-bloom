// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {HunterNFT} from "./HunterNFT.sol";

/// @title DirectLoan — whole-Hunter NFT fixed-term loans (M3.2 first slice)
/// @notice Holds the NFT via `HunterNFT.escrowTo`. Never moves basket backing.
///         Fee bps/cap/recipient and loan asset are deployment inputs — production
///         values are NOT selected here (forge/Anvil placeholders only).
/// @dev Local Anvil / forge evidence only. No Morpho, no Robinhood broadcast,
///      no launch or yield claims.
contract DirectLoan is IERC721Receiver, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error InvalidConfiguration();
    error UnauthorizedNft(address caller);
    error EntryStopped();
    error UnauthorizedStopCaller(address caller);
    error EntryAlreadyStopped();
    error OperatorMustBeOwner(address operator, address from);
    error TokenReleasedThisTransaction(uint256 tokenId);
    error EscrowMismatch(uint256 tokenId, address expected, address actual);
    error UnsupportedTermsVersion(uint256 version);
    error InvalidTerms();
    error PrincipalOutOfBounds(uint256 principal);
    error DurationOutOfBounds(uint256 duration);
    error ZeroNetProceeds(uint256 principal, uint256 fee);
    error LoanDoesNotExist(uint256 loanId);
    error InvalidLoanStatus(uint256 loanId, Status actual);
    error NotBorrower(address caller, address borrower);
    error FundingWindowClosed(uint256 loanId);
    error LoanAlreadyActiveForToken(uint256 tokenId);
    error SelfFunding(address account);
    error RepaymentWindowClosed(uint256 loanId);
    error NothingToWithdraw(uint256 loanId);
    error DefaultNotReady(uint256 loanId);
    error UnauthorizedDefaultResolver(address caller);
    error NftAlreadyClaimed(uint256 loanId);
    error NothingToClaim(address account);
    error Insolvency(uint256 balance, uint256 liabilities);

    enum Status {
        None,
        Requested,
        Cancelled,
        Funded,
        Repaid,
        Defaulted
    }

    /// @dev Escrow callback payload. Borrower is NEVER read from this struct.
    struct Terms {
        uint256 version;
        uint256 principal;
        uint256 repayment;
        uint256 duration;
    }

    /// @dev Constructor bundle (avoids stack-too-deep).
    struct Config {
        address nft;
        address loanAsset;
        address feeRecipient;
        address stopAuthority;
        uint256 feeBps;
        uint256 feeCap;
        uint256 minPrincipal;
        uint256 maxPrincipal;
        uint256 minDuration;
        uint256 maxDuration;
        uint256 requestFundingWindow;
        uint256 defaultResolutionWindow;
    }

    struct Loan {
        uint256 id;
        uint256 tokenId;
        address borrower;
        address lender;
        uint256 principal;
        uint256 repayment;
        uint256 duration;
        uint256 requestedAt;
        uint256 fundedAt;
        uint256 deadline;
        uint256 deposit;
        Status status;
        bool nftClaimed;
    }

    struct Bounds {
        uint128 minPrincipal;
        uint128 maxPrincipal;
        uint64 minDuration;
        uint64 maxDuration;
        uint64 requestFundingWindow;
        uint64 defaultResolutionWindow;
    }

    uint256 public constant TERMS_VERSION = 1;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_FEE_BPS = 2_000;

    HunterNFT public immutable NFT;
    IERC20 public immutable LOAN_ASSET;
    address public immutable FEE_RECIPIENT;
    address public immutable STOP_AUTHORITY;
    /// @notice Test/deploy placeholder — not a launch fee rate.
    uint256 public immutable FEE_BPS;
    /// @notice 0 means no separate cap. Does not mean zero fee when FEE_BPS > 0.
    uint256 public immutable FEE_CAP;

    Bounds public bounds;
    uint256 public nextLoanId = 1;
    bool public entryStopped;

    mapping(uint256 => Loan) internal loans;
    mapping(uint256 => uint256) public loanIdByToken;

    uint256 public totalUncommittedDeposits;
    uint256 public totalLenderClaims;
    uint256 public totalBorrowerRefunds;
    uint256 public totalFeeCredits;

    mapping(address => uint256) public lenderClaimOf;
    mapping(address => uint256) public borrowerRefundOf;
    mapping(address => uint256) public feeCreditOf;

    event LoanRequested(
        uint256 indexed loanId,
        uint256 indexed tokenId,
        address indexed borrower,
        uint256 principal,
        uint256 repayment,
        uint256 duration
    );
    event LoanCancelled(uint256 indexed loanId, uint256 indexed tokenId, address indexed borrower);
    event LoanFunded(
        uint256 indexed loanId,
        address indexed lender,
        uint256 principal,
        uint256 fee,
        uint256 netProceeds,
        uint256 deadline
    );
    event RepaymentDeposited(uint256 indexed loanId, address indexed borrower, uint256 amount, uint256 depositTotal);
    event RepaymentWithdrawn(uint256 indexed loanId, address indexed borrower, uint256 amount);
    event LoanRepaid(uint256 indexed loanId, uint256 indexed tokenId, uint256 repayment, uint256 excess);
    event LoanDefaulted(
        uint256 indexed loanId, uint256 indexed tokenId, address indexed lender, uint256 refundedDeposit
    );
    event NftClaimed(uint256 indexed loanId, uint256 indexed tokenId, address indexed to);
    event AssetClaimed(address indexed account, uint256 amount, bytes32 kind);
    event EntryStopActivated(address indexed caller);

    constructor(Config memory cfg) {
        if (
            cfg.nft.code.length == 0 || cfg.loanAsset.code.length == 0 || cfg.feeRecipient == address(0)
                || cfg.stopAuthority == address(0) || cfg.feeBps > MAX_FEE_BPS || cfg.minPrincipal == 0
                || cfg.maxPrincipal < cfg.minPrincipal || cfg.minDuration == 0 || cfg.maxDuration < cfg.minDuration
                || cfg.requestFundingWindow == 0 || cfg.defaultResolutionWindow == 0
        ) {
            revert InvalidConfiguration();
        }

        if (cfg.feeBps != 0) {
            uint256 raw = Math.mulDiv(cfg.minPrincipal, cfg.feeBps, BPS_DENOMINATOR);
            uint256 fee = cfg.feeCap == 0 ? raw : Math.min(raw, cfg.feeCap);
            if (cfg.minPrincipal <= fee) revert InvalidConfiguration();
        }

        NFT = HunterNFT(cfg.nft);
        LOAN_ASSET = IERC20(cfg.loanAsset);
        FEE_RECIPIENT = cfg.feeRecipient;
        STOP_AUTHORITY = cfg.stopAuthority;
        FEE_BPS = cfg.feeBps;
        FEE_CAP = cfg.feeCap;
        bounds = Bounds({
            minPrincipal: uint128(cfg.minPrincipal),
            maxPrincipal: uint128(cfg.maxPrincipal),
            minDuration: uint64(cfg.minDuration),
            maxDuration: uint64(cfg.maxDuration),
            requestFundingWindow: uint64(cfg.requestFundingWindow),
            defaultResolutionWindow: uint64(cfg.defaultResolutionWindow)
        });
    }

    function quoteFee(uint256 principal) public view returns (uint256 fee, uint256 net) {
        uint256 raw = Math.mulDiv(principal, FEE_BPS, BPS_DENOMINATOR);
        fee = FEE_CAP == 0 ? raw : Math.min(raw, FEE_CAP);
        if (principal <= fee) revert ZeroNetProceeds(principal, fee);
        net = principal - fee;
    }

    function totalLiabilities() public view returns (uint256) {
        return totalUncommittedDeposits + totalLenderClaims + totalBorrowerRefunds + totalFeeCredits;
    }

    function getLoan(uint256 loanId) external view returns (Loan memory) {
        return loans[loanId];
    }

    function stopEntry() external {
        if (msg.sender != STOP_AUTHORITY) revert UnauthorizedStopCaller(msg.sender);
        if (entryStopped) revert EntryAlreadyStopped();
        entryStopped = true;
        emit EntryStopActivated(msg.sender);
    }

    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        override
        nonReentrant
        returns (bytes4)
    {
        if (msg.sender != address(NFT)) revert UnauthorizedNft(msg.sender);
        if (entryStopped) revert EntryStopped();
        if (operator != from) revert OperatorMustBeOwner(operator, from);
        if (from == address(0)) revert InvalidTerms();
        if (NFT.wasReleasedThisTransaction(tokenId)) revert TokenReleasedThisTransaction(tokenId);
        if (NFT.escrowedTo(tokenId) != address(this)) {
            revert EscrowMismatch(tokenId, address(this), NFT.escrowedTo(tokenId));
        }
        if (loanIdByToken[tokenId] != 0) revert LoanAlreadyActiveForToken(tokenId);

        Terms memory t = abi.decode(data, (Terms));
        _validateTerms(t);

        uint256 loanId = nextLoanId++;
        Loan storage loan = loans[loanId];
        loan.id = loanId;
        loan.tokenId = tokenId;
        loan.borrower = from;
        loan.principal = t.principal;
        loan.repayment = t.repayment;
        loan.duration = t.duration;
        // forge-lint: disable-next-line(block-timestamp)
        loan.requestedAt = block.timestamp;
        loan.status = Status.Requested;
        loanIdByToken[tokenId] = loanId;

        emit LoanRequested(loanId, tokenId, from, t.principal, t.repayment, t.duration);
        return IERC721Receiver.onERC721Received.selector;
    }

    function cancel(uint256 loanId) external nonReentrant {
        Loan storage loan = _loan(loanId);
        if (loan.status != Status.Requested) revert InvalidLoanStatus(loanId, loan.status);
        if (msg.sender != loan.borrower) revert NotBorrower(msg.sender, loan.borrower);

        loan.status = Status.Cancelled;
        delete loanIdByToken[loan.tokenId];
        emit LoanCancelled(loanId, loan.tokenId, loan.borrower);
        NFT.transferFrom(address(this), loan.borrower, loan.tokenId);
    }

    function fund(uint256 loanId) external nonReentrant {
        if (entryStopped) revert EntryStopped();
        Loan storage loan = _loan(loanId);
        if (loan.status != Status.Requested) revert InvalidLoanStatus(loanId, loan.status);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > loan.requestedAt + bounds.requestFundingWindow) {
            revert FundingWindowClosed(loanId);
        }
        if (msg.sender == loan.borrower) revert SelfFunding(msg.sender);
        if (NFT.ownerOf(loan.tokenId) != address(this) || NFT.escrowedTo(loan.tokenId) != address(this)) {
            revert EscrowMismatch(loan.tokenId, address(this), NFT.escrowedTo(loan.tokenId));
        }

        (uint256 fee, uint256 net) = quoteFee(loan.principal);
        loan.status = Status.Funded;
        loan.lender = msg.sender;
        // forge-lint: disable-next-line(block-timestamp)
        loan.fundedAt = block.timestamp;
        // forge-lint: disable-next-line(block-timestamp)
        loan.deadline = block.timestamp + loan.duration;

        LOAN_ASSET.safeTransferFrom(msg.sender, address(this), loan.principal);
        LOAN_ASSET.safeTransfer(loan.borrower, net);
        if (fee != 0) {
            feeCreditOf[FEE_RECIPIENT] += fee;
            totalFeeCredits += fee;
        }
        _assertSolvent();
        emit LoanFunded(loanId, msg.sender, loan.principal, fee, net, loan.deadline);
    }

    function depositRepayment(uint256 loanId, uint256 amount) external nonReentrant {
        Loan storage loan = _loan(loanId);
        if (loan.status != Status.Funded) revert InvalidLoanStatus(loanId, loan.status);
        if (msg.sender != loan.borrower) revert NotBorrower(msg.sender, loan.borrower);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > loan.deadline) revert RepaymentWindowClosed(loanId);
        if (amount == 0) revert InvalidTerms();

        LOAN_ASSET.safeTransferFrom(msg.sender, address(this), amount);
        loan.deposit += amount;
        totalUncommittedDeposits += amount;
        emit RepaymentDeposited(loanId, msg.sender, amount, loan.deposit);

        if (loan.deposit >= loan.repayment) _completeRepayment(loan);
        _assertSolvent();
    }

    function withdrawDeposit(uint256 loanId, uint256 amount) external nonReentrant {
        Loan storage loan = _loan(loanId);
        if (loan.status != Status.Funded) revert InvalidLoanStatus(loanId, loan.status);
        if (msg.sender != loan.borrower) revert NotBorrower(msg.sender, loan.borrower);
        if (amount == 0 || amount > loan.deposit) revert NothingToWithdraw(loanId);

        loan.deposit -= amount;
        totalUncommittedDeposits -= amount;
        LOAN_ASSET.safeTransfer(msg.sender, amount);
        emit RepaymentWithdrawn(loanId, msg.sender, amount);
        _assertSolvent();
    }

    function claimNft(uint256 loanId) external nonReentrant {
        Loan storage loan = _loan(loanId);
        if (loan.nftClaimed) revert NftAlreadyClaimed(loanId);
        address to;
        if (loan.status == Status.Repaid) to = loan.borrower;
        else if (loan.status == Status.Defaulted) to = loan.lender;
        else revert InvalidLoanStatus(loanId, loan.status);

        loan.nftClaimed = true;
        if (loanIdByToken[loan.tokenId] == loanId) delete loanIdByToken[loan.tokenId];
        emit NftClaimed(loanId, loan.tokenId, to);
        NFT.transferFrom(address(this), to, loan.tokenId);
    }

    function claimLender(address account) external nonReentrant {
        uint256 amount = lenderClaimOf[account];
        if (amount == 0) revert NothingToClaim(account);
        lenderClaimOf[account] = 0;
        totalLenderClaims -= amount;
        LOAN_ASSET.safeTransfer(account, amount);
        emit AssetClaimed(account, amount, bytes32("lender"));
        _assertSolvent();
    }

    function claimBorrowerRefund(address account) external nonReentrant {
        uint256 amount = borrowerRefundOf[account];
        if (amount == 0) revert NothingToClaim(account);
        borrowerRefundOf[account] = 0;
        totalBorrowerRefunds -= amount;
        LOAN_ASSET.safeTransfer(account, amount);
        emit AssetClaimed(account, amount, bytes32("borrowerRefund"));
        _assertSolvent();
    }

    function claimFee(address account) external nonReentrant {
        uint256 amount = feeCreditOf[account];
        if (amount == 0) revert NothingToClaim(account);
        uint256 bal = LOAN_ASSET.balanceOf(address(this));
        uint256 userLiab = totalUncommittedDeposits + totalLenderClaims + totalBorrowerRefunds;
        if (account == FEE_RECIPIENT && bal < userLiab + amount) revert Insolvency(bal, userLiab + amount);
        feeCreditOf[account] = 0;
        totalFeeCredits -= amount;
        LOAN_ASSET.safeTransfer(account, amount);
        emit AssetClaimed(account, amount, bytes32("fee"));
        _assertSolvent();
    }

    function resolveDefault(uint256 loanId) external nonReentrant {
        Loan storage loan = _loan(loanId);
        if (loan.status != Status.Funded) revert InvalidLoanStatus(loanId, loan.status);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= loan.deadline) revert DefaultNotReady(loanId);
        // forge-lint: disable-next-line(block-timestamp)
        uint256 publicAfter = loan.deadline + bounds.defaultResolutionWindow;
        // forge-lint: disable-next-line(block-timestamp)
        if (msg.sender != loan.lender && block.timestamp <= publicAfter) {
            revert UnauthorizedDefaultResolver(msg.sender);
        }

        uint256 refund = loan.deposit;
        if (refund != 0) {
            loan.deposit = 0;
            totalUncommittedDeposits -= refund;
            borrowerRefundOf[loan.borrower] += refund;
            totalBorrowerRefunds += refund;
        }
        loan.status = Status.Defaulted;
        emit LoanDefaulted(loanId, loan.tokenId, loan.lender, refund);
        _assertSolvent();
    }

    function _completeRepayment(Loan storage loan) private {
        uint256 deposit = loan.deposit;
        uint256 repayment = loan.repayment;
        uint256 excess = deposit - repayment;
        loan.deposit = 0;
        totalUncommittedDeposits -= deposit;
        lenderClaimOf[loan.lender] += repayment;
        totalLenderClaims += repayment;
        if (excess != 0) {
            borrowerRefundOf[loan.borrower] += excess;
            totalBorrowerRefunds += excess;
        }
        loan.status = Status.Repaid;
        emit LoanRepaid(loan.id, loan.tokenId, repayment, excess);
    }

    function _validateTerms(Terms memory t) private view {
        if (t.version != TERMS_VERSION) revert UnsupportedTermsVersion(t.version);
        if (t.repayment < t.principal) revert InvalidTerms();
        if (t.principal < bounds.minPrincipal || t.principal > bounds.maxPrincipal) {
            revert PrincipalOutOfBounds(t.principal);
        }
        if (t.duration < bounds.minDuration || t.duration > bounds.maxDuration) {
            revert DurationOutOfBounds(t.duration);
        }
        quoteFee(t.principal);
    }

    function _loan(uint256 loanId) private view returns (Loan storage loan) {
        loan = loans[loanId];
        if (loan.id == 0 || loan.id != loanId) revert LoanDoesNotExist(loanId);
    }

    function _assertSolvent() private view {
        uint256 bal = LOAN_ASSET.balanceOf(address(this));
        uint256 liab = totalLiabilities();
        if (bal < liab) revert Insolvency(bal, liab);
    }
}
