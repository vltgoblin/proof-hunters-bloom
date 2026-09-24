// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {IMiningPower} from "../../src/bloom/IMiningPower.sol";

/// @dev The one core entry point the cutover uses.
interface ICutoverMiningCore {
    function setMiningPower(IMiningPower power) external;
}

/// @notice S9 (VLT-60) cutover encoding — the artefact S11/S13 re-simulate.
/// @dev Safe `MultiSend` / `MultiSendCallOnly` packed transaction format:
/// each transaction is `abi.encodePacked(uint8 operation, address to,
/// uint256 value, uint256 dataLength, bytes data)` (operation 0 = CALL),
/// the transactions are concatenated, and the Safe calls
/// `multiSend(bytes transactions)` on the MultiSend(CallOnly) library with
/// `operation = 1` (DELEGATECALL) so every inner call's `msg.sender` is the
/// Safe itself (the core's `MINING_STOP_MULTISIG`).
library PrefundedCutoverEncoding {
    /// @dev `setMiningPower(address(0))` — non-terminal detach of the old custody.
    function detachCalldata() internal pure returns (bytes memory) {
        return abi.encodeCall(ICutoverMiningCore.setMiningPower, (IMiningPower(address(0))));
    }

    /// @dev `setMiningPower(module)` — attach of the new module.
    function attachCalldata(address module) internal pure returns (bytes memory) {
        return abi.encodeCall(ICutoverMiningCore.setMiningPower, (IMiningPower(module)));
    }

    /// @dev One packed MultiSend CALL with zero value.
    function packCall(address to, bytes memory data) internal pure returns (bytes memory) {
        return abi.encodePacked(uint8(0), to, uint256(0), uint256(data.length), data);
    }

    /// @dev The cutover batch: DETACH first, then ATTACH, both on `core`.
    /// The core refuses a direct swap (`MiningPowerAlreadyWired`), so the
    /// order is load-bearing.
    function cutoverTransactions(address core, address module) internal pure returns (bytes memory) {
        return bytes.concat(packCall(core, detachCalldata()), packCall(core, attachCalldata(module)));
    }

    /// @dev `multiSend(bytes)` calldata wrapping packed `transactions`.
    function multiSendCalldata(bytes memory transactions) internal pure returns (bytes memory) {
        return abi.encodeWithSignature("multiSend(bytes)", transactions);
    }
}

/// @notice TEST-ONLY stand-in for the Safe that is the core's
/// `MINING_STOP_MULTISIG`: its owner (the test) triggers either one call
/// (`exec`, a single Safe transaction) or a Safe-style `multiSend` batch that
/// runs every packed CALL in order inside ONE transaction and reverts all of
/// them if any fails (the inner revert data is bubbled unchanged). Only
/// operation 0 (CALL) is accepted, like `MultiSendCallOnly`.
contract PrefundedCutoverBatch {
    error NotOwner(address caller);
    error UnsupportedOperation(uint8 operation);
    error MalformedTransactions(uint256 offset);

    /// @dev Fixed packed header: operation (1) + to (20) + value (32) + dataLength (32).
    uint256 private constant _HEADER = 85;

    address public immutable owner;

    constructor(address owner_) {
        owner = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner(msg.sender);
        _;
    }

    /// @notice One Safe transaction: CALL `to` with `data`.
    function exec(address to, bytes calldata data) external onlyOwner returns (bytes memory ret) {
        bool ok;
        (ok, ret) = to.call(data);
        if (!ok) _bubble(ret);
    }

    /// @notice Safe-style batch in MultiSend packed encoding, one transaction.
    function multiSend(bytes memory transactions) external payable onlyOwner {
        uint256 length = transactions.length;
        uint256 i;
        while (i < length) {
            if (length - i < _HEADER) revert MalformedTransactions(i);
            uint8 operation;
            address to;
            uint256 value;
            uint256 dataLength;
            assembly ("memory-safe") {
                let p := add(add(transactions, 0x20), i)
                operation := shr(248, mload(p))
                to := shr(96, mload(add(p, 1)))
                value := mload(add(p, 21))
                dataLength := mload(add(p, 53))
            }
            if (operation != 0) revert UnsupportedOperation(operation);
            if (length - i - _HEADER < dataLength) revert MalformedTransactions(i);
            bytes memory data = new bytes(dataLength);
            uint256 start = i + _HEADER;
            for (uint256 j = 0; j < dataLength; j++) {
                data[j] = transactions[start + j];
            }
            (bool ok, bytes memory ret) = to.call{value: value}(data);
            if (!ok) _bubble(ret);
            i = start + dataLength;
        }
    }

    function _bubble(bytes memory ret) private pure {
        assembly ("memory-safe") {
            revert(add(ret, 0x20), mload(ret))
        }
    }
}
