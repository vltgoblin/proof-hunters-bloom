// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {StdInvariant} from "forge-std/StdInvariant.sol";
import {console} from "forge-std/console.sol";
import {PrefundedMiningPower} from "../src/bloom/PrefundedMiningPower.sol";
import {HunterMiningCore} from "../src/bloom/HunterMiningCore.sol";
import {PrefundedMiningStack} from "./helpers/PrefundedMiningStack.sol";
import {
    PrefundedInvariantHandler,
    PrefundedInvariantFeeToken,
    IPrefundedInvariantToken
} from "./helpers/PrefundedInvariantHandler.sol";

/// @notice S10 (VLT-61) stateful invariant campaign for `PrefundedMiningPower`
/// over the REAL stack (core + NFT + lifecycle + reserve + backing +
/// LiveHunt), driven by `PrefundedInvariantHandler` (model-based: every call's
/// exact outcome is predicted; any unexpected revert, unexpected success or
/// post-condition mismatch fails the campaign in `afterInvariant`).
/// @dev The concrete suites differ only in the module's HUNTER token: the
/// stack's plain fixture token (bonus curve off, S0 default 1) and a
/// fee-on-transfer token that burns 5% of every transfer into the module
/// (curve on, so the gate's multiplier and the widened target are also
/// exercised). All amounts are TEST-ONLY fixture values.
/// Coverage limits (documented, not hidden): the 5,000-NFT mint-out is not
/// reachable in a campaign (<= a few dozen proofs per run; mint-out is
/// covered by `PrefundedMiningPowerLifecycle`), and DirectLoan escrow is not
/// driven here (covered by `PrefundedMiningPowerCompanion`).
abstract contract PrefundedInvariantBase is StdInvariant, PrefundedMiningStack {
    uint256 internal constant MIN = 1_000e18;
    uint256 internal constant LOCK = 100e18;
    uint256 internal constant COOLDOWN = 1 days;
    address internal constant GUARDIAN = address(0x6A4D);

    PrefundedInvariantHandler internal handler;
    IPrefundedInvariantToken internal hunter;

    /// @dev The module's HUNTER token, its inbound tax (bps) and, if it can
    /// count transfers, its counting interface (else address(0)).
    function _moduleToken() internal virtual returns (address hunterToken, uint256 taxBps, address counting);

    function _curveUnit() internal pure virtual returns (uint256);

    function setUp() public virtual override {
        super.setUp();
        (address t, uint256 tax, address counting) = _moduleToken();
        hunter = IPrefundedInvariantToken(t);
        module = new PrefundedMiningPower(t, address(core), MIN, LOCK, COOLDOWN, _curveUnit(), GUARDIAN);
        if (counting != address(0)) PrefundedInvariantFeeToken(counting).setModule(address(module));
        _attach(module);
        handler = new PrefundedInvariantHandler(
            core, module, hunter, hunt, basket, STOP, GUARDIAN, tax, counting, HUNT_OFFER
        );

        // Deterministic bootstrap through the handler: one full cycle
        // (deposit, assign, next challenge, paid win, burn, claim), so every
        // run starts from non-empty books.
        handler.deposit(0, 2_500e18); // D1
        handler.assign(0, 1, 0); // D1 -> W1, whole balance
        handler.refreshExpiredSeed(1); // stake matures
        handler.submitEligible(0); // W1 wins token 1, lock taken
        handler.burn(1); // W1 burns token 1
        handler.claim(1, 1, 1); // W1 (final beneficiary) claims
        _assertHandlerClean();
        assertEq(handler.locksCreated(), 1, "bootstrap: no lock");
        assertEq(handler.locksReleased(), 1, "bootstrap: no release");

        bytes4[] memory selectors = new bytes4[](20);
        selectors[0] = handler.deposit.selector;
        selectors[1] = handler.assign.selector;
        selectors[2] = handler.unassign.selector;
        selectors[3] = handler.withdraw.selector;
        selectors[4] = handler.evictBacker.selector;
        selectors[5] = handler.donate.selector;
        selectors[6] = handler.submitEligible.selector;
        selectors[7] = handler.submitIneligible.selector;
        selectors[8] = handler.submitInvalid.selector;
        selectors[9] = handler.refreshExpiredSeed.selector;
        selectors[10] = handler.easeDifficulty.selector;
        selectors[11] = handler.advanceTime.selector;
        selectors[12] = handler.transferNft.selector;
        selectors[13] = handler.liveHuntFill.selector;
        selectors[14] = handler.burn.selector;
        selectors[15] = handler.claim.selector;
        selectors[16] = handler.toggleModule.selector;
        selectors[17] = handler.disableRequirement.selector;
        selectors[18] = handler.stopMining.selector;
        selectors[19] = handler.approveBacker.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    // ------------------------------------------------------------------
    // Invariants
    // ------------------------------------------------------------------

    /// @notice The module always covers its obligations, and exactly: the
    /// only tokens above `totalStake + totalCommitted` are unsolicited
    /// donations (never credited to anyone).
    function invariant_Solvency() public view {
        uint256 bal = hunter.balanceOf(address(module));
        assertGe(bal, module.totalStake() + module.totalCommitted(), "insolvent");
        assertEq(bal, module.totalStake() + module.totalCommitted() + handler.ghostDonations(), "balance != books + donations");
    }

    /// @notice Every unit is accounted for: per-account parts sum to the
    /// totals, and the handler's independent flow model (measured receipts
    /// in, exact withdrawals and releases out, locks moved stake -> commit)
    /// reproduces the module's totals and balance, globally and per depositor.
    function invariant_Conservation() public view {
        address[3] memory ds = handler.depositors();
        address[2] memory ws = handler.wallets();
        uint256 parts;
        uint256 byDepositor;
        for (uint256 i = 0; i < 3; ++i) {
            address d = ds[i];
            uint256 own = module.unassignedOf(d) + module.assignedBy(d);
            parts += own;
            byDepositor += module.assignedBy(d);
            assertEq(
                handler.depositedBy(d) - handler.withdrawnBy(d) - handler.lockPaidBy(d), own, "per-depositor history"
            );
        }
        assertEq(parts, module.totalStake(), "sum(unassigned + assignedBy) != totalStake");
        assertEq(byDepositor, module.totalAssigned(), "sum(assignedBy) != totalAssigned");
        assertEq(module.assignedOf(ws[0]) + module.assignedOf(ws[1]), module.totalAssigned(), "sum(assignedOf)");
        assertLe(module.totalAssigned(), module.totalStake(), "over-assigned");
        assertEq(
            handler.ghostDeposited() - handler.ghostWithdrawn() - handler.ghostLocked(),
            module.totalStake(),
            "deposited - withdrawn - locked != totalStake"
        );
        assertEq(handler.ghostLocked() - handler.ghostReleased(), module.totalCommitted(), "locked - released");
        assertEq(
            handler.ghostDeposited() - handler.ghostWithdrawn() - handler.ghostReleased() + handler.ghostDonations(),
            hunter.balanceOf(address(module)),
            "flows != balance"
        );
        assertEq(handler.ghostRequested() - handler.ghostTaxBurned(), handler.ghostDeposited(), "tax model");
        _assertTaxLedger();
    }

    /// @notice Every lock is bound to its NFT: challenge id and digest equal
    /// the NFT's birth data, the miner is the wallet the NFT was minted to,
    /// the amount is exactly `LOCK_PER_MINT` and a backer paid it.
    function invariant_LockMatchesNFT() public view {
        uint256 minted = nft.mintedEver();
        for (uint256 id = 1; id <= minted; ++id) {
            (uint256 amount, uint256 cid_, bytes32 digest, address miner, address backer,) = module.committedOf(id);
            if (amount == 0) continue;
            (, bytes32 birthDigest, uint256 birthChallenge,) = nft.birthData(id);
            assertEq(cid_, birthChallenge, "lock challenge != birth");
            assertEq(digest, birthDigest, "lock digest != birth");
            assertEq(miner, handler.minerAtMint(id), "lock miner != minted-to");
            assertEq(amount, LOCK, "lock amount");
            assertTrue(backer != address(0), "lock without backer");
        }
    }

    /// @notice A lock exists for exactly the ids minted while this module
    /// was attached with its gate enforcing — none for ids minted detached
    /// or after the failsafe, none ahead of the NFT counter — and one lock
    /// per id (one per challenge: challenge ids strictly increase).
    function invariant_OneLockPerMintedId() public view {
        uint256 minted = nft.mintedEver();
        uint256 locks;
        uint256 lastChallenge;
        for (uint256 id = 1; id <= minted; ++id) {
            (uint256 amount, uint256 cid_,,,,) = module.committedOf(id);
            assertEq(amount != 0, handler.lockExpected(id), "lock presence != minted-under-enforcing-module");
            if (amount != 0) {
                ++locks;
                assertGt(cid_, lastChallenge, "two locks for one challenge");
                lastChallenge = cid_;
            }
        }
        assertEq(locks, handler.locksCreated(), "locks != created");
        for (uint256 k = 1; k <= 3; ++k) {
            (uint256 ahead,,,,,) = module.committedOf(minted + k);
            assertEq(ahead, 0, "lock ahead of the NFT counter");
        }
    }

    /// @notice Every proof accepted under an enforcing module had been
    /// previewed eligible (`eligibilityOf`: frozen stake >= MIN_STAKE and
    /// live stake >= LOCK_PER_MINT) immediately before the submission.
    function invariant_EveryAcceptedProofWasEligible() public view {
        assertEq(handler.acceptedIneligible(), 0, "ineligible proof accepted");
        uint256 minted = nft.mintedEver();
        for (uint256 id = 1; id <= minted; ++id) {
            if (!handler.lockExpected(id)) continue;
            assertTrue(handler.eligibleAtAcceptance(id), "lock for a proof previewed ineligible");
            assertGe(handler.stakeAtAcceptance(id), MIN, "admitted below MIN_STAKE");
        }
    }

    /// @notice No stake counts twice in the open challenge. Definitions, for
    /// `L = latestChallengeId` while the module is attached, not retired and
    /// its gate enforcing:
    /// - `pendingNow(w)  = pendingEpoch(w) == L ? pendingOf(w) : 0`
    /// - `removingNow(w) = pendingEpoch(w) == L && L != holdWaivedEpoch ? removingOf(w) : 0`
    /// - `preview(w)     = eligibilityOf(w).stake` (what the gate compares)
    /// Then: (a) `preview(w) <= assignedOf(w) - pendingNow(w) + removingNow(w)`
    /// for every wallet; (b) `Σ removingNow == Σ heldStakeOf` — every
    /// removal that still counts is held in the module by its depositor;
    /// (c) every depositor's held stake is still in the module as unassigned
    /// or as pending (non-counting) stake on another wallet; hence (d)
    /// `Σ preview <= totalStake` — each staked unit backs at most one
    /// wallet's admission in the challenge. After the failsafe (S8b, TLA+
    /// F1) removals never count again, so (e) `preview(w) <= assignedOf(w)`:
    /// the curve only ever sees stake that is still in the module.
    function invariant_NothingCountedTwice() public view {
        if (module.gateDisabled()) {
            address[6] memory all = _actors();
            for (uint256 i = 0; i < 6; ++i) {
                (,, uint256 s) = module.eligibilityOf(all[i]);
                assertLe(s, module.assignedOf(all[i]), "failsafe: preview above live stake");
            }
            return;
        }
        if (address(core.miningPower()) != address(module) || module.retired()) return;
        uint256 latest = module.latestChallengeId();
        bool waived = latest == module.holdWaivedEpoch();
        address[6] memory actors = _actors();
        uint256 sumPreview;
        uint256 sumRemoving;
        for (uint256 i = 0; i < 6; ++i) {
            address w = actors[i];
            (,, uint256 stake) = module.eligibilityOf(w);
            bool current = module.pendingEpoch(w) == latest;
            uint256 pendingNow = current ? module.pendingOf(w) : 0;
            uint256 removingNow = current && !waived ? module.removingOf(w) : 0;
            assertLe(stake, module.assignedOf(w) - pendingNow + removingNow, "preview above matured stake");
            sumPreview += stake;
            sumRemoving += removingNow;
        }
        address[3] memory ds = handler.depositors();
        uint256 sumHeld;
        for (uint256 i = 0; i < 3; ++i) {
            address d = ds[i];
            uint256 held = module.heldStakeOf(d);
            sumHeld += held;
            uint256 pendingByNow = module.pendingEpochBy(d) == latest ? module.pendingBy(d) : 0;
            assertLe(held, module.unassignedOf(d) + pendingByNow, "held stake counts elsewhere or left");
        }
        assertEq(sumRemoving, sumHeld, "counting removals != held stake");
        assertLe(sumPreview, module.totalStake(), "stake counted twice");
    }

    /// @notice One funder per wallet: `backerOf(w)` is set exactly while the
    /// wallet has assigned stake, that backer is the only depositor assigned
    /// to it and holds all of it; a depositor has an assignee exactly while
    /// it has assigned stake.
    function invariant_OneBackerPerWallet() public view {
        address[6] memory actors = _actors();
        address[3] memory ds = handler.depositors();
        for (uint256 i = 0; i < 6; ++i) {
            address w = actors[i];
            uint256 backers;
            for (uint256 j = 0; j < 3; ++j) {
                if (module.assigneeOf(ds[j]) == w && module.assignedBy(ds[j]) != 0) ++backers;
            }
            address backer = module.backerOf(w);
            if (module.assignedOf(w) == 0) {
                assertEq(backer, address(0), "backer without stake");
                assertEq(backers, 0, "assignee without wallet stake");
            } else {
                assertEq(backers, 1, "wallet backed by != 1 depositor");
                assertTrue(backer != address(0), "stake without backer");
                assertEq(module.assigneeOf(backer), w, "backer backs another wallet");
                assertEq(module.assignedBy(backer), module.assignedOf(w), "backer stake != wallet stake");
            }
        }
        for (uint256 j = 0; j < 3; ++j) {
            assertEq(module.assignedBy(ds[j]) == 0, module.assigneeOf(ds[j]) == address(0), "dangling assignee");
        }
    }

    /// @notice A lock is released at most once, only after its NFT was
    /// burned, only by the final beneficiary recorded at the burn (the
    /// burning owner), and the released amounts are exactly what left.
    function invariant_ReleaseOnceAfterBurnToBeneficiary() public view {
        uint256 minted = nft.mintedEver();
        uint256 releasedSum;
        uint256 releasedCount;
        for (uint256 id = 1; id <= minted; ++id) {
            (uint256 amount,,,,, bool released) = module.committedOf(id);
            if (!released) {
                assertEq(handler.releaseCount(id), 0, "paid but not marked released");
                continue;
            }
            ++releasedCount;
            releasedSum += amount;
            assertTrue(handler.burned(id), "released before burn");
            assertEq(handler.releaseCount(id), 1, "released more than once");
            address beneficiary = lifecycle.finalBeneficiary(id);
            assertTrue(beneficiary != address(0), "no beneficiary");
            assertEq(beneficiary, handler.beneficiaryAtBurn(id), "beneficiary != burning owner");
            assertEq(handler.releaseCaller(id), beneficiary, "released by someone else");
            assertFalse(lifecycle.currentMember(id).alive, "released for a live member");
        }
        assertEq(releasedCount, handler.locksReleased(), "release count");
        assertEq(releasedSum, handler.ghostReleased(), "released amount");
    }

    /// @notice The core's three lifetime counters agree with each other and
    /// with the handler's count of accepted proofs, within the cap.
    function invariant_CoreCountersAgree() public view {
        uint256 proofs = core.acceptedProofs();
        assertEq(proofs, core.nftsMintedEver(), "acceptedProofs != nftsMintedEver");
        assertEq(proofs, nft.mintedEver(), "acceptedProofs != nft.mintedEver");
        assertEq(proofs, handler.accepted(), "core != handler acceptances");
        assertLe(proofs, core.MAX_NFTS_EVER(), "over cap");
    }

    /// @notice A wallet `eligibilityOf` calls eligible (reason 0) always gets
    /// its valid proof accepted while the challenge is ACTIVE. Reason-4
    /// wallets (frozen stake passes, live stake below the lock) are refused
    /// by settlement — expected, counted separately (`liveStakeBlocked`).
    function invariant_EligibleWinnersNeverBlocked() public view {
        assertEq(handler.eligibleButBlocked(), 0, "eligible winner blocked");
    }

    /// @notice Pending and held buckets stay within the balances they
    /// describe: per wallet `pendingOf <= assignedOf`, per depositor
    /// `pendingBy <= assignedBy` and `heldStakeOf <= unassigned + assigned`,
    /// `withdrawableOf == unassigned - min(held, unassigned)` (0 while an
    /// eviction's carried-over cooldown runs, S8b), and the
    /// wallets' current pending buckets equal the depositors' current shares.
    function invariant_PendingWithinBalances() public view {
        uint256 latest = module.latestChallengeId();
        address[6] memory actors = _actors();
        uint256 pendingWallets;
        for (uint256 i = 0; i < 6; ++i) {
            address w = actors[i];
            assertLe(module.pendingOf(w), module.assignedOf(w), "pendingOf > assignedOf");
            if (module.pendingEpoch(w) == latest) pendingWallets += module.pendingOf(w);
        }
        address[3] memory ds = handler.depositors();
        uint256 pendingDepositors;
        for (uint256 j = 0; j < 3; ++j) {
            address d = ds[j];
            assertLe(module.pendingBy(d), module.assignedBy(d), "pendingBy > assignedBy");
            if (module.pendingEpochBy(d) == latest) pendingDepositors += module.pendingBy(d);
            uint256 held = module.heldStakeOf(d);
            uint256 unassigned = module.unassignedOf(d);
            assertLe(held, unassigned + module.assignedBy(d), "held > stake in module");
            bool evictLocked =
                !module.retired() && !module.gateDisabled() && block.timestamp < module.withdrawLockedUntil(d);
            assertEq(
                module.withdrawableOf(d),
                evictLocked ? 0 : unassigned - (held < unassigned ? held : unassigned),
                "withdrawable"
            );
        }
        assertEq(pendingWallets, pendingDepositors, "wallet pending != depositor pending");
    }

    /// @notice The Mining Core hooks never touch the token: across every
    /// submission (accepted or not) no contract read or wrote the module
    /// token's storage inside `submitProof` (`vm.record` / `vm.accesses` on
    /// the token — every `balanceOf` / `transfer` reads it), and — with the
    /// counting token — no transfer touching the module happened in it.
    function invariant_HooksMadeNoTokenCalls() public view {
        assertEq(handler.hookTokenCalls(), 0, "module called the token inside submitProof");
        assertEq(handler.hookTokenTransfers(), 0, "token moved inside submitProof");
    }

    function afterInvariant() public view {
        _assertHandlerClean();
    }

    // ------------------------------------------------------------------
    // Non-invariant checks
    // ------------------------------------------------------------------

    /// @notice The storage-access detector behind `invariant_HooksMadeNoTokenCalls`
    /// is not vacuous: it sees the module's token calls in a deposit.
    function test_TokenCallDetectorSeesModuleCalls() public {
        hunter.mint(ALICE, 10e18);
        vm.prank(ALICE);
        hunter.approve(address(module), 10e18);
        vm.record();
        vm.prank(ALICE);
        module.deposit(10e18);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(hunter));
        vm.stopRecord();
        assertGt(reads.length, 0, "detector blind to token reads");
        assertGt(writes.length, 0, "detector blind to token writes");
        // A view-only token call (what a hook would most plausibly add) is seen too.
        vm.record();
        hunter.balanceOf(address(module));
        (reads,) = vm.accesses(address(hunter));
        vm.stopRecord();
        assertGt(reads.length, 0, "detector blind to balanceOf");
    }

    /// @notice Deterministic long pseudo-random walk through the same
    /// handler (1,500 actions), then every invariant. Prints the outcome
    /// census (successes per action, expected reverts per reason).
    function test_HandlerRandomWalk() public {
        _walk(uint256(keccak256("prefunded-s10-walk")), 1_500);
        _assertAll();
        _logCensus();
    }

    function testFuzz_HandlerRandomWalk(uint256 seed_) public {
        _walk(seed_, 120);
        _assertAll();
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _walk(uint256 seed_, uint256 steps) internal {
        for (uint256 i = 0; i < steps; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed_, i)));
            uint256 a = uint256(keccak256(abi.encode(r, 1)));
            uint256 b = uint256(keccak256(abi.encode(r, 2)));
            uint256 c = uint256(keccak256(abi.encode(r, 3)));
            uint256 op = r % 22;
            if (op == 0) handler.deposit(a, b);
            else if (op == 1 || op == 19) handler.assign(a, b, c);
            else if (op == 2) handler.unassign(a, b, c);
            else if (op == 3) handler.withdraw(a, b);
            else if (op == 4) handler.evictBacker(a, b);
            else if (op == 5) handler.donate(a);
            else if (op == 6 || op == 20) handler.submitEligible(a);
            else if (op == 7) handler.submitIneligible(a);
            else if (op == 8) handler.submitInvalid(a);
            else if (op == 9) handler.refreshExpiredSeed(a);
            else if (op == 10) handler.easeDifficulty(a);
            else if (op == 11) handler.advanceTime(a, b);
            else if (op == 12) handler.transferNft(a, b);
            else if (op == 13) handler.liveHuntFill(a);
            else if (op == 14) handler.burn(a);
            else if (op == 15) handler.claim(a, b, c);
            else if (op == 16) handler.toggleModule(a);
            else if (op == 21) handler.approveBacker(a, b);
            else if (op == 17) handler.disableRequirement(a % 16 == 0 && i > (steps * 3) / 4 ? 0 : a);
            else handler.stopMining(a % 32 == 0 && i > (steps * 3) / 4 ? 0 : a);
            _assertHandlerClean();
        }
    }

    function _assertAll() internal view {
        invariant_Solvency();
        invariant_Conservation();
        invariant_LockMatchesNFT();
        invariant_OneLockPerMintedId();
        invariant_EveryAcceptedProofWasEligible();
        invariant_NothingCountedTwice();
        invariant_OneBackerPerWallet();
        invariant_ReleaseOnceAfterBurnToBeneficiary();
        invariant_CoreCountersAgree();
        invariant_EligibleWinnersNeverBlocked();
        invariant_PendingWithinBalances();
        invariant_HooksMadeNoTokenCalls();
    }

    function _assertHandlerClean() internal view {
        assertEq(
            handler.unexpected(),
            0,
            string.concat(
                "unexpected outcome in ",
                handler.lastUnexpectedAction(),
                " want=",
                vm.toString(bytes32(handler.lastUnexpectedWant())),
                " got=",
                vm.toString(bytes32(handler.lastUnexpectedGot()))
            )
        );
        assertEq(handler.violations(), 0, string.concat("post-condition: ", handler.lastViolation()));
    }

    function _logCensus() internal view {
        console.log("calls", handler.calls());
        console.log("accepted", handler.accepted(), "with module", handler.acceptedWithModule());
        console.log("locks created", handler.locksCreated(), "released", handler.locksReleased());
        console.log("reason-4 (live stake) refusals", handler.liveStakeBlocked());
        console.log("detaches", handler.detaches(), "attaches", handler.attaches());
        console.log("failsafes", handler.failsafes(), "stops", handler.stops());
        string[17] memory names = [
            "deposit",
            "assign",
            "unassign",
            "withdraw",
            "evictBacker",
            "approveBacker",
            "submit",
            "refreshExpiredSeed",
            "easeDifficulty",
            "transferNft",
            "liveHunt.fill",
            "burn",
            "claim",
            "detach",
            "attach",
            "disableRequirement",
            "stopMining"
        ];
        for (uint256 i = 0; i < names.length; ++i) {
            console.log("ok", names[i], handler.successes(names[i]));
        }
        uint256 n = handler.seenReasonCount();
        for (uint256 i = 0; i < n; ++i) {
            bytes4 sel = handler.seenReasons(i);
            console.log("expected revert", _errorName(sel), handler.expectedReverts(sel));
        }
    }

    function _errorName(bytes4 sel) internal pure returns (string memory) {
        bytes4[25] memory sels = [
            PrefundedMiningPower.Retired.selector,
            PrefundedMiningPower.GateDisabled.selector,
            PrefundedMiningPower.NotWired.selector,
            PrefundedMiningPower.SelfAssignment.selector,
            PrefundedMiningPower.MustUnassignFirst.selector,
            PrefundedMiningPower.WalletAlreadyBacked.selector,
            PrefundedMiningPower.FirstAssignBelowMinimum.selector,
            PrefundedMiningPower.WalletHasCountingRemoval.selector,
            PrefundedMiningPower.InsufficientUnassigned.selector,
            PrefundedMiningPower.WrongAssignee.selector,
            PrefundedMiningPower.CooldownNotMet.selector,
            PrefundedMiningPower.InsufficientAssigned.selector,
            PrefundedMiningPower.StakeHeldUntilNextChallenge.selector,
            PrefundedMiningPower.UnauthorizedCaller.selector,
            PrefundedMiningPower.BackerNotEvictable.selector,
            PrefundedMiningPower.BackerNotApproved.selector,
            PrefundedMiningPower.NotEligible.selector,
            PrefundedMiningPower.InsufficientFunds.selector,
            PrefundedMiningPower.NoLock.selector,
            PrefundedMiningPower.AlreadyReleased.selector,
            PrefundedMiningPower.TokenNotBurned.selector,
            PrefundedMiningPower.NotBeneficiary.selector,
            PrefundedMiningPower.RetainedAssignments.selector,
            HunterMiningCore.InvalidProof.selector,
            HunterMiningCore.ChallengeNotActive.selector
        ];
        string[25] memory names = [
            "Retired",
            "GateDisabled",
            "NotWired",
            "SelfAssignment",
            "MustUnassignFirst",
            "WalletAlreadyBacked",
            "FirstAssignBelowMinimum",
            "WalletHasCountingRemoval",
            "InsufficientUnassigned",
            "WrongAssignee",
            "CooldownNotMet",
            "InsufficientAssigned",
            "StakeHeldUntilNextChallenge",
            "UnauthorizedCaller",
            "BackerNotEvictable",
            "BackerNotApproved",
            "NotEligible",
            "InsufficientFunds",
            "NoLock",
            "AlreadyReleased",
            "TokenNotBurned",
            "NotBeneficiary",
            "RetainedAssignments",
            "InvalidProof",
            "ChallengeNotActive"
        ];
        for (uint256 i = 0; i < sels.length; ++i) {
            if (sels[i] == sel) return names[i];
        }
        if (sel == HunterMiningCore.SeedNotExpired.selector) return "SeedNotExpired";
        if (sel == HunterMiningCore.DifficultyStallIntervalNotMet.selector) return "DifficultyStallIntervalNotMet";
        if (sel == HunterMiningCore.DifficultyAtMaximum.selector) return "DifficultyAtMaximum";
        if (sel == HunterMiningCore.MiningStopSunsetPassed.selector) return "MiningStopSunsetPassed";
        if (sel == HunterMiningCore.MiningAlreadyStopped.selector) return "MiningAlreadyStopped";
        return vm.toString(bytes32(sel));
    }

    function _assertTaxLedger() internal view virtual {}

    function _actors() internal view returns (address[6] memory a) {
        address[3] memory ds = handler.depositors();
        address[2] memory ws = handler.wallets();
        a = [ds[0], ds[1], ds[2], ws[0], ws[1], handler.COLLECTOR()];
    }
}

