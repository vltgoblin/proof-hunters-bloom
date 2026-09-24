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
/// @dev Deliberately free of any PrefundedMiningPower import so it compiles
/// before the module exists; a module-aware stack can extend this contract.
/// No module is attached by default — mining runs module-free until a test
/// calls `_attach`. Every amount, fee and bound is a TEST-ONLY fixture value
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
    address internal basket;

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
    function _attach(IMiningPower module) internal {
        vm.prank(STOP);
        core.setMiningPower(module);
        assertEq(address(core.miningPower()), address(module));
    }

    /// @dev Stop multisig detaches the current module (non-terminal).
    function _detach() internal {
        vm.prank(STOP);
        core.setMiningPower(IMiningPower(address(0)));
        assertEq(address(core.miningPower()), address(0));
    }

    /// @dev Harness token books. With no Prefunded module this checks the old
    /// custody: it holds exactly its recorded stake and never assigns more than
    /// it holds. Module-aware stacks override and call `super._assertBooks()`.
    function _assertBooks() internal view virtual {
        assertEq(token.balanceOf(address(oldCustody)), oldCustody.totalLocked(), "old custody books");
        assertLe(oldCustody.totalAssigned(), oldCustody.totalLocked(), "old custody over-assigned");
    }
}
