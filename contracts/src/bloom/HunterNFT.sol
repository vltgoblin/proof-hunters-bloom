// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BasketRegistry} from "./BasketRegistry.sol";

/// @notice Candidate lifecycle boundary; production custody implementation is pending.
/// @dev Calls are atomic with ERC-721 changes and observe the resulting owner state.
/// The fixed implementation must enforce daily accounting and independently verified
/// loan opening/closure. It is not an arbitrary operator or replaceable adapter.
interface IHunterLifecycle {
    function nft() external view returns (address);
    function onMint(uint256 tokenId, address owner, address basket) external;
    function onTransfer(uint256 tokenId, address from, address to) external;
    function onBurn(uint256 tokenId, address beneficiary) external;
}

/// @notice New-deployment NFT lifecycle candidate. Contains no HUNTER reserve.
/// @dev Not a complete vault or lending implementation; lifecycle wiring is immutable.
contract HunterNFT is ERC721, ReentrancyGuard {
    enum Custody {
        OwnerHeld,
        Escrowed,
        CreditLocked
    }

    struct BirthData {
        uint32 artVersion;
        bytes32 proofDigest;
        uint256 challengeId;
        uint8 proofTier;
    }

    error InvalidConfiguration();
    error UnauthorizedMinter();
    error UnauthorizedLifecycle();
    error InvalidBasket(address asset);
    error LifetimeCapReached();
    error NotTokenOwner();
    error TokenNotOwnerHeld();
    error CreditLocked(uint256 tokenId);
    error InvalidPosition();
    error StaleAuthorization();
    error LifecycleReentry();
    error OwnerHasCreditLock();
    error InvalidEscrow();

    uint256 public constant MAX_NFTS_EVER = 5_000;
    uint96 public constant ROYALTY_BPS = 333;
    address public immutable MINER;
    BasketRegistry public immutable REGISTRY;
    IHunterLifecycle public immutable LIFECYCLE;
    uint32 public immutable ART_VERSION;
    address public immutable ROYALTY_RECIPIENT;
    string public BASE_URI;

    uint256 public mintedEver;
    mapping(uint256 => BirthData) public birthData;
    mapping(uint256 => address) public basketOf;
    mapping(uint256 => address) public escrowedTo;
    mapping(uint256 => address) public creditPositionOf;
    mapping(uint256 => uint256) public authorizationNonce;
    mapping(address => uint256) public activeCreditCount;
    bool private _inLifecycle;
    bytes32 private constant _RELEASE_NAMESPACE = keccak256("proof-hunters.HunterNFT.released.v1");

    event CreditOpened(uint256 indexed tokenId, address indexed position, address indexed borrower, uint256 nonce);
    event CreditClosed(uint256 indexed tokenId, address indexed position, uint256 nonce);
    event EscrowEntered(uint256 indexed tokenId, address indexed owner, address indexed holder);
    event EscrowReleased(uint256 indexed tokenId, address indexed holder, address indexed recipient);
    /// @dev Sole post-mint `basketOf` change signal; fired only by the fixed
    /// lifecycle after a successful switch conversion.
    event BasketConverted(uint256 indexed tokenId, address indexed basket, uint256 nonce);

    constructor(address registry, address lifecycle, uint32 artVersion, address royaltyRecipient, string memory baseURI)
        ERC721("Proof Hunters", "HUNTERS")
    {
        if (
            registry.code.length == 0 || lifecycle.code.length == 0 || artVersion != 1 || royaltyRecipient == address(0)
                || royaltyRecipient == address(this) || royaltyRecipient == msg.sender
        ) {
            revert InvalidConfiguration();
        }
        if (IHunterLifecycle(lifecycle).nft() != address(this)) revert InvalidConfiguration();
        MINER = msg.sender;
        REGISTRY = BasketRegistry(registry);
        LIFECYCLE = IHunterLifecycle(lifecycle);
        ART_VERSION = artVersion;
        ROYALTY_RECIPIENT = royaltyRecipient;
        BASE_URI = baseURI;
    }

    function mint(address to, bytes32 digest, uint256 challengeId, uint8 tier, address basket)
        external
        nonReentrant
        returns (uint256 tokenId)
    {
        if (msg.sender != MINER) revert UnauthorizedMinter();
        if (!REGISTRY.isEntryEnabled(basket)) revert InvalidBasket(basket);
        if (tier < 1 || tier > 4) revert InvalidConfiguration();
        if (mintedEver >= MAX_NFTS_EVER) revert LifetimeCapReached();
        tokenId = ++mintedEver;
        birthData[tokenId] = BirthData(ART_VERSION, digest, challengeId, tier);
        basketOf[tokenId] = basket;
        // Same wallet-directed mint behavior as ProofNFT; no receiver call at mint.
        _mint(to, tokenId);
    }

    /// @notice Atomic owner-directed escrow entry with the request payload.
    function escrowTo(uint256 tokenId, address holder, bytes calldata data) external nonReentrant {
        _requireOwnerHeld(tokenId);
        if (holder == msg.sender || holder == address(this) || holder.code.length == 0) revert InvalidEscrow();
        escrowedTo[tokenId] = holder;
        emit EscrowEntered(tokenId, msg.sender, holder);
        _safeTransfer(msg.sender, holder, tokenId, data);
    }

    /// @notice Burn and lifecycle settlement either both complete or both revert.
    function redeemAndDestroy(uint256 tokenId) external nonReentrant {
        _requireOwnerHeld(tokenId);
        _burn(tokenId);
    }

    /// @dev Only the fixed lifecycle may call after independently verifying a real
    /// atomic loan. This function supplies no token allowance or export authority.
    function lockCredit(uint256 tokenId, address position, address borrower, uint256 expectedNonce) external {
        _requireLifecycle();
        if (_requireOwned(tokenId) != borrower || authorizationNonce[tokenId] != expectedNonce) {
            revert StaleAuthorization();
        }
        if (isEncumbered(tokenId)) revert TokenNotOwnerHeld();
        if (position == address(this) || position == address(LIFECYCLE) || position.code.length == 0) {
            revert InvalidPosition();
        }
        creditPositionOf[tokenId] = position;
        activeCreditCount[borrower] += 1;
        _approve(address(0), tokenId, address(0));
        uint256 nonce = ++authorizationNonce[tokenId];
        emit CreditOpened(tokenId, position, borrower, nonce);
    }

    /// @dev Lifecycle must verify protocol debt and restore collateral first. No
    /// position-supplied callback, boolean, or reported debt can call this directly.
    function unlockCredit(uint256 tokenId, address position, uint256 expectedNonce) external {
        _requireLifecycle();
        if (position == address(0) || creditPositionOf[tokenId] != position) revert InvalidPosition();
        if (authorizationNonce[tokenId] != expectedNonce) revert StaleAuthorization();
        address borrower = _requireOwned(tokenId);
        delete creditPositionOf[tokenId];
        activeCreditCount[borrower] -= 1;
        uint256 nonce = ++authorizationNonce[tokenId];
        emit CreditClosed(tokenId, position, nonce);
    }

    /// @notice Sole post-mint `basketOf` writer, callable only by the fixed
    /// lifecycle after its authenticated switch conversion settles.
    /// @dev Writes `basketOf` directly — never `_update`, never a transfer and
    /// never a lifecycle transfer hook — so no owner/operator approval path or
    /// history side effect exists here. Requires the token live and
    /// owner-held (unencumbered) plus the exact expected authorization nonce;
    /// the nonce increments so a stale caller cannot repeat the write. No
    /// owner, operator or administrator may call it: only LIFECYCLE.
    function setConvertedBasket(uint256 tokenId, address basket, uint256 expectedNonce) external {
        _requireLifecycle();
        _requireOwned(tokenId);
        if (basket == address(0)) revert InvalidBasket(basket);
        if (isEncumbered(tokenId)) revert TokenNotOwnerHeld();
        if (authorizationNonce[tokenId] != expectedNonce) revert StaleAuthorization();
        basketOf[tokenId] = basket;
        uint256 nonce = ++authorizationNonce[tokenId];
        emit BasketConverted(tokenId, basket, nonce);
    }

    function approve(address to, uint256 tokenId) public override {
        _requireOutsideLifecycle();
        if (creditPositionOf[tokenId] != address(0)) revert CreditLocked(tokenId);
        super.approve(to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) public override {
        _requireOutsideLifecycle();
        if (approved && activeCreditCount[msg.sender] != 0) revert OwnerHasCreditLock();
        super.setApprovalForAll(operator, approved);
    }

    function isEncumbered(uint256 tokenId) public view returns (bool) {
        return escrowedTo[tokenId] != address(0) || creditPositionOf[tokenId] != address(0);
    }

    function custody(uint256 tokenId) external view returns (Custody) {
        _requireOwned(tokenId);
        if (creditPositionOf[tokenId] != address(0)) return Custody.CreditLocked;
        if (escrowedTo[tokenId] != address(0)) return Custody.Escrowed;
        return Custody.OwnerHeld;
    }

    function wasReleasedThisTransaction(uint256 tokenId) external view returns (bool released) {
        bytes32 slot = keccak256(abi.encode(_RELEASE_NAMESPACE, tokenId));
        assembly ("memory-safe") { released := tload(slot) }
    }

    function royaltyInfo(uint256, uint256 salePrice) external view returns (address, uint256) {
        return (ROYALTY_RECIPIENT, Math.mulDiv(salePrice, ROYALTY_BPS, 10_000));
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == 0x2a55205a || super.supportsInterface(interfaceId);
    }

    function _baseURI() internal view override returns (string memory) {
        return BASE_URI;
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address from) {
        _requireOutsideLifecycle();
        if (creditPositionOf[tokenId] != address(0)) revert CreditLocked(tokenId);
        from = super._update(to, tokenId, auth);
        authorizationNonce[tokenId] += 1;
        if (escrowedTo[tokenId] != address(0) && to != escrowedTo[tokenId]) {
            address holder = escrowedTo[tokenId];
            delete escrowedTo[tokenId];
            bytes32 slot = keccak256(abi.encode(_RELEASE_NAMESPACE, tokenId));
            assembly ("memory-safe") { tstore(slot, 1) }
            emit EscrowReleased(tokenId, holder, to);
        }
        _inLifecycle = true;
        if (from == address(0)) LIFECYCLE.onMint(tokenId, to, basketOf[tokenId]);
        else if (to == address(0)) LIFECYCLE.onBurn(tokenId, from);
        else LIFECYCLE.onTransfer(tokenId, from, to);
        _inLifecycle = false;
    }

    function _requireOwnerHeld(uint256 tokenId) private view {
        _requireOutsideLifecycle();
        if (_requireOwned(tokenId) != msg.sender) revert NotTokenOwner();
        if (isEncumbered(tokenId)) revert TokenNotOwnerHeld();
    }

    function _requireLifecycle() private view {
        if (msg.sender != address(LIFECYCLE)) revert UnauthorizedLifecycle();
        _requireOutsideLifecycle();
    }

    function _requireOutsideLifecycle() private view {
        if (_inLifecycle) revert LifecycleReentry();
    }
}
