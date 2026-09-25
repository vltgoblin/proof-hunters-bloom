// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HunterMiningCore} from "../../src/bloom/HunterMiningCore.sol";
import {MiningPowerCustody} from "../../src/bloom/MiningPowerCustody.sol";
import {HunterNFT} from "../../src/bloom/HunterNFT.sol";
import {HunterLifecycle} from "../../src/bloom/HunterLifecycle.sol";
import {HunterReserveVault} from "../../src/bloom/HunterReserveVault.sol";
import {IMiningPower} from "../../src/bloom/IMiningPower.sol";
import {WeightedHistory} from "../../src/bloom/libraries/WeightedHistory.sol";

/// @title S1 (VLT-52) read-only facts about the live Robinhood Chain (4663) deployment
/// @notice Every state change below happens only inside the local fork; nothing is
/// broadcast. Skipped unless FORK_RPC_URL is set, so CI is unaffected. Optional
/// FORK_BLOCK pins the fork (the public RPC is non-archive: it serves roughly the
/// last half hour of state, so a stale pin fails with "historical state ... not available").
/// @dev Arbitrum Orbit caveat: on-chain `block.number` is the PARENT-chain (Ethereum L1)
/// block number, but a Foundry fork's `block.number` is the L2 block number. Anything
/// that depends on the core's parent-block clock (challengeState, seed life, easing,
/// retarget) is NOT faithful on a fork unless the test rolls to the parent block.
contract PrefundedForkFactsTest is Test {
    uint256 internal constant CHAIN_ID = 4663;

    HunterMiningCore internal constant CORE = HunterMiningCore(0xF213854c6D5D4334D23D452574556bD53CA24c2C);
    HunterNFT internal constant NFT = HunterNFT(0x924a65312cd535bc8787acECdfa5F71609B4e273);
    HunterLifecycle internal constant LIFECYCLE = HunterLifecycle(0x3Eed4fFaBBE8ff92D84BCD5E6a53f41d05DdEF7d);
    HunterReserveVault internal constant RESERVE = HunterReserveVault(0x681EE81D715aeF90b9d2083DD751DA4a4E6BCb82);
    address internal constant BACKING = 0x7cB8B19D356169664E3DEBeE61Fc9529f557347D;
    address internal constant LEDGER = 0x3c53cBfBfF1154463e22bEb1EaF93100adda37D9;
    address internal constant REGISTRY = 0x04879d316e4572Cd03C53339E7A1F29e9764c703;
    address internal constant LIVE_HUNT = 0x0621902BF715ca4E57a7f9152E8B42b6819e7bF6;
    MiningPowerCustody internal constant CUSTODY = MiningPowerCustody(0x73a9796768F69f9089A03B0eEDd8F0D41EE6F306);
    IERC20 internal constant HUNTER = IERC20(0xBBDD439FD49ADE6Ff3C96f748867de4356647960);

    address internal constant STOP_ACCOUNT = 0xEE951AA16F261B31B921E54FCA6bA2074b496C15;
    address internal constant STOP_ACCOUNT_DELEGATE = 0x63c0c19a282a1B52b07dD5a65b58948A07DAE32B;
    address internal constant TOKEN_AUTHORITY = 0xAC11D1d09f171FE48F2f30BF76466A217c85C00f;
    uint256 internal constant SUNSET = 1_795_166_097;

    /// @dev Release manifest (source commit 2dff62d) Mining Core code hash == keccak256(runtime).
    bytes32 internal constant MANIFEST_CORE_CODEHASH =
        0x0fd8b83da061b5581d3bb4e3b906b80ee60c68130ddf787586324a2b966bfd95;

    /// @dev HunterMiningCore storage slot of `acceptedProofs` (forge inspect storageLayout).
    uint256 internal constant CORE_ACCEPTED_PROOFS_SLOT = 5;

    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pin);
        forked = true;
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _;
    }

    // ------------------------------------------------------------------ 1. code

    function test_fork_codeHashes() public onlyFork {
        assertEq(address(CORE).codehash, MANIFEST_CORE_CODEHASH, "core extcodehash != manifest");
        assertEq(address(CORE).codehash, keccak256(address(CORE).code), "extcodehash is keccak(runtime)");
        assertEq(address(CORE).code.length, 10_370);
        assertEq(address(NFT).code.length, 9729);
        assertEq(address(LIFECYCLE).code.length, 17_670);
        assertEq(address(RESERVE).code.length, 6788);
        assertEq(BACKING.code.length, 15_273);
        assertEq(LEDGER.code.length, 6398);
        assertEq(REGISTRY.code.length, 2873);
        assertEq(LIVE_HUNT.code.length, 8219);
        assertEq(address(CUSTODY).code.length, 6690);
        assertEq(address(HUNTER).code.length, 3248);
        assertEq(address(NFT).codehash, 0x137ff387ef44fd8ea05afdd4524b6414de21988c7ab140042a211c0f0c43ae03);
        assertEq(address(LIFECYCLE).codehash, 0x5333163fd17e2d230298a949453df9d8ecaf353c454ff7d7ac69366dbe0959bb);
        assertEq(address(RESERVE).codehash, 0x028e63d9c55a0a7a775b8ec261b90ad65fbcf56c7edcdddee40a895fd43eed40);
        assertEq(BACKING.codehash, 0x2699ac25a2afa5f6de7b2ca96d57d6a684fa7b543ddd090b20de077d1f40fc87);
        assertEq(LEDGER.codehash, 0xa6a03f46d62f7b226ccc20fd040fbcf462fb7e9dd9bd742560dc498b03402ff1);
        assertEq(REGISTRY.codehash, 0xfc1b48a2a68119fc4429523d77a8ff70db0242aeacad8e3b9bcdaf0d2893abc1);
        assertEq(LIVE_HUNT.codehash, 0xf921eaeeda81dbac3c3a6da0e278fe0c6d862595062e66999d916418c43ddd3f);
        assertEq(address(CUSTODY).codehash, 0xcadf5e8acc363626a1841cffb5adb8da1d7024eb6a659fd074cbc44cb839bcd2);
        assertEq(address(HUNTER).codehash, 0x5cbed682efd35d15e5d2f2cdc88b3fc80176145c6a9aba06fac3553a0943c90c);
    }

    // ------------------------------------------------------------------ 2. core

    function test_fork_coreWiring() public onlyFork {
        assertEq(block.chainid, CHAIN_ID);
        assertEq(address(CORE.miningPower()), address(CUSTODY), "stop (d): miningPower is not the old custody");
        assertTrue(CORE.miningPowerWasAttached(), "stop (d): miningPowerWasAttached");
        assertEq(CORE.MINING_STOP_SUNSET(), SUNSET, "stop (d): sunset");
        assertEq(CORE.MINING_STOP_MULTISIG(), STOP_ACCOUNT);
        assertEq(address(CORE.PROOF_NFT()), address(NFT));
        assertFalse(CORE.miningStopped());
        assertLt(block.timestamp, SUNSET, "stop sunset already passed");
        assertEq(CORE.acceptedProofs(), CORE.nftsMintedEver(), "proof/mint counter drift");
        assertEq(NFT.mintedEver(), CORE.nftsMintedEver(), "NFT/core mint counter drift");
        assertApproxEqRel(CORE.MAX_TARGET(), CORE.GENESIS_TARGET() * 10, 1, "MAX ~= 10x genesis");
        assertApproxEqRel(CORE.MIN_TARGET() * 10, CORE.GENESIS_TARGET(), 1, "MIN ~= genesis / 10");
        assertEq(CORE.SEED_READABLE_PARENT_BLOCKS(), 256);
        assertEq(
            vm.load(address(CORE), bytes32(CORE_ACCEPTED_PROOFS_SLOT)),
            bytes32(CORE.acceptedProofs()),
            "acceptedProofs slot"
        );
        console2.log("acceptedProofs", CORE.acceptedProofs());
        console2.log("activeChallengeId", CORE.activeChallengeId());
        console2.log("activeSeedParentBlock", CORE.activeSeedParentBlock());
        console2.log("lastProofBlock", CORE.lastProofBlock());
        console2.log("currentTarget / GENESIS_TARGET (1e6)", CORE.currentTarget() * 1e6 / CORE.GENESIS_TARGET());
        console2.log("fork challengeState (L2-number clock, NOT faithful)", uint8(CORE.challengeState()));
    }

    // ------------------------------------------------------------------ 3. stop account

    function test_fork_stopAccountIsEip7702DelegatedEoa() public onlyFork {
        bytes memory code = STOP_ACCOUNT.code;
        assertEq(code.length, 23, "EIP-7702 delegation designator is 23 bytes");
        assertEq(uint8(code[0]), 0xef);
        assertEq(uint8(code[1]), 0x01);
        assertEq(uint8(code[2]), 0x00);
        address delegate;
        assembly ("memory-safe") {
            delegate := shr(96, mload(add(code, 35)))
        }
        assertEq(delegate, STOP_ACCOUNT_DELEGATE);
        assertGt(STOP_ACCOUNT_DELEGATE.code.length, 0);
        // Not a Safe: the Safe owner/threshold getters do not exist on the delegate.
        (bool ok,) = STOP_ACCOUNT_DELEGATE.staticcall(abi.encodeWithSignature("getThreshold()"));
        assertFalse(ok, "getThreshold unexpectedly exists");
        (ok,) = STOP_ACCOUNT_DELEGATE.staticcall(abi.encodeWithSignature("getOwners()"));
        assertFalse(ok, "getOwners unexpectedly exists");
        (bool nameOk, bytes memory name) = STOP_ACCOUNT_DELEGATE.staticcall(abi.encodeWithSignature("NAME()"));
        assertTrue(nameOk);
        assertEq(abi.decode(name, (string)), "EIP7702StatelessDeleGator");
        console2.log(
            "Safe MultiSendCallOnly v1.3.0 canonical code size",
            address(0x40A2aCCbd92BCA938b02010E17A5b8929b49130D).code.length
        );
        console2.log(
            "Safe MultiSendCallOnly v1.4.1 code size", address(0x9641d764fc13c8B624c04430C7356C1C7C8102e2).code.length
        );
    }

    // ------------------------------------------------------------------ 4. old custody

    function test_fork_custodyFacts() public onlyFork {
        assertEq(address(CUSTODY.HUNTER()), address(HUNTER));
        assertEq(CUSTODY.miningCore(), address(CORE));
        assertEq(CUSTODY.curveUnit(), 1_000_000e18);
        assertTrue(CUSTODY.wired());
        assertFalse(CUSTODY.retired());
        assertEq(CUSTODY.UNLOCK_DELAY_PROOFS(), 12);
        assertEq(CUSTODY.lastAcceptedProofs(), CORE.acceptedProofs());
        assertEq(CUSTODY.latestChallengeId(), CORE.activeChallengeId());
        assertGe(HUNTER.balanceOf(address(CUSTODY)), CUSTODY.totalLocked(), "custody under-collateralised");
        assertLe(CUSTODY.totalAssigned(), CUSTODY.totalLocked());
        console2.log("custody totalLocked", CUSTODY.totalLocked());
        console2.log("custody totalAssigned", CUSTODY.totalAssigned());
    }

    /// @notice Stop condition (b): after a NON-terminal detach the live custody's
    /// unassign reads the live core's acceptedProofs (delay kept honest) and its
    /// challengeState (terminal waiver). Fork-local simulation only.
    function test_fork_custodyUnassignReadsLiveCoreAfterDetach() public onlyFork {
        address depositor = makeAddr("s1-depositor");
        address wallet = makeAddr("s1-wallet");
        uint256 amount = 1000e18;
        deal(address(HUNTER), depositor, amount);

        vm.startPrank(depositor);
        HUNTER.approve(address(CUSTODY), amount);
        CUSTODY.deposit(amount);
        CUSTODY.assign(wallet, amount);
        vm.stopPrank();
        uint256 startProofs = CUSTODY.lastAcceptedProofs();
        assertEq(CUSTODY.assignProofIndex(depositor), startProofs);

        // Non-terminal detach by the stop account (what the cutover will do first).
        vm.prank(STOP_ACCOUNT);
        CORE.setMiningPower(IMiningPower(address(0)));
        assertEq(address(CORE.miningPower()), address(0));
        assertFalse(CUSTODY.wired());
        assertFalse(CUSTODY.retired(), "non-terminal detach must not retire");

        // Delay still enforced right after detach.
        vm.prank(depositor);
        vm.expectRevert(
            abi.encodeWithSelector(MiningPowerCustody.UnlockDelayNotMet.selector, startProofs + 12, startProofs)
        );
        CUSTODY.unassign(wallet, amount);

        // The live core advances (simulated: proofs on the replacement module) while the
        // detached custody's own counter stays frozen.
        vm.store(address(CORE), bytes32(CORE_ACCEPTED_PROOFS_SLOT), bytes32(startProofs + 11));
        vm.prank(depositor);
        vm.expectRevert(
            abi.encodeWithSelector(MiningPowerCustody.UnlockDelayNotMet.selector, startProofs + 12, startProofs + 11)
        );
        CUSTODY.unassign(wallet, amount);

        vm.store(address(CORE), bytes32(CORE_ACCEPTED_PROOFS_SLOT), bytes32(startProofs + 12));
        assertEq(CUSTODY.lastAcceptedProofs(), startProofs, "custody counter must be frozen after detach");
        uint256 snap = vm.snapshotState();
        vm.prank(depositor);
        CUSTODY.unassign(wallet, amount); // succeeds only via the live core read
        assertEq(CUSTODY.unassignedOf(depositor), amount);
        vm.revertToState(snap);

        // Terminal transition AFTER detach: the custody gets no notice, but the live
        // challengeState read (STOPPED) waives the delay.
        vm.store(address(CORE), bytes32(CORE_ACCEPTED_PROOFS_SLOT), bytes32(startProofs));
        vm.prank(STOP_ACCOUNT);
        CORE.stopMining();
        assertFalse(CUSTODY.retired(), "detached custody was not notified");
        vm.prank(depositor);
        CUSTODY.unassign(wallet, amount);
        vm.prank(depositor);
        CUSTODY.withdraw(amount);
        assertEq(HUNTER.balanceOf(depositor), amount);
    }

    // ------------------------------------------------------------------ 5. NFT / lifecycle / reserve

    function test_fork_nftLifecycleReserveWiring() public onlyFork {
        assertEq(NFT.MINER(), address(CORE));
        assertEq(address(NFT.LIFECYCLE()), address(LIFECYCLE));
        assertEq(address(NFT.REGISTRY()), REGISTRY);
        assertEq(NFT.MAX_NFTS_EVER(), 5000);
        assertEq(LIFECYCLE.nft(), address(NFT));
        assertEq(LIFECYCLE.reserve(), address(RESERVE));
        assertEq(LIFECYCLE.backing(), BACKING);
        assertEq(address(RESERVE.NFT()), address(NFT));
        assertEq(address(RESERVE.LIFECYCLE()), address(LIFECYCLE));
        assertEq(address(RESERVE.HUNTER()), address(HUNTER));
        assertEq(RESERVE.TOKEN_AUTHORITY(), TOKEN_AUTHORITY);
        assertTrue(RESERVE.tokenActivated());
        assertGe(HUNTER.balanceOf(address(RESERVE)), RESERVE.totalReserved());
    }

    /// @notice Stop condition (c): finalBeneficiary/currentMember exist and behave as
    /// the module expects across a burn. No token is burned on-chain yet, so the burn
    /// is simulated on the fork by the real owner.
    function test_fork_lifecycleFinalBeneficiaryAndCurrentMember() public onlyFork {
        uint256 minted = NFT.mintedEver();
        vm.expectRevert(WeightedHistory.UnknownId.selector);
        LIFECYCLE.currentMember(minted + 1);
        assertEq(LIFECYCLE.finalBeneficiary(minted + 1), address(0));

        uint256 tokenId;
        address owner;
        for (uint256 id = 1; id <= minted && id <= 50; ++id) {
            if (!NFT.isEncumbered(id)) {
                tokenId = id;
                owner = NFT.ownerOf(id);
                break;
            }
        }
        assertGt(tokenId, 0, "no owner-held token in the first 50");
        WeightedHistory.Member memory before = LIFECYCLE.currentMember(tokenId);
        assertTrue(before.alive);
        assertEq(before.basket, NFT.basketOf(tokenId));
        assertEq(LIFECYCLE.finalBeneficiary(tokenId), address(0));

        vm.prank(owner);
        NFT.redeemAndDestroy(tokenId);

        WeightedHistory.Member memory afterBurn = LIFECYCLE.currentMember(tokenId);
        assertFalse(afterBurn.alive, "burned member still alive");
        assertFalse(afterBurn.eligible);
        assertEq(LIFECYCLE.finalBeneficiary(tokenId), owner, "finalBeneficiary != burner");
        assertTrue(RESERVE.settled(tokenId));
    }

    // ------------------------------------------------------------------ 6. token

    function test_fork_tokenTransferIsTaxFree() public onlyFork {
        address from = makeAddr("s1-sender");
        address to = makeAddr("s1-receiver");
        deal(address(HUNTER), from, 5e18);
        uint256 supply = HUNTER.totalSupply();

        vm.prank(from);
        assertTrue(HUNTER.transfer(to, 1e18));
        assertEq(HUNTER.balanceOf(to), 1e18, "recipient-side tax");
        assertEq(HUNTER.balanceOf(from), 4e18, "sender-side surcharge");
        assertEq(HUNTER.totalSupply(), supply, "transfer burned supply");

        // transferFrom path and a transfer into the real custody (deposit measures receipt).
        vm.prank(from);
        HUNTER.approve(address(this), 1e18);
        assertTrue(HUNTER.transferFrom(from, to, 1e18));
        assertEq(HUNTER.balanceOf(to), 2e18);

        // Pause / blacklist / proxy surfaces do not exist.
        (bool ok,) = address(HUNTER).staticcall(abi.encodeWithSignature("paused()"));
        assertFalse(ok, "paused() exists");
        (ok,) = address(HUNTER).staticcall(abi.encodeWithSignature("isBlacklisted(address)", from));
        assertFalse(ok, "isBlacklisted exists");
        (ok,) = address(HUNTER).staticcall(abi.encodeWithSignature("blacklist(address)", from));
        assertFalse(ok, "blacklist exists");
        (ok,) = address(HUNTER).staticcall(abi.encodeWithSignature("implementation()"));
        assertFalse(ok, "implementation() exists");
        bytes32 implSlot = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
        bytes32 adminSlot = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        assertEq(vm.load(address(HUNTER), implSlot), bytes32(0));
        assertEq(vm.load(address(HUNTER), adminSlot), bytes32(0));
    }

    // ------------------------------------------------------------------ 7. chain

    function test_fork_chainEnvironment() public onlyFork {
        assertEq(block.chainid, CHAIN_ID);
        // Fork (revm) semantics: block.number is the L2 number, far above the core's
        // parent-block clock. On-chain eth_call semantics differ (see report).
        assertGt(block.number, CORE.activeSeedParentBlock() + 1_000_000, "fork uses L2 block numbers");
        bytes32 h256 = blockhash(block.number - 256);
        bytes32 h1 = blockhash(block.number - 1);
        console2.log("fork block.number", block.number);
        console2.log("fork block.timestamp", block.timestamp);
        console2.logBytes32(h1);
        console2.logBytes32(h256);
        assertTrue(h1 != bytes32(0), "blockhash(n-1) unavailable on fork");
        assertTrue(h256 != bytes32(0), "blockhash(n-256) unavailable on fork");
        assertEq(blockhash(block.number - 257), bytes32(0));
    }
}
