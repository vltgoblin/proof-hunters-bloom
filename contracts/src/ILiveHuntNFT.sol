// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

/// @title Narrow NFT surface used by the Live Hunt module
/// @notice Compile-time boundary only: birth-data reads, the transient release
/// guard and the final owner-to-collector safe transfer. Implemented by both
/// the legacy `ProofNFT` and the bloom `HunterNFT`.
interface ILiveHuntNFT {
    function birthData(uint256 tokenId)
        external
        view
        returns (uint32 artVersion, bytes32 proofDigest, uint256 challengeId, uint8 proofTier);

    function wasReleasedThisTransaction(uint256 tokenId) external view returns (bool);

    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}
