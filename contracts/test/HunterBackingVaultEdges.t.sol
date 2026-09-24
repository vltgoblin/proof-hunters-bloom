// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {LifecycleTestBase} from "./HunterLifecycleCore.t.sol";
import {HunterBackingVault, IHunterBackingLifecycle} from "../src/bloom/HunterBackingVault.sol";
import {WeightedRoundMaterialisation} from "../src/bloom/WeightedRoundMaterialisation.sol";
import {WeightedRoundFunding} from "../src/bloom/WeightedRoundFunding.sol";
import {WeightedHistory} from "../src/bloom/libraries/WeightedHistory.sol";
import {IBasketConverter} from "../src/bloom/IBasketConverter.sol";
import {HunterNFT} from "../src/bloom/HunterNFT.sol";
import {ReserveTokenFixture} from "./helpers/HunterReserveFixtures.sol";
import {PayoutDebitToken} from "./HunterBackingPayout.t.sol";
import {AdversarialConverterFixture} from "./HunterBasketSwitch.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Basket asset whose inbound vault transfer mutates the deposited NFT:
/// mode 1 moves it to a third party (owner change), mode 2 self-transfers it
/// (authorization nonce bump, same owner). TEST-ONLY.
contract StaleBackingToken is ERC20 {
    HunterNFT public nft;
    uint256 public tokenId;
    uint256 public mode;

    constructor() ERC20("Stale", "STALE") {}

    function arm(HunterNFT nft_, uint256 id, uint256 mode_) external {
        nft = nft_;
        tokenId = id;
        mode = mode_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (mode == 0 || to == address(0)) return;
        uint256 m = mode;
        mode = 0;
        address owner = nft.ownerOf(tokenId);
        nft.transferFrom(owner, m == 1 ? address(0xBEEF) : owner, tokenId);
    }
}

/// @dev Converter that honours the pull/output contract then mutates the NFT
/// mid-conversion, tripping the vault's post-call unchanged check.
contract MutatingConverter is IBasketConverter {
    HunterNFT public nft;
    uint256 public tokenId;

    constructor(HunterNFT nft_, uint256 id) {
        nft = nft_;
        tokenId = id;
    }

    function convert(address assetIn, address assetOut, uint256 amountIn, uint256 minAmountOut)
        external
        returns (uint256)
    {
        require(IERC20(assetIn).transferFrom(msg.sender, address(this), amountIn));
        require(IERC20(assetOut).transfer(msg.sender, minAmountOut));
        nft.transferFrom(nft.ownerOf(tokenId), address(0xBEEF), tokenId);
        return minAmountOut;
    }
}

/// @dev Mock lifecycle bound to a second vault deployment: exposes the
/// canonical back-pointer plus the burn/claim reads the vault depends on.
contract BVMockLifecycle {
    address public backingAddr;
    address public nftAddr;
    address public reserveAddr = address(0xCAFE);
    bool public backingReverts;
    mapping(uint256 => address) public beneficiaries;
    WeightedHistory.Member public member;

    function setBacking(address a) external {
        backingAddr = a;
    }

    function setNft(address a) external {
        nftAddr = a;
    }

    function setBackingReverts(bool v) external {
        backingReverts = v;
    }

    function setBeneficiary(uint256 id, address b) external {
        beneficiaries[id] = b;
    }

    function setMember(WeightedHistory.Member memory m) external {
        member = m;
    }

    function backing() external view returns (address) {
        require(!backingReverts, "backing() reverted");
        return backingAddr;
    }

    function nft() external view returns (address) {
        return nftAddr;
    }

    function reserve() external view returns (address) {
        return reserveAddr;
    }

    function finalBeneficiary(uint256 id) external view returns (address) {
        return beneficiaries[id];
    }

    function currentMember(uint256) external view returns (WeightedHistory.Member memory) {
        return member;
    }
}

/// @dev Mock ledger returning only `lifecycle()`.
contract BVMockLedger {
    address private _lc;

    constructor(address lc_) {
        _lc = lc_;
    }

    function lifecycle() external view returns (address) {
        return _lc;
    }
}

