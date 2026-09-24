// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

/// @notice Challenge-bound Mining Power for Mining Core validation.
interface IMiningPower {
    /// @dev Multiplier in 1e18 fixed point. Base = 1e18; max = 3e18.
    function powerMultiplierWad(uint256 challengeId, address miningWallet) external returns (uint256);

    function snapshottedLockedAmount(uint256 challengeId, address miningWallet) external returns (uint256);

    /// @notice Open a challenge snapshot epoch (lazy per-wallet freeze on first read).
    function snapshotChallenge(uint256 challengeId) external;

    /// @notice Advance unlock-delay clock after an accepted proof.
    function onProofAccepted(uint256 acceptedProofs) external;

    /// @notice Lifecycle hook: core calls this when the module is detached.
    /// `terminal` is true when mining can never produce another proof (stop or
    /// mint-out) — the module may then waive its unlock delay so stake exits.
    /// A non-terminal detach (module replacement) must keep the delay honest.
    function onMiningPowerDetached(bool terminal) external;
}
