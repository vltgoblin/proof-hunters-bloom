// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HunterMiningCore} from "../src/bloom/HunterMiningCore.sol";
import {PrefundedMiningPower} from "../src/bloom/PrefundedMiningPower.sol";
import {PrefundedMiningStack} from "./helpers/PrefundedMiningStack.sol";

/// @dev TEST-ONLY contract mining wallet: submits a proof through the real core.
contract SettlementMiner {
    function submit(HunterMiningCore core, uint256 id, uint256 seedBlock, uint256 nonce, address basket)
        external
        returns (bytes32)
    {
        return core.submitProof(id, seedBlock, nonce, basket);
    }
}

/// @dev TEST-ONLY depositor that stakes for a separate contract mining wallet
/// and makes that wallet submit, all in ONE transaction.
contract SameTxStaker {
    IERC20 private immutable _token;
    PrefundedMiningPower private immutable _module;

    constructor(IERC20 token_, PrefundedMiningPower module_) {
        _token = token_;
        _module = module_;
    }

    function stake(address miner, uint256 amount) public {
        _token.approve(address(_module), amount);
        _module.deposit(amount);
        _module.assign(miner, amount);
    }

    function stakeAndSubmit(
        SettlementMiner miner,
        uint256 amount,
        HunterMiningCore core,
        uint256 id,
        uint256 seedBlock,
        uint256 nonce,
        address basket
    ) external {
        stake(address(miner), amount);
        miner.submit(core, id, seedBlock, nonce, basket);
    }
}

interface ISettlementFlashBorrower {
    function onFlashLoan(uint256 amount) external;
}

/// @dev TEST-ONLY flash lender: lends its whole balance for one callback and
/// requires the balance back before returning.
contract SettlementFlashLender {
    error NotRepaid(uint256 expected, uint256 actual);

    IERC20 private immutable _token;

    constructor(IERC20 token_) {
        _token = token_;
    }

    function flashLoan(ISettlementFlashBorrower receiver, uint256 amount) external {
        uint256 beforeBal = _token.balanceOf(address(this));
        _token.transfer(address(receiver), amount);
        receiver.onFlashLoan(amount);
        uint256 afterBal = _token.balanceOf(address(this));
        if (afterBal < beforeBal) revert NotRepaid(beforeBal, afterBal);
    }
}

/// @dev TEST-ONLY borrower: stakes the loan for `miner`, makes it submit, then
/// tries to unwind and repay. With `catchSubmit` the submit failure is
/// swallowed and the borrower attempts unassign + withdraw + repay.
contract SettlementFlashStaker is ISettlementFlashBorrower {
    IERC20 private immutable _token;
    PrefundedMiningPower private immutable _module;
    address private immutable _lender;
    SettlementMiner private immutable _miner;
    HunterMiningCore private immutable _core;
    address private immutable _basket;

    bool public catchSubmit;
    uint256 private _id;
    uint256 private _seed;
    uint256 private _nonce;

    constructor(
        IERC20 token_,
        PrefundedMiningPower module_,
        address lender_,
        SettlementMiner miner_,
        HunterMiningCore core_,
        address basket_
    ) {
        _token = token_;
        _module = module_;
        _lender = lender_;
        _miner = miner_;
        _core = core_;
        _basket = basket_;
    }

    function configure(uint256 id, uint256 seedBlock, uint256 nonce, bool catchSubmit_) external {
        _id = id;
        _seed = seedBlock;
        _nonce = nonce;
        catchSubmit = catchSubmit_;
    }

    function onFlashLoan(uint256 amount) external {
        _token.approve(address(_module), amount);
        _module.deposit(amount);
        _module.assign(address(_miner), amount);
        if (catchSubmit) {
            try _miner.submit(_core, _id, _seed, _nonce, _basket) {} catch {}
            _module.unassign(address(_miner), amount);
            _module.withdraw(amount);
        } else {
            _miner.submit(_core, _id, _seed, _nonce, _basket);
        }
        _token.transfer(_lender, amount);
    }
}