/// @dev Mock NFT with a controllable LIFECYCLE backpointer and liveness.
contract BVMockNft {
    address public immutable bound;
    bool public burned;
    address public owner_ = address(0xBEEF);
    address public basket_ = address(0xBABE);

    constructor(address bound_) {
        bound = bound_;
    }

    function setBurned(bool v) external {
        burned = v;
    }

    function LIFECYCLE() external view returns (address) {
        return bound;
    }

    function ownerOf(uint256) external view returns (address) {
        require(!burned, "burned");
        return owner_;
    }

    function basketOf(uint256) external view returns (address) {
        return basket_;
    }

    function authorizationNonce(uint256) external pure returns (uint256) {
        return 0;
    }

    function isEncumbered(uint256) external pure returns (bool) {
        return false;
    }

    function mintedEver() external pure returns (uint256) {
        return type(uint256).max;
    }
}

/// @notice VLT-38 Stage 2: `HunterBackingVault` guard legs — owner-deposit
/// solvency and stale-state revalidation, the lifecycle-only burn/claim
/// guard rail, the measured switch-conversion guard matrix, and the
/// released-vs-received accounting breaks. Post-transfer insolvency rechecks
/// whose liability moved by the same measured delta are dead by construction
/// and recorded as residuals.
contract HunterBackingVaultEdgesTest is LifecycleTestBase {
    using stdStorage for StdStorage;

    // ---------- depositOwnerBacking ----------

    function testDepositOwnerBackingInsolvencyAndStaleState() public {
        uint256 id = _mint(ALICE, 1, basketA);
        ReserveTokenFixture asset = ReserveTokenFixture(basketA);
        asset.mint(ALICE, 500);
        vm.prank(ALICE);
        asset.approve(address(canonicalBacking), type(uint256).max);
        vm.prank(ALICE);
        canonicalBacking.depositOwnerBacking(id, 100);

        // Balance below combined outstanding liability -> Insolvency.
        stdstore.target(basketA).sig("balanceOf(address)").with_key(address(canonicalBacking)).checked_write(50);
        vm.prank(ALICE);
        vm.expectRevert(WeightedRoundFunding.Insolvency.selector);
        canonicalBacking.depositOwnerBacking(id, 10);
    }

    function testDepositOwnerBackingRejectsOwnerMutationMidPull() public {
        StaleBackingToken stale = new StaleBackingToken();
        registry.admitBasket(address(stale), keccak256("review-stale"));
        uint256 id = _mint(ALICE, 1, address(stale));
        stale.mint(ALICE, 500);
        vm.startPrank(ALICE);
        stale.approve(address(canonicalBacking), type(uint256).max);
        nft.setApprovalForAll(address(stale), true);
        vm.stopPrank();

        // Owner moved away during the pull -> StaleDepositState.
        stale.arm(nft, id, 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.StaleDepositState.selector, id));
        canonicalBacking.depositOwnerBacking(id, 100);
    }

    function testDepositOwnerBackingRejectsNonceMutationMidPull() public {
        StaleBackingToken stale = new StaleBackingToken();
        registry.admitBasket(address(stale), keccak256("review-stale2"));
        uint256 id = _mint(ALICE, 1, address(stale));
        stale.mint(ALICE, 500);
        vm.startPrank(ALICE);
        stale.approve(address(canonicalBacking), type(uint256).max);
        nft.setApprovalForAll(address(stale), true);
        vm.stopPrank();

        // Self-transfer bumps the authorization nonce while the owner reads
        // unchanged -> the nonce/encumbrance leg of StaleDepositState.
        stale.arm(nft, id, 2);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.StaleDepositState.selector, id));
        canonicalBacking.depositOwnerBacking(id, 100);
    }

    // ---------- onBurnBacking / claimBurned caller guards (real wiring) ----------

    function testOnBurnBackingCallerGuards() public {
        uint256 id = _mint(ALICE, 1, basketA);

        // beneficiary bounds are checked before the beneficiary match.
        vm.prank(address(lc));
        vm.expectRevert(HunterBackingVault.InvalidBeneficiary.selector);
        canonicalBacking.onBurnBacking(id, address(0));
        vm.prank(address(lc));
        vm.expectRevert(HunterBackingVault.InvalidBeneficiary.selector);
        canonicalBacking.onBurnBacking(id, address(canonicalBacking));

        // An unburned id has no fixed beneficiary; any nonzero caller-supplied
        // beneficiary mismatches.
        vm.prank(address(lc));
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.BeneficiaryMismatch.selector, id));
        canonicalBacking.onBurnBacking(id, BOB);

        // A real burn settles once; the replay reverts BurnAlreadySettled.
        ReserveTokenFixture asset = ReserveTokenFixture(basketA);
        asset.mint(ALICE, 100);
        vm.prank(ALICE);
        asset.approve(address(canonicalBacking), type(uint256).max);
        vm.prank(ALICE);
        canonicalBacking.depositOwnerBacking(id, 10);
        vm.prank(ALICE);
        nft.redeemAndDestroy(id);
        address beneficiary = lc.finalBeneficiary(id);
        vm.prank(address(lc));
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.BurnAlreadySettled.selector, id));
        canonicalBacking.onBurnBacking(id, beneficiary);
    }

    function testClaimBurnedRejectsUnsettledReplaySurface() public {
        uint256 id = _mint(ALICE, 1, basketA);
        vm.prank(ALICE);
        nft.redeemAndDestroy(id);
        assertTrue(canonicalBacking.burnSettled(id));

        stdstore.target(address(canonicalBacking)).sig("burnSettled(uint256)").with_key(id).checked_write(false);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.BurnNotSettled.selector, id));
        canonicalBacking.claimBurned(1, id);
    }

    function testOnBurnBackingRejectsUnitsWithoutAsset() public {
        uint256 id = _mint(ALICE, 1, basketA);
        vm.prank(ALICE);
        nft.redeemAndDestroy(id);
        address beneficiary = lc.finalBeneficiary(id);

        // Recorded units with a zero basket asset is a malformed ledger: seed
        // the replay surface and re-enter the burn hook.
        stdstore.target(address(canonicalBacking)).sig("burnSettled(uint256)").with_key(id).checked_write(false);
        stdstore.target(address(canonicalBacking)).sig("backingOf(uint256)").with_key(id).checked_write(5);
        stdstore.target(address(nft)).sig("basketOf(uint256)").with_key(id).checked_write(address(0));
        vm.prank(address(lc));
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.InvalidAsset.selector, id));
        canonicalBacking.onBurnBacking(id, beneficiary);
    }

    // ---------- mock-lifecycle vault: canonical binding + member liveness ----------

    function _mockVault() internal returns (HunterBackingVault mv, BVMockLifecycle mlc, BVMockNft mnft) {
        mlc = new BVMockLifecycle();
        mnft = new BVMockNft(address(mlc));
        mlc.setNft(address(mnft));
        BVMockLedger mled = new BVMockLedger(address(mlc));
        mlc.setBacking(vm.computeCreateAddress(address(this), vm.getNonce(address(this))));
        mv = new HunterBackingVault(address(mled), address(this));
    }

    function testMockBoundVaultRejectsUnburnedAndLiveMember() public {
        (HunterBackingVault mv, BVMockLifecycle mlc,) = _mockVault();
        mlc.setBeneficiary(7, BOB);
        mlc.setMember(
            WeightedHistory.Member({basket: address(0xBABE), rarity: 10, hunter: 0, alive: true, eligible: true})
        );
        // A member still alive is not burn-settled history.
        vm.prank(address(mlc));
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.MemberNotBurned.selector, 7));
        mv.onBurnBacking(7, BOB);

        // A dead member with a live NFT contradicts the burn claim.
        mlc.setMember(
            WeightedHistory.Member({basket: address(0xBABE), rarity: 10, hunter: 0, alive: false, eligible: false})
        );
        vm.prank(address(mlc));
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.TokenNotBurned.selector, 7));
        mv.onBurnBacking(7, BOB);
    }

    function testMockBoundVaultClaimGuards() public {
        (HunterBackingVault mv, BVMockLifecycle mlc, BVMockNft mnft) = _mockVault();
        mlc.setMember(
            WeightedHistory.Member({basket: address(0xBABE), rarity: 10, hunter: 0, alive: false, eligible: false})
        );
        mnft.setBurned(true);

        // No settled burn hook -> BurnNotSettled.
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.BurnNotSettled.selector, 7));
        mv.claimBurned(1, 7);

        // A settled hook with a zero fixed beneficiary -> InvalidBeneficiary.
        stdstore.target(address(mv)).sig("burnSettled(uint256)").with_key(7).checked_write(true);
        vm.expectRevert(HunterBackingVault.InvalidBeneficiary.selector);
        mv.claimBurned(1, 7);
    }

    function testCanonicalBindingRejectsMisboundLifecycle() public {
        (HunterBackingVault mv, BVMockLifecycle mlc,) = _mockVault();

        // A lifecycle bound elsewhere fails the canonical check.
        mlc.setBacking(address(0xDEAD));
        vm.expectRevert(WeightedRoundMaterialisation.WiringMismatch.selector);
        mv.claimBurned(1, 7);

        // A reverting backpointer is the same failure class.
        mlc.setBacking(address(mv));
        mlc.setBackingReverts(true);
        vm.expectRevert(WeightedRoundMaterialisation.WiringMismatch.selector);
        mv.claimBurned(1, 7);
    }

    // ---------- convertForSwitch guard matrix (wired lifecycle caller) ----------

    function _backed(uint256 id, uint256 roundUnits, uint256 ownerUnits) internal {
        stdstore.target(address(canonicalBacking)).sig("backingOf(uint256)").with_key(id).checked_write(roundUnits);
        stdstore.target(address(canonicalBacking)).sig("ownerBackingOf(uint256)").with_key(id).checked_write(ownerUnits);
    }

    function testConvertForSwitchQuoteAndAssetGuards() public {
        uint256 id = _mint(ALICE, 1, basketA);

        // Only the wired lifecycle may call the conversion leg.
        vm.expectRevert(HunterBackingVault.UnauthorizedLifecycle.selector);
        canonicalBacking.convertForSwitch(id, address(0xC0DE), basketB, 0, 0);

        // Zero combined backing rejects any nonzero quote.
        vm.prank(address(lc));
        vm.expectRevert(HunterBackingVault.InvalidConversion.selector);
        canonicalBacking.convertForSwitch(id, address(0xC0DE), basketB, 5, 1);

        _backed(id, 100, 0);
        // expectedInput must equal combined backing; minOutput must be nonzero.
        vm.prank(address(lc));
        vm.expectRevert(HunterBackingVault.InvalidConversion.selector);
        canonicalBacking.convertForSwitch(id, address(0xC0DE), basketB, 99, 1);
        vm.prank(address(lc));
        vm.expectRevert(HunterBackingVault.InvalidConversion.selector);
        canonicalBacking.convertForSwitch(id, address(0xC0DE), basketB, 100, 0);

        // Zero and same-asset destinations are invalid.
        vm.prank(address(lc));
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.InvalidAsset.selector, id));
        canonicalBacking.convertForSwitch(id, address(0xC0DE), address(0), 100, 1);
        vm.prank(address(lc));
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.InvalidAsset.selector, id));
        canonicalBacking.convertForSwitch(id, address(0xC0DE), basketA, 100, 1);

        // Encumbered custody blocks conversion.
        vm.prank(ALICE);
        nft.escrowTo(id, address(escrow), "");
        vm.prank(address(lc));
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.TokenEncumbered.selector, id));
        canonicalBacking.convertForSwitch(id, address(0xC0DE), basketB, 100, 1);
    }

    function testConvertForSwitchSolvencyAndCounterGuards() public {
        uint256 id = _mint(ALICE, 1, basketA);
        _backed(id, 1, 0);

        // Combined liability ahead of the measured balance -> Insolvency.
        stdstore.target(address(canonicalBacking)).sig("totalReceived(address)").with_key(basketA).checked_write(200);
        stdstore.target(basketA).sig("balanceOf(address)").with_key(address(canonicalBacking)).checked_write(50);
        vm.prank(address(lc));
        vm.expectRevert(WeightedRoundFunding.Insolvency.selector);
        canonicalBacking.convertForSwitch(id, address(0xC0DE), basketB, 1, 1);

        // Released counter at the received bound leaves no headroom for the
        // switch debit.
        stdstore.target(basketA).sig("balanceOf(address)").with_key(address(canonicalBacking)).checked_write(300);
        stdstore.target(address(canonicalBacking)).sig("totalReleased(address)").with_key(basketA).checked_write(200);
        vm.prank(address(lc));
        vm.expectRevert(WeightedRoundFunding.Insolvency.selector);
        canonicalBacking.convertForSwitch(id, address(0xC0DE), basketB, 1, 1);

        // The owner-source mirror: released at the received bound.
        stdstore.target(address(canonicalBacking)).sig("totalReleased(address)").with_key(basketA)
            .checked_write(uint256(0));
        stdstore.target(address(canonicalBacking)).sig("backingOf(uint256)").with_key(id).checked_write(uint256(0));
        stdstore.target(address(canonicalBacking)).sig("ownerBackingOf(uint256)").with_key(id).checked_write(1);
        stdstore.target(address(canonicalBacking)).sig("totalOwnerReceived(address)").with_key(basketA)
            .checked_write(50);
        stdstore.target(address(canonicalBacking)).sig("totalOwnerReleased(address)").with_key(basketA)
            .checked_write(50);
        vm.prank(address(lc));
        vm.expectRevert(WeightedRoundFunding.Insolvency.selector);
        canonicalBacking.convertForSwitch(id, address(0xC0DE), basketB, 1, 1);
    }

    function testConvertForSwitchConverterMisbehavior() public {
        uint256 id = _mint(ALICE, 1, basketA);
        _backed(id, 100, 0);
        stdstore.target(address(canonicalBacking)).sig("totalReceived(address)").with_key(basketA).checked_write(100);
        ReserveTokenFixture assetA = ReserveTokenFixture(basketA);
        assetA.mint(address(canonicalBacking), 100);
        ReserveTokenFixture assetB = ReserveTokenFixture(basketB);
        AdversarialConverterFixture conv = new AdversarialConverterFixture();
        assetB.mint(address(conv), 1_000);

        // Under-debit: the converter pulled less than the exact input.
        conv.setMode(AdversarialConverterFixture.Mode.UnderDebit);
        vm.prank(address(lc));
        vm.expectRevert(HunterBackingVault.DebitMismatch.selector);
        canonicalBacking.convertForSwitch(id, address(conv), basketB, 100, 1);

        // No output at all -> InsufficientConversionOutput(minOutput, 0).
        conv.setMode(AdversarialConverterFixture.Mode.NoOutput);
        vm.prank(address(lc));
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.InsufficientConversionOutput.selector, 10, 0));
        canonicalBacking.convertForSwitch(id, address(conv), basketB, 100, 10);

        // Short output -> InsufficientConversionOutput(minOutput, actual).
        conv.setMode(AdversarialConverterFixture.Mode.ShortOutput);
        vm.prank(address(lc));
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.InsufficientConversionOutput.selector, 10, 9));
        canonicalBacking.convertForSwitch(id, address(conv), basketB, 100, 10);
    }

    function testConvertForSwitchRejectsNftMutationMidConversion() public {
        uint256 id = _mint(ALICE, 1, basketA);
        _backed(id, 100, 0);
        stdstore.target(address(canonicalBacking)).sig("totalReceived(address)").with_key(basketA).checked_write(100);
        ReserveTokenFixture assetA = ReserveTokenFixture(basketA);
        assetA.mint(address(canonicalBacking), 100);
        ReserveTokenFixture assetB = ReserveTokenFixture(basketB);

        MutatingConverter conv = new MutatingConverter(nft, id);
        assetB.mint(address(conv), 1_000);
        vm.prank(ALICE);
        nft.setApprovalForAll(address(conv), true);

        vm.prank(address(lc));
        vm.expectRevert(abi.encodeWithSelector(HunterBackingVault.StaleConversionState.selector, id));
        canonicalBacking.convertForSwitch(id, address(conv), basketB, 100, 10);
    }

    // ---------- _outstanding override + _release accounting breaks ----------

    function testOutstandingRejectsOwnerReleasedAheadOfReceived() public {
        // ownerReleased > ownerReceived is an impossible-by-construction
        // break; the combined liability view reverts rather than underflowing.
        stdstore.target(address(canonicalBacking)).sig("totalOwnerReleased(address)").with_key(basketA).checked_write(1);
        vm.expectRevert(WeightedRoundFunding.Insolvency.selector);
        canonicalBacking.unaccountedBalance(basketA);
    }

    function testReleaseAccountingGuards() public {
        uint256 id = _mint(ALICE, 1, basketA);
        ReserveTokenFixture assetA = ReserveTokenFixture(basketA);
        assetA.mint(address(canonicalBacking), 1_000);
        vm.prank(ALICE);
        nft.redeemAndDestroy(id);
        address beneficiary = lc.finalBeneficiary(id);
        stdstore.target(address(canonicalBacking)).sig("burnSettled(uint256)").with_key(id).checked_write(false);
        _backed(id, 100, 0);
        stdstore.target(address(canonicalBacking)).sig("totalReceived(address)").with_key(basketA).checked_write(100);

        // Balance below combined outstanding liability -> Insolvency.
        stdstore.target(basketA).sig("balanceOf(address)").with_key(address(canonicalBacking)).checked_write(50);
        vm.prank(address(lc));
        vm.expectRevert(WeightedRoundFunding.Insolvency.selector);
        canonicalBacking.onBurnBacking(id, beneficiary);

        // Released at the received bound leaves the debit unpayable.
        stdstore.target(basketA).sig("balanceOf(address)").with_key(address(canonicalBacking)).checked_write(1_000);
        stdstore.target(address(canonicalBacking)).sig("totalReleased(address)").with_key(basketA).checked_write(100);
        vm.prank(address(lc));
        vm.expectRevert(WeightedRoundFunding.Insolvency.selector);
        canonicalBacking.onBurnBacking(id, beneficiary);

        // The owner-source mirror inside _release.
        stdstore.target(address(canonicalBacking)).sig("totalReleased(address)").with_key(basketA)
            .checked_write(uint256(0));
        stdstore.target(address(canonicalBacking)).sig("backingOf(uint256)").with_key(id).checked_write(uint256(0));
        stdstore.target(address(canonicalBacking)).sig("ownerBackingOf(uint256)").with_key(id).checked_write(1);
        stdstore.target(address(canonicalBacking)).sig("totalOwnerReceived(address)").with_key(basketA)
            .checked_write(100);
        stdstore.target(address(canonicalBacking)).sig("totalOwnerReleased(address)").with_key(basketA)
            .checked_write(100);
        vm.prank(address(lc));
        vm.expectRevert(WeightedRoundFunding.Insolvency.selector);
        canonicalBacking.onBurnBacking(id, beneficiary);
    }

    function testReleaseRejectsMisdebitingAsset() public {
        PayoutDebitToken hostile = new PayoutDebitToken();
        registry.admitBasket(address(hostile), keccak256("review-debit"));
        uint256 id = _mint(ALICE, 1, address(hostile));
        hostile.mint(address(canonicalBacking), 200);
        vm.prank(ALICE);
        nft.redeemAndDestroy(id);
        address beneficiary = lc.finalBeneficiary(id);

        stdstore.target(address(canonicalBacking)).sig("burnSettled(uint256)").with_key(id).checked_write(false);
        _backed(id, 100, 0);
        stdstore.target(address(canonicalBacking)).sig("totalReceived(address)").with_key(address(hostile))
            .checked_write(200);
        hostile.configure(address(canonicalBacking), 2); // burn one unit on outbound

        vm.prank(address(lc));
        vm.expectRevert(HunterBackingVault.DebitMismatch.selector);
        canonicalBacking.onBurnBacking(id, beneficiary);
    }
}
