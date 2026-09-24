// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BasketRegistry} from "../../src/bloom/BasketRegistry.sol";
import {HunterNFT} from "../../src/bloom/HunterNFT.sol";
import {HunterLifecycle} from "../../src/bloom/HunterLifecycle.sol";
import {HunterReserveVault} from "../../src/bloom/HunterReserveVault.sol";
import {HunterBackingVault} from "../../src/bloom/HunterBackingVault.sol";
import {WeightedRoundLedger} from "../../src/bloom/WeightedRoundLedger.sol";
import {HunterMiningCore} from "../../src/bloom/HunterMiningCore.sol";
import {MiningPowerCustody} from "../../src/bloom/MiningPowerCustody.sol";
import {PrefundedMiningPower} from "../../src/bloom/PrefundedMiningPower.sol";
import {IMiningPower} from "../../src/bloom/IMiningPower.sol";
import {DirectLoan} from "../../src/bloom/DirectLoan.sol";
import {LiveHunt} from "../../src/LiveHunt.sol";
import {ILiveHuntNFT} from "../../src/ILiveHuntNFT.sol";
import {HunterBasketFixture} from "../HunterNFT.t.sol";
import {ReserveTokenFixture} from "./HunterReserveFixtures.sol";

/// @dev TEST-ONLY loan asset for the harness DirectLoan. Open mint; not a
/// product token and not a launch choice.
contract PrefundedStackLoanAsset is ERC20 {
    constructor() ERC20("MOCK-LOAN-PREFUNDED-STACK", "mLOAN") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice Shared REAL-stack harness for the Prefunded Mining Power slices.
/// Wiring is copied from `HunterLateMiningPower.t.sol`: registry, basket,
/// lifecycle, ledger, backing, reserve and finally the mining core, which
/// deploys its own HunterNFT at a predicted address. On top of that recipe the
/// harness adds a HUNTER stand-in (`token`) recorded on the reserve by the
/// launch authority (token-bound like production), a real LiveHunt and a real
/// DirectLoan bound to the core-deployed NFT, and the OLD MiningPowerCustody
/// (`oldCustody`) constructed against `token` and `core` but NOT attached.
/// @dev `_deployModule` builds a PrefundedMiningPower against `token` and
/// `core` and records it as `module`; ledger helpers (`_deposit`, `_assign`,
/// `_unassign`, `_withdraw`) track every depositor and mining wallet they
/// touch so `_assertBooks` can prove the per-account sums. No module is
/// attached by default — mining runs module-free until a test calls
/// `_attach`. Every amount, fee and bound is a TEST-ONLY fixture value
/// taken from existing suites, never a launch decision.
abstract contract PrefundedMiningStack is Test {
    BasketRegistry internal registry;
    HunterLifecycle internal lifecycle;
    WeightedRoundLedger internal ledger;
    HunterBackingVault internal backing;
    HunterReserveVault internal vault;
    HunterNFT internal nft;
    HunterMiningCore internal core;
    ReserveTokenFixture internal token;
    LiveHunt internal hunt;
    DirectLoan internal loan;
    PrefundedStackLoanAsset internal loanAsset;
    MiningPowerCustody internal oldCustody;
    /// @dev Module under test, set by `_deployModule` (zero until then).
    PrefundedMiningPower internal module;
    address internal basket;

    /// @dev Every depositor / mining wallet the ledger helpers touched.
    address[] internal trackedDepositors;
    address[] internal trackedWallets;
    mapping(address => bool) private _isTrackedDepositor;
    mapping(address => bool) private _isTrackedWallet;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant MINER = address(0x111E);
    address internal constant FUNDER = address(0xF0);
    address internal constant LAUNCH = address(0x1A04C);
    address internal constant STOP = address(0x5709);
    address internal constant COLLECTOR = address(0xC011EC7);
    address internal constant LENDER = address(0x1E4D);
    address internal constant FEE_SINK = address(0xFEE5);

    uint256 internal constant CURVE_UNIT = 1_000e18;

    // TEST-ONLY LiveHunt constructor fixtures (same values as
    // DirectLoanMutualExclusion.t.sol / HunterLiveHuntIntegration.t.sol).
    uint256 internal constant HUNT_MIN_OFFER = 0.005 ether;
    uint256 internal constant HUNT_MIN_DURATION = 1 days;
    uint256 internal constant HUNT_MAX_DURATION = 90 days;
    uint256 internal constant HUNT_FEE_BPS = 250;
    uint256 internal constant HUNT_MAX_FEE_BPS = 500;
    uint256 internal constant HUNT_OFFER = 0.01 ether + 3;

    // TEST-ONLY DirectLoan fixtures (same values as DirectLoan.t.sol).
    uint256 internal constant LOAN_FEE_BPS = 100;
    uint256 internal constant LOAN_PRINCIPAL = 100 ether;
    uint256 internal constant LOAN_REPAYMENT = 110 ether;
    uint256 internal constant LOAN_DURATION = 7 days;

    /// @dev Active challenge id / seed parent block, synced by `_activate`.
    uint256 internal cid;
    uint256 internal seed;

    function setUp() public virtual {
        vm.roll(1_000);
        vm.warp(100);
        registry = new BasketRegistry(address(this));
        basket = address(new HunterBasketFixture());
        registry.admitBasket(basket, keccak256("review"));

        // Real stack: the mining core lands LAST and deploys its own NFT, so
        // the lifecycle/reserve/backing predictions wrap around it.
        uint64 n = vm.getNonce(address(this));
        address wantCore = vm.computeCreateAddress(address(this), n + 4);
        address wantNft = vm.computeCreateAddress(wantCore, 1);
        address wantReserve = vm.computeCreateAddress(address(this), n + 3);
        address wantBacking = vm.computeCreateAddress(address(this), n + 2);
        lifecycle = new HunterLifecycle(
            wantNft, wantReserve, wantBacking, [uint64(100), uint64(110), uint64(125), uint64(150)]
        );
        ledger = new WeightedRoundLedger(address(lifecycle), address(this), 7, 10);
        backing = new HunterBackingVault(address(ledger), address(this));
        vault = new HunterReserveVault(wantNft, address(lifecycle), LAUNCH);
        core = new HunterMiningCore(
            type(uint256).max / 4,
            type(uint256).max - type(uint256).max / 4,
            type(uint256).max / 2,
            block.number + 3,
            3,
            STOP,
            block.timestamp + 30 days,
            HunterMiningCore.ProofNftDeploymentData(
                address(registry), address(lifecycle), 1, address(this), "ipfs://hunters/"
            )
        );
        nft = core.PROOF_NFT();
        assertEq(address(nft), wantNft);
        assertEq(address(core), wantCore);
        assertEq(address(vault), wantReserve);
        assertEq(address(backing), wantBacking);
        assertEq(nft.MINER(), address(core));
        assertEq(address(nft.LIFECYCLE()), address(lifecycle));

        // HUNTER stand-in recorded once by the reserve's launch authority —
        // deployed after the core so the positional predictions above hold.
        token = new ReserveTokenFixture();
        token.setVault(address(vault));
        vm.prank(LAUNCH);
        vault.activateToken(address(token));
        assertEq(address(vault.HUNTER()), address(token));

        hunt = new LiveHunt(
            ILiveHuntNFT(address(nft)),
            HUNT_MIN_OFFER,
            HUNT_MIN_DURATION,
            HUNT_MAX_DURATION,
            HUNT_FEE_BPS,
            HUNT_MAX_FEE_BPS,
            FEE_SINK,
            STOP,
            block.timestamp + 360 days
        );
        assertEq(address(hunt.PROOF_NFT()), address(nft));

        loanAsset = new PrefundedStackLoanAsset();
        loan = new DirectLoan(
            DirectLoan.Config({
                nft: address(nft),
                loanAsset: address(loanAsset),
                feeRecipient: FEE_SINK,
                stopAuthority: STOP,
                feeBps: LOAN_FEE_BPS,
                feeCap: 0,
                minPrincipal: 1 ether,
                maxPrincipal: 1_000 ether,
                minDuration: 1 days,
                maxDuration: 90 days,
                requestFundingWindow: 3 days,
                defaultResolutionWindow: 1 days
            })
        );

        // The old module exists for regression comparisons but is NOT wired:
        // mining stays module-free until a test calls `_attach`.
        oldCustody = new MiningPowerCustody(address(token), address(core), CURVE_UNIT);
        assertEq(address(core.miningPower()), address(0));
        assertFalse(oldCustody.wired());
    }

    /// @dev Syncs `cid`/`seed` to the core and makes the seed blockhash
    /// readable. Only rolls forward (never back past a later block).
    function _activate() internal {
        cid = core.activeChallengeId();
        seed = core.activeSeedParentBlock();
        if (block.number <= seed) vm.roll(seed + 1);
        vm.setBlockhash(seed, keccak256(abi.encode("seed", cid, seed)));
    }

    /// @dev Any nonce whose proof digest clears the current (base) target.
    function _nonce(address miner) internal view returns (uint256 nonce, bytes32 digest) {
        bytes32 challenge = core.currentChallenge();
        uint256 target = core.currentTarget();
        for (; nonce < 4_096; nonce++) {
            digest = core.deriveProofDigest(cid, challenge, miner, nonce);
            if (uint256(digest) <= target) return (nonce, digest);
        }
        revert("nonce not found");
    }

    /// @dev Submits through the REAL core as `miner` for the synced challenge.
    function _send(address miner, uint256 nonce) internal returns (bytes32) {
        vm.prank(miner);
        return core.submitProof(cid, seed, nonce, basket);
    }

    /// @dev Activate, find a base-target nonce and mine one real NFT to `wallet`.
    function _win(address wallet) internal returns (uint256 tokenId) {
        _activate();
        (uint256 nonce,) = _nonce(wallet);
        uint256 before = nft.mintedEver();
        _send(wallet, nonce);
        tokenId = nft.mintedEver();
        assertEq(tokenId, before + 1);
        assertEq(nft.ownerOf(tokenId), wallet);
    }

    /// @dev Real owner-directed burn: lifecycle settles reserve and backing
    /// and records the final beneficiary.
    function _burn(uint256 tokenId) internal {
        address owner = nft.ownerOf(tokenId);
        vm.prank(owner);
        nft.redeemAndDestroy(tokenId);
    }

    /// @dev Stop multisig wires `module` through the pre-sunset setter.
    function _attach(IMiningPower power) internal {
        vm.prank(STOP);
        core.setMiningPower(power);
        assertEq(address(core.miningPower()), address(power));
    }

    /// @dev Stop multisig detaches the current module (non-terminal).
    function _detach() internal {
        vm.prank(STOP);
        core.setMiningPower(IMiningPower(address(0)));
        assertEq(address(core.miningPower()), address(0));
    }

    /// @dev Deploys the module under test against `token` and `core` and
    /// records it as `module`. Not attached — call `_attach(module)`.
    function _deployModule(uint256 minStake, uint256 lock, uint256 cooldown, uint256 curveUnit, address guardian)
        internal
        returns (PrefundedMiningPower)
    {
        module = new PrefundedMiningPower(address(token), address(core), minStake, lock, cooldown, curveUnit, guardian);
        return module;
    }

    function _trackDepositor(address who) internal {
        if (_isTrackedDepositor[who]) return;
        _isTrackedDepositor[who] = true;
        trackedDepositors.push(who);
    }

    function _trackWallet(address wallet) internal {
        if (_isTrackedWallet[wallet]) return;
        _isTrackedWallet[wallet] = true;
        trackedWallets.push(wallet);
    }

    /// @dev Mints `amt` fixture HUNTER to `who` and deposits it into `module`.
    function _deposit(address who, uint256 amt) internal {
        _trackDepositor(who);
        token.mint(who, amt);
        vm.startPrank(who);
        token.approve(address(module), amt);
        module.deposit(amt);
        vm.stopPrank();
    }

    function _assign(address who, address wallet, uint256 amt) internal {
        _trackDepositor(who);
        _trackWallet(wallet);
        vm.prank(who);
        module.assign(wallet, amt);
    }

    function _unassign(address who, address wallet, uint256 amt) internal {
        _trackDepositor(who);
        _trackWallet(wallet);
        vm.prank(who);
        module.unassign(wallet, amt);
    }

    function _withdraw(address who, uint256 amt) internal {
        _trackDepositor(who);
        vm.prank(who);
        module.withdraw(amt);
    }

    /// @dev Harness token books. The old custody holds exactly its recorded
    /// stake and never assigns more than it holds. When a Prefunded `module`
    /// is deployed it must hold at least its obligations, and the tracked
    /// accounts must reproduce its totals exactly (every depositor's
    /// unassigned + assigned stake sums to `totalStake`; every wallet's
    /// assigned stake sums to `totalAssigned` and equals the sum of its
    /// backers' `assignedBy`). Only exact while all ledger calls go through
    /// the tracking helpers (or `_trackDepositor` / `_trackWallet`).
    function _assertBooks() internal view virtual {
        assertEq(token.balanceOf(address(oldCustody)), oldCustody.totalLocked(), "old custody books");
        assertLe(oldCustody.totalAssigned(), oldCustody.totalLocked(), "old custody over-assigned");
        if (address(module) == address(0)) return;

        assertGe(
            token.balanceOf(address(module)),
            module.totalStake() + module.totalFunds() + module.totalCommitted(),
            "module insolvent"
        );
        assertLe(module.totalAssigned(), module.totalStake(), "module over-assigned");

        uint256 stakeSum;
        for (uint256 i = 0; i < trackedDepositors.length; i++) {
            address d = trackedDepositors[i];
            stakeSum += module.unassignedOf(d) + module.assignedBy(d);
            assertLe(module.pendingBy(d), module.assignedBy(d), "pendingBy > assignedBy");
            if (module.assignedBy(d) == 0) assertEq(module.assigneeOf(d), address(0), "dangling assignee");
            else assertTrue(module.assigneeOf(d) != address(0), "assigned without assignee");
        }
        assertEq(stakeSum, module.totalStake(), "depositor sums != totalStake");

        uint256 assignedSum;
        for (uint256 j = 0; j < trackedWallets.length; j++) {
            address w = trackedWallets[j];
            assignedSum += module.assignedOf(w);
            assertLe(module.pendingOf(w), module.assignedOf(w), "pendingOf > assignedOf");
            uint256 backers;
            for (uint256 i = 0; i < trackedDepositors.length; i++) {
                address d = trackedDepositors[i];
                if (module.assigneeOf(d) == w) backers += module.assignedBy(d);
            }
            assertEq(backers, module.assignedOf(w), "wallet != sum of backers");
        }
        assertEq(assignedSum, module.totalAssigned(), "wallet sums != totalAssigned");
    }
}
