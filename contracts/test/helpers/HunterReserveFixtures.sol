// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {HunterReserveVault, IHunterReserveLifecycle} from "../../src/bloom/HunterReserveVault.sol";
import {HunterNFT} from "../../src/bloom/HunterNFT.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

/// @notice TEST-ONLY lifecycle stand-in. NOT production: no real loan
/// verification; predicted positional addresses handled in the test file.
contract ReserveLifecycleFixture is IHunterReserveLifecycle {
    error NotNft();
    error NotVault();
    error CheckpointFailed();
    error BurnFailed();

    address public immutable nft;
    address public immutable reserve;
    bool public failCheckpoint;
    bool public failBurn;

    constructor(address expectedNft, address expectedReserve) {
        nft = expectedNft;
        reserve = expectedReserve;
    }

    /// @dev TEST-ONLY flag setter to exercise vault/NFT rollback paths.
    function setFailures(bool checkpoint, bool burn) external {
        failCheckpoint = checkpoint;
        failBurn = burn;
    }

    function onMint(uint256, address, address) external view {
        if (msg.sender != nft) revert NotNft();
        if (failCheckpoint) revert CheckpointFailed();
    }

    function onTransfer(uint256, address, address) external view {
        if (msg.sender != nft) revert NotNft();
        if (failCheckpoint) revert CheckpointFailed();
    }

    function onBurn(uint256 tokenId, address beneficiary) external {
        if (msg.sender != nft) revert NotNft();
        if (failBurn) revert BurnFailed();
        HunterReserveVault(reserve).settleBurn(tokenId, beneficiary);
    }

    function onReserveChanged(uint256) external view {
        if (msg.sender != reserve) revert NotVault();
        if (failCheckpoint) revert CheckpointFailed();
    }

    /// @dev TEST-ONLY: forwards credit calls, no loan verification.
    function openCredit(uint256 tokenId, address position, address borrower, uint256 nonce) external {
        HunterNFT(nft).lockCredit(tokenId, position, borrower, nonce);
    }

    function closeCredit(uint256 tokenId, address position, uint256 nonce) external {
        HunterNFT(nft).unlockCredit(tokenId, position, nonce);
    }

    /// @dev TEST-ONLY authority bypass: settleBurn outside a real burn.
    function forceSettle(uint256 tokenId, address beneficiary) external {
        HunterReserveVault(reserve).settleBurn(tokenId, beneficiary);
    }
}

/// @notice TEST-ONLY HUNTER stand-in. NOT production: open mint plus
/// configurable failure/tax/callback switches to exercise vault edge cases.
contract ReserveTokenFixture is ERC20 {
    error BadTax();
    error InboundBlocked();
    error OutboundBlocked();
    error ZeroTransfer();

    address public vault;
    uint256 public depositTaxBps;
    bool public failInbound;
    bool public failOutbound;
    bool public zeroTransferForbidden;
    HunterNFT public callbackNft;
    uint256 public callbackTokenId;
    bool public callbackEnabled;

    constructor() ERC20("Fixture HUNTER", "fHUNT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setVault(address newVault) external {
        vault = newVault;
    }

    /// @dev TEST-ONLY behavior switches; defaults are 0 tax, all flags false.
    function setBehavior(uint256 taxBps, bool inFail, bool outFail, bool forbidZero) external {
        if (taxBps > 10_000) revert BadTax();
        depositTaxBps = taxBps;
        failInbound = inFail;
        failOutbound = outFail;
        zeroTransferForbidden = forbidZero;
    }

    /// @dev TEST-ONLY callback: while this contract (the real NFT owner)
    /// deposits, self-transfer the NFT to trip stale-authorization.
    function setCallback(address nft_, uint256 tokenId, bool enabled) external {
        callbackNft = HunterNFT(nft_);
        callbackTokenId = tokenId;
        callbackEnabled = enabled;
    }

    /// @dev TEST-ONLY: token contract is the NFT owner; approves then deposits.
    function beginDeposit(uint256 tokenId, uint256 requested) external {
        _approve(address(this), vault, requested);
        HunterReserveVault(vault).deposit(tokenId, requested);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (zeroTransferForbidden && value == 0) revert ZeroTransfer();
        if (failOutbound && from == vault && from != address(0)) revert OutboundBlocked();
        if (to == vault && from != address(0)) {
            if (failInbound) revert InboundBlocked();
            uint256 tax = (value * depositTaxBps) / 10_000;
            if (tax != 0) super._update(from, address(0), tax); // burn tax, bypasses hooks
            super._update(from, to, value - tax); // net amount reaches the vault
            if (callbackEnabled && from == address(this)) {
                callbackNft.transferFrom(address(this), address(this), callbackTokenId);
            }
            return;
        }
        super._update(from, to, value);
    }
}

/// @notice TEST-ONLY escrow holder. NOT production: no loan claims/checks.
contract ReserveEscrowFixture is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function release(IERC721 target, uint256 tokenId, address to) external {
        target.transferFrom(address(this), to, tokenId);
    }
}