/// @dev TEST-ONLY token that can be switched to revert on EVERY call.
contract BrickableHunter is ERC20 {
    error Bricked();

    bool public bricked;

    constructor() ERC20("Brickable HUNTER", "brHUNT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function brick() external {
        bricked = true;
    }

    function totalSupply() public view override returns (uint256) {
        if (bricked) revert Bricked();
        return super.totalSupply();
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (bricked) revert Bricked();
        return super.balanceOf(account);
    }

    function allowance(address owner, address spender) public view override returns (uint256) {
        if (bricked) revert Bricked();
        return super.allowance(owner, spender);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (bricked) revert Bricked();
        return super.transfer(to, value);
    }

    function approve(address spender, uint256 value) public override returns (bool) {
        if (bricked) revert Bricked();
        return super.approve(spender, value);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (bricked) revert Bricked();
        return super.transferFrom(from, to, value);
    }
}

/// @dev TEST-ONLY stand-in "core" for ONE unit probe of the note encoding.
/// It is bound to its own module instance; it never stands in for the real
/// core in a positive-path mining test. Between the gate and
/// `onProofAccepted` the real core makes no external call, so the note is not
/// otherwise observable.
contract NoteProbeCore {
    function probe(PrefundedMiningPower m, uint256 id, address miner)
        external
        returns (uint256 noteDuring, address minerDuring, uint256 noteAfter, address minerAfter)
    {
        m.snapshotChallenge(id);
        m.powerMultiplierWad(id, miner);
        (noteDuring, minerDuring) = m.pendingEligibleNote();
        m.onProofAccepted(1);
        (noteAfter, minerAfter) = m.pendingEligibleNote();
    }
}

