// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

/// @notice Narrow conversion surface the canonical backing vault exposes to an
/// admitted basket converter. The vault grants the converter exactly
/// `amountIn` of `assetIn` allowance for the call and clears it afterwards;
/// the converter must deliver the `assetOut` proceeds to `msg.sender` (the
/// calling vault). The return value is informational only — the vault measures
/// the actual old-asset debit and new-asset credit from balances and never
/// trusts it for accounting. No target, recipient or calldata blob exists in
/// this interface: there is nothing for a caller to steer.
interface IBasketConverter {
    /// @param assetIn Basket asset the vault is converting out of; `amountIn`
    /// is the exact combined input the vault approved for this call.
    /// @param assetOut Destination basket asset; output must reach `msg.sender`.
    /// @param amountIn Exact old-asset input to pull from `msg.sender`.
    /// @param minAmountOut Minimum acceptable new-asset delivery.
    /// @return amountOut Converter-reported output; not trusted for accounting.
    function convert(address assetIn, address assetOut, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256 amountOut);
}
