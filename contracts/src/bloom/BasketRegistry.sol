// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @notice Basket identity and new-entry policy for the planned Hunter Bloom core.
/// @dev Does not custody funds, validate lending routes, or verify asset economics.
/// Integrations must use entry status only for new selections, never existing exits.
contract BasketRegistry is Ownable2Step {
    struct Basket {
        uint256 chainId;
        bytes32 codeHashAtAdmission;
        bytes32 reviewHash;
        bool entryEnabled;
    }

    /// @dev Admission record for a reviewed conversion route. Lives in a
    /// mapping separate from `_baskets`: a converter is never a basket and
    /// admission here never makes an address selectable as an NFT basket.
    /// `enabled` blocks NEW completions only; it seizes no backing.
    struct Converter {
        uint256 chainId;
        bytes32 codeHashAtAdmission;
        bytes32 reviewHash;
        bool enabled;
    }

    error InvalidBasket(address asset);
    error EmptyReview();
    error AlreadyAdmitted(address asset);
    error UnknownBasket(address asset);
    error InvalidConverter(address converter);
    error AlreadyAdmittedConverter(address converter);
    error UnknownConverter(address converter);
    error RenunciationDisabled();

    event BasketAdmitted(address indexed asset, uint256 chainId, bytes32 codeHash, bytes32 indexed reviewHash);
    event BasketEntryStatusChanged(address indexed asset, bool enabled);
    event ConverterAdmitted(address indexed converter, uint256 chainId, bytes32 codeHash, bytes32 indexed reviewHash);
    event ConverterStatusChanged(address indexed converter, bool enabled);

    // A nonzero reviewHash is also the admission sentinel; EmptyReview enforces it.
    mapping(address => Basket) private _baskets;
    // Separate converter records: never mixed into `_baskets`.
    mapping(address => Converter) private _converters;

    constructor(address initialAdmin) Ownable(initialAdmin) {
        if (initialAdmin == address(this)) revert OwnableInvalidOwner(initialAdmin);
    }

    /// @notice Immediately admit an asset following an off-chain review.
    /// @dev reviewHash commits to a published, versioned review including redemption,
    /// transfer behavior and issuer/upgrade powers. Neither hash proves safety.
    /// Proxy implementation changes are not detected by the recorded code hash.
    function admitBasket(address asset, bytes32 reviewHash) external onlyOwner {
        if (asset == address(this) || asset.code.length == 0) revert InvalidBasket(asset);
        if (reviewHash == bytes32(0)) revert EmptyReview();
        if (_baskets[asset].reviewHash != bytes32(0)) revert AlreadyAdmitted(asset);

        _baskets[asset] = Basket(block.chainid, asset.codehash, reviewHash, true);
        emit BasketAdmitted(asset, block.chainid, asset.codehash, reviewHash);
        emit BasketEntryStatusChanged(asset, true);
    }

    /// @notice Stop or resume new selections without deleting the original record.
    function setEntryEnabled(address asset, bool enabled) external onlyOwner {
        if (_baskets[asset].reviewHash == bytes32(0)) revert UnknownBasket(asset);
        if (_baskets[asset].entryEnabled == enabled) return;
        _baskets[asset].entryEnabled = enabled;
        emit BasketEntryStatusChanged(asset, enabled);
    }

    /// @notice Original admission data stays readable even when entry is disabled.
    function basket(address asset) external view returns (Basket memory record) {
        record = _baskets[asset];
        if (record.reviewHash == bytes32(0)) revert UnknownBasket(asset);
    }

    /// @notice False for both unknown assets and disabled entries.
    /// @dev This is an admin policy flag, not a live asset safety check.
    function isEntryEnabled(address asset) external view returns (bool) {
        return _baskets[asset].entryEnabled;
    }

    /// @notice Immediately admit a reviewed conversion route. The record pins
    /// the admission-time chain id and code hash; a later code change (or a
    /// different chain) makes `isConverterUsable` false even while `enabled`.
    /// Converters are admitted into their own mapping — admission never makes
    /// an address eligible for NFT basket selection.
    /// @dev reviewHash commits to the published, versioned route review. Proxy
    /// implementation changes are not detected by the recorded code hash.
    function admitConverter(address converter, bytes32 reviewHash) external onlyOwner {
        if (converter == address(this) || converter.code.length == 0) revert InvalidConverter(converter);
        if (reviewHash == bytes32(0)) revert EmptyReview();
        if (_converters[converter].reviewHash != bytes32(0)) revert AlreadyAdmittedConverter(converter);

        _converters[converter] = Converter(block.chainid, converter.codehash, reviewHash, true);
        emit ConverterAdmitted(converter, block.chainid, converter.codehash, reviewHash);
        emit ConverterStatusChanged(converter, true);
    }

    /// @notice Block or resume new completions through this route. Disabling
    /// cannot seize backing — pending requests stay cancellable and burnable.
    function setConverterEnabled(address converter, bool enabled) external onlyOwner {
        if (_converters[converter].reviewHash == bytes32(0)) revert UnknownConverter(converter);
        if (_converters[converter].enabled == enabled) return;
        _converters[converter].enabled = enabled;
        emit ConverterStatusChanged(converter, enabled);
    }

    /// @notice Original admission data stays readable even when disabled.
    function converter(address converter_) external view returns (Converter memory record) {
        record = _converters[converter_];
        if (record.reviewHash == bytes32(0)) revert UnknownConverter(converter_);
    }

    /// @notice False for both unknown converters and disabled routes.
    function isConverterEnabled(address converter_) external view returns (bool) {
        return _converters[converter_].enabled;
    }

    /// @notice Enabled AND still matching the admission record on this chain:
    /// current `block.chainid` and `codehash` must equal the stored values.
    /// @dev The only check completions may rely on; admission is a review
    /// gate, not a live proof of economic safety.
    function isConverterUsable(address converter_) external view returns (bool) {
        Converter storage c = _converters[converter_];
        return c.enabled && c.chainId == block.chainid && converter_.codehash == c.codeHashAtAdmission;
    }

    /// @dev Zero cancels a pending nomination, as in OpenZeppelin Ownable2Step.
    function transferOwnership(address newOwner) public override onlyOwner {
        if (newOwner == address(this)) revert OwnableInvalidOwner(newOwner);
        super.transferOwnership(newOwner);
    }

    /// @dev Keep a restricted admin role available for future basket admissions.
    function renounceOwnership() public view override onlyOwner {
        revert RenunciationDisabled();
    }
}
