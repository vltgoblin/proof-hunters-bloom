// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test, Vm, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HunterMiningCore} from "../../src/bloom/HunterMiningCore.sol";
import {MiningPowerCustody} from "../../src/bloom/MiningPowerCustody.sol";
import {HunterNFT} from "../../src/bloom/HunterNFT.sol";
import {HunterLifecycle} from "../../src/bloom/HunterLifecycle.sol";
import {HunterReserveVault} from "../../src/bloom/HunterReserveVault.sol";
import {IMiningPower} from "../../src/bloom/IMiningPower.sol";
import {PrefundedMiningPower} from "../../src/bloom/PrefundedMiningPower.sol";
import {PrefundedCutoverEncoding} from "../helpers/PrefundedCutoverBatch.sol";

/// @dev ERC-7579 / MetaMask Delegation Framework `Execution` (batch element).
struct Execution {
    address target;
    uint256 value;
    bytes callData;
}

/// @dev The surface of MetaMask's EIP7702StatelessDeleGator 1.3.0 this rehearsal uses.
interface IStatelessDeleGator {
    function execute(bytes32 mode, bytes calldata executionCalldata) external payable;
    function supportsExecutionMode(bytes32 mode) external view returns (bool);
    function NAME() external view returns (string memory);
    function VERSION() external view returns (string memory);
}

