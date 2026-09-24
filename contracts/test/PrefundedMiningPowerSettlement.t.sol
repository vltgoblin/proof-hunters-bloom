// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {stdStorage, StdStorage} from "forge-std/StdStorage.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HunterMiningCore} from "../src/bloom/HunterMiningCore.sol";
import {HunterNFT} from "../src/bloom/HunterNFT.sol";
import {IMiningPower} from "../src/bloom/IMiningPower.sol";
import {PrefundedMiningPower} from "../src/bloom/PrefundedMiningPower.sol";
import {PrefundedMiningStack} from "./helpers/PrefundedMiningStack.sol";
import {HunterLifecycleFixture} from "./HunterNFT.t.sol";
import {DummyMiningPower, HunterMiningHarness} from "./HunterMiningCore.t.sol";

/// @dev TEST-ONLY contract mining wallet: submits a proof through the real core.
contract SettlementMiner {
    function submit(HunterMiningCore core, uint256 id, uint256 seedBlock, uint256 nonce, address basket)
        external
        returns (bytes32)
    {
        return core.submitProof(id, seedBlock, nonce, basket);
    }
}

/// @dev TEST-ONLY contract mining wallet that wins once and then, in the SAME
/// transaction, tries (a) the next challenge and (b) a replay of the proof it
/// just had accepted. Both failures are caught and recorded so the first
/// acceptance (and its lock) survives; it also records the transient note
/// right after the first acceptance.
contract DoubleSubmitMiner {
    bytes public nextErr;
    bytes public replayErr;
    bool public nextOk;
    bool public replayOk;
    uint256 public noteAfterFirst;
    address public noteMinerAfterFirst;

    function run(
        HunterMiningCore core,
        PrefundedMiningPower m,
        uint256 id,
        uint256 seedBlock,
        uint256 nonce,
        address basket
    ) external {
        core.submitProof(id, seedBlock, nonce, basket);
        (noteAfterFirst, noteMinerAfterFirst) = m.pendingEligibleNote();
        try core.submitProof(core.activeChallengeId(), core.activeSeedParentBlock(), nonce, basket) {
            nextOk = true;
        } catch (bytes memory err) {
            nextErr = err;
        }
        try core.submitProof(id, seedBlock, nonce, basket) {
            replayOk = true;
        } catch (bytes memory err) {
            replayErr = err;
        }
    }
}

