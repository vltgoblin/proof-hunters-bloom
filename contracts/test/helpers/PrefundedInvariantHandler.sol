// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {HunterNFT} from "../../src/bloom/HunterNFT.sol";
import {HunterLifecycle} from "../../src/bloom/HunterLifecycle.sol";
import {HunterMiningCore} from "../../src/bloom/HunterMiningCore.sol";
import {PrefundedMiningPower} from "../../src/bloom/PrefundedMiningPower.sol";
import {IMiningPower} from "../../src/bloom/IMiningPower.sol";
import {LiveHunt} from "../../src/LiveHunt.sol";

/// @dev TEST-ONLY mintable HUNTER surface shared by the stack fixture token
/// (`ReserveTokenFixture`) and `PrefundedInvariantFeeToken`.
interface IPrefundedInvariantToken is IERC20 {
    function mint(address to, uint256 amount) external;
}

/// @dev TEST-ONLY hostile HUNTER for the invariant campaign: every transfer
/// INTO `module` burns `feeBps` of the amount (fee-on-transfer, so deposits
/// are credited by measured receipt), and every transfer touching `module`
/// is counted (`moduleTransfers`) so the campaign can prove that no Mining
/// Core hook ever moves tokens. Open mint; not a product token.
contract PrefundedInvariantFeeToken is ERC20 {
    uint256 public immutable feeBps;
    address public module;
    uint256 public moduleTransfers;
    uint256 public feesBurned;

    constructor(uint256 feeBps_) ERC20("Invariant Fee HUNTER", "ifHUNT") {
        feeBps = feeBps_;
    }

    function setModule(address module_) external {
        module = module_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from == module || to == module) ++moduleTransfers;
        if (from != address(0) && to == module && feeBps != 0) {
            uint256 fee = (value * feeBps) / 10_000;
            if (fee != 0) {
                super._update(from, address(0), fee);
                feesBurned += fee;
            }
            super._update(from, to, value - fee);
            return;
        }
        super._update(from, to, value);
    }
}