/// @notice Campaign on the stack's plain fixture HUNTER (the reserve's own
/// token, as in production), bonus curve disabled.
/// @dev The handler catches every protocol revert itself, so a revert that
/// escapes it is a handler bug and must fail the run (size stays default).
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: release.invariant.fail-on-revert = true
contract PrefundedMiningPowerInvariantTest is PrefundedInvariantBase {
    function _moduleToken() internal view override returns (address, uint256, address) {
        return (address(token), 0, address(0));
    }

    function _curveUnit() internal pure override returns (uint256) {
        return 0;
    }
}

/// @notice Hostile variant: the module's HUNTER burns 5% of every transfer
/// into the module (measured receipts), counts every transfer touching the
/// module, and the bonus curve is on. Same handler, same invariants; the
/// flow model credits measured receipts and `_assertTaxLedger` reconciles
/// the burned tax with the token's own record.
/// @dev The handler catches every protocol revert itself, so a revert that
/// escapes it is a handler bug and must fail the run. Runs are halved to 128
/// (depth stays 500) to keep the CI job within budget; the plain variant
/// keeps the default 256.
/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: release.invariant.fail-on-revert = true
/// forge-config: default.invariant.runs = 128
/// forge-config: release.invariant.runs = 128
contract PrefundedMiningPowerHostileInvariantTest is PrefundedInvariantBase {
    uint256 internal constant TAX_BPS = 500;
    PrefundedInvariantFeeToken internal feeToken;

    function _moduleToken() internal override returns (address, uint256, address) {
        feeToken = new PrefundedInvariantFeeToken(TAX_BPS);
        return (address(feeToken), TAX_BPS, address(feeToken));
    }

    function _curveUnit() internal pure override returns (uint256) {
        return CURVE_UNIT;
    }

    function _assertTaxLedger() internal view override {
        assertEq(feeToken.feesBurned(), handler.ghostTaxBurned(), "token fees != handler tax model");
    }
}
