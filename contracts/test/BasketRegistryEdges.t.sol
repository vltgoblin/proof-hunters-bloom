// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {BasketRegistry} from "../src/bloom/BasketRegistry.sol";

/// @dev Minimal contract so converter admission accepts it (code.length > 0).
contract ConverterFixture {}

/// @notice VLT-38 Stage 2: converter admission, enablement and read paths.
/// The basket-admission surface is covered by BasketRegistry.t.sol; this file
/// covers only the converter side and its guards.
contract BasketRegistryEdgesTest is Test {
    BasketRegistry private registry;
    ConverterFixture private conv;
    bytes32 private constant REVIEW = keccak256("converter review v1");

    function setUp() public {
        registry = new BasketRegistry(address(this));
        conv = new ConverterFixture();
    }

    function testAdmitConverterGuardsAndDuplicate() public {
        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.InvalidConverter.selector, address(registry)));
        registry.admitConverter(address(registry), REVIEW);

        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.InvalidConverter.selector, address(0xCAFE)));
        registry.admitConverter(address(0xCAFE), REVIEW); // no code

        vm.expectRevert(BasketRegistry.EmptyReview.selector);
        registry.admitConverter(address(conv), bytes32(0));

        registry.admitConverter(address(conv), REVIEW);
        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.AlreadyAdmittedConverter.selector, address(conv)));
        registry.admitConverter(address(conv), keccak256("second review"));
    }

    function testConverterRecordEnableAndReads() public {
        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.UnknownConverter.selector, address(conv)));
        registry.converter(address(conv));
        assertFalse(registry.isConverterEnabled(address(conv)));
        assertFalse(registry.isConverterUsable(address(conv)));

        registry.admitConverter(address(conv), REVIEW);
        BasketRegistry.Converter memory record = registry.converter(address(conv));
        assertEq(record.reviewHash, REVIEW);
        assertTrue(record.enabled);
        assertTrue(registry.isConverterEnabled(address(conv)));
        assertTrue(registry.isConverterUsable(address(conv)));

        // Disabling keeps the admission record but fails usability.
        registry.setConverterEnabled(address(conv), false);
        assertEq(registry.converter(address(conv)).reviewHash, REVIEW);
        assertFalse(registry.isConverterEnabled(address(conv)));
        assertFalse(registry.isConverterUsable(address(conv)));

        vm.expectRevert(abi.encodeWithSelector(BasketRegistry.UnknownConverter.selector, address(0xCAFE)));
        registry.setConverterEnabled(address(0xCAFE), true);
    }
}
