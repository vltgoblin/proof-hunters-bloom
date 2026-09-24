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
/// It doubles as its own `PROOF_NFT` (counter views) and as the depositor
/// backing the probed mining wallet, so it can pull that stake between the
/// gate and `onProofAccepted`. Never used in a positive-path mining test.
contract ForeignSequenceCore {
    uint256 public activeChallengeId;
    uint256 public nftsMintedEver = 1;
    uint256 public mintedEver;
    bytes32 public constant previousAcceptedDigest = keccak256("foreign digest");

    function PROOF_NFT() external view returns (address) {
        return address(this);
    }

    /// @dev Opens `id`, then stakes `amount` from this contract for `miner`
    /// (pending in `id`, matured from the next id).
    function openAndStake(PrefundedMiningPower m, IERC20 token, uint256 id, address miner, uint256 amount) external {
        activeChallengeId = id;
        m.snapshotChallenge(id);
        token.approve(address(m), amount);
        m.deposit(amount);
        m.assign(miner, amount);
    }

    /// @dev Gate admits `id`, the core's active id then reads `activeAtAccept`.
    function gateThenAccept(PrefundedMiningPower m, uint256 id, uint256 activeAtAccept, address miner)
        external
        returns (bytes memory err)
    {
        activeChallengeId = id;
        m.snapshotChallenge(id);
        m.powerMultiplierWad(id, miner);
        activeChallengeId = activeAtAccept;
        try m.onProofAccepted(1) {}
        catch (bytes memory e) {
            err = e;
        }
    }

    /// @dev Gate admits, the backer (this contract) pulls `amount` of the
    /// miner's stake, then acceptance.
    function gateUnassignThenAccept(PrefundedMiningPower m, uint256 id, address miner, uint256 amount)
        external
        returns (bytes memory err)
    {
        activeChallengeId = id;
        m.snapshotChallenge(id);
        m.powerMultiplierWad(id, miner);
        m.unassign(miner, amount);
        try m.onProofAccepted(1) {}
        catch (bytes memory e) {
            err = e;
        }
    }

    /// @dev A second gate + acceptance in the SAME challenge, counters moved
    /// on by one mint. The real core never does this (every acceptance opens
    /// a new challenge); the gate returns the cached frozen stake.
    function acceptAgainSameChallenge(PrefundedMiningPower m, address miner) external returns (bytes memory err) {
        mintedEver = nftsMintedEver;
        nftsMintedEver += 1;
        m.powerMultiplierWad(activeChallengeId, miner);
        try m.onProofAccepted(2) {}
        catch (bytes memory e) {
            err = e;
        }
    }

    /// @dev Opens `first`, stakes this contract's whole balance for `miner`
    /// (pending there), then opens challenge 0 — which the real core never
    /// does — so that stake counts, then gates 0.
    function gateChallengeZero(PrefundedMiningPower m, IERC20 token, uint256 first, address miner)
        external
        returns (bytes memory err)
    {
        m.snapshotChallenge(first);
        uint256 bal = token.balanceOf(address(this));
        token.approve(address(m), bal);
        m.deposit(bal);
        m.assign(miner, bal);
        m.snapshotChallenge(0);
        try m.powerMultiplierWad(0, miner) {}
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

    /// @dev Opens `id` (wires the module) so stake can be assigned before
    /// the probed challenge.
    function open(PrefundedMiningPower m, uint256 id) external {
        activeChallengeId = id;
        m.snapshotChallenge(id);
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

/// @notice S5 (VLT-56) eligibility gate and S6 (VLT-57) per-mint lock of
/// PrefundedMiningPower on the REAL stack: every admitted or rejected proof
/// goes through `HunterMiningCore.submitProof`. Owner decision 2026-09-25:
/// the lock is taken from the stake assigned to the winning wallet (one
/// backer per wallet); there are no mint funds. All amounts are TEST-ONLY
/// fixture values.
contract PrefundedMiningPowerSettlementTest is PrefundedMiningStack {
    using stdStorage for StdStorage;

    address internal constant CAROL = address(0xCA201);
    address internal constant MINER2 = address(0x222E);

    uint256 private constant MIN_STAKE = 1_000e18;
    uint256 private constant LOCK = 100e18;
    uint256 private constant BONUS_UNIT = 1_000_000e18;
    address private constant GUARDIAN = address(0x6A2D);

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
        // Stake for two wins, so MINER is still eligible after one.
        _qualifyFor(ALICE, MINER, 2);
        (bool eligible, uint8 reason, uint256 stake) = module.eligibilityOf(MINER);
        assertTrue(eligible);
        assertEq(reason, 0);
        assertEq(stake, MIN_STAKE + LOCK);

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
        // MIN_STAKE stays assigned, so MINER stays eligible next challenge.
        (eligible,, stake) = module.eligibilityOf(MINER);
        assertTrue(eligible);
        assertEq(stake, MIN_STAKE);
        _assertBooks();
    }

    function testIneligibleRevertsWithReasonAndNoStateChange() public {
        // (a) no stake at all.
        _activate();
        _assertGateRejectsWithoutSideEffects(MINER);

        // (b) matured stake one wei below MIN_STAKE. S8: a first assign must
        // reach MIN_STAKE, so one wei leaves again and the next challenge
        // freezes MIN_STAKE - 1.
        _qualify(ALICE, MINER2, MIN_STAKE);
        _unassign(ALICE, MINER2, 1);
        _nextChallenge();
        _activate();
        (bool eligible, uint8 reason, uint256 stake) = module.eligibilityOf(MINER2);
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
            (bool eligible, uint8 reason, uint256 stake) = module.eligibilityOf(ws[i]);
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
            (bool eligible, uint8 reason, uint256 stake) = module.eligibilityOf(ws[i]);
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
        assertEq(module.backerOf(address(miner)), address(0));
        assertEq(token.balanceOf(address(funder)), MIN_STAKE);
        _assertNoteEmpty();

        // The same pair qualifies once the stake has sat through a snapshot.
        funder.stake(address(miner), MIN_STAKE);
        _nextChallenge();
        _activate();
        (nonce,) = _nonce(address(miner));
        miner.submit(core, cid, seed, nonce, basket);
        assertEq(nft.ownerOf(1), address(miner));
        (,,,, address backer,) = module.committedOf(1);
        assertEq(backer, address(funder));
        assertEq(module.assignedOf(address(miner)), MIN_STAKE - LOCK);
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

    /// @dev Mid-challenge move (cooldown 0): the removal applies from the
    /// next challenge and the new assignment counts from the next challenge,
    /// so in the open challenge the stake still admits MINER (not MINER2).
    /// Single bucket: MINER's live stake is gone, so its admitted win cannot
    /// pay the lock and is rejected (`InsufficientFunds`); the next
    /// challenge the same stake qualifies — and pays for — MINER2 only.
    function testOneStakeQualifiesOneWalletPerChallenge() public {
        _qualify(ALICE, MINER, MIN_STAKE);
        _assertEligibility(MINER, true, 0, MIN_STAKE);

        _unassign(ALICE, MINER, MIN_STAKE);
        _assign(ALICE, MINER2, MIN_STAKE);
        // S8 reason 4: frozen MIN_STAKE still admits, the live stake is 0.
        _assertEligibility(MINER, false, 4, MIN_STAKE);
        _assertEligibility(MINER2, false, 2, 0);
        (uint256 nonce,) = _nonce(MINER2);
        _expectNotEligible(2);
        _send(MINER2, nonce);
        (nonce,) = _nonce(MINER);
        Snap memory s0 = _snap(MINER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.InsufficientFunds.selector, 0, LOCK));
        _send(MINER, nonce);
        _assertSnap(s0, MINER);
        _assertBooks();

        // Next challenge: the stake qualifies MINER2 only.
        _nextChallenge();
        _activate();
        _assertEligibility(MINER, false, 2, 0);
        _assertEligibility(MINER2, true, 0, MIN_STAKE);
        (nonce,) = _nonce(MINER);
        _expectNotEligible(2);
        _send(MINER, nonce);
        _win(MINER2);
        assertEq(nft.mintedEver(), 1);
        assertEq(nft.ownerOf(1), MINER2);
        (,,,, address backer,) = module.committedOf(1);
        assertEq(backer, ALICE);
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

        (bool eligible,,) = m.eligibilityOf(MINER);
        assertTrue(eligible);
        uint256 tokenId = _win(MINER);
        assertEq(nft.ownerOf(tokenId), MINER);
        assertEq(m.lastAcceptedProofs(), 1);
        // The win also settled a lock from the stake with the token bricked.
        (uint256 locked,,, address lockMiner, address lockBacker,) = m.committedOf(tokenId);
        assertEq(locked, LOCK);
        assertEq(lockMiner, MINER);
        assertEq(lockBacker, ALICE);
        assertEq(m.assignedOf(MINER), MIN_STAKE - LOCK);
        assertEq(m.totalStake(), MIN_STAKE - LOCK);
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
        _qualify(ALICE, MINER, MIN_STAKE);

        (bool ok, bytes memory ret) =
            address(module).staticcall(abi.encodeCall(PrefundedMiningPower.eligibilityOf, (MINER)));
        assertTrue(ok);
        (bool eligible, uint8 reason, uint256 stake) = abi.decode(ret, (bool, uint8, uint256));
        assertTrue(eligible);
        assertEq(reason, 0);
        assertEq(stake, MIN_STAKE);

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
    /// settles from it (taking the lock from ALICE's stake) and clears both;
    /// a disabled gate writes nothing.
    function testGateNoteKeyedByChallengeAndMinerAndClearedOnAccept() public {
        NoteProbeCore probeCore = new NoteProbeCore();
        PrefundedMiningPower m =
            new PrefundedMiningPower(address(token), address(probeCore), LOCK, LOCK, 0, 0, address(0));
        // Staked in challenge 6, so it counts in challenge 7.
        probeCore.open(m, 6);
        token.mint(ALICE, LOCK);
        vm.startPrank(ALICE);
        token.approve(address(m), LOCK);
        m.deposit(LOCK);
        m.assign(MINER, LOCK);
        vm.stopPrank();
        (uint256 noteDuring, address minerDuring, uint256 noteAfter, address minerAfter) = probeCore.probe(m, 7, MINER);
        assertEq(noteDuring, 7);
        assertEq(minerDuring, MINER);
        assertEq(noteAfter, 0);
        assertEq(minerAfter, address(0));
        (uint256 amount, uint256 lockChallenge, bytes32 lockDigest, address lockMiner, address lockBacker,) =
            m.committedOf(1);
        assertEq(amount, LOCK);
        assertEq(lockChallenge, 7);
        assertEq(lockDigest, keccak256("probe digest"));
        assertEq(lockMiner, MINER);
        assertEq(lockBacker, ALICE);
        assertEq(m.assignedOf(MINER), 0);
        assertEq(m.backerOf(MINER), address(0));

        PrefundedMiningPower off =
            new PrefundedMiningPower(address(token), address(probeCore), MIN_STAKE, LOCK, 0, 0, GUARDIAN);
        vm.prank(GUARDIAN);
        off.disableRequirement();
        (noteDuring, minerDuring,,) = probeCore.probe(off, 7, MINER);
        assertEq(noteDuring, 0);
        assertEq(minerDuring, address(0));
        (amount,,,,,) = off.committedOf(1);
        assertEq(amount, 0);
    }

    function testEligibilityReasonOneWhenModuleNotLive() public {
        _detach();
        _deployModule(MIN_STAKE, LOCK, 0, 0, GUARDIAN);
        _attach(module);
        _qualify(ALICE, MINER, MIN_STAKE);
        _assertEligibility(MINER, true, 0, MIN_STAKE);

        // A fresh, never-attached module is not the live one.
        PrefundedMiningPower fresh =
            new PrefundedMiningPower(address(token), address(core), MIN_STAKE, LOCK, 0, 0, address(0));
        (bool eligible, uint8 reason,) = fresh.eligibilityOf(MINER);
        assertFalse(eligible);
        assertEq(reason, 1);

        // Non-terminal detach.
        _detach();
        (eligible, reason,) = module.eligibilityOf(MINER);
        assertFalse(eligible);
        assertEq(reason, 1);

        // Terminal detach (retired), even with the failsafe flag set.
        _unassign(ALICE, MINER, MIN_STAKE);
        _attach(module);
        vm.prank(STOP);
        core.stopMining();
        assertTrue(module.retired());
        vm.prank(GUARDIAN);
        module.disableRequirement();
        (eligible, reason,) = module.eligibilityOf(MINER);
        assertFalse(eligible);
        assertEq(reason, 1);
    }

    /// @dev Random stake, matured or not, plus a random top-up assigned while
    /// the challenge is open (pending: never counts for it, but it is live
    /// stake the lock may be paid from).
    function testFuzz_PreviewMatchesGate(uint256 stakeSeed, bool matured, uint256 topUpSeed) public {
        uint256 amount = bound(stakeSeed, 0, 2 * MIN_STAKE);
        uint256 topUp = bound(topUpSeed, 0, 3 * LOCK);
        if (amount != 0) {
            _deposit(ALICE, amount);
            if (amount < MIN_STAKE) {
                // S8: a first assign below MIN_STAKE is refused outright.
                vm.prank(ALICE);
                vm.expectRevert(
                    abi.encodeWithSelector(PrefundedMiningPower.FirstAssignBelowMinimum.selector, amount, MIN_STAKE)
                );
                module.assign(MINER, amount);
                amount = 0;
            } else {
                _assign(ALICE, MINER, amount);
            }
        }
        if (matured) _nextChallenge();
        _activate();
        if (topUp != 0) {
            _deposit(ALICE, topUp);
            if (amount == 0) {
                // Still a first assign (topUp <= 3L < MIN_STAKE): refused.
                vm.prank(ALICE);
                vm.expectRevert(
                    abi.encodeWithSelector(PrefundedMiningPower.FirstAssignBelowMinimum.selector, topUp, MIN_STAKE)
                );
                module.assign(MINER, topUp);
                topUp = 0;
            } else {
                _assign(ALICE, MINER, topUp);
            }
        }

        uint256 frozen = matured ? amount : 0;
        bool eligible = frozen >= MIN_STAKE;
        (bool e, uint8 reason, uint256 stake) = module.eligibilityOf(MINER);
        assertEq(stake, frozen);
        assertEq(e, eligible);
        assertEq(reason, eligible ? 0 : 2);
        assertEq(module.previewSubmit(MINER), 1e18);

        (uint256 nonce,) = _nonce(MINER);
        uint256 before = nft.mintedEver();
        if (!eligible) _expectNotEligible(reason);
        _send(MINER, nonce);
        assertEq(nft.mintedEver(), eligible ? before + 1 : before);
        (uint256 locked,,, address lockMiner, address lockBacker,) = module.committedOf(before + 1);
        assertEq(locked, eligible ? LOCK : 0);
        assertEq(lockMiner, eligible ? MINER : address(0));
        assertEq(lockBacker, eligible ? ALICE : address(0));
        uint256 live = amount + topUp - (eligible ? LOCK : 0);
        assertEq(module.assignedOf(MINER), live);
        assertEq(module.assignedBy(ALICE), live);
        assertEq(module.backerOf(MINER), live == 0 ? address(0) : ALICE);
        assertEq(module.totalCommitted(), eligible ? LOCK : 0);
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
        // The lock is L whatever the bonus; the next freeze sees the rest.
        assertEq(module.assignedOf(wallets[1]), BONUS_UNIT - LOCK);
        _assertNoteEmpty();
    }

    /// @dev The failsafe fired through S8's `disableRequirement`.
    function testGateDisabledSkipsChecksAndWritesNoNote() public {
        _detach();
        _deployModule(MIN_STAKE, LOCK, 0, 0, GUARDIAN);
        _attach(module);
        _activate();
        (uint256 nonce,) = _nonce(MINER);
        _expectNotEligible(2);
        _send(MINER, nonce);

        vm.prank(GUARDIAN);
        module.disableRequirement();
        assertTrue(module.gateDisabled());
        _assertEligibility(MINER, true, 0, 0);
        uint256 tokenId = _win(MINER);
        assertEq(nft.ownerOf(tokenId), MINER);
        assertEq(module.lastAcceptedProofs(), 1);
        _assertNoLock(tokenId);
        _assertNoteEmpty();
        // Still open in the following challenge.
        _win(MINER2);
        assertEq(module.totalCommitted(), 0);
        _assertNoteEmpty();
    }

    // ------------------------------------------------------------------
    // S6: the per-mint lock from the winner's assigned stake
    // ------------------------------------------------------------------

    function testEligibleDirectSubmissionMintsAndLocksOnce() public {
        _qualify(ALICE, MINER, MIN_STAKE + 7);
        uint256 moduleBal = token.balanceOf(address(module));
        uint256 id = cid;
        (uint256 nonce, bytes32 digest) = _nonce(MINER);

        vm.expectEmit(true, true, true, true, address(module));
        emit PrefundedMiningPower.Committed(1, MINER, id, ALICE, digest, LOCK);
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
        // Every stake total −L, the backer recorded, no token moved by hooks.
        uint256 left = MIN_STAKE + 7 - LOCK;
        assertEq(module.assignedOf(MINER), left);
        assertEq(module.assignedBy(ALICE), left);
        assertEq(module.totalAssigned(), left);
        assertEq(module.totalStake(), left);
        assertEq(module.totalCommitted(), LOCK);
        assertEq(module.backerOf(MINER), ALICE);
        assertEq(module.assigneeOf(ALICE), MINER);
        assertEq(module.unassignedOf(ALICE), 0);
        assertEq(token.balanceOf(address(module)), moduleBal);
        assertEq(token.balanceOf(address(module)), MIN_STAKE + 7);
        assertEq(token.balanceOf(address(module)), module.totalStake() + module.totalCommitted());
        // Below the floor now: not eligible next challenge (reason 2).
        _activate();
        _assertEligibility(MINER, false, 2, left);
        _assertRejectedNoChange(MINER, 2);
        _assertNoteEmpty();
        _assertBooks();
    }

    /// @dev Floor rule: stake MIN_STAKE + 2L pays for exactly three wins, one
    /// per challenge (each acceptance opens the next challenge, so the
    /// frozen value is never reused); the fourth attempt, in the following
    /// challenge, freezes MIN_STAKE - L and is rejected by the gate.
    function testFloorRuleAllowsExactlyNWins() public {
        uint256 stake = _qualifyFor(ALICE, MINER, 3);
        assertEq(stake, MIN_STAKE + 2 * LOCK);
        uint256[3] memory frozen = [MIN_STAKE + 2 * LOCK, MIN_STAKE + LOCK, MIN_STAKE];
        for (uint256 i = 0; i < 3; i++) {
            _activate();
            _assertEligibility(MINER, true, 0, frozen[i]);
            uint256 opened = cid;
            uint256 tokenId = _win(MINER);
            assertEq(tokenId, i + 1);
            assertEq(module.latestChallengeId(), opened + 1);
            (, bytes32 d, uint256 c,) = nft.birthData(tokenId);
            _assertLock(tokenId, MINER, c, d);
            assertEq(module.assignedOf(MINER), frozen[i] - LOCK);
        }
        _activate();
        _assertEligibility(MINER, false, 2, MIN_STAKE - LOCK);
        _assertRejectedNoChange(MINER, 2);
        _assertNoLock(4);
        assertEq(module.totalCommitted(), 3 * LOCK);
        assertEq(module.totalStake(), MIN_STAKE - LOCK);
        assertEq(token.balanceOf(address(module)), MIN_STAKE + 2 * LOCK);
        _assertBooks();
    }

    /// @dev The lock is always exactly L out of the LIVE assigned stake, not
    /// a share of the frozen value: a top-up assigned in the open challenge
    /// does not count for it (frozen = MIN_STAKE) but is part of the balance
    /// the lock comes from. The lock consumes matured stake first, so the
    /// pending top-up is untouched; the next challenge freezes what is left.
    function testLockDeductedFromLiveStakeNotFrozen() public {
        uint256 topUp = 3 * LOCK;
        _qualify(ALICE, MINER, MIN_STAKE);
        _deposit(ALICE, topUp);
        _assign(ALICE, MINER, topUp);
        _assertEligibility(MINER, true, 0, MIN_STAKE);
        assertEq(module.assignedOf(MINER), MIN_STAKE + topUp);
        assertEq(module.pendingOf(MINER), topUp);

        _win(MINER);
        assertEq(module.assignedOf(MINER), MIN_STAKE + topUp - LOCK);
        assertEq(module.assignedBy(ALICE), MIN_STAKE + topUp - LOCK);
        assertEq(module.pendingOf(MINER), topUp);
        assertEq(module.pendingBy(ALICE), topUp);
        assertEq(module.totalCommitted(), LOCK);

        _activate();
        _assertEligibility(MINER, true, 0, MIN_STAKE + topUp - LOCK);
        _assertBooks();
    }

    /// @dev Frozen vs live, case 1: the backer unassigns matured stake in the
    /// open challenge. It still counts (removingOf), so the gate admits, but
    /// the live assigned stake is below L and settlement rejects the win
    /// (`InsufficientFunds`) — nothing changes. The held stake is in the
    /// backer's unassigned balance and is never locked. Topping the live
    /// stake back up to L (a pending assign) makes the same wallet's win
    /// settle; the lock then eats into the pending top-up, so the pending
    /// buckets are clamped to the remaining balance.
    function testRemovedStakeAdmitsButLiveStakeBelowLockReverts() public {
        _qualify(ALICE, MINER, MIN_STAKE + LOCK - 1);
        _unassign(ALICE, MINER, MIN_STAKE);
        assertEq(module.assignedOf(MINER), LOCK - 1);
        assertEq(module.removingOf(MINER), MIN_STAKE);
        assertEq(module.heldStakeOf(ALICE), MIN_STAKE);
        // S8 reason 4: the gate admits on the frozen stake, the live stake
        // (L - 1) cannot pay the lock.
        _assertEligibility(MINER, false, 4, MIN_STAKE + LOCK - 1);

        Snap memory s0 = _snap(MINER);
        (uint256 nonce,) = _nonce(MINER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.InsufficientFunds.selector, LOCK - 1, LOCK));
        _send(MINER, nonce);
        _assertSnap(s0, MINER);
        assertEq(module.heldStakeOf(ALICE), MIN_STAKE);
        assertEq(module.unassignedOf(ALICE), MIN_STAKE);
        _assertBooks();

        // One pending wei brings the live stake to L: the win settles.
        _deposit(ALICE, 1);
        _assign(ALICE, MINER, 1);
        assertEq(module.pendingOf(MINER), 1);
        _assertEligibility(MINER, true, 0, MIN_STAKE + LOCK - 1);
        _win(MINER);
        (,,,, address backer,) = module.committedOf(1);
        assertEq(backer, ALICE);
        assertEq(module.assignedOf(MINER), 0);
        assertEq(module.assignedBy(ALICE), 0);
        assertEq(module.pendingOf(MINER), 0);
        assertEq(module.pendingBy(ALICE), 0);
        assertEq(module.backerOf(MINER), address(0));
        assertEq(module.assigneeOf(ALICE), address(0));
        // The removal and the hold are untouched by the lock.
        assertEq(module.removingOf(MINER), MIN_STAKE);
        assertEq(module.heldBy(ALICE), MIN_STAKE);
        assertEq(module.totalCommitted(), LOCK);
        assertEq(module.totalStake(), MIN_STAKE);
        _assertBooks();

        // Next challenge: the hold lifts and MINER has nothing left.
        _activate();
        assertEq(module.withdrawableOf(ALICE), MIN_STAKE);
        _assertEligibility(MINER, false, 2, 0);
        _withdraw(ALICE, MIN_STAKE);
        assertEq(token.balanceOf(ALICE), MIN_STAKE);
        assertEq(token.balanceOf(address(module)), LOCK);
        _assertBooks();
    }

    /// @dev Frozen vs live, case 2: after the same kind of mid-challenge
    /// removal the live assigned stake is still >= L, so the admitted win
    /// settles from it; the held stake stays with the backer.
    function testRemovedStakeAdmitsAndLiveStakePaysLock() public {
        _qualify(ALICE, MINER, MIN_STAKE + LOCK);
        _unassign(ALICE, MINER, MIN_STAKE);
        assertEq(module.assignedOf(MINER), LOCK);
        _assertEligibility(MINER, true, 0, MIN_STAKE + LOCK);

        uint256 tokenId = _win(MINER);
        (, bytes32 d, uint256 c,) = nft.birthData(tokenId);
        _assertLock(tokenId, MINER, c, d);
        assertEq(module.assignedOf(MINER), 0);
        assertEq(module.backerOf(MINER), address(0));
        assertEq(module.unassignedOf(ALICE), MIN_STAKE);
        assertEq(module.heldBy(ALICE), MIN_STAKE);
        _assertBooks();

        _activate();
        _assertEligibility(MINER, false, 2, 0);
        _withdraw(ALICE, MIN_STAKE);
        assertEq(token.balanceOf(address(module)), LOCK);
        assertEq(module.totalCommitted(), LOCK);
        _assertBooks();
    }

    function testSecondBackerRejected() public {
        // S8: the first assign must reach MIN_STAKE; top-ups need not.
        _deposit(ALICE, MIN_STAKE + MIN_STAKE / 2);
        _assign(ALICE, MINER, MIN_STAKE);
        assertEq(module.backerOf(MINER), ALICE);
        _deposit(BOB, MIN_STAKE);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.WalletAlreadyBacked.selector, ALICE));
        module.assign(MINER, MIN_STAKE);

        // The backer itself tops up freely; BOB backs another wallet.
        _assign(ALICE, MINER, MIN_STAKE / 2);
        _assign(BOB, MINER2, MIN_STAKE);
        assertEq(module.assignedOf(MINER), MIN_STAKE + MIN_STAKE / 2);
        assertEq(module.backerOf(MINER2), BOB);
        _assertBooks();

        // A partial exit keeps ALICE the backer; a full exit frees the slot.
        _unassign(ALICE, MINER, 1);
        assertEq(module.backerOf(MINER), ALICE);
        _unassign(BOB, MINER2, MIN_STAKE);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.WalletAlreadyBacked.selector, ALICE));
        module.assign(MINER, 1);
        _unassign(ALICE, MINER, MIN_STAKE + MIN_STAKE / 2 - 1);
        assertEq(module.backerOf(MINER), address(0));
        _assign(BOB, MINER, MIN_STAKE);
        assertEq(module.backerOf(MINER), BOB);
        assertEq(module.assignedOf(MINER), MIN_STAKE);
        _assertBooks();

        // The new backer's stake is what the next lock is paid from.
        _nextChallenge();
        uint256 tokenId = _win(MINER);
        (,,,, address backer,) = module.committedOf(tokenId);
        assertEq(backer, BOB);
        assertEq(module.assignedBy(BOB), MIN_STAKE - LOCK);
        assertEq(module.unassignedOf(ALICE), MIN_STAKE + MIN_STAKE / 2);
        _assertBooks();
    }

    /// @dev With MIN_STAKE == L one win consumes the whole stake: the
    /// wallet's backer slot and the backer's assignee are both cleared, so
    /// another depositor may back the wallet and the old backer may back
    /// another wallet without unassigning.
    function testBackerClearedWhenStakeReachesZero() public {
        _detach();
        _deployModule(LOCK, LOCK, 0, 0, address(0));
        _attach(module);
        _qualify(ALICE, MINER, LOCK);
        assertEq(module.backerOf(MINER), ALICE);
        _win(MINER);
        assertEq(module.assignedOf(MINER), 0);
        assertEq(module.assignedBy(ALICE), 0);
        assertEq(module.backerOf(MINER), address(0));
        assertEq(module.assigneeOf(ALICE), address(0));
        assertEq(module.totalAssigned(), 0);
        assertEq(module.totalStake(), 0);
        assertEq(module.totalCommitted(), LOCK);
        _assertBooks();

        _deposit(BOB, LOCK);
        _assign(BOB, MINER, LOCK);
        _deposit(ALICE, LOCK);
        _assign(ALICE, MINER2, LOCK);
        assertEq(module.backerOf(MINER), BOB);
        assertEq(module.backerOf(MINER2), ALICE);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.WrongAssignee.selector, MINER2, MINER));
        module.unassign(MINER, 1);
        _assertBooks();
    }

    function testMinStakeBelowLockRejectedByConstructor() public {
        vm.expectRevert(PrefundedMiningPower.InvalidConfiguration.selector);
        new PrefundedMiningPower(address(token), address(core), LOCK - 1, LOCK, 0, 0, address(0));
        vm.expectRevert(PrefundedMiningPower.InvalidConfiguration.selector);
        new PrefundedMiningPower(address(token), address(core), 0, LOCK, 0, 0, address(0));
        vm.expectRevert(PrefundedMiningPower.InvalidConfiguration.selector);
        new PrefundedMiningPower(address(token), address(core), 0, 0, 0, 0, address(0));
        PrefundedMiningPower equal =
            new PrefundedMiningPower(address(token), address(core), LOCK, LOCK, 0, 0, address(0));
        assertEq(equal.MIN_STAKE(), equal.LOCK_PER_MINT());
    }

    // -- rollback matrix: a lock never survives a reverted submission --------

    function testInvalidDigestRollsBack() public {
        _qualify(ALICE, MINER, MIN_STAKE);
        uint256 target = core.currentTarget();
        (uint256 bad, bytes32 badDigest) = _invalidNonce(MINER, target);
        Snap memory s0 = _snap(MINER);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.InvalidProof.selector, badDigest, target));
        _send(MINER, bad);
        _assertSnap(s0, MINER);

        // The same wallet still mints (and locks) with a valid digest.
        _win(MINER);
        (uint256 amount,,,,,) = module.committedOf(1);
        assertEq(amount, LOCK);
        _assertBooks();
    }

    function testStaleIdSeedWaitingExpiredRejected() public {
        _qualify(ALICE, MINER, MIN_STAKE);
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
        assertEq(module.assignedOf(MINER), s0.walletStake);
        assertEq(module.totalStake(), s0.totalStake);
        assertEq(module.totalCommitted(), 0);
        assertEq(nft.mintedEver(), 0);
        _assertNoLock(1);
        _assertNoteEmpty();
        _assertBooks();
    }

    function testBadBasketRollsBackLock() public {
        _qualify(ALICE, MINER, MIN_STAKE);
        (uint256 nonce,) = _nonce(MINER);
        Snap memory s0 = _snap(MINER);
        address unadmitted = address(0xBA5CE7);
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(HunterNFT.InvalidBasket.selector, unadmitted));
        core.submitProof(cid, seed, nonce, unadmitted);
        _assertSnap(s0, MINER);

        _send(MINER, nonce);
        (uint256 amount,,, address lockMiner,,) = module.committedOf(1);
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
        vm.startPrank(ALICE);
        token.approve(address(m), MIN_STAKE);
        m.deposit(MIN_STAKE);
        m.assign(MINER, MIN_STAKE);
        vm.stopPrank();

        // Open the next challenge (stake matures) and make it active.
        vm.roll(c2.activeSeedParentBlock() + c2.SEED_READABLE_PARENT_BLOCKS() + 1);
        c2.refreshExpiredSeed();
        uint256 id = c2.activeChallengeId();
        uint256 sb = c2.activeSeedParentBlock();
        vm.roll(sb + 1);
        vm.setBlockhash(sb, keccak256(abi.encode("seed2", sb)));
        (bool eligible,,) = m.eligibilityOf(MINER);
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
        assertEq(m.assignedOf(MINER), MIN_STAKE);
        assertEq(m.assignedBy(ALICE), MIN_STAKE);
        assertEq(m.totalStake(), MIN_STAKE);
        assertEq(m.totalAssigned(), MIN_STAKE);
        assertEq(m.totalCommitted(), 0);
        (uint256 amount,,,,,) = m.committedOf(1);
        assertEq(amount, 0);
        (uint256 note, address noteMiner) = m.pendingEligibleNote();
        assertEq(note, 0);
        assertEq(noteMiner, address(0));
        assertEq(c2.acceptedProofs(), 0);
        assertEq(c2.nftsMintedEver(), 0);
        assertEq(n2.mintedEver(), 0);
        assertEq(m.lastAcceptedProofs(), 0);
        assertEq(token.balanceOf(address(m)), MIN_STAKE);

        fixture.setFail(false);
        vm.prank(MINER);
        c2.submitProof(id, sb, nonce, basket);
        (amount,,,,,) = m.committedOf(1);
        assertEq(amount, LOCK);
        assertEq(m.assignedOf(MINER), MIN_STAKE - LOCK);
        assertEq(n2.ownerOf(1), MINER);
    }

    function testCopiedNonceOtherWalletNoLock() public {
        _deposit(BOB, MIN_STAKE);
        _assign(BOB, MINER2, MIN_STAKE);
        _qualify(ALICE, MINER, MIN_STAKE);
        // Both wallets are eligible; the proof is wallet-bound.
        _assertEligibility(MINER2, true, 0, MIN_STAKE);
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
        assertEq(module.assignedOf(MINER), MIN_STAKE);

        _send(MINER, nonce);
        (uint256 amount,,, address lockMiner, address lockBacker,) = module.committedOf(1);
        assertEq(amount, LOCK);
        assertEq(lockMiner, MINER);
        assertEq(lockBacker, ALICE);
        assertEq(module.assignedOf(MINER), MIN_STAKE - LOCK);
        assertEq(module.assignedOf(MINER2), MIN_STAKE);
        assertEq(module.assignedBy(BOB), MIN_STAKE);
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
        _deposit(ALICE, MIN_STAKE);
        _attach(module);
        assertEq(module.lastAcceptedProofs(), 2);
        assertEq(module.totalCommitted(), 0);
        assertEq(module.totalStake(), MIN_STAKE);
        for (uint256 t = 1; t <= 3; t++) {
            _assertNoLock(t);
        }
        _assertNoteEmpty();
        _assertBooks();

        // The first real win after attach is the first lock.
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
        _qualifyFor(ALICE, MINER, 2);
        address[3] memory winners = [MINER, MINER2, MINER];
        address[3] memory backers = [ALICE, BOB, ALICE];
        for (uint256 i = 0; i < 3; i++) {
            uint256 tokenId = _win(winners[i]);
            assertEq(tokenId, i + 1);
            (, bytes32 d, uint256 c,) = nft.birthData(tokenId);
            _assertLock(tokenId, nft.ownerOf(tokenId), c, d);
            assertEq(nft.ownerOf(tokenId), winners[i]);
            (,,,, address backer,) = module.committedOf(tokenId);
            assertEq(backer, backers[i]);
        }
        // Distinct challenges and digests per lock.
        (, uint256 c1, bytes32 d1,,,) = module.committedOf(1);
        (, uint256 c3, bytes32 d3,,,) = module.committedOf(3);
        assertTrue(c1 != c3);
        assertTrue(d1 != d3);
        // The lock records the minter, not whoever holds the NFT later.
        vm.prank(MINER);
        nft.transferFrom(MINER, CAROL, 1);
        (,,, address lockMiner,,) = module.committedOf(1);
        assertEq(lockMiner, MINER);
        assertEq(module.totalCommitted(), 3 * LOCK);
        assertEq(module.assignedOf(MINER), MIN_STAKE - LOCK);
        assertEq(module.assignedOf(MINER2), MIN_STAKE - LOCK);
        _assertBooks();
    }

    function testCounterDivergenceFailsClosed() public {
        _qualify(ALICE, MINER, MIN_STAKE);
        stdstore.target(address(nft)).sig("mintedEver()").checked_write(1);
        (uint256 nonce,) = _nonce(MINER);
        // Core counter becomes 1; NFT would mint id 2.
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(PrefundedMiningPower.CounterMismatch.selector, 1, 2));
        core.submitProof(cid, seed, nonce, basket);
        _assertNoLock(1);
        _assertNoLock(2);
        assertEq(module.assignedOf(MINER), MIN_STAKE);
        assertEq(module.totalCommitted(), 0);
        assertEq(core.acceptedProofs(), 0);
        assertEq(core.nftsMintedEver(), 0);
        _assertNoteEmpty();

        // The permissionless counter trip still works and stops mining.
        vm.prank(BOB);
        core.tripMining();
        assertTrue(core.miningStopped());
        assertTrue(module.retired());
        // Nothing to mint any more: no new assigns, but stake exits freely.
        vm.prank(ALICE);
        vm.expectRevert(PrefundedMiningPower.Retired.selector);
        module.assign(MINER, 1);
        _unassign(ALICE, MINER, MIN_STAKE);
        _withdraw(ALICE, MIN_STAKE);
        assertEq(token.balanceOf(ALICE), MIN_STAKE);
        assertEq(module.totalStake(), 0);
    }

    /// @dev Both counters rewound in lockstep (stdstore on the core and the
    /// NFT) pass the counter check but point at an id that already carries
    /// a lock: settlement refuses to overwrite it, before the NFT mint.
    function testExistingLockNeverOverwritten() public {
        _qualifyFor(ALICE, MINER, 2);
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
        assertEq(module.assignedOf(MINER), MIN_STAKE);
        assertEq(module.totalCommitted(), LOCK);
        _assertNoteEmpty();
    }

    /// @dev Unit probes on SEPARATE modules bound to a stand-in core (see
    /// `ForeignSequenceCore`): the defensive settlement checks the real core
    /// can never trigger still fail closed — a note for another challenge
    /// (`StaleChallengeId`), stake pulled between gate and settlement
    /// (`InsufficientFunds`), a second win in the SAME challenge whose cached
    /// frozen stake still admits it while the live stake cannot pay
    /// (`InsufficientFunds`), and a gate for challenge 0 (`ChallengeNotOpen`).
    function testSettlementFailsClosedOnForeignSequence() public {
        ForeignSequenceCore fc;
        PrefundedMiningPower m;

        (fc, m) = _foreignModule(LOCK);
        bytes memory err = fc.gateThenAccept(m, 7, 8, MINER);
        assertEq(err, abi.encodeWithSelector(PrefundedMiningPower.StaleChallengeId.selector, 7, 8));
        (uint256 amount,,,,,) = m.committedOf(1);
        assertEq(amount, 0);
        assertEq(m.assignedOf(MINER), LOCK);

        // Stake pulled (all, then all but one wei) between gate and settlement.
        (fc, m) = _foreignModule(LOCK);
        err = fc.gateUnassignThenAccept(m, 7, MINER, LOCK);
        assertEq(err, abi.encodeWithSelector(PrefundedMiningPower.InsufficientFunds.selector, 0, LOCK));
        (amount,,,,,) = m.committedOf(1);
        assertEq(amount, 0);
        assertEq(m.totalCommitted(), 0);
        (fc, m) = _foreignModule(LOCK);
        err = fc.gateUnassignThenAccept(m, 7, MINER, 1);
        assertEq(err, abi.encodeWithSelector(PrefundedMiningPower.InsufficientFunds.selector, LOCK - 1, LOCK));
        assertEq(m.totalCommitted(), 0);

        // Same challenge twice: the frozen value (LOCK) still admits, the
        // first lock took the whole live stake, the second cannot be paid.
        (fc, m) = _foreignModule(LOCK);
        err = fc.gateThenAccept(m, 7, 7, MINER);
        assertEq(err.length, 0);
        assertEq(m.assignedOf(MINER), 0);
        err = fc.acceptAgainSameChallenge(m, MINER);
        assertEq(err, abi.encodeWithSelector(PrefundedMiningPower.InsufficientFunds.selector, 0, LOCK));
        (amount,,,,,) = m.committedOf(2);
        assertEq(amount, 0);
        assertEq(m.totalCommitted(), LOCK);
        // With two locks' worth of live stake the same sequence pays both
        // (within one challenge a wallet's frozen stake is not changed by
        // its own wins).
        (fc, m) = _foreignModule(2 * LOCK);
        fc.gateThenAccept(m, 7, 7, MINER);
        err = fc.acceptAgainSameChallenge(m, MINER);
        assertEq(err.length, 0);
        (amount,,,,,) = m.committedOf(2);
        assertEq(amount, LOCK);
        assertEq(m.assignedOf(MINER), 0);
        assertEq(m.totalCommitted(), 2 * LOCK);

        fc = new ForeignSequenceCore();
        m = new PrefundedMiningPower(address(token), address(fc), LOCK, LOCK, 0, 0, address(0));
        token.mint(address(fc), LOCK);
        err = fc.gateChallengeZero(m, IERC20(address(token)), 5, MINER);
        assertEq(err, abi.encodeWithSelector(PrefundedMiningPower.ChallengeNotOpen.selector, 0));

        // The honest order on the same stand-in settles token 1.
        (fc, m) = _foreignModule(LOCK);
        err = fc.gateThenAccept(m, 7, 7, MINER);
        assertEq(err.length, 0);
        (uint256 a, uint256 c, bytes32 d, address who, address backer,) = m.committedOf(1);
        assertEq(a, LOCK);
        assertEq(c, 7);
        assertEq(d, keccak256("foreign digest"));
        assertEq(who, MINER);
        assertEq(backer, address(fc));
        assertEq(m.totalStake(), 0);
        assertEq(token.balanceOf(address(m)), LOCK);
    }

    function testSecondSubmitInSameTxCannotSettle() public {
        DoubleSubmitMiner dm = new DoubleSubmitMiner();
        _qualifyFor(ALICE, address(dm), 3);
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
        assertEq(module.assignedOf(address(dm)), MIN_STAKE + LOCK);
        assertEq(module.totalCommitted(), LOCK);
        _assertNoteEmpty();
        _assertBooks();
    }

    function testReplayAfterAcceptanceNoSecondLock() public {
        _qualifyFor(ALICE, MINER, 3);
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
        assertEq(module.assignedOf(MINER), MIN_STAKE + LOCK);
        _assertNoteEmpty();
        _assertBooks();
    }

    /// @dev With the bonus disabled the gate never widens the target: a
    /// digest just above the base target is rejected at the base target even
    /// for an eligible wallet with an enormous stake.
    function testCurveDisabledGateNeverWidensTarget() public {
        _qualify(ALICE, MINER, 1e30);
        uint256 base = core.currentTarget();
        (uint256 n, bytes32 d) = _bandNonce(MINER, base, _widen(base, 3e18));
        vm.prank(MINER);
        vm.expectRevert(abi.encodeWithSelector(HunterMiningCore.InvalidProof.selector, d, base));
        core.submitProof(cid, seed, n, basket);
        assertEq(module.totalCommitted(), 0);
        assertEq(module.assignedOf(MINER), 1e30);
    }

    /// @dev The settlement hook is O(1): gas of a winning submission is flat
    /// in the number of depositors, whether they back other wallets or only
    /// hold unassigned stake. Every scenario starts from the same state
    /// snapshot and runs the same core schedule, so only the module's
    /// unrelated population differs. Also logs the overhead of the module
    /// over the ungated `DummyMiningPower` on the same core.
    function testHookGasFlatInDepositorCount() public {
        uint256 base = vm.snapshotState();

        uint256 g1 = _measuredWin(0, 0);
        vm.revertToState(base);
        uint256 gBacking = _measuredWin(200, 0);
        vm.revertToState(base);
        uint256 gIdle = _measuredWin(0, 200);
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
        emit log_named_uint("win gas, +200 depositors backing other wallets", gBacking);
        emit log_named_uint("win gas, +200 depositors with unassigned stake", gIdle);
        emit log_named_uint("win gas, DummyMiningPower", gDummy);
        emit log_named_uint("module overhead over dummy", g1 - gDummy);
        assertLt(_diff(g1, gBacking) * 100, g1 * 5, "backing depositor count moved hook gas");
        assertLt(_diff(g1, gIdle) * 100, g1 * 5, "idle depositor count moved hook gas");
    }

    /// @dev Random single-wallet sequences (one backer, deposits, top-ups,
    /// unassigns, wins and snapshots): after every action the harness books
    /// hold — in particular `pendingOf <= assignedOf` and
    /// `pendingBy <= assignedBy`, however a lock lands on pending stake —
    /// and every win outcome matches the frozen/live rule.
    /// forge-config: default.fuzz.runs = 64
    /// forge-config: release.fuzz.runs = 64
    function testFuzz_LockKeepsPendingWithinBalance(uint256 fuzzSeed) public {
        _deposit(ALICE, MIN_STAKE);
        _assign(ALICE, MINER, MIN_STAKE);
        uint256 wins;
        for (uint256 i = 0; i < 32; i++) {
            uint256 r = uint256(keccak256(abi.encode(fuzzSeed, i)));
            uint256 op = r % 5;
            uint256 amt = ((r >> 8) % (MIN_STAKE / 2)) + 1;
            if (op == 0) {
                // Top-up (pending for the open challenge).
                _deposit(ALICE, amt);
                if (module.assigneeOf(ALICE) == MINER) {
                    _assign(ALICE, MINER, amt);
                } else {
                    // S8: re-taking the empty slot needs MIN_STAKE and no
                    // removed stake still counting in the open challenge.
                    vm.prank(ALICE);
                    vm.expectRevert(
                        abi.encodeWithSelector(PrefundedMiningPower.FirstAssignBelowMinimum.selector, amt, MIN_STAKE)
                    );
                    module.assign(MINER, amt);
                    uint256 removing = module.removingOf(MINER);
                    if (module.pendingEpoch(MINER) == module.latestChallengeId() && removing != 0) {
                        vm.prank(ALICE);
                        vm.expectRevert(
                            abi.encodeWithSelector(PrefundedMiningPower.WalletHasCountingRemoval.selector, removing)
                        );
                        module.assign(MINER, MIN_STAKE);
                    } else {
                        uint256 free = module.unassignedOf(ALICE);
                        if (free < MIN_STAKE) _deposit(ALICE, MIN_STAKE - free);
                        _assign(ALICE, MINER, MIN_STAKE);
                    }
                }
            } else if (op == 1) {
                uint256 assigned = module.assignedBy(ALICE);
                if (assigned != 0) _unassign(ALICE, MINER, (amt % assigned) + 1);
            } else if (op == 2) {
                _nextChallenge();
            } else {
                _activate();
                (bool eligible, uint8 reason, uint256 frozen) = module.eligibilityOf(MINER);
                uint256 live = module.assignedOf(MINER);
                (uint256 nonce,) = _nonce(MINER);
                assertEq(eligible, reason == 0);
                if (reason == 2) {
                    _expectNotEligible(2);
                    _send(MINER, nonce);
                } else if (reason == 4) {
                    // S8: reason 4 previews exactly the settlement failure.
                    assertLt(live, LOCK);
                    assertGe(frozen, MIN_STAKE);
                    vm.expectRevert(
                        abi.encodeWithSelector(PrefundedMiningPower.InsufficientFunds.selector, live, LOCK)
                    );
                    _send(MINER, nonce);
                } else {
                    _send(MINER, nonce);
                    wins++;
                    assertEq(module.assignedOf(MINER), live - LOCK);
                }
            }
            _assertBooks();
        }
        assertEq(module.totalCommitted(), wins * LOCK);
        assertEq(nft.mintedEver(), wins);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    /// @dev Stake, lock, note and counter state a rejected submission must
    /// not move.
    struct Snap {
        uint256 walletStake;
        address backer;
        uint256 backerStake;
        uint256 pending;
        uint256 totalStake;
        uint256 totalAssigned;
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
        s.walletStake = module.assignedOf(wallet);
        s.backer = module.backerOf(wallet);
        s.backerStake = s.backer == address(0) ? 0 : module.assignedBy(s.backer);
        s.pending = module.pendingOf(wallet);
        s.totalStake = module.totalStake();
        s.totalAssigned = module.totalAssigned();
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
        assertEq(module.assignedOf(wallet), s.walletStake, "assignedOf moved");
        assertEq(module.backerOf(wallet), s.backer, "backerOf moved");
        if (s.backer != address(0)) assertEq(module.assignedBy(s.backer), s.backerStake, "assignedBy moved");
        assertEq(module.pendingOf(wallet), s.pending, "pendingOf moved");
        assertEq(module.totalStake(), s.totalStake, "totalStake moved");
        assertEq(module.totalAssigned(), s.totalAssigned, "totalAssigned moved");
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

    /// @dev Checks amount, challenge, digest, miner and released; the backer
    /// is checked where a test knows it.
    function _assertLock(uint256 tokenId, address miner, uint256 challengeId, bytes32 digest) private view {
        (uint256 amount, uint256 c, bytes32 d, address m, address b, bool released) = module.committedOf(tokenId);
        assertEq(amount, LOCK, "lock amount");
        assertEq(c, challengeId, "lock challenge");
        assertEq(d, digest, "lock digest");
        assertEq(m, miner, "lock miner");
        assertTrue(b != address(0), "lock without backer");
        assertFalse(released, "lock released");
    }

    function _assertNoLock(uint256 tokenId) private view {
        (uint256 amount, uint256 c, bytes32 d, address m, address b, bool released) = module.committedOf(tokenId);
        assertEq(amount, 0, "unexpected lock");
        assertEq(c, 0);
        assertEq(d, bytes32(0));
        assertEq(m, address(0));
        assertEq(b, address(0));
        assertFalse(released);
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

    /// @dev Populates the module with `backing` extra depositors (each
    /// backing its own other wallet) and `idle` extra depositors holding
    /// unassigned stake, qualifies MINER, then measures its winning
    /// submission.
    function _measuredWin(uint256 backing, uint256 idle) private returns (uint256 used) {
        for (uint256 i = 0; i < backing; i++) {
            address d = address(uint160(0xD0000 + i));
            _deposit(d, MIN_STAKE);
            _assign(d, address(uint160(0xE0000 + i)), MIN_STAKE);
        }
        for (uint256 i = 0; i < idle; i++) {
            _deposit(address(uint160(0xF0000 + i)), MIN_STAKE);
        }
        _deposit(ALICE, MIN_STAKE);
        _assign(ALICE, MINER, MIN_STAKE);
        _nextChallenge();
        _activate();
        (uint256 nonce,) = _nonce(MINER);
        vm.prank(MINER);
        uint256 before = gasleft();
        core.submitProof(cid, seed, nonce, basket);
        used = before - gasleft();
        (uint256 amount,,,,,) = module.committedOf(1);
        assertEq(amount, LOCK);
    }

    /// @dev A stand-in core with its own MIN_STAKE = LOCK module; the core
    /// itself stakes `stake` for MINER in challenge 6, so it counts from 7.
    function _foreignModule(uint256 stake) private returns (ForeignSequenceCore fc, PrefundedMiningPower m) {
        fc = new ForeignSequenceCore();
        m = new PrefundedMiningPower(address(token), address(fc), LOCK, LOCK, 0, 0, address(0));
        token.mint(address(fc), stake);
        fc.openAndStake(m, IERC20(address(token)), 6, MINER, stake);
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
        (bool e, uint8 r, uint256 s) = module.eligibilityOf(wallet);
        assertEq(e, eligible, "eligible");
        assertEq(r, reason, "reason");
        assertEq(s, stake, "stake");
    }

    /// @dev A valid-digest submission from `miner` reverts NotEligible(2) and
    /// changes nothing in the core, NFT or module.
    function _assertGateRejectsWithoutSideEffects(address miner) private {
        (bool e0, uint8 r0, uint256 s0) = module.eligibilityOf(miner);
        Snap memory before = _snap(miner);

        (uint256 nonce,) = _nonce(miner);
        _expectNotEligible(2);
        _send(miner, nonce);

        _assertSnap(before, miner);
        (bool e1, uint8 r1, uint256 s1) = module.eligibilityOf(miner);
        assertEq(e1, e0);
        assertEq(r1, r0);
        assertEq(s1, s0);
    }

    function _assertFlashRolledBack(SettlementFlashLender lender, SettlementMiner miner) private view {
        assertEq(token.balanceOf(address(lender)), MIN_STAKE);
        assertEq(token.balanceOf(address(module)), 0);
        assertEq(module.totalStake(), 0);
        assertEq(module.assignedOf(address(miner)), 0);
        assertEq(module.backerOf(address(miner)), address(0));
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
