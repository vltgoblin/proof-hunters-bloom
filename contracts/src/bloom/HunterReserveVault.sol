// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {HunterNFT, IHunterLifecycle} from "./HunterNFT.sol";

/// @notice Reserve boundary required from the fixed HunterNFT lifecycle.
/// @dev The future production lifecycle authenticates calls from this immutable
/// reserve, reads actual credited current/history state and checkpoints reward
/// weight. Test-only fixtures may implement it meanwhile; this interface is not
/// a claim that a production controller exists.
interface IHunterReserveLifecycle is IHunterLifecycle {
    function reserve() external view returns (address);
    function onReserveChanged(uint256 tokenId) external;
}

/// @title HunterReserveVault
/// @notice Per-NFT credited HUNTER reserve with atomic burn payout.
/// @dev New-deployment CANDIDATE, not a fully wired production lifecycle and not
/// a production-complete lifecycle claim. Atomic burn payout is the normal path
/// under test; recovery for transfer-blocking tokens is an unresolved launch
/// gate, so there is deliberately no admin exit, sweep, export, generic call,
/// live claim or burn/pull fallback. NFT and LIFECYCLE wiring is immutable and
/// revalidated by a wiring guard on every operational call. HUNTER is different:
/// the reserve deploys BEFORE the token exists; the fixed launch authority
/// records the canonical token exactly once via `activateToken` and it can never
/// be replaced or cleared afterward. Until activation, deposits are refused and
/// every read/exit path stays token-call-free. The reserve is never revenue;
/// live-balance excess (donations or other unsolicited receipt) is never
/// credited or distributed. Credits track actual receipt only, independent of
/// external balances.
contract HunterReserveVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Checkpoint {
        uint256 timestamp;
        uint256 amount;
    }

    error InvalidConfiguration();
    error WiringMismatch();
    error UnauthorizedLifecycle();
    error NotTokenOwner();
    error TokenEncumbered(uint256 tokenId);
    error AlreadySettled(uint256 tokenId);
    error InvalidAmount();
    error UnsupportedTokenReceipt();
    error StaleAuthorization();
    error Insolvency();
    error FutureCutoff();
    error InvalidTokenId();
    error TokenNotBurned(uint256 tokenId);
    error InvalidBeneficiary();
    error DebitMismatch();
    error TokenNotActivated();
    error TokenAlreadyActivated();
    error InvalidToken();
    error UnauthorizedTokenAuthority(address caller);

    /// @dev The canonical token is recorded once by `activateToken`; zero until
    /// then. Storage is deliberately not immutable — the immutable-after-set
    /// invariant is enforced by the one-time setter, and the public `HUNTER()`
    /// getter below keeps the read surface identical to before.
    IERC20 private _hunter;
    HunterNFT public immutable NFT;
    IHunterReserveLifecycle public immutable LIFECYCLE;
    /// @dev Sole account allowed to record the canonical token once. It can
    /// never withdraw reserves, rewrite histories or choose allocations.
    address public immutable TOKEN_AUTHORITY;

    mapping(uint256 => uint256) public reserveOf;
    mapping(uint256 => bool) public settled;
    mapping(uint256 => Checkpoint[]) public history;
    uint256 public totalReserved;

    event Deposited(uint256 indexed tokenId, address indexed owner, uint256 requested, uint256 credited);
    event BurnSettled(uint256 indexed tokenId, address indexed beneficiary, uint256 gross);
    event TokenActivated(address indexed token, address indexed authority);

    /// @param expectedNft May be a predicted, not-yet-deployed HunterNFT address
    /// (the current NFT constructor itself requires a predeployed lifecycle), so
    /// NFT code size is enforced by the wiring guard, not here. The lifecycle
    /// must already precompute and expose both `nft()` and `reserve()`.
    /// @param tokenAuthority The sole launch account that may later call
    /// `activateToken` once. No token is recorded at construction: the reserve
    /// deploys before HUNTER exists.
    constructor(address expectedNft, address lifecycle, address tokenAuthority) {
        if (
            expectedNft == address(0) || lifecycle == address(0) || tokenAuthority == address(0)
                || expectedNft == lifecycle || expectedNft == address(this) || lifecycle == address(this)
                || tokenAuthority == address(this)
        ) {
            revert InvalidConfiguration();
        }
        if (lifecycle.code.length == 0) revert InvalidConfiguration();
        IHunterReserveLifecycle lc = IHunterReserveLifecycle(lifecycle);
        if (lc.nft() != expectedNft || lc.reserve() != address(this)) revert InvalidConfiguration();
        NFT = HunterNFT(expectedNft);
        LIFECYCLE = lc;
        TOKEN_AUTHORITY = tokenAuthority;
    }

    /// @notice The canonical HUNTER token; `address(0)` until the one-time
    /// `activateToken` recording. Read-compatible with the previous immutable.
    function HUNTER() external view returns (IERC20) {
        return _hunter;
    }

    /// @notice Whether the canonical token has been recorded.
    function tokenActivated() external view returns (bool) {
        return address(_hunter) != address(0);
    }

    /// @notice Records the canonical HUNTER token address exactly once. Only
    /// the fixed launch authority may call it; after success the token is
    /// immutable forever — no replacement or clearing path exists for anyone,
    /// including a future multisig.
    /// @dev Checks: caller is TOKEN_AUTHORITY, token still unset, nonzero and
    /// distinct from the wired contracts, deployed code present, and an ERC-20
    /// surface probe (`totalSupply` + a `balanceOf` self-read) must decode.
    /// Code presence and the probe are NOT proof of token safety or Pons
    /// provenance — the launch review remains the real compatibility gate.
    /// `totalReserved` is always zero here because deposits cannot run before
    /// activation; a nonzero read would be an accounting break, never waived.
    function activateToken(address token) external nonReentrant {
        if (msg.sender != TOKEN_AUTHORITY) revert UnauthorizedTokenAuthority(msg.sender);
        if (address(_hunter) != address(0)) revert TokenAlreadyActivated();
        if (
            token == address(0) || token == address(this) || token == address(NFT) || token == address(LIFECYCLE)
                || token == TOKEN_AUTHORITY || token.code.length == 0
        ) {
            revert InvalidToken();
        }
        try IERC20(token).totalSupply() returns (uint256) {}
        catch {
            revert InvalidToken();
        }
        try IERC20(token).balanceOf(address(this)) returns (uint256) {}
        catch {
            revert InvalidToken();
        }
        if (totalReserved != 0) revert Insolvency();
        _hunter = IERC20(token);
        emit TokenActivated(token, msg.sender);
    }

    /// @notice Pull `requested` HUNTER from the live unencumbered token owner and
    /// credit the NFT reserve by the actual received amount. No user-supplied
    /// owner, recipient or credited amount exists. Reverts `TokenNotActivated`
    /// until the canonical token is recorded — a pre-token deposit can never
    /// create a reserve or a claim liability.
    function deposit(uint256 tokenId, uint256 requested) external nonReentrant returns (uint256 actualReceived) {
        _requireWired();
        IERC20 token = _hunter;
        if (address(token) == address(0)) revert TokenNotActivated();
        if (requested == 0) revert InvalidAmount();
        if (settled[tokenId]) revert AlreadySettled(tokenId);
        address owner = NFT.ownerOf(tokenId);
        if (owner != msg.sender) revert NotTokenOwner();
        if (NFT.isEncumbered(tokenId)) revert TokenEncumbered(tokenId);
        uint256 nonce = NFT.authorizationNonce(tokenId);

        uint256 balBefore = token.balanceOf(address(this));
        if (balBefore < totalReserved) revert Insolvency();

        token.safeTransferFrom(msg.sender, address(this), requested);
        actualReceived = token.balanceOf(address(this)) - balBefore;
        if (actualReceived == 0 || actualReceived > requested) revert UnsupportedTokenReceipt();

        _requireUnchanged(tokenId, owner, nonce);

        uint256 credited = reserveOf[tokenId] + actualReceived;
        reserveOf[tokenId] = credited;
        totalReserved += actualReceived;
        _checkpoint(tokenId, credited);
        emit Deposited(tokenId, owner, requested, actualReceived);

        LIFECYCLE.onReserveChanged(tokenId);

        _requireUnchanged(tokenId, owner, nonce);
        if (token.balanceOf(address(this)) < totalReserved) revert Insolvency();
    }

    /// @notice Atomic gross payout on NFT burn, callable only by the fixed
    /// lifecycle from its authenticated onBurn path. `beneficiary` originates
    /// solely from that hook: the NFT hook observes destroyed state, so no
    /// current-owner check is possible or required. No onReserveChanged call is
    /// made here — the lifecycle is already executing the burn and must read
    /// `settled`/checkpoints atomically rather than be reentered. `gross` labels
    /// the debited amount; recipient-side token tax is never promised away.
    function settleBurn(uint256 tokenId, address beneficiary) external nonReentrant {
        if (msg.sender != address(LIFECYCLE)) revert UnauthorizedLifecycle();
        _requireWired();
        if (tokenId == 0 || tokenId > NFT.mintedEver()) revert InvalidTokenId();
        if (beneficiary == address(0) || beneficiary == address(this)) revert InvalidBeneficiary();
        if (settled[tokenId]) revert AlreadySettled(tokenId);
        try NFT.ownerOf(tokenId) returns (address) {
            revert TokenNotBurned(tokenId);
        } catch {}

        IERC20 token = _hunter;
        uint256 gross = reserveOf[tokenId];
        uint256 balBefore;
        if (address(token) == address(0)) {
            // No token was ever recordable, so no reserve could have been
            // credited: a nonzero liability here is an accounting break and
            // must NOT be silently bypassed by the inactive-token branch.
            if (gross != 0 || totalReserved != 0) revert Insolvency();
        } else {
            balBefore = token.balanceOf(address(this));
            if (balBefore < totalReserved) revert Insolvency();
        }

        settled[tokenId] = true;
        delete reserveOf[tokenId];
        totalReserved -= gross;
        _checkpoint(tokenId, 0);
        emit BurnSettled(tokenId, beneficiary, gross);

        if (address(token) == address(0)) return; // zero-reserve settle: no ERC-20 call to address zero
        if (gross != 0) token.safeTransfer(beneficiary, gross);
        uint256 balAfter = token.balanceOf(address(this));
        if (balBefore - balAfter != gross) revert DebitMismatch();
        if (balAfter < totalReserved) revert Insolvency();
    }

    /// @notice Credited reserve of `tokenId` at the last checkpoint STRICTLY
    /// before `cutoff`; 0 before the first checkpoint. Burned ids are valid
    /// historical queries; zero or never-minted ids are not.
    function reserveBefore(uint256 tokenId, uint256 cutoff) external view returns (uint256) {
        _requireWired();
        if (cutoff > block.timestamp) revert FutureCutoff();
        if (tokenId == 0 || tokenId > NFT.mintedEver()) revert InvalidTokenId();
        Checkpoint[] storage h = history[tokenId];
        uint256 lo;
        uint256 hi = h.length;
        while (lo < hi) {
            uint256 mid = lo + (hi - lo) / 2;
            if (h[mid].timestamp < cutoff) lo = mid + 1;
            else hi = mid;
        }
        return lo == 0 ? 0 : h[lo - 1].amount;
    }

    function historyLength(uint256 tokenId) external view returns (uint256) {
        return history[tokenId].length;
    }

    /// @notice Live balance above credited reserves (donations/excess). Never
    /// credited or distributed; reverts on insolvency rather than narrowing.
    /// Before token activation there is no balance to read: zero liability
    /// returns 0 and a nonzero one is an impossible accounting break.
    function unreservedBalance() external view returns (uint256) {
        IERC20 token = _hunter;
        if (address(token) == address(0)) {
            if (totalReserved != 0) revert Insolvency();
            return 0;
        }
        uint256 bal = token.balanceOf(address(this));
        if (bal < totalReserved) revert Insolvency();
        return bal - totalReserved;
    }

    function _requireWired() internal view {
        if (
            address(NFT).code.length == 0 || address(NFT.LIFECYCLE()) != address(LIFECYCLE)
                || LIFECYCLE.nft() != address(NFT) || LIFECYCLE.reserve() != address(this)
        ) {
            revert WiringMismatch();
        }
    }

    /// @dev Cross-contract race defense, not merely a token callback guard: the
    /// NFT must keep the same owner, authorization nonce and unencumbered status
    /// after the token transfer and again after the lifecycle hook.
    function _requireUnchanged(uint256 tokenId, address owner, uint256 nonce) private view {
        if (NFT.ownerOf(tokenId) != owner || NFT.authorizationNonce(tokenId) != nonce || NFT.isEncumbered(tokenId)) {
            revert StaleAuthorization();
        }
    }

    function _checkpoint(uint256 tokenId, uint256 amount) private {
        Checkpoint[] storage h = history[tokenId];
        uint256 len = h.length;
        if (len != 0 && h[len - 1].timestamp == block.timestamp) h[len - 1].amount = amount;
        else h.push(Checkpoint({timestamp: block.timestamp, amount: amount}));
    }
}