/// @notice Stateful handler for the S10 (VLT-61) invariant campaign over the
/// REAL stack: `HunterMiningCore` (and its HunterNFT), `HunterLifecycle`,
/// the reserve/backing it settles into, `LiveHunt`, and one
/// `PrefundedMiningPower` attached through the stop multisig. No hook is
/// ever pranked: every proof goes through `core.submitProof`.
/// @dev Model-based: before every call the handler predicts the exact
/// outcome (success, or the selector of the ONE revert the protocol must
/// raise, following each function's check order) from the live state, then
/// makes the call inside try/catch and compares. A match is counted by
/// reason (`expectedReverts`); a mismatch — an unexpected revert, an
/// unexpected success or a different revert — is recorded in `unexpected`
/// and fails the campaign (`afterInvariant`). Every success is then checked
/// against the handler's own ghost books (receipts, debits, lock contents).
/// Actors: three depositors (`D1`..`D3`), two mining wallets (`W1`, `W2`),
/// a collector (LiveHunt buyer / NFT recipient), plus the core's `STOP`
/// multisig, the module's `GUARDIAN` and the reserve's `LAUNCH` authority
/// (only used at stack construction). TEST-ONLY amounts.
contract PrefundedInvariantHandler is Test {
    bytes4 internal constant OK = bytes4(0);
    bytes4 internal constant NO_DATA = bytes4(0xffffffff);

    HunterMiningCore public immutable core;
    HunterNFT public immutable nft;
    HunterLifecycle public immutable lifecycle;
    PrefundedMiningPower public immutable module;
    IPrefundedInvariantToken public immutable token;
    LiveHunt public immutable hunt;
    address public immutable basket;
    address public immutable stop;
    address public immutable guardian;
    /// @dev Inbound tax on transfers into the module (0 for the plain token).
    uint256 public immutable taxBps;
    /// @dev Counting fee token, or address(0) when the token cannot count.
    PrefundedInvariantFeeToken public immutable countingToken;
    uint256 public immutable startTimestamp;
    uint256 public immutable huntOffer;

    address public constant D1 = address(0xD0001);
    address public constant D2 = address(0xD0002);
    address public constant D3 = address(0xD0003);
    address public constant W1 = address(0xE0001);
    address public constant W2 = address(0xE0002);
    address public constant COLLECTOR = address(0xC0FFEE);

    /// @dev Warps stop here so LiveHunt entry (open 360 days) stays open.
    uint256 public constant MAX_ELAPSED = 300 days;

    // ------------------------------------------------------------------
    // Outcome bookkeeping
    // ------------------------------------------------------------------
    uint256 public calls;
    uint256 public unexpected;
    string public lastUnexpectedAction;
    bytes4 public lastUnexpectedWant;
    bytes4 public lastUnexpectedGot;
    bytes public lastUnexpectedData;
    /// @dev Post-condition failures of a successful call (ghost mismatch).
    uint256 public violations;
    string public lastViolation;
    mapping(bytes4 => uint256) public expectedReverts;
    bytes4[] public seenReasons;
    mapping(bytes32 => uint256) public actionSuccesses;

    // ------------------------------------------------------------------
    // Ghost books
    // ------------------------------------------------------------------
    uint256 public ghostRequested;
    uint256 public ghostDeposited; // measured receipts
    uint256 public ghostTaxBurned;
    uint256 public ghostWithdrawn;
    uint256 public ghostLocked;
    uint256 public ghostReleased;
    uint256 public ghostDonations;
    uint256 public locksCreated;
    uint256 public locksReleased;
    mapping(address => uint256) public depositedBy;
    mapping(address => uint256) public withdrawnBy;
    mapping(address => uint256) public lockPaidBy;
    mapping(address => uint256) public releasedTo;

    // Per minted token id.
    uint256 public minted;
    mapping(uint256 => address) public ownerOfGhost; // 0 once burned
    mapping(uint256 => address) public minerAtMint;
    mapping(uint256 => uint256) public challengeAtMint;
    mapping(uint256 => bytes32) public digestAtMint;
    mapping(uint256 => bool) public lockExpected;
    mapping(uint256 => bool) public acceptedUnderModule;
    mapping(uint256 => bool) public eligibleAtAcceptance;
    mapping(uint256 => uint256) public stakeAtAcceptance;
    mapping(uint256 => bool) public burned;
    mapping(uint256 => address) public beneficiaryAtBurn;
    mapping(uint256 => uint256) public releaseCount;
    mapping(uint256 => address) public releaseRecipient;
    mapping(uint256 => address) public releaseCaller;

    // Proof counters.
    uint256 public accepted;
    uint256 public acceptedWithModule;
    uint256 public acceptedIneligible;
    uint256 public eligibleButBlocked;
    uint256 public liveStakeBlocked; // reason 4: expected, InsufficientFunds
    /// @dev Token storage reads/writes (by anyone) inside `submitProof`
    /// (`vm.record`): any hook token call (`balanceOf`, transfers) shows up.
    uint256 public hookTokenCalls;
    uint256 public hookTokenTransfers; // counting token: transfers during submitProof

    // Terminal / rare flags.
    uint256 public detaches;
    uint256 public attaches;
    uint256 public failsafes;
    uint256 public stops;

    struct Submit {
        address w;
        bool validNonce;
        bool attached;
        bool gateOff;
        bool elig;
        uint8 reason;
        uint256 stake;
        bytes4 want;
        bool lockWanted;
        address backer;
        uint256 walletBefore;
        uint256 backerBefore;
        uint256 totalStakeBefore;
        uint256 totalCommittedBefore;
        uint256 balanceBefore;
        uint256 mintedBefore;
        uint256 cid;
        uint256 seed;
        uint256 nonce;
        uint256 transfersBefore;
    }

    constructor(
        HunterMiningCore core_,
        PrefundedMiningPower module_,
        IPrefundedInvariantToken token_,
        LiveHunt hunt_,
        address basket_,
        address stop_,
        address guardian_,
        uint256 taxBps_,
        address countingToken_,
        uint256 huntOffer_
    ) {
        core = core_;
        nft = core_.PROOF_NFT();
        lifecycle = HunterLifecycle(address(nft.LIFECYCLE()));
        module = module_;
        token = token_;
        hunt = hunt_;
        basket = basket_;
        stop = stop_;
        guardian = guardian_;
        taxBps = taxBps_;
        countingToken = PrefundedInvariantFeeToken(countingToken_);
        startTimestamp = block.timestamp;
        huntOffer = huntOffer_;
    }

    // ==================================================================
    // Stake ledger actions
    // ==================================================================

    function deposit(uint256 actorSeed, uint256 amountSeed) public {
        ++calls;
        address d = _depositor(actorSeed);
        uint256 amount = _bound(amountSeed, 1, 4_000e18);
        bytes4 want = OK;
        if (module.retired()) want = PrefundedMiningPower.Retired.selector;
        else if (module.gateDisabled()) want = PrefundedMiningPower.GateDisabled.selector;
        token.mint(d, amount);
        vm.prank(d);
        token.approve(address(module), amount);
        uint256 balBefore = token.balanceOf(address(module));
        uint256 unassignedBefore = module.unassignedOf(d);
        uint256 stakeBefore = module.totalStake();
        vm.prank(d);
        (bool ok, bytes memory err) = address(module).call(abi.encodeCall(module.deposit, (amount)));
        if (!_outcome("deposit", want, ok, err)) {
            // Return the unused mint so the depositor's wallet never matters.
            return;
        }
        uint256 received = token.balanceOf(address(module)) - balBefore;
        uint256 expected = amount - (amount * taxBps) / 10_000;
        _check(received == expected, "deposit: receipt != tax model");
        _check(module.unassignedOf(d) - unassignedBefore == received, "deposit: credit != receipt");
        _check(module.totalStake() - stakeBefore == received, "deposit: totalStake != receipt");
        ghostRequested += amount;
        ghostDeposited += received;
        ghostTaxBurned += amount - received;
        depositedBy[d] += received;
    }

    function assign(uint256 actorSeed, uint256 walletSeed, uint256 amountSeed) public {
        ++calls;
        address d = _depositor(actorSeed);
        address current = module.assigneeOf(d);
        address w;
        uint256 r = walletSeed % 16;
        if (r == 0) w = d; // self-assignment attempt
        else if (current != address(0) && r < 12) w = current;
        else w = _wallet(walletSeed >> 8);
        uint256 available = module.unassignedOf(d);
        uint256 amount;
        if (available == 0) amount = _bound(amountSeed, 1, 1_000e18);
        else if (amountSeed % 3 == 0) amount = available;
        else amount = _bound(amountSeed, 1, available + available / 8);
        // S8b: an empty slot needs the wallet's consent. Usually the wallet
        // approves `d` first; otherwise the assign is predicted to fail
        // `BackerNotApproved` (unless `d` is still approved from before).
        if (w != d && module.assignedOf(w) == 0 && (walletSeed >> 16) % 4 != 3) _approveBacker(w, d);
        bytes4 want = _expectAssign(d, w, amount);
        uint256 backerBefore = module.assignedBy(d);
        vm.prank(d);
        (bool ok, bytes memory err) = address(module).call(abi.encodeCall(module.assign, (w, amount)));
        if (!_outcome("assign", want, ok, err)) return;
        _check(module.backerOf(w) == d, "assign: backer slot");
        _check(module.assigneeOf(d) == w, "assign: assignee");
        _check(module.assignedBy(d) == backerBefore + amount, "assign: assignedBy");
        _check(module.assignTimestamp(d) == block.timestamp, "assign: clock");
    }

    function unassign(uint256 actorSeed, uint256 walletSeed, uint256 amountSeed) public {
        ++calls;
        address d = _depositor(actorSeed);
        address w = module.assigneeOf(d);
        if (w == address(0) || walletSeed % 10 == 0) w = _wallet(walletSeed >> 8);
        uint256 assigned = module.assignedBy(d);
        uint256 amount = assigned == 0 ? _bound(amountSeed, 1, 1_000e18) : amountSeed % 3 == 0
            ? assigned
            : _bound(amountSeed, 1, assigned + assigned / 8);
        bytes4 want;
        if (module.assigneeOf(d) != w) {
            want = PrefundedMiningPower.WrongAssignee.selector;
        } else if (
            !module.retired() && !module.gateDisabled()
                && block.timestamp < module.assignTimestamp(d) + module.EXIT_COOLDOWN()
        ) {
            want = PrefundedMiningPower.CooldownNotMet.selector;
        } else if (amount > assigned) {
            want = PrefundedMiningPower.InsufficientAssigned.selector;
        }
        uint256 unassignedBefore = module.unassignedOf(d);
        uint256 stakeBefore = module.totalStake();
        vm.prank(d);
        (bool ok, bytes memory err) = address(module).call(abi.encodeCall(module.unassign, (w, amount)));
        if (!_outcome("unassign", want, ok, err)) return;
        _check(module.unassignedOf(d) == unassignedBefore + amount, "unassign: unassigned");
        _check(module.totalStake() == stakeBefore, "unassign moved totalStake");
    }

    function withdraw(uint256 actorSeed, uint256 amountSeed) public {
        ++calls;
        address d = _depositor(actorSeed);
        uint256 unassigned = module.unassignedOf(d);
        uint256 free = module.withdrawableOf(d);
        uint256 amount;
        uint256 mode = amountSeed % 8;
        if (mode == 0) amount = unassigned + 1;
        else if (mode == 1 || free == 0) amount = unassigned == 0 ? 1 : unassigned;
        else amount = _bound(amountSeed >> 3, 1, free);
        bytes4 want;
        uint256 held = module.heldStakeOf(d);
        // S8b: an eviction's carried-over cooldown blocks every withdrawal
        // (waived once retired or after the failsafe).
        if (_evictLocked(d)) {
            want = PrefundedMiningPower.CooldownNotMet.selector;
            _check(free == 0, "withdrawableOf != 0 while evict-locked");
        } else {
            if (amount > unassigned) {
                want = PrefundedMiningPower.InsufficientUnassigned.selector;
            } else if (amount > unassigned - Math.min(held, unassigned)) {
                want = PrefundedMiningPower.StakeHeldUntilNextChallenge.selector;
            }
            _check(free == unassigned - Math.min(held, unassigned), "withdrawableOf != unassigned - held");
        }
        uint256 userBefore = token.balanceOf(d);
        uint256 balBefore = token.balanceOf(address(module));
        vm.prank(d);
        (bool ok, bytes memory err) = address(module).call(abi.encodeCall(module.withdraw, (amount)));
        if (!_outcome("withdraw", want, ok, err)) return;
        _check(token.balanceOf(d) - userBefore == amount, "withdraw: user received");
        _check(balBefore - token.balanceOf(address(module)) == amount, "withdraw: module debit");
        ghostWithdrawn += amount;
        withdrawnBy[d] += amount;
    }

    function evictBacker(uint256 walletSeed, uint256 callerSeed) public {
        ++calls;
        address w = _wallet(walletSeed);
        address caller = callerSeed % 6 == 0 ? _depositor(callerSeed >> 8) : w;
        uint256 amount = module.assignedOf(w);
        address backer = module.backerOf(w);
        bytes4 want;
        if (caller != w) want = PrefundedMiningPower.UnauthorizedCaller.selector;
        else if (amount == 0 || amount >= module.MIN_STAKE()) want = PrefundedMiningPower.BackerNotEvictable.selector;
        uint256 backerUnassigned = backer == address(0) ? 0 : module.unassignedOf(backer);
        address approvedAfter = module.approvedBackerOf(w) == backer ? address(0) : module.approvedBackerOf(w);
        uint256 lockWanted =
            Math.max(module.withdrawLockedUntil(backer), module.assignTimestamp(backer) + module.EXIT_COOLDOWN());
        vm.prank(caller);
        (bool ok, bytes memory err) = address(module).call(abi.encodeCall(module.evictBacker, (w)));
        if (!_outcome("evictBacker", want, ok, err)) return;
        _check(module.assignedOf(w) == 0 && module.backerOf(w) == address(0), "evict: slot not cleared");
        _check(module.unassignedOf(backer) == backerUnassigned + amount, "evict: stake not returned");
        // S8b: the backer's own cooldown carries over to its withdrawals.
        _check(module.withdrawLockedUntil(backer) == lockWanted, "evict: backer cooldown not kept");
        // S8b: eviction revokes the evicted backer's standing approval.
        _check(module.approvedBackerOf(w) == approvedAfter, "evict: approval not revoked");
    }

    /// @dev S8b: `withdraw` is blocked by an eviction's carried-over cooldown.
    function _evictLocked(address d) internal view returns (bool) {
        return !module.retired() && !module.gateDisabled() && block.timestamp < module.withdrawLockedUntil(d);
    }

    /// @dev S8b: a wallet names (or clears, or tries to name itself as) the
    /// depositor it consents to as backer. Allowed in every state; never
    /// touches the current backer or any stake.
    function approveBacker(uint256 walletSeed, uint256 backerSeed) public {
        ++calls;
        address w = _wallet(walletSeed);
        uint256 mode = backerSeed % 8;
        address backer = mode == 0 ? address(0) : mode == 1 ? w : _depositor(backerSeed >> 3);
        _approveBacker(w, backer);
    }

    function _approveBacker(address w, address backer) internal {
        bytes4 want = backer == w ? PrefundedMiningPower.SelfAssignment.selector : OK;
        address slotBefore = module.backerOf(w);
        uint256 stakeBefore = module.assignedOf(w);
        uint256 totalBefore = module.totalStake();
        vm.prank(w);
        (bool ok, bytes memory err) = address(module).call(abi.encodeCall(module.approveBacker, (backer)));
        if (!_outcome("approveBacker", want, ok, err)) return;
        _check(module.approvedBackerOf(w) == backer, "approveBacker: not recorded");
        _check(
            module.backerOf(w) == slotBefore && module.assignedOf(w) == stakeBefore
                && module.totalStake() == totalBefore,
            "approveBacker moved the slot or stake"
        );
    }

    function donate(uint256 amountSeed) public {
        ++calls;
        if (amountSeed % 4 != 0) return;
        uint256 amount = _bound(amountSeed >> 2, 1, 50e18);
        token.mint(address(module), amount);
        ghostDonations += amount;
    }

    // ==================================================================
    // Proof actions (REAL core)
    // ==================================================================

    /// @dev A proof with a base-target nonce from a staked wallet (the one
    /// `eligibilityOf` calls eligible, if any).
    function submitEligible(uint256 walletSeed) public {
        ++calls;
        // An expired seed would only waste the attempt: refresh it first.
        if (core.challengeState() == HunterMiningCore.ChallengeState.EXPIRED) refreshExpiredSeed(1);
        address w = _wallet(walletSeed);
        (bool e,,) = module.eligibilityOf(w);
        if (!e) {
            address other = w == W1 ? W2 : W1;
            (bool e2,,) = module.eligibilityOf(other);
            if (e2) w = other;
        }
        _submit(w, true);
    }

    /// @dev A proof with a valid nonce from an unstaked or under-staked
    /// wallet (a depositor, the collector, or an ineligible mining wallet).
    function submitIneligible(uint256 walletSeed) public {
        ++calls;
        address w;
        uint256 r = walletSeed % 6;
        if (r < 3) w = _depositor(walletSeed >> 8);
        else if (r == 3) w = COLLECTOR;
        else w = _wallet(walletSeed >> 8);
        _submit(w, true);
    }

    /// @dev A proof whose digest misses the effective target.
    function submitInvalid(uint256 walletSeed) public {
        ++calls;
        _submit(walletSeed % 4 == 0 ? _depositor(walletSeed >> 8) : _wallet(walletSeed >> 8), false);
    }

    function refreshExpiredSeed(uint256 rollSeed) public {
        ++calls;
        HunterMiningCore.ChallengeState state = core.challengeState();
        uint256 seedBlock = core.activeSeedParentBlock();
        if (rollSeed % 4 != 0) {
            uint256 expiry = seedBlock + core.SEED_READABLE_PARENT_BLOCKS() + 1;
            if (block.number < expiry) vm.roll(expiry);
        }
        state = core.challengeState();
        bytes4 want;
        if (state == HunterMiningCore.ChallengeState.ENDED || state == HunterMiningCore.ChallengeState.STOPPED) {
            want = HunterMiningCore.ChallengeNotActive.selector;
        } else if (block.number <= seedBlock || block.number - seedBlock <= core.SEED_READABLE_PARENT_BLOCKS()) {
            want = HunterMiningCore.SeedNotExpired.selector;
        }
        uint256 idBefore = core.activeChallengeId();
        (bool ok, bytes memory err) = address(core).call(abi.encodeCall(core.refreshExpiredSeed, ()));
        if (!_outcome("refreshExpiredSeed", want, ok, err)) return;
        _check(core.activeChallengeId() == idBefore + 1, "refresh: id");
        _checkModuleSynced("refresh: module not synced");
    }

    function easeDifficulty(uint256 rollSeed) public {
        ++calls;
        _makeActive();
        uint256 ref = Math.max(core.lastProofBlock(), core.lastEaseBlock());
        uint256 earliest = ref + core.STALL_INTERVAL_PARENT_BLOCKS();
        uint256 seedBlock = core.activeSeedParentBlock();
        if (rollSeed % 3 != 0 && block.number < earliest && earliest <= seedBlock + core.SEED_READABLE_PARENT_BLOCKS()) {
            vm.roll(earliest);
        }
        bytes4 want;
        HunterMiningCore.ChallengeState state = core.challengeState();
        if (state != HunterMiningCore.ChallengeState.ACTIVE) want = HunterMiningCore.ChallengeNotActive.selector;
        else if (core.currentTarget() == core.MAX_TARGET()) want = HunterMiningCore.DifficultyAtMaximum.selector;
        else if (block.number < earliest) want = HunterMiningCore.DifficultyStallIntervalNotMet.selector;
        (bool ok, bytes memory err) = address(core).call(abi.encodeCall(core.easeDifficulty, ()));
        _outcome("easeDifficulty", want, ok, err);
    }

    function advanceTime(uint256 blockSeed, uint256 secondsSeed) public {
        ++calls;
        vm.roll(block.number + _bound(blockSeed, 1, 300));
        uint256 dt = _bound(secondsSeed, 0, 3 days);
        if (block.timestamp + dt <= startTimestamp + MAX_ELAPSED) vm.warp(block.timestamp + dt);
    }

    // ==================================================================
    // NFT actions
    // ==================================================================

    function transferNft(uint256 idSeed, uint256 toSeed) public {
        ++calls;
        uint256 id = _liveId(idSeed);
        if (id == 0) return;
        address from = ownerOfGhost[id];
        address to = _anyActor(toSeed);
        if (to == from) to = COLLECTOR == from ? D1 : COLLECTOR;
        vm.prank(from);
        (bool ok, bytes memory err) =
            address(nft).call(abi.encodeWithSignature("transferFrom(address,address,uint256)", from, to, id));
        if (!_outcome("transferNft", OK, ok, err)) return;
        ownerOfGhost[id] = to;
        _check(nft.ownerOf(id) == to, "transfer: owner");
    }

    /// @dev LiveHunt sale: the collector posts a matching hunt, the owner
    /// fills it, and the NFT (with its lock right) moves to the collector.
    function liveHuntFill(uint256 idSeed) public {
        ++calls;
        uint256 id = _liveId(idSeed);
        if (id == 0) return;
        address seller = ownerOfGhost[id];
        if (seller == COLLECTOR) return;
        LiveHunt.Criteria memory criteria;
        criteria.artVersion = 1;
        uint256 duration = hunt.MIN_HUNT_DURATION();
        vm.deal(COLLECTOR, huntOffer);
        vm.prank(COLLECTOR);
        (bool ok, bytes memory err) =
            address(hunt).call{value: huntOffer}(abi.encodeCall(hunt.createHunt, (criteria, duration)));
        if (!_outcome("liveHunt.create", OK, ok, err)) return;
        uint256 huntId = abi.decode(err, (uint256));
        vm.prank(seller);
        (ok, err) = address(nft).call(
            abi.encodeWithSignature(
                "safeTransferFrom(address,address,uint256,bytes)", seller, address(hunt), id, abi.encode(huntId)
            )
        );
        if (!_outcome("liveHunt.fill", OK, ok, err)) return;
        ownerOfGhost[id] = COLLECTOR;
        _check(nft.ownerOf(id) == COLLECTOR, "liveHunt: owner");
    }

    function burn(uint256 idSeed) public {
        ++calls;
        uint256 id = _liveId(idSeed);
        if (id == 0) return;
        address owner = ownerOfGhost[id];
        vm.prank(owner);
        (bool ok, bytes memory err) = address(nft).call(abi.encodeCall(nft.redeemAndDestroy, (id)));
        if (!_outcome("burn", OK, ok, err)) return;
        ownerOfGhost[id] = address(0);
        burned[id] = true;
        beneficiaryAtBurn[id] = owner;
        _check(lifecycle.finalBeneficiary(id) == owner, "burn: beneficiary");
    }

    function claim(uint256 idSeed, uint256 callerSeed, uint256 recipientSeed) public {
        ++calls;
        if (minted == 0) return;
        uint256 id = idSeed % (minted + 1) + (idSeed % 17 == 0 ? 1 : 0); // sometimes an unminted id
        if (id == 0) id = 1;
        // Prefer ids that can actually be claimed.
        if (idSeed % 3 != 0) {
            for (uint256 i = 0; i < minted; ++i) {
                uint256 cand = (idSeed % minted + i) % minted + 1;
                if (burned[cand] && releaseCount[cand] == 0 && lockExpected[cand]) {
                    id = cand;
                    break;
                }
            }
        }
        address beneficiary = burned[id] ? beneficiaryAtBurn[id] : address(0);
        address caller;
        if (callerSeed % 4 == 0 || beneficiary == address(0)) {
            caller = callerSeed % 8 == 0 ? ownerOfGhost[id] : _anyActor(callerSeed >> 3);
            if (caller == address(0)) caller = _anyActor(callerSeed >> 3);
        } else {
            caller = beneficiary;
        }
        bool toOther = recipientSeed % 2 == 0;
        address recipient = toOther ? _anyActor(recipientSeed >> 1) : caller;
        (uint256 amount,,,,, bool released) = module.committedOf(id);
        bytes4 want;
        if (amount == 0) want = PrefundedMiningPower.NoLock.selector;
        else if (released) want = PrefundedMiningPower.AlreadyReleased.selector;
        else if (!burned[id]) want = PrefundedMiningPower.TokenNotBurned.selector;
        else if (caller != beneficiary) want = PrefundedMiningPower.NotBeneficiary.selector;
        uint256 recipientBefore = token.balanceOf(recipient);
        uint256 balBefore = token.balanceOf(address(module));
        vm.prank(caller);
        (bool ok, bytes memory err) = toOther
            ? address(module).call(abi.encodeCall(module.claimCommittedTo, (id, recipient)))
            : address(module).call(abi.encodeCall(module.claimCommitted, (id)));
        if (!_outcome("claim", want, ok, err)) return;
        _check(token.balanceOf(recipient) - recipientBefore == amount, "claim: recipient paid");
        _check(balBefore - token.balanceOf(address(module)) == amount, "claim: module debit");
        ghostReleased += amount;
        ++locksReleased;
        ++releaseCount[id];
        releaseRecipient[id] = recipient;
        releaseCaller[id] = caller;
        releasedTo[recipient] += amount;
    }

    // ==================================================================
    // Governance actions
    // ==================================================================

    /// @dev STOP detaches the wired module, or re-attaches it when detached
    /// (RetainedAssignments while any stake is still assigned).
    function toggleModule(uint256 seed) public {
        ++calls;
        bool attached = address(core.miningPower()) == address(module);
        // Keep the module wired most of the time: detach rarely, and before a
        // re-attach let every backer try to take its stake off (a re-attach
        // needs `totalAssigned == 0`; cooldowns still apply).
        if (attached && seed % 8 != 0) return;
        if (!attached && seed % 2 == 0) {
            for (uint256 i = 0; i < 3; ++i) {
                if (module.assignedBy(_depositor(i)) != 0) unassign(i, 1, 0);
            }
        }
        bytes4 want = _expectStopMultisigCall();
        if (want == OK && !attached && module.totalAssigned() != 0) {
            want = PrefundedMiningPower.RetainedAssignments.selector;
        }
        IMiningPower target = attached ? IMiningPower(address(0)) : IMiningPower(address(module));
        vm.prank(stop);
        (bool ok, bytes memory err) = address(core).call(abi.encodeCall(core.setMiningPower, (target)));
        if (!_outcome(attached ? "detach" : "attach", want, ok, err)) return;
        if (attached) {
            ++detaches;
            _check(!module.wired(), "detach: still wired");
        } else {
            ++attaches;
            _check(module.wired() && !module.retired(), "attach: not wired");
            _checkModuleSynced("attach: module not synced");
        }
    }

    function disableRequirement(uint256 seed) public {
        ++calls;
        if (seed % 128 != 0) {
            // Anyone but the guardian is refused.
            address caller = _anyActor(seed);
            vm.prank(caller);
            (bool ok0, bytes memory err0) = address(module).call(abi.encodeCall(module.disableRequirement, ()));
            _outcome("disableRequirement.other", PrefundedMiningPower.UnauthorizedCaller.selector, ok0, err0);
            return;
        }
        bytes4 want = module.gateDisabled() ? PrefundedMiningPower.GateDisabled.selector : OK;
        uint256 balBefore = token.balanceOf(address(module));
        uint256 stakeBefore = module.totalStake();
        uint256 committedBefore = module.totalCommitted();
        vm.prank(guardian);
        (bool ok, bytes memory err) = address(module).call(abi.encodeCall(module.disableRequirement, ()));
        if (!_outcome("disableRequirement", want, ok, err)) return;
        ++failsafes;
        _check(
            token.balanceOf(address(module)) == balBefore && module.totalStake() == stakeBefore
                && module.totalCommitted() == committedBefore,
            "failsafe moved funds"
        );
    }

    function stopMining(uint256 seed) public {
        ++calls;
        if (seed % 256 != 0) return;
        bytes4 want = _expectStopMultisigCall();
        bool attached = address(core.miningPower()) == address(module);
        vm.prank(stop);
        (bool ok, bytes memory err) = address(core).call(abi.encodeCall(core.stopMining, ()));
        if (!_outcome("stopMining", want, ok, err)) return;
        ++stops;
        if (attached) _check(module.retired() && !module.wired(), "stop: module not retired");
    }

    // ==================================================================
    // Submission model
    // ==================================================================

    function _submit(address w, bool validNonce) internal {
        Submit memory s;
        s.w = w;
        s.validNonce = validNonce;
        bool active = _makeActive();
        s.attached = address(core.miningPower()) == address(module);
        s.gateOff = module.gateDisabled();
        (s.elig, s.reason, s.stake) = module.eligibilityOf(w);
        s.cid = core.activeChallengeId();
        s.seed = core.activeSeedParentBlock();
        if (!active) {
            s.want = HunterMiningCore.ChallengeNotActive.selector;
        } else {
            _expectSubmit(s);
            s.nonce = validNonce ? _validNonce(w) : _invalidNonce(w, s.attached);
            if (!validNonce && s.want != PrefundedMiningPower.NotEligible.selector) {
                s.want = HunterMiningCore.InvalidProof.selector;
                s.lockWanted = false;
            }
        }
        if (s.attached) {
            _check(module.latestChallengeId() == s.cid, "submit: module epoch != core challenge");
            if (module.CURVE_UNIT() == 0) _check(module.previewSubmit(w) == 1e18, "curve disabled but multiplier != 1");
        }
        s.backer = module.backerOf(w);
        s.walletBefore = module.assignedOf(w);
        s.backerBefore = s.backer == address(0) ? 0 : module.assignedBy(s.backer);
        s.totalStakeBefore = module.totalStake();
        s.totalCommittedBefore = module.totalCommitted();
        s.balanceBefore = token.balanceOf(address(module));
        s.mintedBefore = nft.mintedEver();
        if (address(countingToken) != address(0)) s.transfersBefore = countingToken.moduleTransfers();

        vm.record();
        vm.prank(w);
        (bool ok, bytes memory err) =
            address(core).call(abi.encodeCall(core.submitProof, (s.cid, s.seed, s.nonce, basket)));
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(address(token));
        vm.stopRecord();
        hookTokenCalls += reads.length + writes.length;
        if (address(countingToken) != address(0)) {
            hookTokenTransfers += countingToken.moduleTransfers() - s.transfersBefore;
        }

        bool matched = (ok ? OK : _selector(err)) == s.want;
        _outcome(validNonce ? "submit" : "submitInvalid", s.want, ok, err);
        if (!ok) {
            if (s.want == OK && s.attached && !s.gateOff && s.elig) ++eligibleButBlocked;
            if (matched && s.want == PrefundedMiningPower.InsufficientFunds.selector) ++liveStakeBlocked;
            _check(token.balanceOf(address(module)) == s.balanceBefore, "reverted submit moved tokens");
            _check(nft.mintedEver() == s.mintedBefore, "reverted submit minted");
            return;
        }
        _recordAcceptance(s);
    }

    function _recordAcceptance(Submit memory s) internal {
        uint256 id = nft.mintedEver();
        ++accepted;
        minted = id;
        _check(id == s.mintedBefore + 1, "accept: id not sequential");
        _check(nft.ownerOf(id) == s.w, "accept: NFT not to miner");
        (, bytes32 digest, uint256 challengeId,) = nft.birthData(id);
        ownerOfGhost[id] = s.w;
        minerAtMint[id] = s.w;
        challengeAtMint[id] = challengeId;
        digestAtMint[id] = digest;
        _check(challengeId == s.cid, "accept: birth challenge");
        acceptedUnderModule[id] = s.attached;
        eligibleAtAcceptance[id] = s.elig;
        stakeAtAcceptance[id] = s.stake;
        bool lockNow = s.attached && !s.gateOff;
        lockExpected[id] = lockNow;
        _check(lockNow == s.lockWanted, "accept: lock expectation");
        if (s.attached) {
            ++acceptedWithModule;
            if (!s.gateOff && !s.elig) ++acceptedIneligible;
            (uint256 note, address noteMiner) = module.pendingEligibleNote();
            _check(note == 0 && noteMiner == address(0), "accept: note survived");
            _checkModuleSynced("accept: module not synced");
        }
        (uint256 amount, uint256 lockCid, bytes32 lockDigest, address miner, address backer, bool released) =
            module.committedOf(id);
        uint256 lockAmount = module.LOCK_PER_MINT();
        if (!lockNow) {
            _check(amount == 0, "accept: lock without enforcing gate");
            _check(module.totalCommitted() == s.totalCommittedBefore, "accept: committed moved without lock");
            _check(module.totalStake() == s.totalStakeBefore, "accept: stake moved without lock");
            return;
        }
        _check(amount == lockAmount && !released, "lock: amount");
        _check(lockCid == s.cid && lockDigest == digest, "lock: birth data");
        _check(miner == s.w && backer == s.backer, "lock: parties");
        _check(module.assignedOf(s.w) == s.walletBefore - lockAmount, "lock: wallet stake");
        _check(module.assignedBy(s.backer) == s.backerBefore - lockAmount, "lock: backer stake");
        _check(module.totalStake() == s.totalStakeBefore - lockAmount, "lock: totalStake");
        _check(module.totalCommitted() == s.totalCommittedBefore + lockAmount, "lock: totalCommitted");
        _check(token.balanceOf(address(module)) == s.balanceBefore, "lock moved tokens");
        ghostLocked += lockAmount;
        lockPaidBy[s.backer] += lockAmount;
        ++locksCreated;
    }

    /// @dev Exact outcome of an ACTIVE-challenge submission with a
    /// base-target nonce, from the module's own preview.
    function _expectSubmit(Submit memory s) internal view {
        if (!s.attached || s.gateOff) {
            s.want = OK;
            return;
        }
        if (s.reason == 0) {
            s.want = OK;
            s.lockWanted = true;
        } else if (s.reason == 2) {
            s.want = PrefundedMiningPower.NotEligible.selector;
        } else if (s.reason == 4) {
            s.want = PrefundedMiningPower.InsufficientFunds.selector;
        } else {
            s.want = NO_DATA; // reason 1 while attached is impossible
        }
    }

    /// @dev Makes the active challenge ACTIVE if it is merely waiting for
    /// its seed block (rolls forward and sets the seed blockhash). Returns
    /// false when it is EXPIRED, ENDED or STOPPED.
    function _makeActive() internal returns (bool) {
        HunterMiningCore.ChallengeState state = core.challengeState();
        if (state != HunterMiningCore.ChallengeState.WAITING_FOR_SEED && state != HunterMiningCore.ChallengeState.ACTIVE)
        {
            return false;
        }
        uint256 seedBlock = core.activeSeedParentBlock();
        if (block.number <= seedBlock) vm.roll(seedBlock + 1);
        vm.setBlockhash(seedBlock, keccak256(abi.encode("seed", core.activeChallengeId(), seedBlock)));
        return core.challengeState() == HunterMiningCore.ChallengeState.ACTIVE;
    }

    function _validNonce(address miner) internal view returns (uint256 nonce) {
        bytes32 challenge = core.currentChallenge();
        uint256 target = core.currentTarget();
        uint256 cid = core.activeChallengeId();
        for (; nonce < 4_096; ++nonce) {
            if (uint256(core.deriveProofDigest(cid, challenge, miner, nonce)) <= target) return nonce;
        }
        revert("valid nonce not found");
    }

    /// @dev A nonce whose digest is above the EFFECTIVE target (base target
    /// widened by the module's previewed multiplier, as the core does).
    function _invalidNonce(address miner, bool attached) internal view returns (uint256 nonce) {
        bytes32 challenge = core.currentChallenge();
        uint256 target = core.currentTarget();
        if (attached) {
            uint256 mult = module.previewSubmit(miner);
            if (mult > 1e18) {
                if (mult > 3e18) mult = 3e18;
                uint256 maxT = core.MAX_TARGET();
                uint256 maxSafe = Math.mulDiv(maxT, 1e18, mult);
                target = target >= maxSafe ? maxT : Math.mulDiv(target, mult, 1e18);
                if (target > maxT) target = maxT;
            }
        }
        uint256 cid = core.activeChallengeId();
        for (nonce = 1 << 128; nonce < (1 << 128) + 4_096; ++nonce) {
            if (uint256(core.deriveProofDigest(cid, challenge, miner, nonce)) > target) return nonce;
        }
        revert("invalid nonce not found");
    }

    // ==================================================================
    // Expectation helpers
    // ==================================================================

    /// @dev `assign` check order, mirrored.
    function _expectAssign(address d, address w, uint256 amount) internal view returns (bytes4) {
        if (module.retired()) return PrefundedMiningPower.Retired.selector;
        if (!module.wired()) return PrefundedMiningPower.NotWired.selector;
        if (module.gateDisabled()) return PrefundedMiningPower.GateDisabled.selector;
        if (w == d) return PrefundedMiningPower.SelfAssignment.selector;
        address current = module.assigneeOf(d);
        if (current != address(0) && current != w) return PrefundedMiningPower.MustUnassignFirst.selector;
        if (module.assignedOf(w) != 0) {
            if (module.backerOf(w) != d) return PrefundedMiningPower.WalletAlreadyBacked.selector;
        } else {
            if (module.approvedBackerOf(w) != d) return PrefundedMiningPower.BackerNotApproved.selector;
            if (amount < module.MIN_STAKE()) return PrefundedMiningPower.FirstAssignBelowMinimum.selector;
            uint256 latest = module.latestChallengeId();
            if (
                module.pendingEpoch(w) == latest && module.removingOf(w) != 0 && latest != module.holdWaivedEpoch()
            ) return PrefundedMiningPower.WalletHasCountingRemoval.selector;
        }
        if (amount > module.unassignedOf(d)) return PrefundedMiningPower.InsufficientUnassigned.selector;
        return OK;
    }

    /// @dev Shared prechecks of `setMiningPower` / `stopMining` for STOP.
    function _expectStopMultisigCall() internal view returns (bytes4) {
        if (block.timestamp > core.MINING_STOP_SUNSET()) return HunterMiningCore.MiningStopSunsetPassed.selector;
        if (core.miningStopped()) return HunterMiningCore.MiningAlreadyStopped.selector;
        if (core.nftsMintedEver() >= core.MAX_NFTS_EVER()) return HunterMiningCore.ChallengeNotActive.selector;
        return OK;
    }

    function _checkModuleSynced(string memory what) internal {
        if (address(core.miningPower()) == address(module)) {
            _check(module.wired() && module.latestChallengeId() == core.activeChallengeId(), what);
        }
    }

    // ==================================================================
    // Bookkeeping
    // ==================================================================

    function _outcome(string memory action, bytes4 want, bool ok, bytes memory err) internal returns (bool) {
        bytes4 got = ok ? OK : _selector(err);
        if (got != want) {
            ++unexpected;
            lastUnexpectedAction = action;
            lastUnexpectedWant = want;
            lastUnexpectedGot = got;
            lastUnexpectedData = err;
            return false;
        }
        if (ok) {
            ++actionSuccesses[keccak256(bytes(action))];
        } else {
            if (expectedReverts[got] == 0) seenReasons.push(got);
            ++expectedReverts[got];
        }
        return ok;
    }

    function _check(bool cond, string memory what) internal {
        if (!cond) {
            ++violations;
            lastViolation = what;
        }
    }

    function _selector(bytes memory err) internal pure returns (bytes4 sel) {
        if (err.length < 4) return NO_DATA;
        assembly ("memory-safe") {
            sel := mload(add(err, 32))
        }
    }

    function _liveId(uint256 seed) internal view returns (uint256) {
        if (minted == 0) return 0;
        uint256 start = seed % minted;
        for (uint256 i = 0; i < minted; ++i) {
            uint256 id = (start + i) % minted + 1;
            if (ownerOfGhost[id] != address(0)) return id;
        }
        return 0;
    }

    function _depositor(uint256 seed) internal pure returns (address) {
        uint256 r = seed % 3;
        return r == 0 ? D1 : r == 1 ? D2 : D3;
    }

    function _wallet(uint256 seed) internal pure returns (address) {
        return seed % 2 == 0 ? W1 : W2;
    }

    function _anyActor(uint256 seed) internal pure returns (address) {
        uint256 r = seed % 6;
        if (r < 3) return _depositor(r);
        if (r < 5) return _wallet(r);
        return COLLECTOR;
    }

    // ==================================================================
    // Views for the invariant contract
    // ==================================================================

    function seenReasonCount() external view returns (uint256) {
        return seenReasons.length;
    }

    function depositors() external pure returns (address[3] memory) {
        return [D1, D2, D3];
    }

    function wallets() external pure returns (address[2] memory) {
        return [W1, W2];
    }

    function successes(string memory action) external view returns (uint256) {
        return actionSuccesses[keccak256(bytes(action))];
    }

    receive() external payable {}
}