/// @title S11 (VLT-62) mainnet-fork rehearsal of the Prefunded Mining Power cutover
/// @notice READ-ONLY against the chain: every state change happens inside the local
/// Foundry fork; nothing is broadcast and no key is used (the stop account is
/// impersonated with `vm.prank`). Skipped unless FORK_RPC_URL is set, same pattern as
/// `PrefundedForkFacts.t.sol` (S1), so CI is unaffected.
/// @dev Environment:
/// - FORK_RPC_URL (required to run), FORK_BLOCK (L2 pin; the public RPC is non-archive,
///   so pin a block that is at most ~20 min old) and FORK_PARENT_BLOCK (required when
///   forked: the pin's `l1BlockNumber` header field).
/// - Arbitrum Orbit: on-chain `block.number` is the PARENT (L1) block, a Foundry fork's
///   is the L2 block. `setUp` therefore `vm.roll`s to the pin's parent block before
///   any test touches seeds or proofs. Seed blockhashes are set with `vm.setBlockhash`
///   (the chain's values are ArbOS-recorded and not reproducible on a fork).
/// - `testCutoverAtomic7702Batch` needs `--evm-version prague`: a Cancun-spec fork does
///   not execute EIP-7702 delegation designators and the test skips itself.
/// - Everything labelled SIMULATION overrides live storage (`vm.store` of the core's
///   `currentTarget`) or rolls/warps the clock into the future; it proves code paths,
///   not live difficulty.
/// Module parameters are PLACEHOLDERS (MIN_STAKE 1_000e18, LOCK 100e18, cooldown 1 day,
/// curveUnit 0, guardian = the stop account), not launch decisions.
contract PrefundedForkRehearsalTest is Test {
    uint256 internal constant CHAIN_ID = 4663;

    HunterMiningCore internal constant CORE = HunterMiningCore(0xF213854c6D5D4334D23D452574556bD53CA24c2C);
    HunterNFT internal constant NFT = HunterNFT(0x924a65312cd535bc8787acECdfa5F71609B4e273);
    HunterLifecycle internal constant LIFECYCLE = HunterLifecycle(0x3Eed4fFaBBE8ff92D84BCD5E6a53f41d05DdEF7d);
    HunterReserveVault internal constant RESERVE = HunterReserveVault(0x681EE81D715aeF90b9d2083DD751DA4a4E6BCb82);
    MiningPowerCustody internal constant CUSTODY = MiningPowerCustody(0x73a9796768F69f9089A03B0eEDd8F0D41EE6F306);
    IERC20 internal constant HUNTER = IERC20(0xBBDD439FD49ADE6Ff3C96f748867de4356647960);

    /// @dev The core's MINING_STOP_MULTISIG: a single-key EOA with an EIP-7702 delegation.
    address internal constant STOP_ACCOUNT = 0xEE951AA16F261B31B921E54FCA6bA2074b496C15;
    /// @dev Delegation target recorded by S1 (MetaMask EIP7702StatelessDeleGator 1.3.0).
    address internal constant STOP_ACCOUNT_DELEGATE = 0x63c0c19a282a1B52b07dD5a65b58948A07DAE32B;
    uint256 internal constant SUNSET = 1_795_166_097;

    /// @dev The only basket every live mint so far used (NFT.basketOf(1..450)); admitted in
    /// the live registry.
    address internal constant LIVE_BASKET = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    // S1 extcodehashes (formal/fork/2026-09-25-S1-fork-facts.md §1).
    bytes32 internal constant CORE_CODEHASH = 0x0fd8b83da061b5581d3bb4e3b906b80ee60c68130ddf787586324a2b966bfd95;
    bytes32 internal constant NFT_CODEHASH = 0x137ff387ef44fd8ea05afdd4524b6414de21988c7ab140042a211c0f0c43ae03;
    bytes32 internal constant LIFECYCLE_CODEHASH = 0x5333163fd17e2d230298a949453df9d8ecaf353c454ff7d7ac69366dbe0959bb;
    bytes32 internal constant RESERVE_CODEHASH = 0x028e63d9c55a0a7a775b8ec261b90ad65fbcf56c7edcdddee40a895fd43eed40;
    bytes32 internal constant CUSTODY_CODEHASH = 0xcadf5e8acc363626a1841cffb5adb8da1d7024eb6a659fd074cbc44cb839bcd2;
    bytes32 internal constant HUNTER_CODEHASH = 0x5cbed682efd35d15e5d2f2cdc88b3fc80176145c6a9aba06fac3553a0943c90c;

    // Real old-custody depositors, from the custody's `Assigned` logs (queried with
    // `cast logs --address 0x73a9…F306 'Assigned(address indexed,address indexed,uint256,uint256)'`
    // from L2 block 70_000_000 to latest on 2026-09-25; 5 Assigned, 0 Unassigned, 0 Withdrawn
    // logs; the 4 depositors hold all 6_014_424 HUNTER). Proof index at assign in brackets.
    address internal constant DEP_5M = 0xC3881136bf7502e9fB4444F9c45B67B550A74315; // 5_000_000 [2], 7702-delegated
    address internal constant DEP_5M_WALLET = 0x586476aDA258d5dcE97D416B608E037ee5b15d96;
    address internal constant DEP_1M = 0x60Ca2a87C0f9cE808000ed45eb88BAEdfB71d332; // 1_000_000 [9], 7702-delegated
    address internal constant DEP_1M_WALLET = 0xC58A26E1AB8c5198376A5691099039184C85A9b9;
    address internal constant DEP_9K = 0xA135684f7990ab2Ed7C8383a1Eb6527bfB3a3C65; // 7_999 [44] + 1_315 [46]
    address internal constant DEP_9K_WALLET = 0x52201Ed6758Ac6FD645f5B72D32E7F5183Cc9C2B;
    address internal constant DEP_5K = 0xf144889E554D30DE80128dF8151C7F33284D850A; // 5_110 [120]
    address internal constant DEP_5K_WALLET = 0xb1c8c2b249C7Fb19A083a81583180a8dB23B7Daf;

    // PLACEHOLDER module parameters (not launch decisions).
    uint256 internal constant MIN_STAKE = 1_000e18;
    uint256 internal constant LOCK = 100e18;
    uint256 internal constant COOLDOWN = 1 days;
    uint256 internal constant CURVE_UNIT = 0;

    /// @dev ERC-7579 mode: callType BATCH (0x01), execType DEFAULT (0x00, revert on
    /// failure), unused, modeSelector 0, payload 0. `supportsExecutionMode` = true live.
    bytes32 internal constant BATCH_MODE = 0x0100000000000000000000000000000000000000000000000000000000000000;
    /// @dev Placeholder module address for runbook calldata.
    address internal constant MODULE_PLACEHOLDER = 0x000000000000000000000000000000000000dEaD;

    // HunterMiningCore storage slots (forge inspect storageLayout; checked in setUp).
    uint256 internal constant CORE_CURRENT_TARGET_SLOT = 4;
    uint256 internal constant CORE_ACCEPTED_PROOFS_SLOT = 5;
    /// @dev SIMULATION: easy target (1 in 8 hashes) so real proofs can be mined on the fork.
    uint256 internal constant EASY_TARGET = type(uint256).max >> 3;

    uint8 internal constant ACTIVE = uint8(HunterMiningCore.ChallengeState.ACTIVE);

    bool internal forked;
    uint256 internal forkBlock;
    uint256 internal forkTimestamp;
    uint256 internal parentBlock;

    function setUp() public {
        string memory rpc = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        uint256 pin = vm.envOr("FORK_BLOCK", uint256(0));
        if (pin == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, pin);
        forked = true;
        forkBlock = block.number;
        forkTimestamp = block.timestamp;
        // The pin's `l1BlockNumber` header field (`cast block $FORK_BLOCK --json`); Foundry
        // cannot read it, and a guess would put the core's parent-block clock off.
        parentBlock = vm.envOr("FORK_PARENT_BLOCK", uint256(0));
        require(parentBlock != 0, "set FORK_PARENT_BLOCK = l1BlockNumber of FORK_BLOCK");
        // Plausibility: the core's last recorded parent-clock values are behind the pin.
        require(parentBlock >= CORE.lastProofBlock(), "FORK_PARENT_BLOCK behind lastProofBlock");
        require(parentBlock + 3 >= CORE.activeSeedParentBlock(), "FORK_PARENT_BLOCK behind seed");
        require(parentBlock < CORE.lastProofBlock() + 100_000, "FORK_PARENT_BLOCK implausible");
        vm.roll(parentBlock); // the core's clock is the parent block (see contract NatSpec)
        require(
            vm.load(address(CORE), bytes32(CORE_CURRENT_TARGET_SLOT)) == bytes32(CORE.currentTarget()),
            "currentTarget slot moved"
        );
        require(
            vm.load(address(CORE), bytes32(CORE_ACCEPTED_PROOFS_SLOT)) == bytes32(CORE.acceptedProofs()),
            "acceptedProofs slot moved"
        );
    }

    modifier onlyFork() {
        if (!forked) {
            vm.skip(true);
            return;
        }
        _logPin();
        _;
    }

    // ================================================================== 1. manifest

    function testRuntimeMatchesReleaseManifest() public onlyFork {
        assertEq(address(CORE).codehash, CORE_CODEHASH, "core");
        assertEq(address(CORE).codehash, keccak256(address(CORE).code), "extcodehash == keccak(runtime)");
        assertEq(address(NFT).codehash, NFT_CODEHASH, "NFT");
        assertEq(address(LIFECYCLE).codehash, LIFECYCLE_CODEHASH, "lifecycle");
        assertEq(address(RESERVE).codehash, RESERVE_CODEHASH, "reserve");
        assertEq(address(CUSTODY).codehash, CUSTODY_CODEHASH, "old custody");
        assertEq(address(HUNTER).codehash, HUNTER_CODEHASH, "HUNTER");
    }

    // ================================================================== 2. wiring

    function testLiveWiringAndAuthority() public onlyFork {
        assertEq(block.chainid, CHAIN_ID);
        assertEq(address(CORE.miningPower()), address(CUSTODY), "miningPower != old custody");
        assertTrue(CORE.miningPowerWasAttached());
        assertEq(CORE.MINING_STOP_SUNSET(), SUNSET);
        assertEq(CORE.MINING_STOP_MULTISIG(), STOP_ACCOUNT);
        assertFalse(CORE.miningStopped());
        assertLt(forkTimestamp, SUNSET, "sunset passed");
        assertTrue(CUSTODY.wired());
        assertFalse(CUSTODY.retired());
        assertEq(CUSTODY.latestChallengeId(), CORE.activeChallengeId());
        assertEq(CUSTODY.lastAcceptedProofs(), CORE.acceptedProofs());

        address target = _delegationTarget(STOP_ACCOUNT);
        assertEq(target, STOP_ACCOUNT_DELEGATE, "stop account delegation target changed");
        console2.log("stop account delegation target", target);
        console2.logBytes(STOP_ACCOUNT.code);
        console2.log("delegate code size", target.code.length);
        console2.logBytes32(target.codehash);
        console2.log("stop account ETH balance (wei)", STOP_ACCOUNT.balance);
        console2.log("stop account nonce", vm.getNonce(STOP_ACCOUNT));
        console2.log("acceptedProofs", CORE.acceptedProofs());
        console2.log("activeChallengeId", CORE.activeChallengeId());
        console2.log("activeSeedParentBlock", CORE.activeSeedParentBlock());
        console2.log("lastProofBlock", CORE.lastProofBlock());
        console2.log("challengeState at parent clock", uint8(CORE.challengeState()));
        console2.log("seconds to sunset", SUNSET - forkTimestamp);
    }

    // ================================================================== 3. deploy

    function testDeployModuleAgainstLiveCore() public onlyFork {
        bytes memory args =
            abi.encode(address(HUNTER), address(CORE), MIN_STAKE, LOCK, COOLDOWN, CURVE_UNIT, STOP_ACCOUNT);
        PrefundedMiningPower module = _deployModule();
        assertEq(address(module.HUNTER()), address(HUNTER));
        assertEq(module.miningCore(), address(CORE));
        assertEq(module.MIN_STAKE(), MIN_STAKE);
        assertEq(module.LOCK_PER_MINT(), LOCK);
        assertEq(module.EXIT_COOLDOWN(), COOLDOWN);
        assertEq(module.CURVE_UNIT(), CURVE_UNIT);
        assertEq(module.FAILSAFE_GUARDIAN(), STOP_ACCOUNT);
        assertFalse(module.wired());
        assertFalse(module.retired());
        assertFalse(module.gateDisabled());
        assertEq(module.totalStake(), 0);
        assertEq(module.latestChallengeId(), 0);

        bytes memory creation = type(PrefundedMiningPower).creationCode;
        console2.log("PLACEHOLDER constructor args (abi.encode):");
        console2.logBytes(args);
        console2.log("creation code length", creation.length);
        console2.log("keccak256(creationCode) [compile-profile dependent]");
        console2.logBytes32(keccak256(creation));
        console2.log("keccak256(creationCode ++ args) = deploy tx data hash");
        console2.logBytes32(keccak256(bytes.concat(creation, args)));
        console2.log("deployed runtime size", address(module).code.length);
        console2.log("deployed extcodehash [includes immutables]");
        console2.logBytes32(address(module).codehash);
    }

    // ================================================================== 4. two-tx cutover

    function testCutoverTwoTransactionsFromAuthority() public onlyFork {
        PrefundedMiningPower module = _deployModule();
        uint256 proofs = CORE.acceptedProofs();
        uint256 challenge = CORE.activeChallengeId();

        // tx 1: non-terminal detach of the old custody.
        vm.prank(STOP_ACCOUNT, STOP_ACCOUNT);
        CORE.setMiningPower(IMiningPower(address(0)));
        assertEq(address(CORE.miningPower()), address(0));
        assertFalse(CUSTODY.wired());
        assertFalse(CUSTODY.retired(), "detach must be non-terminal");

        // tx 2: attach the module.
        vm.prank(STOP_ACCOUNT, STOP_ACCOUNT);
        CORE.setMiningPower(IMiningPower(address(module)));
        assertEq(address(CORE.miningPower()), address(module), "pointer");
        assertTrue(module.wired(), "module wired");
        assertEq(module.latestChallengeId(), CORE.activeChallengeId(), "module snapshot");
        assertEq(module.latestChallengeId(), challenge);
        assertEq(module.lastAcceptedProofs(), proofs, "module proof clock synced");
        assertEq(CUSTODY.lastAcceptedProofs(), proofs, "old custody clock frozen");

        // Nobody but the stop account can do this.
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.UnauthorizedMiningStopCaller.selector, address(0xBAD)));
        CORE.setMiningPower(IMiningPower(address(0)));

        // Every real old-custody depositor matured long ago (proof index <= 120 of >= 450),
        // so the live 12-proof rule lets each one unassign and withdraw at once.
        _exitOldDepositor(DEP_5M, DEP_5M_WALLET);
        _exitOldDepositor(DEP_1M, DEP_1M_WALLET);
        _exitOldDepositor(DEP_9K, DEP_9K_WALLET);
        _exitOldDepositor(DEP_5K, DEP_5K_WALLET);
        assertEq(CUSTODY.totalAssigned(), 0, "old custody still assigned");
        assertEq(CUSTODY.totalLocked(), 0, "old custody still locked");
        assertEq(HUNTER.balanceOf(address(CUSTODY)), 0, "old custody still holds HUNTER");
    }

    // ================================================================== 5. atomic 7702 batch

    /// @notice Runs only on a Prague-spec fork (`--evm-version prague`). The stop account
    /// calls its OWN `execute(BATCH_MODE, abi.encode(Execution[]))`; the DeleGator
    /// (`onlyEntryPointOrSelf`) admits it because msg.sender == address(this), and every
    /// inner CALL then carries msg.sender == the stop account, as the core requires.
    function testCutoverAtomic7702Batch() public onlyFork {
        (bool honoured, bytes memory nameRet) = STOP_ACCOUNT.staticcall(abi.encodeCall(IStatelessDeleGator.NAME, ()));
        if (!honoured || nameRet.length == 0) {
            console2.log("SKIP: this fork does not execute EIP-7702 delegations; rerun with --evm-version prague");
            vm.skip(true, "fork does not execute EIP-7702 delegation (use --evm-version prague)");
            return;
        }
        assertEq(abi.decode(nameRet, (string)), "EIP7702StatelessDeleGator");
        assertEq(IStatelessDeleGator(STOP_ACCOUNT).VERSION(), "1.3.0");
        assertTrue(IStatelessDeleGator(STOP_ACCOUNT).supportsExecutionMode(BATCH_MODE), "batch mode");

        PrefundedMiningPower module = _deployModule();
        uint256 proofs = CORE.acceptedProofs();

        // Runbook calldata with the placeholder module.
        bytes memory runbook = _batchCalldata(MODULE_PLACEHOLDER);
        console2.log("RUNBOOK 7702 batch: to = from = stop account, value 0, data =");
        console2.logBytes(runbook);
        assertEq(bytes4(runbook), IStatelessDeleGator.execute.selector);

        // A third party cannot drive the account (not self, not the EntryPoint).
        vm.prank(address(0xBAD));
        (bool ok,) = STOP_ACCOUNT.call(_batchCalldata(address(module)));
        assertFalse(ok, "third party executed the stop account");
        assertEq(address(CORE.miningPower()), address(CUSTODY));

        // Wrong order (attach before detach) reverts the whole batch.
        Execution[] memory wrong = new Execution[](2);
        wrong[0] = Execution(address(CORE), 0, PrefundedCutoverEncoding.attachCalldata(address(module)));
        wrong[1] = Execution(address(CORE), 0, PrefundedCutoverEncoding.detachCalldata());
        vm.prank(STOP_ACCOUNT, STOP_ACCOUNT);
        (ok,) = STOP_ACCOUNT.call(abi.encodeCall(IStatelessDeleGator.execute, (BATCH_MODE, abi.encode(wrong))));
        assertFalse(ok, "wrong order must revert");
        assertEq(address(CORE.miningPower()), address(CUSTODY), "wrong order changed state");
        assertTrue(CUSTODY.wired());

        // Probe inside ONE transaction: detach, attach, attach-again. The third call reverts
        // MiningPowerAlreadyWired(module), proving the pointer was already the module within
        // the same transaction; the whole batch then rolls back.
        Execution[] memory probe = new Execution[](3);
        probe[0] = Execution(address(CORE), 0, PrefundedCutoverEncoding.detachCalldata());
        probe[1] = Execution(address(CORE), 0, PrefundedCutoverEncoding.attachCalldata(address(module)));
        probe[2] = probe[1];
        vm.prank(STOP_ACCOUNT, STOP_ACCOUNT);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.MiningPowerAlreadyWired.selector, address(module)));
        IStatelessDeleGator(STOP_ACCOUNT).execute(BATCH_MODE, abi.encode(probe));
        assertEq(address(CORE.miningPower()), address(CUSTODY));

        // THE cutover: one self-call from the stop account.
        vm.recordLogs();
        vm.prank(STOP_ACCOUNT, STOP_ACCOUNT);
        (ok,) = STOP_ACCOUNT.call(_batchCalldata(address(module)));
        assertTrue(ok, "7702 batch failed");
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(address(CORE.miningPower()), address(module), "pointer");
        assertTrue(module.wired());
        assertFalse(CUSTODY.wired());
        assertFalse(CUSTODY.retired());
        assertEq(module.latestChallengeId(), CORE.activeChallengeId());
        assertEq(module.lastAcceptedProofs(), proofs);

        uint256 sets;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(CORE)) continue;
            assertTrue(logs[i].topics[0] != HunterMiningCore.ProofAccepted.selector, "proof inside the batch");
            if (logs[i].topics[0] != HunterMiningCore.MiningPowerSet.selector) continue;
            assertEq(address(uint160(uint256(logs[i].topics[1]))), sets == 0 ? address(0) : address(module), "order");
            assertEq(address(uint160(uint256(logs[i].topics[2]))), STOP_ACCOUNT, "msg.sender inside the batch");
            sets++;
        }
        assertEq(sets, 2, "two MiningPowerSet in one transaction");

        // Gated right after: an unstaked wallet is refused (SIMULATION: easy target).
        _easyTarget();
        (uint256 cid, uint256 seed) = _activate();
        address outsider = makeAddr("s11-outsider");
        uint256 n = _findNonce(cid, outsider);
        vm.prank(outsider);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.NotEligible.selector, uint8(2)));
        CORE.submitProof(cid, seed, n, LIVE_BASKET);
    }

    // ================================================================== 6. journey

    /// @notice SIMULATION (currentTarget overridden, clock rolled forward): the full
    /// module journey through the LIVE core, NFT, lifecycle and reserve.
    function testJourneyWithOverriddenTarget() public onlyFork {
        PrefundedMiningPower module = _deployModule();
        _cutoverTwoTx(module);
        _easyTarget();

        address funder = makeAddr("s11-funder");
        address wallet = makeAddr("s11-wallet");
        deal(address(HUNTER), funder, MIN_STAKE);
        vm.startPrank(funder);
        HUNTER.approve(address(module), MIN_STAKE);
        module.deposit(MIN_STAKE);
        vm.stopPrank();
        vm.prank(wallet);
        module.approveBacker(funder);
        vm.prank(funder);
        module.assign(wallet, MIN_STAKE);
        (bool eligible, uint8 reason,) = module.eligibilityOf(wallet);
        assertFalse(eligible);
        assertEq(reason, 2, "pending in the challenge the attach opened");

        // Wait one snapshot: expire the live seed and refresh (permissionless).
        _nextChallenge();
        (eligible, reason,) = module.eligibilityOf(wallet);
        assertTrue(eligible, "matured at the next snapshot");
        assertEq(reason, 0);

        uint256 tokenId = _mine(wallet);
        assertEq(NFT.ownerOf(tokenId), wallet);
        _assertLock(module, tokenId, wallet, funder);
        assertEq(module.totalCommitted(), LOCK);
        assertEq(module.assignedOf(wallet), MIN_STAKE - LOCK);
        assertEq(HUNTER.balanceOf(address(module)), MIN_STAKE);
        assertEq(CORE.acceptedProofs(), module.lastAcceptedProofs());
        console2.log("journey tokenId", tokenId);
        _burnAndClaim(module, tokenId, wallet, funder);
    }

    function _assertLock(PrefundedMiningPower module, uint256 tokenId, address wallet, address funder) internal view {
        (uint256 amount, uint256 lockCid,, address miner, address backer, bool released) = module.committedOf(tokenId);
        assertEq(amount, LOCK, "lock");
        assertEq(miner, wallet);
        assertEq(backer, funder);
        assertFalse(released);
        assertEq(lockCid, CORE.activeChallengeId() - 1, "lock tagged with the won challenge");
    }

    /// @dev Burn through the live NFT; the live lifecycle records the burner, who claims.
    function _burnAndClaim(PrefundedMiningPower module, uint256 tokenId, address wallet, address funder) internal {
        vm.prank(wallet);
        NFT.redeemAndDestroy(tokenId);
        assertEq(LIFECYCLE.finalBeneficiary(tokenId), wallet);
        assertFalse(LIFECYCLE.currentMember(tokenId).alive);
        assertTrue(RESERVE.settled(tokenId));
        (bool claimable, address beneficiary, uint256 claimAmount) = module.claimableOf(tokenId);
        assertTrue(claimable);
        assertEq(beneficiary, wallet);
        assertEq(claimAmount, LOCK);

        vm.prank(funder);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.NotBeneficiary.selector, funder));
        module.claimCommitted(tokenId);

        vm.prank(wallet);
        module.claimCommitted(tokenId);
        assertEq(HUNTER.balanceOf(wallet), LOCK, "paid");
        assertEq(module.totalCommitted(), 0);
        assertEq(HUNTER.balanceOf(address(module)), MIN_STAKE - LOCK);
        (,,,,, bool released) = module.committedOf(tokenId);
        assertTrue(released);
    }

    // ================================================================== 7. token

    function testLiveTokenBehaviourAgainstModule() public onlyFork {
        PrefundedMiningPower module = _deployModule();
        address user = makeAddr("s11-token-user");

        // Unwired (prefunding before the cutover) and wired.
        for (uint256 round = 0; round < 2; round++) {
            if (round == 1) _cutoverTwoTx(module);
            deal(address(HUNTER), user, 1e18);
            uint256 supply = HUNTER.totalSupply();
            vm.startPrank(user);
            HUNTER.approve(address(module), 1e18);
            module.deposit(1e18);
            assertEq(module.unassignedOf(user), 1e18, "credited exactly");
            assertEq(module.totalStake(), 1e18);
            assertEq(HUNTER.balanceOf(address(module)), 1e18, "no transfer tax");
            assertEq(HUNTER.balanceOf(user), 0);
            assertEq(module.withdrawableOf(user), 1e18);
            module.withdraw(1e18);
            vm.stopPrank();
            assertEq(HUNTER.balanceOf(user), 1e18, "withdrawn exactly");
            assertEq(HUNTER.balanceOf(address(module)), 0);
            assertEq(module.totalStake(), 0);
            assertEq(HUNTER.totalSupply(), supply, "supply unchanged");
        }
    }

    // ================================================================== 8. sunset

    function testPostSunsetPermanence() public onlyFork {
        PrefundedMiningPower module = _deployModule();
        _cutoverTwoTx(module);

        vm.warp(SUNSET); // last second the setter still works (timestamp > SUNSET reverts)
        uint256 snap = vm.snapshotState();
        vm.prank(STOP_ACCOUNT);
        CORE.setMiningPower(IMiningPower(address(0)));
        vm.revertToState(snap);

        vm.warp(SUNSET + 1);
        vm.prank(STOP_ACCOUNT);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.MiningStopSunsetPassed.selector, SUNSET, SUNSET + 1));
        CORE.setMiningPower(IMiningPower(address(0)));
        vm.prank(STOP_ACCOUNT);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.MiningStopSunsetPassed.selector, SUNSET, SUNSET + 1));
        CORE.stopMining();
        assertEq(address(CORE.miningPower()), address(module), "module permanent after sunset");

        // Only the guardian's one-way failsafe remains, and it still works.
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.UnauthorizedCaller.selector, address(0xBAD)));
        module.disableRequirement();
        vm.prank(STOP_ACCOUNT);
        module.disableRequirement();
        assertTrue(module.gateDisabled());
        vm.prank(STOP_ACCOUNT);
        vm.expectRevert(PrefundedMiningPower.GateDisabled.selector);
        module.disableRequirement();

        // SIMULATION: with the gate disabled an unstaked wallet mines through the live core.
        _easyTarget();
        _nextChallenge();
        address anyone = makeAddr("s11-post-sunset-miner");
        uint256 tokenId = _mine(anyone);
        assertEq(NFT.ownerOf(tokenId), anyone);
        (uint256 amount,,,,,) = module.committedOf(tokenId);
        assertEq(amount, 0, "no lock once the gate is disabled");
    }

    // ================================================================== 9. real depositor, recent

    /// @notice The real depositor DEP_9K tops up (1 HUNTER, dealt) and re-assigns to its
    /// real wallet just BEFORE the cutover, which moves its whole assignment's proof index to
    /// the current count — the case of a depositor who acted within the last 12 proofs. After
    /// the two-tx cutover, it can leave only after 12 live proofs, which now come only from
    /// wallets qualified on the new module. SIMULATION: target overridden, clock rolled.
    function testOldCustodyExitAfterCutoverForRealDepositor() public onlyFork {
        uint256 topUp = 1e18;
        uint256 heldBefore = HUNTER.balanceOf(DEP_9K);
        uint256 assignedBefore = CUSTODY.assignedBy(DEP_9K);
        assertEq(CUSTODY.assigneeOf(DEP_9K), DEP_9K_WALLET);
        deal(address(HUNTER), DEP_9K, heldBefore + topUp);
        vm.startPrank(DEP_9K);
        HUNTER.approve(address(CUSTODY), topUp);
        CUSTODY.deposit(topUp);
        CUSTODY.assign(DEP_9K_WALLET, topUp);
        vm.stopPrank();
        uint256 p = CORE.acceptedProofs();
        assertEq(CUSTODY.assignProofIndex(DEP_9K), p, "proof index reset by the top-up");
        uint256 total = assignedBefore + topUp;

        PrefundedMiningPower module = _deployModule();
        _cutoverTwoTx(module);
        _expectOldDelay(total, p + 12, p);

        // A qualified wallet on the new module mines the next 12 live proofs.
        _easyTarget();
        address funder = makeAddr("s11-qualifier-funder");
        address wallet = makeAddr("s11-qualified-wallet");
        uint256 stake = MIN_STAKE + 11 * LOCK; // floor rule: exactly 12 wins
        deal(address(HUNTER), funder, stake);
        vm.startPrank(funder);
        HUNTER.approve(address(module), stake);
        module.deposit(stake);
        vm.stopPrank();
        vm.prank(wallet);
        module.approveBacker(funder);
        vm.prank(funder);
        module.assign(wallet, stake);
        _nextChallenge();

        for (uint256 i = 0; i < 11; i++) {
            _mine(wallet);
        }
        assertEq(CORE.acceptedProofs(), p + 11);
        assertEq(CUSTODY.lastAcceptedProofs(), p, "detached custody never notified");
        _expectOldDelay(total, p + 12, p + 11);

        _mine(wallet); // 12th live proof on the new module
        assertEq(CORE.acceptedProofs(), p + 12);
        assertEq(module.totalCommitted(), 12 * LOCK);
        assertEq(module.assignedOf(wallet), MIN_STAKE - LOCK, "floor rule: below MIN after 12 wins");

        vm.startPrank(DEP_9K);
        CUSTODY.unassign(DEP_9K_WALLET, total);
        CUSTODY.withdraw(total);
        vm.stopPrank();
        assertEq(HUNTER.balanceOf(DEP_9K), heldBefore + total, "withdraw pays");
        assertEq(CUSTODY.assignedBy(DEP_9K), 0);
    }

    // ================================================================== helpers

    function _deployModule() internal returns (PrefundedMiningPower) {
        return
            new PrefundedMiningPower(
                address(HUNTER), address(CORE), MIN_STAKE, LOCK, COOLDOWN, CURVE_UNIT, STOP_ACCOUNT
            );
    }

    function _cutoverTwoTx(PrefundedMiningPower module) internal {
        vm.prank(STOP_ACCOUNT, STOP_ACCOUNT);
        CORE.setMiningPower(IMiningPower(address(0)));
        vm.prank(STOP_ACCOUNT, STOP_ACCOUNT);
        CORE.setMiningPower(IMiningPower(address(module)));
        assertEq(address(CORE.miningPower()), address(module));
        assertTrue(module.wired());
    }

    function _batchCalldata(address module) internal pure returns (bytes memory) {
        Execution[] memory calls = new Execution[](2);
        calls[0] = Execution(address(CORE), 0, PrefundedCutoverEncoding.detachCalldata());
        calls[1] = Execution(address(CORE), 0, PrefundedCutoverEncoding.attachCalldata(module));
        return abi.encodeCall(IStatelessDeleGator.execute, (BATCH_MODE, abi.encode(calls)));
    }

    function _exitOldDepositor(address depositor, address wallet) internal {
        uint256 amount = CUSTODY.assignedBy(depositor);
        assertGt(amount, 0, "depositor has nothing assigned");
        assertEq(CUSTODY.assigneeOf(depositor), wallet);
        assertLe(CUSTODY.assignProofIndex(depositor) + CUSTODY.UNLOCK_DELAY_PROOFS(), CORE.acceptedProofs());
        uint256 unassigned = CUSTODY.unassignedOf(depositor);
        uint256 before = HUNTER.balanceOf(depositor);
        vm.startPrank(depositor);
        CUSTODY.unassign(wallet, amount);
        CUSTODY.withdraw(amount + unassigned);
        vm.stopPrank();
        assertEq(HUNTER.balanceOf(depositor), before + amount + unassigned, "old custody pays exactly");
    }

    function _expectOldDelay(uint256 amount, uint256 earliest, uint256 current) internal {
        vm.prank(DEP_9K);
        vm.expectRevert(abi.encodeWithSelector(MiningPowerCustody.UnlockDelayNotMet.selector, earliest, current));
        CUSTODY.unassign(DEP_9K_WALLET, amount);
    }

    /// @dev SIMULATION: overrides the live core's currentTarget.
    function _easyTarget() internal {
        vm.store(address(CORE), bytes32(CORE_CURRENT_TARGET_SLOT), bytes32(EASY_TARGET));
        assertEq(CORE.currentTarget(), EASY_TARGET);
    }

    /// @dev Rolls (parent clock) until the active seed is readable and sets its blockhash.
    function _activate() internal returns (uint256 cid, uint256 seed) {
        cid = CORE.activeChallengeId();
        seed = CORE.activeSeedParentBlock();
        if (block.number <= seed) vm.roll(seed + 1);
        require(block.number - seed <= CORE.SEED_READABLE_PARENT_BLOCKS(), "seed expired: call _nextChallenge");
        vm.setBlockhash(seed, keccak256(abi.encode("s11-seed", cid, seed)));
        assertEq(uint8(CORE.challengeState()), ACTIVE);
    }

    /// @dev Expires the live seed (parent clock) and opens the next challenge through the
    /// permissionless refreshExpiredSeed, which snapshots it on the attached module.
    function _nextChallenge() internal {
        uint256 expiry = CORE.activeSeedParentBlock() + CORE.SEED_READABLE_PARENT_BLOCKS() + 1;
        if (block.number < expiry) vm.roll(expiry);
        CORE.refreshExpiredSeed();
    }

    function _findNonce(uint256 cid, address miner) internal view returns (uint256 nonce) {
        bytes32 challenge = CORE.currentChallenge();
        uint256 target = CORE.currentTarget();
        for (; nonce < 4096; nonce++) {
            if (uint256(CORE.deriveProofDigest(cid, challenge, miner, nonce)) <= target) return nonce;
        }
        revert("nonce not found");
    }

    /// @dev Mines one real proof through the live core as `miner`.
    function _mine(address miner) internal returns (uint256 tokenId) {
        (uint256 cid, uint256 seed) = _activate();
        uint256 nonce = _findNonce(cid, miner);
        uint256 before = NFT.mintedEver();
        vm.prank(miner, miner);
        CORE.submitProof(cid, seed, nonce, LIVE_BASKET);
        tokenId = NFT.mintedEver();
        assertEq(tokenId, before + 1);
        assertEq(NFT.ownerOf(tokenId), miner);
    }

    function _delegationTarget(address account) internal view returns (address target) {
        bytes memory code = account.code;
        require(code.length == 23 && code[0] == 0xef && code[1] == 0x01 && code[2] == 0x00, "not 7702-delegated");
        assembly ("memory-safe") {
            target := shr(96, mload(add(code, 35)))
        }
    }

    function _logPin() internal view {
        console2.log("fork L2 block", forkBlock);
        console2.log("fork L2 timestamp", forkTimestamp);
        console2.log("parent (L1) block = core clock", parentBlock);
    }
}
