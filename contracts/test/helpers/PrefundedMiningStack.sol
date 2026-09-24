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

    // S9 (VLT-60) old-custody depositors for cutover tests (TEST-ONLY).
    address internal constant OLD_MATURED = address(0x01D1);
    address internal constant OLD_RECENT = address(0x01D2);
    address internal constant OLD_IDLE = address(0x01D3);
    address internal constant OLD_MATURED_WALLET = address(0x01E1);
    address internal constant OLD_RECENT_WALLET = address(0x01E2);
    /// @dev Unstaked wallet that mines the old custody's live proofs.
    address internal constant OLD_SOLO = address(0x0150);
    uint256 internal constant OLD_MATURED_STAKE = 3_000e18;
    uint256 internal constant OLD_RECENT_STAKE = 2_000e18;
    uint256 internal constant OLD_IDLE_STAKE = 1_500e18;

    function setUp() public virtual {
        vm.roll(1_000);
        vm.warp(100);
        _buildStack(STOP);
    }

    /// @dev Deploys the whole real stack (registry through old custody) with
    /// `miningStopMultisig` as the core's immutable `MINING_STOP_MULTISIG`,
    /// and points every harness variable at it. `setUp` calls it with the
    /// `STOP` EOA; a test may call it again (S9) to get a SECOND, fully
    /// independent real stack — own core, NFT, lifecycle, reserve, token and
    /// old custody — governed by a contract multisig. Resets `module`.
    function _buildStack(address miningStopMultisig) internal {
        module = PrefundedMiningPower(address(0));
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
            miningStopMultisig,
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
        assertEq(core.MINING_STOP_MULTISIG(), miningStopMultisig);
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

    /// @dev Stop multisig (the `STOP` EOA) wires the OLD custody (S9).
    function _attachOld() internal {
        _attach(IMiningPower(address(oldCustody)));
        assertTrue(oldCustody.wired());
    }

    /// @dev Mints `amt` fixture HUNTER to `who` and deposits it into the OLD custody.
    function _oldDeposit(address who, uint256 amt) internal {
        token.mint(who, amt);
        vm.startPrank(who);
        token.approve(address(oldCustody), amt);
        oldCustody.deposit(amt);
        vm.stopPrank();
    }

    /// @dev `who` assigns `amt` of its old-custody stake to `wallet` (needs
    /// the old custody wired).
    function _oldAssign(address who, address wallet, uint256 amt) internal {
        vm.prank(who);
        oldCustody.assign(wallet, amt);
    }

    /// @dev S9 old-custody population on an ATTACHED old custody:
    /// - OLD_MATURED assigns `OLD_MATURED_STAKE` to OLD_MATURED_WALLET, then
    ///   `UNLOCK_DELAY_PROOFS` (12) live proofs are mined (by the unstaked
    ///   OLD_SOLO — the old module is optional power, never a gate), so its
    ///   unlock delay is met;
    /// - OLD_RECENT assigns `OLD_RECENT_STAKE` to OLD_RECENT_WALLET after
    ///   those proofs (within the last 12), so it still waits 12 more;
    /// - OLD_IDLE deposits `OLD_IDLE_STAKE` and never assigns.
    /// Returns the core's accepted-proof count at the end (the RECENT
    /// assignment's proof index).
    function _mixedOldDepositors() internal returns (uint256 proofs) {
        require(address(core.miningPower()) == address(oldCustody), "old custody not attached");
        _oldDeposit(OLD_MATURED, OLD_MATURED_STAKE);
        _oldDeposit(OLD_RECENT, OLD_RECENT_STAKE);
        _oldDeposit(OLD_IDLE, OLD_IDLE_STAKE);
        _oldAssign(OLD_MATURED, OLD_MATURED_WALLET, OLD_MATURED_STAKE);
        uint256 maturedAt = oldCustody.assignProofIndex(OLD_MATURED);
        uint256 delay = oldCustody.UNLOCK_DELAY_PROOFS();
        for (uint256 i = 0; i < delay; i++) {
            _win(OLD_SOLO);
        }
        _oldAssign(OLD_RECENT, OLD_RECENT_WALLET, OLD_RECENT_STAKE);
        proofs = core.acceptedProofs();
        assertEq(oldCustody.lastAcceptedProofs(), proofs);
        assertGe(proofs, maturedAt + delay, "MATURED not matured");
        assertEq(oldCustody.assignProofIndex(OLD_RECENT), proofs);
        assertEq(oldCustody.unassignedOf(OLD_IDLE), OLD_IDLE_STAKE);
        assertEq(oldCustody.totalAssigned(), OLD_MATURED_STAKE + OLD_RECENT_STAKE);
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

    /// @dev Opens the next challenge WITHOUT an accepted proof: rolls past the
    /// active seed's readable window and calls the permissionless
    /// `core.refreshExpiredSeed()`, which snapshots the new challenge on the
    /// attached module. Call `_activate()` afterwards to mine in it.
    function _nextChallenge() internal {
        uint256 expiry = core.activeSeedParentBlock() + core.SEED_READABLE_PARENT_BLOCKS() + 1;
        if (block.number < expiry) vm.roll(expiry);
        core.refreshExpiredSeed();
    }

    /// @dev `depositor` deposits `stake` and assigns it to `wallet`; the next
    /// challenge is then opened (via `_nextChallenge`, so no pre-existing
    /// eligible miner is needed) and activated, so the stake has matured and
    /// `wallet` can mine immediately. The module must be attached.
    function _qualify(address depositor, address wallet, uint256 stake) internal {
        _deposit(depositor, stake);
        _assign(depositor, wallet, stake);
        _nextChallenge();
        _activate();
    }

    /// @dev Floor rule: `depositor` stakes exactly enough for `wallet` to
    /// win `wins` times (one per challenge) — `MIN_STAKE + (wins - 1) *
    /// LOCK_PER_MINT`, read from `module` — then the next challenge opens
    /// and is activated, as in `_qualify`. After the last paid win the
    /// wallet's stake is `MIN_STAKE - LOCK_PER_MINT`, below the floor.
    function _qualifyFor(address depositor, address wallet, uint256 wins) internal returns (uint256 stake) {
        require(wins != 0, "wins == 0");
        stake = module.MIN_STAKE() + (wins - 1) * module.LOCK_PER_MINT();
        _qualify(depositor, wallet, stake);
    }

    /// @dev `claimant` claims the lock of burned `tokenId` to itself (S7).
    function _claim(uint256 tokenId, address claimant) internal {
        vm.prank(claimant);
        module.claimCommitted(tokenId);
    }

    /// @dev Expects the next call to revert with the gate's `NotEligible(reason)`.
    function _expectNotEligible(uint8 reason) internal {
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.NotEligible.selector, reason));
    }

    /// @dev Harness token books. The old custody holds exactly its recorded
    /// stake and never assigns more than it holds. When a Prefunded `module`
    /// is deployed it must hold at least its obligations, and the tracked
    /// accounts must reproduce its totals exactly (every depositor's
    /// unassigned + assigned stake sums to `totalStake`; every wallet's
    /// assigned stake sums to `totalAssigned` and equals the sum of its
    /// backers' `assignedBy`; a depositor's held stake never exceeds what
    /// it still has in the module and `withdrawableOf` is exactly the unheld
    /// unassigned part). One funder per wallet: `backerOf[w]` is nonzero
    /// exactly while `assignedOf[w]` is, and then that backer's `assignedBy`
    /// is the whole of `assignedOf[w]` and its assignee is `w`. Locks: the
    /// unreleased locks over every minted token id sum to `totalCommitted`
    /// (released locks are excluded, and each released lock belongs to a
    /// burned NFT), and the balance covers `totalStake + totalCommitted`.
    /// Only exact while all ledger calls go through the tracking helpers
    /// (or `_trackDepositor` / `_trackWallet`).
    function _assertBooks() internal view virtual {
        assertEq(token.balanceOf(address(oldCustody)), oldCustody.totalLocked(), "old custody books");
        assertLe(oldCustody.totalAssigned(), oldCustody.totalLocked(), "old custody over-assigned");
        if (address(module) == address(0)) return;

        assertGe(
            token.balanceOf(address(module)),
            module.totalStake() + module.totalCommitted(),
            "module insolvent"
        );
        assertLe(module.totalAssigned(), module.totalStake(), "module over-assigned");

        uint256 stakeSum;
        for (uint256 i = 0; i < trackedDepositors.length; i++) {
            address d = trackedDepositors[i];
            stakeSum += module.unassignedOf(d) + module.assignedBy(d);
            assertLe(module.pendingBy(d), module.assignedBy(d), "pendingBy > assignedBy");
            // Held stake is always still in the module (unassigned, or
            // re-assigned as pending elsewhere); only the unheld part leaves.
            uint256 held = module.heldStakeOf(d);
            assertLe(held, module.unassignedOf(d) + module.assignedBy(d), "held stake left the module");
            assertLe(module.withdrawableOf(d), module.unassignedOf(d), "withdrawable > unassigned");
            assertEq(
                module.withdrawableOf(d),
                module.unassignedOf(d) - (held < module.unassignedOf(d) ? held : module.unassignedOf(d)),
                "withdrawable != unassigned - held"
            );
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
            address backer = module.backerOf(w);
            if (module.assignedOf(w) == 0) {
                assertEq(backer, address(0), "backer without stake");
            } else {
                assertTrue(backer != address(0), "stake without backer");
                assertEq(module.assignedBy(backer), module.assignedOf(w), "backer != wallet stake");
                assertEq(module.assigneeOf(backer), w, "backer backs another wallet");
            }
        }
        assertEq(assignedSum, module.totalAssigned(), "wallet sums != totalAssigned");

        uint256 committedSum;
        uint256 minted = nft.mintedEver();
        for (uint256 id = 1; id <= minted; id++) {
            (uint256 amount,,,,, bool released) = module.committedOf(id);
            if (!released) {
                committedSum += amount;
            } else {
                // S7: a lock is only ever released for a burned NFT.
                assertTrue(amount != 0, "released lock without amount");
                assertFalse(lifecycle.currentMember(id).alive, "released lock of a live member");
                bool ownerReadable;
                try nft.ownerOf(id) returns (address) {
                    ownerReadable = true;
                } catch {}
                assertFalse(ownerReadable, "released lock of an unburned NFT");
            }
        }
        assertEq(committedSum, module.totalCommitted(), "unreleased locks != totalCommitted");
    }
}