/// @notice S5 (VLT-56) eligibility gate of PrefundedMiningPower on the REAL
/// stack: every admitted or rejected proof goes through
/// `HunterMiningCore.submitProof`. All amounts are TEST-ONLY fixture values.
contract PrefundedMiningPowerSettlementTest is PrefundedMiningStack {
    using stdStorage for StdStorage;

    address internal constant CAROL = address(0xCA201);
    address internal constant MINER2 = address(0x222E);

    uint256 private constant MIN_STAKE = 1_000e18;
    uint256 private constant LOCK = 100e18;
    uint256 private constant BONUS_UNIT = 1_000_000e18;

    function setUp() public override {
        super.setUp();
        _deployModule(MIN_STAKE, LOCK, 0, 0, address(0));
        _attach(module);
        assertTrue(module.wired());
    }

    // ------------------------------------------------------------------
    // Admission through the real core
    // ------------------------------------------------------------------

    function testEligibleDirectSubmissionMints() public {
        _qualify(ALICE, MINER, MIN_STAKE);
        (bool eligible, uint8 reason, uint256 stake, uint256 funds) = module.eligibilityOf(MINER);
        assertTrue(eligible);
        assertEq(reason, 0);
        assertEq(stake, MIN_STAKE);
        assertEq(funds, 0);

        uint256 moduleBal = token.balanceOf(address(module));
        uint256 id = cid;
        (uint256 nonce, bytes32 digest) = _nonce(MINER);
        vm.prank(MINER);
        assertEq(core.submitProof(id, seed, nonce, basket), digest);

        uint256 tokenId = nft.mintedEver();
        assertEq(tokenId, 1);
        assertEq(nft.ownerOf(tokenId), MINER);
        (, bytes32 birthDigest, uint256 birthChallenge,) = nft.birthData(tokenId);
        assertEq(birthDigest, digest);
        assertEq(birthChallenge, id);
        assertEq(core.previousAcceptedDigest(), digest);
        assertEq(module.lastAcceptedProofs(), core.acceptedProofs());
        assertEq(module.latestChallengeId(), id + 1);
        _assertNoteEmpty();
        // Hooks moved no tokens.
        assertEq(token.balanceOf(address(module)), moduleBal);
        // The stake stays assigned, so MINER stays eligible next challenge.
        (eligible,,,) = module.eligibilityOf(MINER);
        assertTrue(eligible);
        _assertBooks();
    }

    function testIneligibleRevertsWithReasonAndNoStateChange() public {
        // (a) no stake at all.
        _activate();
        _assertGateRejectsWithoutSideEffects(MINER);

        // (b) matured stake one wei below MIN_STAKE.
        _qualify(ALICE, MINER2, MIN_STAKE - 1);
        (bool eligible, uint8 reason, uint256 stake,) = module.eligibilityOf(MINER2);
        assertFalse(eligible);
        assertEq(reason, 2);
        assertEq(stake, MIN_STAKE - 1);
        _assertGateRejectsWithoutSideEffects(MINER2);
        _assertBooks();
    }

    function testStakeAssignedAfterScheduleCountsNextChallenge() public {
        // Challenge scheduled but seed not yet readable (WAITING_FOR_SEED).
        _nextChallenge();
        assertEq(uint8(core.challengeState()), uint8(HunterMiningCore.ChallengeState.WAITING_FOR_SEED));
        _deposit(BOB, MIN_STAKE);
        _assign(BOB, MINER2, MIN_STAKE);
        // Challenge ACTIVE (seed readable).
        _activate();
        _deposit(ALICE, MIN_STAKE);
        _assign(ALICE, MINER, MIN_STAKE);

        address[2] memory ws = [MINER, MINER2];
        for (uint256 i = 0; i < 2; i++) {
            (bool eligible, uint8 reason, uint256 stake,) = module.eligibilityOf(ws[i]);
            assertFalse(eligible);
            assertEq(reason, 2);
            assertEq(stake, 0);
            (uint256 nonce,) = _nonce(ws[i]);
            _expectNotEligible(2);
            _send(ws[i], nonce);
        }
        assertEq(nft.mintedEver(), 0);

        // Next snapshot (no win needed): both have matured.
        _nextChallenge();
        _activate();
        for (uint256 i = 0; i < 2; i++) {
            (bool eligible, uint8 reason, uint256 stake,) = module.eligibilityOf(ws[i]);
            assertTrue(eligible);
            assertEq(reason, 0);
            assertEq(stake, MIN_STAKE);
        }
        _win(MINER);
        _win(MINER2);
        assertEq(nft.mintedEver(), 2);
        _assertNoteEmpty();
        _assertBooks();
    }

    function testSameTxDepositAssignSubmitRejected() public {
        SettlementMiner miner = new SettlementMiner();
        SameTxStaker funder = new SameTxStaker(IERC20(address(token)), module);
        token.mint(address(funder), MIN_STAKE);
        _activate();
        (uint256 nonce,) = _nonce(address(miner));

        _expectNotEligible(2);
        funder.stakeAndSubmit(miner, MIN_STAKE, core, cid, seed, nonce, basket);

        assertEq(nft.mintedEver(), 0);
        assertEq(core.acceptedProofs(), 0);
        assertEq(module.totalStake(), 0);
        assertEq(module.assignedOf(address(miner)), 0);
        assertEq(token.balanceOf(address(funder)), MIN_STAKE);
        _assertNoteEmpty();

        // The same pair qualifies once the stake has sat through a snapshot.
        funder.stake(address(miner), MIN_STAKE);
        _nextChallenge();
        _activate();
        (nonce,) = _nonce(address(miner));
        miner.submit(core, cid, seed, nonce, basket);
        assertEq(nft.ownerOf(1), address(miner));
        _assertNoteEmpty();
    }

    function testFlashLoanedStakeCannotBeRepaid() public {
        SettlementMiner miner = new SettlementMiner();
        SettlementFlashLender lender = new SettlementFlashLender(IERC20(address(token)));
        token.mint(address(lender), MIN_STAKE);
        SettlementFlashStaker borrower =
            new SettlementFlashStaker(IERC20(address(token)), module, address(lender), miner, core, basket);
        _activate();
        (uint256 nonce,) = _nonce(address(miner));

        // (a) Straight attempt: the gate rejects the freshly assigned stake.
        borrower.configure(cid, seed, nonce, false);
        _expectNotEligible(2);
        lender.flashLoan(borrower, MIN_STAKE);
        _assertFlashRolledBack(lender, miner);

        // (b) With a real exit cooldown the borrower cannot even unwind the
        // failed attempt: the loaned stake is stuck in the module, so the
        // repay never happens and the whole loan reverts.
        _detach();
        _deployModule(MIN_STAKE, LOCK, 1 hours, 0, address(0));
        _attach(module);
        _activate();
        borrower = new SettlementFlashStaker(IERC20(address(token)), module, address(lender), miner, core, basket);
        (nonce,) = _nonce(address(miner));
        borrower.configure(cid, seed, nonce, true);
        vm.expectRevert(
            abi.encodeWithSelector(
                PrefundedMiningPower.CooldownNotMet.selector, block.timestamp + 1 hours, block.timestamp
            )
        );
        lender.flashLoan(borrower, MIN_STAKE);
        _assertFlashRolledBack(lender, miner);
    }

    function testOneStakeQualifiesOneWalletPerChallenge() public {
        _qualify(ALICE, MINER, MIN_STAKE);
        _assertEligibility(MINER, true, 0, MIN_STAKE);

        // Mid-challenge move (cooldown 0): removal applies next challenge,
        // the new assignment counts from next challenge.
        _unassign(ALICE, MINER, MIN_STAKE);
        _assign(ALICE, MINER2, MIN_STAKE);
        _assertEligibility(MINER, true, 0, MIN_STAKE);
        _assertEligibility(MINER2, false, 2, 0);
        (uint256 nonce,) = _nonce(MINER2);
        _expectNotEligible(2);
        _send(MINER2, nonce);
        _win(MINER);
        _assertBooks();

        // Next challenge: the stake qualifies MINER2 only.
        _activate();
        _assertEligibility(MINER, false, 2, 0);
        _assertEligibility(MINER2, true, 0, MIN_STAKE);
        (nonce,) = _nonce(MINER);
        _expectNotEligible(2);
        _send(MINER, nonce);
        _win(MINER2);
        assertEq(nft.mintedEver(), 2);
        assertEq(nft.ownerOf(1), MINER);
        assertEq(nft.ownerOf(2), MINER2);
        _assertNoteEmpty();
        _assertBooks();
    }

    function testEligibleMiningSurvivesTokenThatRevertsEverything() public {
        BrickableHunter brick = new BrickableHunter();
        _detach();
        PrefundedMiningPower m =
            new PrefundedMiningPower(address(brick), address(core), MIN_STAKE, LOCK, 0, 0, address(0));
        _attach(m);
        brick.mint(ALICE, MIN_STAKE);
        vm.startPrank(ALICE);
        brick.approve(address(m), MIN_STAKE);
        m.deposit(MIN_STAKE);
        m.assign(MINER, MIN_STAKE);
        vm.stopPrank();
        _nextChallenge();
        _activate();

        brick.brick();
        vm.expectRevert(BrickableHunter.Bricked.selector);
        brick.balanceOf(address(m));

        (bool eligible,,,) = m.eligibilityOf(MINER);
        assertTrue(eligible);
        uint256 tokenId = _win(MINER);
        assertEq(nft.ownerOf(tokenId), MINER);
        assertEq(m.lastAcceptedProofs(), 1);
        _assertNoteEmptyOn(m);

        // Refresh and terminal stop hooks also run with the token bricked.
        _activate();
        _nextChallenge();
        assertEq(m.latestChallengeId(), core.activeChallengeId());
        vm.prank(STOP);
        core.stopMining();
        assertTrue(m.retired());
    }

    // ------------------------------------------------------------------
    // Views and caller checks
    // ------------------------------------------------------------------

    function testPreviewsRunUnderStaticcall() public {
        _qualify(ALICE, MINER, MIN_STAKE);

        (bool ok, bytes memory ret) =
            address(module).staticcall(abi.encodeCall(PrefundedMiningPower.eligibilityOf, (MINER)));
        assertTrue(ok);
        (bool eligible, uint8 reason, uint256 stake, uint256 funds) = abi.decode(ret, (bool, uint8, uint256, uint256));
        assertTrue(eligible);
        assertEq(reason, 0);
        assertEq(stake, MIN_STAKE);
        assertEq(funds, 0);

        (ok, ret) = address(module).staticcall(abi.encodeCall(PrefundedMiningPower.previewSubmit, (MINER)));
        assertTrue(ok);
        assertEq(abi.decode(ret, (uint256)), 1e18);

        (ok, ret) = address(module).staticcall(abi.encodeCall(PrefundedMiningPower.pendingEligibleNote, ()));
        assertTrue(ok);
        (uint256 note, address noteMiner) = abi.decode(ret, (uint256, address));
        assertEq(note, 0);
        assertEq(noteMiner, address(0));

        // The gate itself is not a view and not callable by anyone but the core.
        (ok, ret) = address(module).staticcall(abi.encodeCall(PrefundedMiningPower.powerMultiplierWad, (cid, MINER)));
        assertFalse(ok);
        assertEq(ret, abi.encodeWithSelector(PrefundedMiningPower.UnauthorizedCaller.selector, address(this)));
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.UnauthorizedCaller.selector, MINER));
        module.powerMultiplierWad(cid, MINER);
    }

    function testNonCoreCannotWriteNote() public {
        _qualify(ALICE, MINER, MIN_STAKE);
        address[4] memory callers = [ALICE, MINER, address(nft), address(this)];
        for (uint256 i = 0; i < callers.length; i++) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.UnauthorizedCaller.selector, callers[i]));
            module.powerMultiplierWad(cid, MINER);
            _assertNoteEmpty();
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.UnauthorizedCaller.selector, callers[i]));
            module.onProofAccepted(99);
        }
        assertEq(module.lastAcceptedProofs(), 0);
        _assertNoteEmpty();
    }

    /// @dev Unit probe of the note encoding on a SEPARATE module bound to a
    /// stand-in core (see `NoteProbeCore`): an enforcing gate writes
    /// (keccak(challengeId, miner), miner); `onProofAccepted` clears both; a
    /// disabled gate writes nothing.
    function testGateNoteKeyedByChallengeAndMinerAndClearedOnAccept() public {
        NoteProbeCore probeCore = new NoteProbeCore();
        PrefundedMiningPower m = new PrefundedMiningPower(address(token), address(probeCore), 0, LOCK, 0, 0, address(0));
        (uint256 noteDuring, address minerDuring, uint256 noteAfter, address minerAfter) = probeCore.probe(m, 7, MINER);
        assertEq(noteDuring, uint256(keccak256(abi.encode(uint256(7), MINER))));
        assertEq(minerDuring, MINER);
        assertEq(noteAfter, 0);
        assertEq(minerAfter, address(0));

        PrefundedMiningPower off =
            new PrefundedMiningPower(address(token), address(probeCore), MIN_STAKE, LOCK, 0, 0, address(0));
        stdstore.enable_packed_slots().target(address(off)).sig("gateDisabled()").checked_write(true);
        (noteDuring, minerDuring,,) = probeCore.probe(off, 7, MINER);
        assertEq(noteDuring, 0);
        assertEq(minerDuring, address(0));
    }

    function testEligibilityReasonOneWhenModuleNotLive() public {
        _qualify(ALICE, MINER, MIN_STAKE);
        _assertEligibility(MINER, true, 0, MIN_STAKE);

        // A fresh, never-attached module is not the live one.
        PrefundedMiningPower fresh =
            new PrefundedMiningPower(address(token), address(core), MIN_STAKE, LOCK, 0, 0, address(0));
        (bool eligible, uint8 reason,,) = fresh.eligibilityOf(MINER);
        assertFalse(eligible);
        assertEq(reason, 1);

        // Non-terminal detach.
        _detach();
        (eligible, reason,,) = module.eligibilityOf(MINER);
        assertFalse(eligible);
        assertEq(reason, 1);

        // Terminal detach (retired), even with the failsafe flag set.
        _unassign(ALICE, MINER, MIN_STAKE);
        _attach(module);
        vm.prank(STOP);
        core.stopMining();
        assertTrue(module.retired());
        stdstore.enable_packed_slots().target(address(module)).sig("gateDisabled()").checked_write(true);
        (eligible, reason,,) = module.eligibilityOf(MINER);
        assertFalse(eligible);
        assertEq(reason, 1);
    }

    function testFuzz_PreviewMatchesGate(uint256 stakeSeed, bool matured) public {
        uint256 amount = bound(stakeSeed, 0, 2 * MIN_STAKE);
        if (amount != 0) {
            _deposit(ALICE, amount);
            _assign(ALICE, MINER, amount);
        }
        if (matured) _nextChallenge();
        _activate();

        (bool eligible, uint8 reason, uint256 stake, uint256 funds) = module.eligibilityOf(MINER);
        assertEq(stake, matured ? amount : 0);
        assertEq(funds, 0);
        assertEq(eligible, matured && amount >= MIN_STAKE);
        assertEq(reason, eligible ? 0 : 2);
        assertEq(module.previewSubmit(MINER), 1e18);

        (uint256 nonce,) = _nonce(MINER);
        uint256 before = nft.mintedEver();
        if (!eligible) _expectNotEligible(reason);
        _send(MINER, nonce);
        assertEq(nft.mintedEver(), eligible ? before + 1 : before);
        _assertNoteEmpty();
        _assertBooks();
    }

    function testBonusCurve() public {
        // CURVE_UNIT == 0: 1.0x however large the stake.
        _qualify(CAROL, MINER, 1e30);
        assertEq(module.previewSubmit(MINER), 1e18);
        _assertEligibility(MINER, true, 0, 1e30);

        // Published table with CURVE_UNIT = 1,000,000 HUNTER.
        _detach();
        _deployModule(MIN_STAKE, LOCK, 0, BONUS_UNIT, address(0));
        _attach(module);
        uint256[6] memory stakes =
            [MIN_STAKE, BONUS_UNIT, 3 * BONUS_UNIT, 7 * BONUS_UNIT, 15 * BONUS_UNIT, 1_000 * BONUS_UNIT];
        uint256[6] memory mults = [uint256(1e18), 1.5e18, 2e18, 2.5e18, 3e18, 3e18];
        address[6] memory wallets;
        for (uint256 i = 0; i < 6; i++) {
            address depositor = address(uint160(0xD000 + i));
            wallets[i] = address(uint160(0xE000 + i));
            _deposit(depositor, stakes[i]);
            _assign(depositor, wallets[i], stakes[i]);
            // Pending stake previews at 1.0x.
            assertEq(module.previewSubmit(wallets[i]), 1e18);
        }
        assertEq(module.multiplierFromLockedAmount(BONUS_UNIT - 1), 1e18);
        _nextChallenge();
        _activate();
        for (uint256 i = 0; i < 6; i++) {
            assertEq(module.previewSubmit(wallets[i]), mults[i]);
            _assertEligibility(wallets[i], true, 0, stakes[i]);
        }

        // Real effect: a 1.5x-band digest is rejected for the 1.0x wallet and
        // accepted for the 1.5x wallet (the band saturates at MAX_TARGET).
        uint256 base = core.currentTarget();
        uint256 widened = _widen(base, 1.5e18);
        assertGt(widened, base);
        (uint256 n0, bytes32 d0) = _bandNonce(wallets[0], base, widened);
        vm.prank(wallets[0]);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.InvalidProof.selector, d0, base));
        core.submitProof(cid, seed, n0, basket);
        (uint256 n1, bytes32 d1) = _bandNonce(wallets[1], base, widened);
        vm.prank(wallets[1]);
        core.submitProof(cid, seed, n1, basket);
        assertEq(nft.ownerOf(1), wallets[1]);
        assertGt(uint256(d1), base);
        _assertNoteEmpty();
    }

    /// @dev S8's `disableRequirement` does not exist yet; the failsafe flag is
    /// injected with stdstore.
    function testGateDisabledSkipsChecksAndWritesNoNote() public {
        _activate();
        (uint256 nonce,) = _nonce(MINER);
        _expectNotEligible(2);
        _send(MINER, nonce);

        stdstore.enable_packed_slots().target(address(module)).sig("gateDisabled()").checked_write(true);
        assertTrue(module.gateDisabled());
        _assertEligibility(MINER, true, 0, 0);
        uint256 tokenId = _win(MINER);
        assertEq(nft.ownerOf(tokenId), MINER);
        assertEq(module.lastAcceptedProofs(), 1);
        _assertNoteEmpty();
        // Still open in the following challenge.
        _win(MINER2);
        _assertNoteEmpty();
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _assertNoteEmpty() private view {
        _assertNoteEmptyOn(module);
    }

    function _assertNoteEmptyOn(PrefundedMiningPower m) private view {
        (uint256 note, address noteMiner) = m.pendingEligibleNote();
        assertEq(note, 0, "note survived");
        assertEq(noteMiner, address(0), "note miner survived");
    }

    function _assertEligibility(address wallet, bool eligible, uint8 reason, uint256 stake) private view {
        (bool e, uint8 r, uint256 s, uint256 f) = module.eligibilityOf(wallet);
        assertEq(e, eligible, "eligible");
        assertEq(r, reason, "reason");
        assertEq(s, stake, "stake");
        assertEq(f, 0, "funds");
    }

    /// @dev A valid-digest submission from `miner` reverts NotEligible(2) and
    /// changes nothing in the core, NFT or module.
    function _assertGateRejectsWithoutSideEffects(address miner) private {
        uint256 accepted = core.acceptedProofs();
        uint256 coreMinted = core.nftsMintedEver();
        uint256 nftMinted = nft.mintedEver();
        bytes32 prevDigest = core.previousAcceptedDigest();
        uint256 activeId = core.activeChallengeId();
        uint256 lastAccepted = module.lastAcceptedProofs();
        (bool e0, uint8 r0, uint256 s0,) = module.eligibilityOf(miner);

        (uint256 nonce,) = _nonce(miner);
        _expectNotEligible(2);
        _send(miner, nonce);

        assertEq(core.acceptedProofs(), accepted);
        assertEq(core.nftsMintedEver(), coreMinted);
        assertEq(nft.mintedEver(), nftMinted);
        assertEq(core.previousAcceptedDigest(), prevDigest);
        assertEq(core.activeChallengeId(), activeId);
        assertEq(module.lastAcceptedProofs(), lastAccepted);
        (bool e1, uint8 r1, uint256 s1,) = module.eligibilityOf(miner);
        assertEq(e1, e0);
        assertEq(r1, r0);
        assertEq(s1, s0);
        _assertNoteEmpty();
    }

    function _assertFlashRolledBack(SettlementFlashLender lender, SettlementMiner miner) private view {
        assertEq(token.balanceOf(address(lender)), MIN_STAKE);
        assertEq(token.balanceOf(address(module)), 0);
        assertEq(module.totalStake(), 0);
        assertEq(module.assignedOf(address(miner)), 0);
        assertEq(nft.mintedEver(), 0);
        assertEq(core.acceptedProofs(), 0);
        _assertNoteEmpty();
    }

    /// @dev Mirrors `HunterMiningCore._effectiveTarget` (saturates at MAX_TARGET).
    function _widen(uint256 base, uint256 multWad) private view returns (uint256) {
        uint256 cap = core.MAX_TARGET();
        uint256 maxSafe = Math.mulDiv(cap, 1e18, multWad);
        return base >= maxSafe ? cap : Math.mulDiv(base, multWad, 1e18);
    }

    /// @dev A nonce whose digest for `miner` lies in (lo, hi] for the synced challenge.
    function _bandNonce(address miner, uint256 lo, uint256 hi) private view returns (uint256 nonce, bytes32 digest) {
        bytes32 challenge = core.currentChallenge();
        for (; nonce < 4_096; nonce++) {
            digest = core.deriveProofDigest(cid, challenge, miner, nonce);
            if (uint256(digest) > lo && uint256(digest) <= hi) return (nonce, digest);
        }
        revert("band nonce not found");
    }
}