/// @dev TEST-ONLY stand-in "core" that drives its OWN module through call
/// sequences the real core never produces, to prove settlement fails closed.
/// It is also the mining wallet (so it can withdraw its own funds between the
/// gate and `onProofAccepted`). Never used in a positive-path mining test.
contract ForeignSequenceCore {
    uint256 public activeChallengeId;
    uint256 public nftsMintedEver = 1;
    bytes32 public constant previousAcceptedDigest = keccak256("foreign digest");

    function PROOF_NFT() external view returns (address) {
        return address(this);
    }

    function mintedEver() external pure returns (uint256) {
        return 0;
    }

    function approveAndFund(PrefundedMiningPower m, IERC20 token, uint256 amount) external {
        token.approve(address(m), amount);
        m.fund(address(this), amount);
    }

    /// @dev Gate admits `id`, the core's active id then reads `activeAtAccept`.
    function gateThenAccept(PrefundedMiningPower m, uint256 id, uint256 activeAtAccept)
        external
        returns (bytes memory err)
    {
        activeChallengeId = id;
        m.snapshotChallenge(id);
        m.powerMultiplierWad(id, address(this));
        activeChallengeId = activeAtAccept;
        try m.onProofAccepted(1) {}
        catch (bytes memory e) {
            err = e;
        }
    }

    /// @dev Gate admits, the wallet withdraws its funds, then acceptance.
    function gateWithdrawThenAccept(PrefundedMiningPower m, uint256 id) external returns (bytes memory err) {
        activeChallengeId = id;
        m.snapshotChallenge(id);
        m.powerMultiplierWad(id, address(this));
        m.withdrawFunds(m.fundsOf(address(this)));
        try m.onProofAccepted(1) {}
        catch (bytes memory e) {
            err = e;
        }
    }

    /// @dev Opens `first`, funds (pending there), then opens challenge 0 —
    /// which the real core never does — so those funds count, then gates 0.
    function gateChallengeZero(PrefundedMiningPower m, IERC20 token, uint256 first)
        external
        returns (bytes memory err)
    {
        m.snapshotChallenge(first);
        uint256 bal = token.balanceOf(address(this));
        token.approve(address(m), bal);
        m.fund(address(this), bal);
        m.snapshotChallenge(0);
        try m.powerMultiplierWad(0, address(this)) {}
        catch (bytes memory e) {
            err = e;
        }
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
/// otherwise observable. S6: it answers the core/NFT views settlement reads
/// exactly as the real core does at that point (active id = the probed
/// challenge, core counter 1, NFT counter 0, previous digest), so the probe's
/// own module settles token 1.
contract NoteProbeCore {
    uint256 public activeChallengeId;
    bytes32 public constant previousAcceptedDigest = keccak256("probe digest");

    function nftsMintedEver() external pure returns (uint256) {
        return 1;
    }

    function PROOF_NFT() external view returns (address) {
        return address(this);
    }

    function mintedEver() external pure returns (uint256) {
        return 0;
    }

    function probe(PrefundedMiningPower m, uint256 id, address miner)
        external
        returns (uint256 noteDuring, address minerDuring, uint256 noteAfter, address minerAfter)
    {
        activeChallengeId = id;
        m.snapshotChallenge(id);
        m.powerMultiplierWad(id, miner);
        (noteDuring, minerDuring) = m.pendingEligibleNote();
        m.onProofAccepted(1);
        (noteAfter, minerAfter) = m.pendingEligibleNote();
    }
}

/// @notice S5 (VLT-56) eligibility gate and S6 (VLT-57) mint funds and
/// per-mint lock of PrefundedMiningPower on the REAL stack: every admitted
/// or rejected proof goes through `HunterMiningCore.submitProof`. All
/// amounts are TEST-ONLY fixture values.
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
        // S6: funds for two mints, so MINER is still eligible after one.
        _qualifyAndFund(ALICE, MINER, MIN_STAKE, 2 * LOCK);
        (bool eligible, uint8 reason, uint256 stake, uint256 funds) = module.eligibilityOf(MINER);
        assertTrue(eligible);
        assertEq(reason, 0);
        assertEq(stake, MIN_STAKE);
        assertEq(funds, 2 * LOCK);

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
        // S6: both wallets hold mint funds that have matured well before the
        // final challenge, so only the stake decides here.
        _fund(MINER, LOCK);
        _fund(MINER2, LOCK);
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
        _fund(address(miner), LOCK); // S6: funds never the blocker here
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
        // S6: both wallets hold matured mint funds; only the stake moves.
        _fund(MINER2, LOCK);
        _qualifyAndFund(ALICE, MINER, MIN_STAKE, LOCK);
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
        // S6: mint funds, so the win also settles a lock with the token bricked.
        brick.mint(FUNDER, LOCK);
        vm.startPrank(FUNDER);
        brick.approve(address(m), LOCK);
        m.fund(MINER, LOCK);
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
        (uint256 locked,,, address lockMiner,) = m.committedOf(tokenId);
        assertEq(locked, LOCK);
        assertEq(lockMiner, MINER);
        assertEq(m.fundsOf(MINER), 0);
        assertEq(m.totalCommitted(), LOCK);
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
        _qualifyAndFund(ALICE, MINER, MIN_STAKE, LOCK);

        (bool ok, bytes memory ret) =
            address(module).staticcall(abi.encodeCall(PrefundedMiningPower.eligibilityOf, (MINER)));
        assertTrue(ok);
        (bool eligible, uint8 reason, uint256 stake, uint256 funds) = abi.decode(ret, (bool, uint8, uint256, uint256));
        assertTrue(eligible);
        assertEq(reason, 0);
        assertEq(stake, MIN_STAKE);
        assertEq(funds, LOCK);

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
    /// (challengeId, miner) — S6 stores the id itself instead of S5's hash so
    /// settlement can re-check it against the core; `onProofAccepted`
    /// settles from it and clears both; a disabled gate writes nothing.
    function testGateNoteKeyedByChallengeAndMinerAndClearedOnAccept() public {
        NoteProbeCore probeCore = new NoteProbeCore();
        PrefundedMiningPower m = new PrefundedMiningPower(address(token), address(probeCore), 0, LOCK, 0, 0, address(0));
        // Funded before the probe opens challenge 7, so they count in it.
        token.mint(FUNDER, LOCK);
        vm.startPrank(FUNDER);
        token.approve(address(m), LOCK);
        m.fund(MINER, LOCK);
        vm.stopPrank();
        (uint256 noteDuring, address minerDuring, uint256 noteAfter, address minerAfter) = probeCore.probe(m, 7, MINER);
        assertEq(noteDuring, 7);
        assertEq(minerDuring, MINER);
        assertEq(noteAfter, 0);
        assertEq(minerAfter, address(0));
        (uint256 amount, uint256 lockChallenge, bytes32 lockDigest, address lockMiner,) = m.committedOf(1);
        assertEq(amount, LOCK);
        assertEq(lockChallenge, 7);
        assertEq(lockDigest, keccak256("probe digest"));
        assertEq(lockMiner, MINER);

        PrefundedMiningPower off =
            new PrefundedMiningPower(address(token), address(probeCore), MIN_STAKE, LOCK, 0, 0, address(0));
        stdstore.enable_packed_slots().target(address(off)).sig("gateDisabled()").checked_write(true);
        (noteDuring, minerDuring,,) = probeCore.probe(off, 7, MINER);
        assertEq(noteDuring, 0);
        assertEq(minerDuring, address(0));
    }

    function testEligibilityReasonOneWhenModuleNotLive() public {
        _qualifyAndFund(ALICE, MINER, MIN_STAKE, LOCK);
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

    /// @dev S6 extension: random mint funds, funded either before the
    /// challenge was scheduled (matured when `matured`) or after it
    /// (pending), so reason 3 and the lock are covered too.
    function testFuzz_PreviewMatchesGate(uint256 stakeSeed, bool matured, uint256 fundSeed, bool fundsEarly) public {
        uint256 amount = bound(stakeSeed, 0, 2 * MIN_STAKE);
        uint256 f = bound(fundSeed, 0, 3 * LOCK);
        if (amount != 0) {
            _deposit(ALICE, amount);
            _assign(ALICE, MINER, amount);
        }
        if (fundsEarly && f != 0) _fund(MINER, f);
        if (matured) _nextChallenge();
        _activate();
        if (!fundsEarly && f != 0) _fund(MINER, f);

        uint256 expectFunds = fundsEarly && matured ? f : 0;
        bool stakeOk = matured && amount >= MIN_STAKE;
        (bool eligible, uint8 reason, uint256 stake, uint256 funds) = module.eligibilityOf(MINER);
        assertEq(stake, matured ? amount : 0);
        assertEq(funds, expectFunds);
        assertEq(module.eligibleFundsOf(MINER), expectFunds);
        assertEq(eligible, stakeOk && expectFunds >= LOCK);
        assertEq(reason, eligible ? 0 : (stakeOk ? 3 : 2));
        assertEq(module.previewSubmit(MINER), 1e18);

        (uint256 nonce,) = _nonce(MINER);
        uint256 before = nft.mintedEver();
        if (!eligible) _expectNotEligible(reason);
        _send(MINER, nonce);
        assertEq(nft.mintedEver(), eligible ? before + 1 : before);
        (uint256 locked,,, address lockMiner,) = module.committedOf(before + 1);
        assertEq(locked, eligible ? LOCK : 0);
        assertEq(lockMiner, eligible ? MINER : address(0));
        assertEq(module.fundsOf(MINER), eligible ? f - LOCK : f);
        assertEq(module.totalCommitted(), eligible ? LOCK : 0);
        _assertNoteEmpty();
        _assertBooks();
    }

    function testBonusCurve() public {
        // CURVE_UNIT == 0: 1.0x however large the stake.
        _qualifyAndFund(CAROL, MINER, 1e30, LOCK);
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
            _fund(wallets[i], LOCK); // S6: matures with the stake
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
    // S6: mint funds and the per-mint lock (all through the real core)
    // ------------------------------------------------------------------

    function testEligibleDirectSubmissionMintsAndLocksOnce() public {
        _qualifyAndFund(ALICE, MINER, MIN_STAKE, LOCK + 7);
        uint256 moduleBal = token.balanceOf(address(module));
        uint256 id = cid;
        (uint256 nonce, bytes32 digest) = _nonce(MINER);

        vm.expectEmit(true, true, true, true, address(module));
        emit PrefundedMiningPower.Committed(1, MINER, id, digest, LOCK);
        _send(MINER, nonce);

        uint256 tokenId = nft.mintedEver();
        assertEq(tokenId, 1);
        assertEq(nft.ownerOf(tokenId), MINER);
        (, bytes32 birthDigest, uint256 birthChallenge,) = nft.birthData(tokenId);
        _assertLock(tokenId, MINER, birthChallenge, birthDigest);
        assertEq(birthChallenge, id);
        assertEq(birthDigest, digest);
        // Exactly one lock: nothing for the next id.
        _assertNoLock(tokenId + 1);
        // Funds −L, totals moved, stake untouched, no token moved by hooks.
        assertEq(module.fundsOf(MINER), 7);
        assertEq(module.totalFunds(), 7);
        assertEq(module.totalCommitted(), LOCK);
        assertEq(module.assignedOf(MINER), MIN_STAKE);
        assertEq(module.assignedBy(ALICE), MIN_STAKE);
        assertEq(module.totalStake(), MIN_STAKE);
        assertEq(module.totalAssigned(), MIN_STAKE);
        assertEq(token.balanceOf(address(module)), moduleBal);
        assertEq(token.balanceOf(address(module)), MIN_STAKE + LOCK + 7);
        // 7 left < L: no longer eligible (reason 3).
        _activate();
        (bool eligible, uint8 reason,, uint256 funds) = module.eligibilityOf(MINER);
        assertFalse(eligible);
        assertEq(reason, 3);
        assertEq(funds, 7);
        _assertNoteEmpty();
        _assertBooks();
    }

    function testIneligibleWithoutFundsRevertsReason3() public {
        // Stake ok, funds 0.
        _qualify(ALICE, MINER, MIN_STAKE);
        _assertGate(MINER, false, 3, MIN_STAKE, 0);
        _assertRejectedNoChange(MINER, 3);

        // Funds L-1 (matured): still reason 3.
        _fund(MINER, LOCK - 1);
        _nextChallenge();
        _activate();
        _assertGate(MINER, false, 3, MIN_STAKE, LOCK - 1);
        _assertRejectedNoChange(MINER, 3);

        // Topping up the missing wei mid-challenge is pending: still reason 3.
        _fund(MINER, 1);
        assertEq(module.fundsOf(MINER), LOCK);
        _assertGate(MINER, false, 3, MIN_STAKE, LOCK - 1);
        _assertRejectedNoChange(MINER, 3);

        // Reason 2 still wins over reason 3 when both fail.
        _activate();
        _assertGate(MINER2, false, 2, 0, 0);
        _assertRejectedNoChange(MINER2, 2);
        assertEq(nft.mintedEver(), 0);
        assertEq(module.totalCommitted(), 0);
        _assertBooks();
    }

    function testMintFundsAddedAfterScheduleCountNextChallenge() public {
        _deposit(ALICE, MIN_STAKE);
        _assign(ALICE, MINER, MIN_STAKE);
        _deposit(BOB, MIN_STAKE);
        _assign(BOB, MINER2, MIN_STAKE);
        _nextChallenge(); // stake matures in this challenge
        // Challenge scheduled, seed not readable yet (WAITING_FOR_SEED).
        assertEq(uint8(core.challengeState()), uint8(HunterMiningCore.ChallengeState.WAITING_FOR_SEED));
        _fund(MINER, LOCK);
        // Seed readable (ACTIVE).
        _activate();
        _fund(MINER2, LOCK);
        address[2] memory ws = [MINER, MINER2];
        for (uint256 i = 0; i < 2; i++) {
            assertEq(module.pendingFunds(ws[i]), LOCK);
            assertEq(module.fundsEpoch(ws[i]), cid);
            _assertGate(ws[i], false, 3, MIN_STAKE, 0);
            _assertRejectedNoChange(ws[i], 3);
        }

        // Next snapshot (no win needed): both have matured.
        _nextChallenge();
        _activate();
        for (uint256 i = 0; i < 2; i++) {
            _assertGate(ws[i], true, 0, MIN_STAKE, LOCK);
        }
        _win(MINER);
        _win(MINER2);
        (uint256 a1,,, address m1,) = module.committedOf(1);
        (uint256 a2,,, address m2,) = module.committedOf(2);
        assertEq(a1, LOCK);
        assertEq(a2, LOCK);
        assertEq(m1, MINER);
        assertEq(m2, MINER2);

        // A new top-up in a later challenge restarts the pending bucket.
        _fund(MINER, 3 * LOCK);
        assertEq(module.pendingFunds(MINER), 3 * LOCK);
        assertEq(module.fundsEpoch(MINER), module.latestChallengeId());
        assertEq(module.eligibleFundsOf(MINER), 0);
        _assertNoteEmpty();
        _assertBooks();
    }

    function testFundsForTwoLocksPayExactlyTwo() public {
        _qualifyAndFund(ALICE, MINER, MIN_STAKE, 2 * LOCK);
        assertEq(_win(MINER), 1);
        assertEq(_win(MINER), 2);
        assertEq(module.fundsOf(MINER), 0);
        _activate();
        _assertGate(MINER, false, 3, MIN_STAKE, 0);
        _assertRejectedNoChange(MINER, 3);

        for (uint256 t = 1; t <= 2; t++) {
            (, bytes32 d, uint256 c,) = nft.birthData(t);
            _assertLock(t, MINER, c, d);
        }
        _assertNoLock(3);
        assertEq(module.totalCommitted(), 2 * LOCK);
        assertEq(module.totalFunds(), 0);
        assertEq(token.balanceOf(address(module)), MIN_STAKE + 2 * LOCK);
        _assertBooks();
    }

    function testFundsWithdrawnMidChallengeBlocksWin() public {
        _qualifyAndFund(ALICE, MINER, MIN_STAKE, LOCK);
        _assertGate(MINER, true, 0, MIN_STAKE, LOCK);

        vm.expectEmit(true, false, false, true, address(module));
        emit PrefundedMiningPower.FundsWithdrawn(MINER, 1);
        vm.prank(MINER);
        module.withdrawFunds(1);
        assertEq(token.balanceOf(MINER), 1);
        _assertGate(MINER, false, 3, MIN_STAKE, LOCK - 1);
        _assertRejectedNoChange(MINER, 3);

        // Re-funding in the same challenge is pending: still blocked.
        _fund(MINER, 1);
        _assertRejectedNoChange(MINER, 3);
        assertEq(module.totalCommitted(), 0);
        _assertBooks();
    }

    /// @dev Pending funds leave first, so withdrawing only the fresh top-up
    /// keeps the matured part eligible; withdrawing more eats into it.
    function testWithdrawFundsTakesPendingFirst() public {
        _qualifyAndFund(ALICE, MINER, MIN_STAKE, LOCK);
        _fund(MINER, 50e18); // pending this challenge
        assertEq(module.eligibleFundsOf(MINER), LOCK);
        vm.prank(MINER);
        module.withdrawFunds(50e18);
        assertEq(module.pendingFunds(MINER), 0);
        assertEq(module.fundsOf(MINER), LOCK);
        _assertGate(MINER, true, 0, MIN_STAKE, LOCK);

        _fund(MINER, 50e18);
        vm.prank(MINER);
        module.withdrawFunds(60e18); // 50 pending + 10 matured
        assertEq(module.pendingFunds(MINER), 0);
        _assertGate(MINER, false, 3, MIN_STAKE, LOCK - 10e18);

        // Only the wallet's own funds: others have nothing to withdraw.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.InsufficientFunds.selector, 0, 1));
        module.withdrawFunds(1);
        vm.prank(FUNDER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.InsufficientFunds.selector, 0, 1));
        module.withdrawFunds(1);
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.InsufficientFunds.selector, LOCK - 10e18, LOCK));
        module.withdrawFunds(LOCK);
        _assertBooks();
    }

    // -- rollback matrix: a lock never survives a reverted submission --------

    function testInvalidDigestRollsBack() public {
        _qualifyAndFund(ALICE, MINER, MIN_STAKE, LOCK);
        uint256 target = core.currentTarget();
        (uint256 bad, bytes32 badDigest) = _invalidNonce(MINER, target);
        Snap memory s0 = _snap(MINER);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.InvalidProof.selector, badDigest, target));
        _send(MINER, bad);
        _assertSnap(s0, MINER);

        // The same wallet still mints (and locks) with a valid digest.
        _win(MINER);
        (uint256 amount,,,,) = module.committedOf(1);
        assertEq(amount, LOCK);
        _assertBooks();
    }

    function testStaleIdSeedWaitingExpiredRejected() public {
        _qualifyAndFund(ALICE, MINER, MIN_STAKE, LOCK);
        (uint256 nonce,) = _nonce(MINER);
        Snap memory s0 = _snap(MINER);

        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.StaleChallengeId.selector, cid + 1, cid));
        core.submitProof(cid + 1, seed, nonce, basket);
        _assertSnap(s0, MINER);

        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.StaleSeedBlock.selector, seed + 1, seed));
        core.submitProof(cid, seed + 1, nonce, basket);
        _assertSnap(s0, MINER);

        // Expired seed.
        vm.roll(seed + core.SEED_READABLE_PARENT_BLOCKS() + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                HunterMiningCore.ChallengeNotActive.selector, HunterMiningCore.ChallengeState.EXPIRED
            )
        );
        _send(MINER, nonce);
        _assertSnap(s0, MINER);

        // Refreshed, seed not yet readable.
        core.refreshExpiredSeed();
        uint256 newId = core.activeChallengeId();
        uint256 newSeed = core.activeSeedParentBlock();
        vm.prank(MINER);
        vm.expectRevert(
            abi.encodeWithSelector(
                HunterMiningCore.ChallengeNotActive.selector, HunterMiningCore.ChallengeState.WAITING_FOR_SEED
            )
        );
        core.submitProof(newId, newSeed, nonce, basket);
        assertEq(module.fundsOf(MINER), s0.funds);
        assertEq(module.totalCommitted(), 0);
        assertEq(nft.mintedEver(), 0);
        _assertNoLock(1);
        _assertNoteEmpty();
        _assertBooks();
    }

    function testBadBasketRollsBackLock() public {
        _qualifyAndFund(ALICE, MINER, MIN_STAKE, LOCK);
        (uint256 nonce,) = _nonce(MINER);
        Snap memory s0 = _snap(MINER);
        address unadmitted = address(0xBA5CE7);
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(HunterNFT.InvalidBasket.selector, unadmitted));
        core.submitProof(cid, seed, nonce, unadmitted);
        _assertSnap(s0, MINER);

        _send(MINER, nonce);
        (uint256 amount,,, address lockMiner,) = module.committedOf(1);
        assertEq(amount, LOCK);
        assertEq(lockMiner, MINER);
        _assertBooks();
    }

    /// @dev The real `HunterLifecycle` cannot be made to revert on `onMint`,
    /// so this ONE test runs on a SEPARATE stack: a `HunterMiningHarness`
    /// core whose NFT is wired to a `HunterLifecycleFixture` (as in
    /// HunterMiningCore.t.sol), with its own PrefundedMiningPower attached to
    /// that core. The submission still goes through the real
    /// `submitProof`: the lock is settled in `onProofAccepted`, then the
    /// NFT mint's lifecycle hook reverts and the whole transaction — lock
    /// included — rolls back.
    function testLifecycleMintRevertRollsBackLock() public {
        address predictedCore = vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
        address predictedNft = vm.computeCreateAddress(predictedCore, 1);
        HunterLifecycleFixture fixture = new HunterLifecycleFixture(predictedNft);
        HunterMiningHarness c2 = new HunterMiningHarness(
            HunterMiningCore.ProofNftDeploymentData(
                address(registry), address(fixture), 1, address(0x123), "ipfs://hunters/"
            )
        );
        HunterNFT n2 = c2.PROOF_NFT();
        assertEq(address(n2), predictedNft);
        PrefundedMiningPower m =
            new PrefundedMiningPower(address(token), address(c2), MIN_STAKE, LOCK, 0, 0, address(0));
        vm.prank(STOP);
        c2.setMiningPower(m);

        token.mint(ALICE, MIN_STAKE);
        token.mint(FUNDER, LOCK);
        vm.startPrank(ALICE);
        token.approve(address(m), MIN_STAKE);
        m.deposit(MIN_STAKE);
        m.assign(MINER, MIN_STAKE);
        vm.stopPrank();
        vm.startPrank(FUNDER);
        token.approve(address(m), LOCK);
        m.fund(MINER, LOCK);
        vm.stopPrank();

        // Open the next challenge (stake and funds mature) and make it active.
        vm.roll(c2.activeSeedParentBlock() + c2.SEED_READABLE_PARENT_BLOCKS() + 1);
        c2.refreshExpiredSeed();
        uint256 id = c2.activeChallengeId();
        uint256 sb = c2.activeSeedParentBlock();
        vm.roll(sb + 1);
        vm.setBlockhash(sb, keccak256(abi.encode("seed2", sb)));
        (bool eligible,,,) = m.eligibilityOf(MINER);
        assertTrue(eligible);
        uint256 nonce;
        {
            bytes32 ch = c2.currentChallenge();
            uint256 target = c2.currentTarget();
            while (uint256(c2.deriveProofDigest(id, ch, MINER, nonce)) > target) nonce++;
        }

        fixture.setFail(true);
        vm.prank(MINER);
        vm.expectRevert(bytes("hook failed"));
        c2.submitProof(id, sb, nonce, basket);
        assertEq(m.fundsOf(MINER), LOCK);
        assertEq(m.totalFunds(), LOCK);
        assertEq(m.totalCommitted(), 0);
        (uint256 amount,,,,) = m.committedOf(1);
        assertEq(amount, 0);
        (uint256 note, address noteMiner) = m.pendingEligibleNote();
        assertEq(note, 0);
        assertEq(noteMiner, address(0));
        assertEq(c2.acceptedProofs(), 0);
        assertEq(c2.nftsMintedEver(), 0);
        assertEq(n2.mintedEver(), 0);
        assertEq(m.lastAcceptedProofs(), 0);
        assertEq(token.balanceOf(address(m)), MIN_STAKE + LOCK);

        fixture.setFail(false);
        vm.prank(MINER);
        c2.submitProof(id, sb, nonce, basket);
        (amount,,,,) = m.committedOf(1);
        assertEq(amount, LOCK);
        assertEq(m.fundsOf(MINER), 0);
        assertEq(n2.ownerOf(1), MINER);
    }

    function testCopiedNonceOtherWalletNoLock() public {
        _deposit(BOB, MIN_STAKE);
        _assign(BOB, MINER2, MIN_STAKE);
        _fund(MINER2, LOCK);
        _qualifyAndFund(ALICE, MINER, MIN_STAKE, LOCK);
        // Both wallets are eligible; the proof is wallet-bound.
        _assertGate(MINER2, true, 0, MIN_STAKE, LOCK);
        bytes32 challenge = core.currentChallenge();
        uint256 target = core.currentTarget();
        uint256 nonce;
        bytes32 copied;
        for (; nonce < 4_096; nonce++) {
            copied = core.deriveProofDigest(cid, challenge, MINER2, nonce);
            if (uint256(core.deriveProofDigest(cid, challenge, MINER, nonce)) <= target && uint256(copied) > target) {
                break;
            }
        }
        assertLt(nonce, 4_096);
        Snap memory s2 = _snap(MINER2);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.InvalidProof.selector, copied, target));
        _send(MINER2, nonce);
        _assertSnap(s2, MINER2);
        assertEq(module.fundsOf(MINER), LOCK);

        _send(MINER, nonce);
        (uint256 amount,,, address lockMiner,) = module.committedOf(1);
        assertEq(amount, LOCK);
        assertEq(lockMiner, MINER);
        assertEq(module.fundsOf(MINER), 0);
        assertEq(module.fundsOf(MINER2), LOCK);
        _assertBooks();
    }

    /// @dev Attach with proofs already accepted: the core fires
    /// `onProofAccepted(acceptedProofs)` with no submission, so no note
    /// exists and no lock is recorded — even for already-minted token ids.
    function testAttachBootstrapRecordsNoLock() public {
        _detach();
        _win(BOB);
        _win(CAROL);
        assertEq(core.acceptedProofs(), 2);

        _deployModule(MIN_STAKE, LOCK, 0, 0, address(0));
        _fund(MINER, LOCK);
        _fund(BOB, LOCK);
        uint256 funds = module.totalFunds();
        _attach(module);
        assertEq(module.lastAcceptedProofs(), 2);
        assertEq(module.totalCommitted(), 0);
        assertEq(module.totalFunds(), funds);
        assertEq(module.fundsOf(BOB), LOCK);
        for (uint256 t = 1; t <= 3; t++) {
            _assertNoLock(t);
        }
        _assertNoteEmpty();
        _assertBooks();

        // The first real win after attach is the first lock.
        _deposit(ALICE, MIN_STAKE);
        _assign(ALICE, MINER, MIN_STAKE);
        _nextChallenge();
        uint256 tokenId = _win(MINER);
        assertEq(tokenId, 3);
        (, bytes32 d, uint256 c,) = nft.birthData(tokenId);
        _assertLock(tokenId, MINER, c, d);
        assertEq(module.totalCommitted(), LOCK);
        _assertBooks();
    }

    function testLockBindsToMintedIdDigestChallenge() public {
        _deposit(BOB, MIN_STAKE);
        _assign(BOB, MINER2, MIN_STAKE);
        _fund(MINER2, LOCK);
        _qualifyAndFund(ALICE, MINER, MIN_STAKE, 2 * LOCK);
        address[3] memory winners = [MINER, MINER2, MINER];
        for (uint256 i = 0; i < 3; i++) {
            uint256 tokenId = _win(winners[i]);
            assertEq(tokenId, i + 1);
            (, bytes32 d, uint256 c,) = nft.birthData(tokenId);
            _assertLock(tokenId, nft.ownerOf(tokenId), c, d);
            assertEq(nft.ownerOf(tokenId), winners[i]);
        }
        // Distinct challenges and digests per lock.
        (, uint256 c1, bytes32 d1,,) = module.committedOf(1);
        (, uint256 c3, bytes32 d3,,) = module.committedOf(3);
        assertTrue(c1 != c3);
        assertTrue(d1 != d3);
        // The lock records the minter, not whoever holds the NFT later.
        vm.prank(MINER);
        nft.transferFrom(MINER, CAROL, 1);
        (,,, address lockMiner,) = module.committedOf(1);
        assertEq(lockMiner, MINER);
        assertEq(module.totalCommitted(), 3 * LOCK);
        assertEq(module.fundsOf(MINER), 0);
        assertEq(module.fundsOf(MINER2), 0);
        _assertBooks();
    }

    function testCounterDivergenceFailsClosed() public {
        _qualifyAndFund(ALICE, MINER, MIN_STAKE, LOCK);
        stdstore.target(address(nft)).sig("mintedEver()").checked_write(1);
        (uint256 nonce,) = _nonce(MINER);
        // Core counter becomes 1; NFT would mint id 2.
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.CounterMismatch.selector, 1, 2));
        core.submitProof(cid, seed, nonce, basket);
        _assertNoLock(1);
        _assertNoLock(2);
        assertEq(module.fundsOf(MINER), LOCK);
        assertEq(module.totalCommitted(), 0);
        assertEq(core.acceptedProofs(), 0);
        assertEq(core.nftsMintedEver(), 0);
        _assertNoteEmpty();

        // The permissionless counter trip still works and stops mining.
        vm.prank(BOB);
        core.tripMining();
        assertTrue(core.miningStopped());
        assertTrue(module.retired());
        // Nothing to mint any more: no new funding, but funds exit freely.
        vm.prank(FUNDER);
        vm.expectRevert(PrefundedMiningPower.Retired.selector);
        module.fund(MINER, 1);
        vm.prank(MINER);
        module.withdrawFunds(LOCK);
        assertEq(token.balanceOf(MINER), LOCK);
        assertEq(module.totalFunds(), 0);
    }

    /// @dev Both counters rewound in lockstep (stdstore on the core and the
    /// NFT) pass the counter check but point at an id that already carries
    /// a lock: settlement refuses to overwrite it, before the NFT mint.
    function testExistingLockNeverOverwritten() public {
        _qualifyAndFund(ALICE, MINER, MIN_STAKE, 2 * LOCK);
        uint256 tokenId = _win(MINER);
        (, bytes32 d, uint256 c,) = nft.birthData(tokenId);
        stdstore.target(address(core)).sig("nftsMintedEver()").checked_write(uint256(0));
        stdstore.target(address(nft)).sig("mintedEver()").checked_write(uint256(0));
        _activate();
        (uint256 nonce,) = _nonce(MINER);
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.LockAlreadyExists.selector, tokenId));
        core.submitProof(cid, seed, nonce, basket);
        _assertLock(tokenId, MINER, c, d);
        assertEq(module.fundsOf(MINER), LOCK);
        assertEq(module.totalCommitted(), LOCK);
        _assertNoteEmpty();
    }

    /// @dev Unit probes on SEPARATE modules bound to a stand-in core (see
    /// `ForeignSequenceCore`): the defensive settlement checks the real core
    /// can never trigger still fail closed — a note for another challenge
    /// (`StaleChallengeId`), funds gone between gate and settlement
    /// (`InsufficientFunds`) and a gate for challenge 0 (`ChallengeNotOpen`).
    function testSettlementFailsClosedOnForeignSequence() public {
        ForeignSequenceCore fc;
        PrefundedMiningPower m;

        (fc, m) = _foreignModule();
        bytes memory err = fc.gateThenAccept(m, 7, 8);
        assertEq(err, abi.encodeWithSelector(PrefundedMiningPower.StaleChallengeId.selector, 7, 8));
        (uint256 amount,,,,) = m.committedOf(1);
        assertEq(amount, 0);
        assertEq(m.fundsOf(address(fc)), LOCK);

        (fc, m) = _foreignModule();
        err = fc.gateWithdrawThenAccept(m, 7);
        assertEq(err, abi.encodeWithSelector(PrefundedMiningPower.InsufficientFunds.selector, 0, LOCK));
        (amount,,,,) = m.committedOf(1);
        assertEq(amount, 0);
        assertEq(m.totalCommitted(), 0);

        fc = new ForeignSequenceCore();
        m = new PrefundedMiningPower(address(token), address(fc), 0, LOCK, 0, 0, address(0));
        token.mint(address(fc), LOCK);
        err = fc.gateChallengeZero(m, IERC20(address(token)), 5);
        assertEq(err, abi.encodeWithSelector(PrefundedMiningPower.ChallengeNotOpen.selector, 0));

        // The honest order on the same stand-in settles token 1.
        (fc, m) = _foreignModule();
        err = fc.gateThenAccept(m, 7, 7);
        assertEq(err.length, 0);
        (uint256 a, uint256 c, bytes32 d, address who,) = m.committedOf(1);
        assertEq(a, LOCK);
        assertEq(c, 7);
        assertEq(d, keccak256("foreign digest"));
        assertEq(who, address(fc));
    }

    function testSecondSubmitInSameTxCannotSettle() public {
        DoubleSubmitMiner dm = new DoubleSubmitMiner();
        _qualifyAndFund(ALICE, address(dm), MIN_STAKE, 3 * LOCK);
        (uint256 nonce,) = _nonce(address(dm));
        uint256 id = cid;
        dm.run(core, module, id, seed, nonce, basket);

        assertEq(dm.noteAfterFirst(), 0);
        assertEq(dm.noteMinerAfterFirst(), address(0));
        assertFalse(dm.nextOk());
        assertEq(
            dm.nextErr(),
            abi.encodeWithSelector(
                HunterMiningCore.ChallengeNotActive.selector, HunterMiningCore.ChallengeState.WAITING_FOR_SEED
            )
        );
        assertFalse(dm.replayOk());
        assertEq(
            dm.replayErr(),
            abi.encodeWithSelector(
                HunterMiningCore.ChallengeNotActive.selector, HunterMiningCore.ChallengeState.WAITING_FOR_SEED
            )
        );
        // Exactly one acceptance and one lock.
        assertEq(nft.mintedEver(), 1);
        (, bytes32 d, uint256 c,) = nft.birthData(1);
        _assertLock(1, address(dm), c, d);
        _assertNoLock(2);
        assertEq(module.fundsOf(address(dm)), 2 * LOCK);
        assertEq(module.totalCommitted(), LOCK);
        _assertNoteEmpty();
        _assertBooks();
    }

    function testReplayAfterAcceptanceNoSecondLock() public {
        _qualifyAndFund(ALICE, MINER, MIN_STAKE, 3 * LOCK);
        uint256 id = cid;
        uint256 sb = seed;
        (uint256 nonce,) = _nonce(MINER);
        _send(MINER, nonce);

        // Same block: the next seed is not readable yet.
        vm.prank(MINER);
        vm.expectRevert(
            abi.encodeWithSelector(
                HunterMiningCore.ChallengeNotActive.selector, HunterMiningCore.ChallengeState.WAITING_FOR_SEED
            )
        );
        core.submitProof(id, sb, nonce, basket);
        // Next challenge active: the old id is stale.
        _activate();
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.StaleChallengeId.selector, id, id + 1));
        core.submitProof(id, sb, nonce, basket);

        assertEq(nft.mintedEver(), 1);
        _assertNoLock(2);
        assertEq(module.totalCommitted(), LOCK);
        assertEq(module.fundsOf(MINER), 2 * LOCK);
        _assertNoteEmpty();
        _assertBooks();
    }

    /// @dev With the bonus disabled the gate never widens the target: a
    /// digest just above the base target is rejected at the base target even
    /// for an eligible wallet with an enormous stake.
    function testCurveDisabledGateNeverWidensTarget() public {
        _qualifyAndFund(ALICE, MINER, 1e30, LOCK);
        uint256 base = core.currentTarget();
        (uint256 n, bytes32 d) = _bandNonce(MINER, base, _widen(base, 3e18));
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.InvalidProof.selector, d, base));
        core.submitProof(cid, seed, n, basket);
        assertEq(module.totalCommitted(), 0);
    }

    /// @dev The settlement hook is O(1): gas of a winning submission is flat
    /// in the number of depositors and funded wallets. Every scenario starts
    /// from the same state snapshot and runs the same core schedule, so only
    /// the module's unrelated population differs. Also logs the overhead of
    /// the module over the ungated `DummyMiningPower` on the same core.
    function testHookGasFlatInDepositorCount() public {
        uint256 base = vm.snapshotState();

        uint256 g1 = _measuredWin(0, 0);
        vm.revertToState(base);
        uint256 gDepositors = _measuredWin(200, 0);
        vm.revertToState(base);
        uint256 gFunded = _measuredWin(0, 200);
        vm.revertToState(base);

        // Same schedule with the ungated dummy module on the same core.
        _detach();
        DummyMiningPower dummy = new DummyMiningPower();
        _attach(IMiningPower(address(dummy)));
        _nextChallenge();
        _activate();
        (uint256 nonce,) = _nonce(MINER);
        vm.prank(MINER);
        uint256 before = gasleft();
        core.submitProof(cid, seed, nonce, basket);
        uint256 gDummy = before - gasleft();

        emit log_named_uint("win gas, 1 depositor", g1);
        emit log_named_uint("win gas, +200 depositors backing other wallets", gDepositors);
        emit log_named_uint("win gas, +200 funded wallets", gFunded);
        emit log_named_uint("win gas, DummyMiningPower", gDummy);
        emit log_named_uint("module overhead over dummy", g1 - gDummy);
        assertLt(_diff(g1, gDepositors) * 100, g1 * 5, "depositor count moved hook gas");
        assertLt(_diff(g1, gFunded) * 100, g1 * 5, "funded wallet count moved hook gas");
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Money, note and counter state a rejected submission must not move.
    struct Snap {
        uint256 funds;
        uint256 pending;
        uint256 totalFunds;
        uint256 totalCommitted;
        uint256 moduleBal;
        uint256 accepted;
        uint256 coreMinted;
        uint256 nftMinted;
        bytes32 prevDigest;
        uint256 activeId;
        uint256 lastAccepted;
    }

    function _snap(address wallet) private view returns (Snap memory s) {
        s.funds = module.fundsOf(wallet);
        s.pending = module.pendingFunds(wallet);
        s.totalFunds = module.totalFunds();
        s.totalCommitted = module.totalCommitted();
        s.moduleBal = token.balanceOf(address(module));
        s.accepted = core.acceptedProofs();
        s.coreMinted = core.nftsMintedEver();
        s.nftMinted = nft.mintedEver();
        s.prevDigest = core.previousAcceptedDigest();
        s.activeId = core.activeChallengeId();
        s.lastAccepted = module.lastAcceptedProofs();
    }

    function _assertSnap(Snap memory s, address wallet) private view {
        assertEq(module.fundsOf(wallet), s.funds, "fundsOf moved");
        assertEq(module.pendingFunds(wallet), s.pending, "pendingFunds moved");
        assertEq(module.totalFunds(), s.totalFunds, "totalFunds moved");
        assertEq(module.totalCommitted(), s.totalCommitted, "totalCommitted moved");
        assertEq(token.balanceOf(address(module)), s.moduleBal, "module balance moved");
        assertEq(core.acceptedProofs(), s.accepted, "acceptedProofs moved");
        assertEq(core.nftsMintedEver(), s.coreMinted, "core nftsMintedEver moved");
        assertEq(nft.mintedEver(), s.nftMinted, "nft mintedEver moved");
        assertEq(core.previousAcceptedDigest(), s.prevDigest, "previousAcceptedDigest moved");
        assertEq(core.activeChallengeId(), s.activeId, "activeChallengeId moved");
        assertEq(module.lastAcceptedProofs(), s.lastAccepted, "lastAcceptedProofs moved");
        _assertNoLock(s.nftMinted + 1);
        _assertNoteEmpty();
    }

    function _assertLock(uint256 tokenId, address miner, uint256 challengeId, bytes32 digest) private view {
        (uint256 amount, uint256 c, bytes32 d, address m, bool released) = module.committedOf(tokenId);
        assertEq(amount, LOCK, "lock amount");
        assertEq(c, challengeId, "lock challenge");
        assertEq(d, digest, "lock digest");
        assertEq(m, miner, "lock miner");
        assertFalse(released, "lock released");
    }

    function _assertNoLock(uint256 tokenId) private view {
        (uint256 amount, uint256 c, bytes32 d, address m, bool released) = module.committedOf(tokenId);
        assertEq(amount, 0, "unexpected lock");
        assertEq(c, 0);
        assertEq(d, bytes32(0));
        assertEq(m, address(0));
        assertFalse(released);
    }

    function _assertGate(address wallet, bool eligible, uint8 reason, uint256 stake, uint256 funds) private view {
        (bool e, uint8 r, uint256 s, uint256 f) = module.eligibilityOf(wallet);
        assertEq(e, eligible, "eligible");
        assertEq(r, reason, "reason");
        assertEq(s, stake, "stake");
        assertEq(f, funds, "funds");
        assertEq(module.eligibleFundsOf(wallet), funds, "eligibleFundsOf");
    }

    /// @dev A valid-digest submission from `wallet` reverts
    /// NotEligible(reason) and moves nothing.
    function _assertRejectedNoChange(address wallet, uint8 reason) private {
        Snap memory s0 = _snap(wallet);
        (uint256 nonce,) = _nonce(wallet);
        _expectNotEligible(reason);
        _send(wallet, nonce);
        _assertSnap(s0, wallet);
    }

    /// @dev A nonce whose digest for `miner` is ABOVE `target`.
    function _invalidNonce(address miner, uint256 target) private view returns (uint256 nonce, bytes32 digest) {
        bytes32 challenge = core.currentChallenge();
        for (; nonce < 4_096; nonce++) {
            digest = core.deriveProofDigest(cid, challenge, miner, nonce);
            if (uint256(digest) > target) return (nonce, digest);
        }
        revert("invalid nonce not found");
    }

    /// @dev Populates the module with `depositors` extra depositors (each
    /// backing its own other wallet) and `funded` extra funded wallets,
    /// qualifies and funds MINER, then measures MINER's winning submission.
    function _measuredWin(uint256 depositors, uint256 funded) private returns (uint256 used) {
        for (uint256 i = 0; i < depositors; i++) {
            address d = address(uint160(0xD0000 + i));
            _deposit(d, MIN_STAKE);
            _assign(d, address(uint160(0xE0000 + i)), MIN_STAKE);
        }
        for (uint256 i = 0; i < funded; i++) {
            _fund(address(uint160(0xF0000 + i)), LOCK);
        }
        _deposit(ALICE, MIN_STAKE);
        _assign(ALICE, MINER, MIN_STAKE);
        _fund(MINER, LOCK);
        _nextChallenge();
        _activate();
        (uint256 nonce,) = _nonce(MINER);
        vm.prank(MINER);
        uint256 before = gasleft();
        core.submitProof(cid, seed, nonce, basket);
        used = before - gasleft();
        (uint256 amount,,,,) = module.committedOf(1);
        assertEq(amount, LOCK);
    }

    /// @dev A stand-in core with its own MIN_STAKE-0 module, funded with
    /// LOCK before its first snapshot so the funds count there.
    function _foreignModule() private returns (ForeignSequenceCore fc, PrefundedMiningPower m) {
        fc = new ForeignSequenceCore();
        m = new PrefundedMiningPower(address(token), address(fc), 0, LOCK, 0, 0, address(0));
        token.mint(address(fc), LOCK);
        fc.approveAndFund(m, IERC20(address(token)), LOCK);
    }

    function _diff(uint256 a, uint256 b) private pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

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
        // S6: `funds` is the wallet's eligible (non-pending) mint funds.
        assertEq(f, module.eligibleFundsOf(wallet), "funds");
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
