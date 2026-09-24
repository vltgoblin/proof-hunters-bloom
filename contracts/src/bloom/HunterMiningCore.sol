// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HunterNFT} from "./HunterNFT.sol";
import {IMiningPower} from "./IMiningPower.sol";
import {MiningPowerCustody} from "./MiningPowerCustody.sol";

/// @dev Lifecycle read surface exposing the canonical reserve binding. The
/// production lifecycle implements it; a mining-only dry-run lifecycle does
/// not, in which case late attachment has no canonical token source at all.
interface IReserveBoundLifecycle {
    function reserve() external view returns (address);
}

/// @dev The reserve's late-activation read surface: its bound canonical NFT,
/// the recorded HUNTER token (address zero until activated) and the sole
/// account authorized for one-time token/module activation.
interface IHunterTokenActivationSource {
    function NFT() external view returns (HunterNFT);
    function HUNTER() external view returns (IERC20);
    function TOKEN_AUTHORITY() external view returns (address);
}

/// @title NFT-only Proof Hunters mining candidate for a new deployment
/// @dev Not wired to a production vault. Legacy MiningCore and its clients are unchanged.
contract HunterMiningCore is ReentrancyGuard {
    error InvalidTargetConfiguration(uint256 minTarget, uint256 genesisTarget, uint256 maxTarget);
    error UnusableMinimumNftThreshold(uint256 minTarget, uint256 deepestTierThreshold);
    error InvalidGenesisSeedMinimumDelay(uint256 supplied, uint256 required);
    error GenesisSeedNotFuture(uint256 supplied, uint256 deploymentBlock);
    error GenesisSeedTooSoon(uint256 supplied, uint256 earliestAllowed);
    error InvalidMiningStopMultisig(address supplied, address deployingAccount);
    error InvalidMiningStopSunset(uint256 supplied, uint256 earliestAllowed, uint256 latestAllowed);
    error UnauthorizedMiningStopCaller(address caller);
    error MiningStopSunsetPassed(uint256 sunset, uint256 currentTimestamp);
    error MiningAlreadyStopped();
    error MiningPowerAlreadyWired(address current);
    error MiningPowerAlreadyAttached();
    error InvalidCanonicalReserve();
    error CanonicalTokenNotActivated();
    error UnauthorizedMiningPowerActivation(address caller);
    error InvalidMiningPowerModule();
    error MiningPowerTokenMismatch(address expected, address actual);
    error MiningPowerCoreMismatch(address expected, address actual);
    error NoMiningCounterViolation(uint256 proofs, uint256 coreNfts, uint256 nftMints);
    error ChallengeNotActive(ChallengeState state);
    error SeedBlockhashUnavailable(uint256 seedParentBlock);
    error StaleChallengeId(uint256 supplied, uint256 active);
    error StaleSeedBlock(uint256 supplied, uint256 active);
    error InvalidProof(bytes32 digest, uint256 target);
    error SeedNotExpired(uint256 seedParentBlock, uint256 currentBlock);
    error DifficultyStallIntervalNotMet(uint256 earliestBlock, uint256 currentBlock);
    error DifficultyAtMaximum();

    enum ChallengeState {
        WAITING_FOR_SEED,
        ACTIVE,
        EXPIRED,
        ENDED,
        STOPPED
    }

    enum StopCause {
        KEYED,
        COUNTER_VIOLATION
    }

    struct AcceptedProofData {
        address miner;
        uint256 challengeId;
        bytes32 digest;
        uint256 seedParentBlock;
        bytes32 challenge;
        uint256 nonce;
        uint256 acceptedTarget;
    }

    struct ProofSettlementData {
        uint256 proofNftTokenId;
        uint8 proofTier;
    }

    struct ProofNftDeploymentData {
        address registry;
        address lifecycle;
        uint32 artVersion;
        address royaltyRecipient;
        string baseURI;
    }

    // Contract Rulebook v0.1 section 8.2, line 1074.
    uint256 public constant PROOF_VERSION = 1;
    bytes32 public constant PROOF_TYPEHASH = 0xdf48049c8032f061c47a9b74b3f54516ba0b8339560bd23c99b0c5d45061393a;
    bytes32 public constant CHALLENGE_TYPEHASH = 0xe0e82b0a91887386e16d4209170f8f80216318fc95f902a4a5ab3f18cf5b0c5b;

    // Ticket 16 Numbers v0.1 lines 99-103.
    uint256 public constant TARGET_CADENCE_PARENT_BLOCKS = 50;
    uint256 public constant RETARGET_WINDOW_PROOFS = 144;
    uint256 public constant STALL_INTERVAL_PARENT_BLOCKS = 250;
    uint256 public constant EASE_NUMERATOR = 5;
    uint256 public constant EASE_DENOMINATOR = 4;
    uint256 public constant SEED_DELAY_PARENT_BLOCKS = 3;

    // Secure Mining Design v0.1 lines 183 and 214-216.
    uint256 public constant SEED_READABLE_PARENT_BLOCKS = 256;
    uint256 public constant EXPECTED_RETARGET_PARENT_BLOCKS = RETARGET_WINDOW_PROOFS * TARGET_CADENCE_PARENT_BLOCKS;
    uint256 public constant MIN_OBSERVED_PARENT_BLOCKS = EXPECTED_RETARGET_PARENT_BLOCKS / 4;
    uint256 public constant MAX_OBSERVED_PARENT_BLOCKS = EXPECTED_RETARGET_PARENT_BLOCKS * 4;

    // Slice 11 ruling lines 78-89. The genesis digest has no prior accepted proof.
    uint256 public constant INITIAL_CHALLENGE_ID = 1;
    bytes32 public constant GENESIS_PREVIOUS_ACCEPTED_DIGEST = bytes32(0);

    // Ticket 06 Options v0.1 lines 123-139 / Contract Rulebook v0.1 section 8.2.
    uint256 public constant MAX_NFTS_EVER = 5_000;
    uint256 public constant TIER_BAND_DENOMINATOR = 1_000;
    uint256 public constant LEGENDARY_TIER_NUMERATOR = 10;
    uint256 public constant RARE_TIER_NUMERATOR = 80;
    uint256 public constant UNCOMMON_TIER_NUMERATOR = 300;

    // MP.2 freeze: base chance 1.0×; published maximum 3.0×. Core clamps the module.
    uint256 public constant POWER_BASE_WAD = 1e18;
    uint256 public constant MAX_POWER_MULTIPLIER_WAD = 3e18;

    // Frozen Proof Hunters trait vocabulary v1, proofTiers values 1 through 4.
    uint8 public constant PROOF_TIER_COMMON = 1;
    uint8 public constant PROOF_TIER_UNCOMMON = 2;
    uint8 public constant PROOF_TIER_RARE = 3;
    uint8 public constant PROOF_TIER_LEGENDARY = 4;

    uint256 private constant _MINING_STOP_SUNSET_MIN_DELAY = 30 days;
    uint256 private constant _MINING_STOP_SUNSET_MAX_DELAY = 180 days;

    uint256 public immutable MIN_TARGET;
    uint256 public immutable MAX_TARGET;
    uint256 public immutable GENESIS_TARGET;
    uint256 public immutable GENESIS_SEED_PARENT_BLOCK;
    uint256 public immutable GENESIS_SEED_MINIMUM_DELAY;
    address public immutable MINING_STOP_MULTISIG;
    uint256 public immutable MINING_STOP_SUNSET;
    HunterNFT public immutable PROOF_NFT;
    IMiningPower public miningPower;
    /// @dev Set once by the first nonzero module attach through EITHER path
    /// and never cleared — detach leaves it true. It is what makes
    /// `attachMiningPowerLate` a one-time first-attach instead of a second
    /// post-sunset wiring surface: a module that was ever attached (even one
    /// later detached pre-sunset) consumes the slot permanently.
    bool public miningPowerWasAttached;

    uint256 public activeChallengeId;
    uint256 public activeSeedParentBlock;
    bytes32 public previousAcceptedDigest;
    uint256 public currentTarget;
    uint256 public acceptedProofs;
    uint256 public nftsMintedEver;

    uint256 public retargetWindowProofs;
    uint256 public retargetWindowStartBlock;
    uint256 public lastProofBlock;
    uint256 public lastEaseBlock;
    bool public miningStopped;

    event ProofAccepted(
        address indexed miner,
        uint256 indexed challengeId,
        bytes32 indexed digest,
        uint256 seedParentBlock,
        bytes32 challenge,
        uint256 nonce,
        uint256 acceptedTarget,
        uint256 nextChallengeId,
        uint256 nextSeedParentBlock,
        uint256 nextTarget,
        bool ended
    );
    event ProofNftMinted(
        address indexed miner,
        uint256 indexed tokenId,
        uint256 indexed challengeId,
        bytes32 digest,
        uint8 proofTier,
        address basket
    );
    event SeedRefreshed(
        uint256 indexed expiredChallengeId,
        uint256 indexed newChallengeId,
        uint256 expiredSeedParentBlock,
        uint256 newSeedParentBlock
    );
    event DifficultyRetargeted(
        uint256 indexed acceptedProofCount,
        uint256 oldTarget,
        uint256 newTarget,
        uint256 actualParentBlocks,
        uint256 observedParentBlocks
    );
    event DifficultyEased(address indexed caller, uint256 oldTarget, uint256 newTarget, uint256 parentBlock);
    event MiningStopped(address indexed module, StopCause indexed cause, address indexed caller, uint256 timestamp);
    event MiningPowerSet(address indexed power, address indexed caller);
    event MiningPowerDetachHookFailed(address indexed power);

    constructor(
        uint256 minTarget,
        uint256 maxTarget,
        uint256 genesisTarget,
        uint256 genesisSeedParentBlock,
        uint256 genesisSeedMinimumDelay,
        address miningStopMultisig,
        uint256 miningStopSunset,
        ProofNftDeploymentData memory proofNftDeployment
    ) {
        if (
            minTarget == 0 || genesisTarget == 0 || maxTarget == 0 || minTarget >= genesisTarget
                || genesisTarget >= maxTarget
        ) revert InvalidTargetConfiguration(minTarget, genesisTarget, maxTarget);
        uint256 deepestTierThreshold = _legendaryThreshold(minTarget);
        if (deepestTierThreshold == 0) revert UnusableMinimumNftThreshold(minTarget, deepestTierThreshold);
        if (miningStopMultisig == address(0) || miningStopMultisig == msg.sender) {
            revert InvalidMiningStopMultisig(miningStopMultisig, msg.sender);
        }

        // The stop sunset is the Mining Core's one deliberate timestamp clock. Difficulty,
        // seed life, retargeting and easing remain exclusively on parent-block numbers.
        uint256 earliestMiningStopSunset = block.timestamp + _MINING_STOP_SUNSET_MIN_DELAY;
        uint256 latestMiningStopSunset = block.timestamp + _MINING_STOP_SUNSET_MAX_DELAY;
        if (miningStopSunset < earliestMiningStopSunset || miningStopSunset > latestMiningStopSunset) {
            revert InvalidMiningStopSunset(miningStopSunset, earliestMiningStopSunset, latestMiningStopSunset);
        }
        if (genesisSeedMinimumDelay < SEED_DELAY_PARENT_BLOCKS) {
            revert InvalidGenesisSeedMinimumDelay(genesisSeedMinimumDelay, SEED_DELAY_PARENT_BLOCKS);
        }
        if (genesisSeedParentBlock <= block.number) {
            revert GenesisSeedNotFuture(genesisSeedParentBlock, block.number);
        }

        uint256 earliestGenesisSeed = block.number + genesisSeedMinimumDelay;
        if (genesisSeedParentBlock < earliestGenesisSeed) {
            revert GenesisSeedTooSoon(genesisSeedParentBlock, earliestGenesisSeed);
        }

        MIN_TARGET = minTarget;
        MAX_TARGET = maxTarget;
        GENESIS_TARGET = genesisTarget;
        GENESIS_SEED_PARENT_BLOCK = genesisSeedParentBlock;
        GENESIS_SEED_MINIMUM_DELAY = genesisSeedMinimumDelay;
        MINING_STOP_MULTISIG = miningStopMultisig;
        MINING_STOP_SUNSET = miningStopSunset;

        activeChallengeId = INITIAL_CHALLENGE_ID;
        activeSeedParentBlock = genesisSeedParentBlock;
        previousAcceptedDigest = GENESIS_PREVIOUS_ACCEPTED_DIGEST;
        currentTarget = genesisTarget;
        // Ticket 05 simulator lines 703-706 start both samples at its block-zero origin.
        // The deployment block is the onchain equivalent for the first window and stall.
        retargetWindowStartBlock = block.number;
        lastProofBlock = block.number;
        lastEaseBlock = block.number;

        PROOF_NFT = _deployProofNft(proofNftDeployment);

        // The decided 250-block stall interval is inside the 256-block seed life. The deployment
        // proof must separately show that its chosen genesis delay leaves the intended room.
    }

    function _deployProofNft(ProofNftDeploymentData memory deployment) private returns (HunterNFT) {
        return new HunterNFT(
            deployment.registry,
            deployment.lifecycle,
            deployment.artVersion,
            deployment.royaltyRecipient,
            deployment.baseURI
        );
    }

    /// @notice Returns the state derived from the parent-block estimate and current seed.
    function challengeState() public view returns (ChallengeState) {
        if (miningStopped) return ChallengeState.STOPPED;
        if (nftsMintedEver >= MAX_NFTS_EVER) return ChallengeState.ENDED;
        uint256 seedParentBlock = activeSeedParentBlock;
        if (block.number <= seedParentBlock) return ChallengeState.WAITING_FOR_SEED;
        if (block.number - seedParentBlock > SEED_READABLE_PARENT_BLOCKS) return ChallengeState.EXPIRED;
        if (blockhash(seedParentBlock) == bytes32(0)) return ChallengeState.WAITING_FOR_SEED;
        return ChallengeState.ACTIVE;
    }

    /// @notice Derives the current active challenge from authoritative contract state.
    function currentChallenge() public view returns (bytes32) {
        bytes32 seedBlockhash = _activeSeedBlockhash();
        return deriveChallenge(activeChallengeId, previousAcceptedDigest, activeSeedParentBlock, seedBlockhash);
    }

    /// @notice Reproduces the canonical Rust `challenge_preimage` encoding.
    function deriveChallenge(
        uint256 challengeId,
        bytes32 priorAcceptedDigest,
        uint256 seedParentBlock,
        bytes32 seedBlockhash
    ) public view returns (bytes32) {
        return keccak256(
            abi.encode(
                CHALLENGE_TYPEHASH,
                block.chainid,
                address(this),
                PROOF_VERSION,
                challengeId,
                priorAcceptedDigest,
                seedParentBlock,
                seedBlockhash
            )
        );
    }

    /// @notice Reproduces the canonical Rust `proof_preimage` encoding for a wallet-bound proof.
    function deriveProofDigest(uint256 challengeId, bytes32 challenge, address miner, uint256 nonce)
        public
        view
        returns (bytes32)
    {
        return keccak256(
            abi.encode(
                PROOF_TYPEHASH, block.chainid, address(this), PROOF_VERSION, challengeId, challenge, miner, nonce
            )
        );
    }

    /// @notice Accepts one proof for the expected active challenge and schedules its successor.
    function submitProof(uint256 expectedChallengeId, uint256 expectedSeedParentBlock, uint256 nonce, address basket)
        external
        nonReentrant
        returns (bytes32 digest)
    {
        if (challengeState() != ChallengeState.ACTIVE) revert ChallengeNotActive(challengeState());
        if (expectedChallengeId != activeChallengeId) {
            revert StaleChallengeId(expectedChallengeId, activeChallengeId);
        }
        if (expectedSeedParentBlock != activeSeedParentBlock) {
            revert StaleSeedBlock(expectedSeedParentBlock, activeSeedParentBlock);
        }

        AcceptedProofData memory proof;
        proof.miner = msg.sender;
        proof.challengeId = activeChallengeId;
        proof.seedParentBlock = activeSeedParentBlock;
        proof.nonce = nonce;
        proof.acceptedTarget = currentTarget;
        proof.challenge =
            deriveChallenge(proof.challengeId, previousAcceptedDigest, proof.seedParentBlock, _activeSeedBlockhash());
        proof.digest = deriveProofDigest(proof.challengeId, proof.challenge, proof.miner, proof.nonce);
        digest = proof.digest;
        uint256 effectiveTarget = proof.acceptedTarget;
        if (address(miningPower) != address(0)) {
            uint256 mult = miningPower.powerMultiplierWad(proof.challengeId, proof.miner);
            effectiveTarget = _effectiveTarget(proof.acceptedTarget, mult);
        }
        if (uint256(proof.digest) > effectiveTarget) revert InvalidProof(proof.digest, effectiveTarget);

        ProofSettlementData memory settlement = _prepareSettlement(proof.digest, proof.acceptedTarget);
        // Power may accept a digest outside the base target. Every accepted proof
        // still mints exactly one NFT; the bonus window is the outer (common) band.
        if (settlement.proofTier == 0) {
            settlement.proofTier = PROOF_TIER_COMMON;
        }

        acceptedProofs += 1;
        nftsMintedEver += 1;
        previousAcceptedDigest = proof.digest;
        lastProofBlock = block.number;

        _recordAcceptedProofForRetarget();

        if (address(miningPower) != address(0)) {
            miningPower.onProofAccepted(acceptedProofs);
        }

        bool ended = nftsMintedEver >= MAX_NFTS_EVER;
        if (!ended) {
            activeChallengeId = proof.challengeId + 1;
            activeSeedParentBlock = block.number + SEED_DELAY_PARENT_BLOCKS;
            if (address(miningPower) != address(0)) {
                miningPower.snapshotChallenge(activeChallengeId);
            }
        } else {
            // Mint-out is terminal: no more proof callbacks can arrive, so the
            // module's unlock clock is frozen. Retire it so assigners can exit.
            _retireMiningPower(true);
        }

        settlement.proofNftTokenId = _mintProofAssets(proof, settlement, basket);
        _emitProofAccepted(proof, settlement, basket, ended);
    }

    function _prepareSettlement(bytes32 digest, uint256 acceptedTarget)
        private
        pure
        returns (ProofSettlementData memory settlement)
    {
        (, settlement.proofTier) = _classifyProof(digest, acceptedTarget);
    }

    function _mintProofAssets(AcceptedProofData memory proof, ProofSettlementData memory settlement, address basket)
        private
        returns (uint256)
    {
        // The submitting wallet selects the basket and receives its NFT. The new
        // calldata selector is intentional; PoW encoding remains wallet-bound v1.
        return PROOF_NFT.mint(proof.miner, proof.digest, proof.challengeId, settlement.proofTier, basket);
    }

    function _emitProofAccepted(
        AcceptedProofData memory proof,
        ProofSettlementData memory settlement,
        address basket,
        bool ended
    ) private {
        emit ProofAccepted(
            proof.miner,
            proof.challengeId,
            proof.digest,
            proof.seedParentBlock,
            proof.challenge,
            proof.nonce,
            proof.acceptedTarget,
            activeChallengeId,
            activeSeedParentBlock,
            currentTarget,
            ended
        );
        emit ProofNftMinted(
            proof.miner, settlement.proofNftTokenId, proof.challengeId, proof.digest, settlement.proofTier, basket
        );
    }

    /// @notice Classifies an accepted digest against the target snapshot that accepted it.
    function _classifyProof(bytes32 digest, uint256 acceptedTarget)
        internal
        pure
        returns (bool isNftProof, uint8 proofTier)
    {
        uint256 digestValue = uint256(digest);
        uint256 nftThreshold = acceptedTarget;
        if (digestValue > nftThreshold) return (false, 0);

        if (digestValue <= _legendaryThreshold(nftThreshold)) {
            return (true, PROOF_TIER_LEGENDARY);
        }
        if (digestValue <= Math.mulDiv(nftThreshold, RARE_TIER_NUMERATOR, TIER_BAND_DENOMINATOR)) {
            return (true, PROOF_TIER_RARE);
        }
        if (digestValue <= Math.mulDiv(nftThreshold, UNCOMMON_TIER_NUMERATOR, TIER_BAND_DENOMINATOR)) {
            return (true, PROOF_TIER_UNCOMMON);
        }
        return (true, PROOF_TIER_COMMON);
    }

    function _legendaryThreshold(uint256 nftThreshold) private pure returns (uint256) {
        return Math.mulDiv(nftThreshold, LEGENDARY_TIER_NUMERATOR, TIER_BAND_DENOMINATOR);
    }

    /// @dev Widen `acceptedTarget` by a 1.0×–3.0× multiplier and saturate at MAX_TARGET.
    function _effectiveTarget(uint256 acceptedTarget, uint256 multiplierWad) internal view returns (uint256) {
        if (multiplierWad <= POWER_BASE_WAD) return acceptedTarget;
        uint256 mult = multiplierWad > MAX_POWER_MULTIPLIER_WAD ? MAX_POWER_MULTIPLIER_WAD : multiplierWad;
        uint256 maxSafe = Math.mulDiv(MAX_TARGET, POWER_BASE_WAD, mult);
        uint256 widened = acceptedTarget >= maxSafe ? MAX_TARGET : Math.mulDiv(acceptedTarget, mult, POWER_BASE_WAD);
        return widened > MAX_TARGET ? MAX_TARGET : widened;
    }

    /// @notice Wires Mining Power. Same caller and sunset as `stopMining`.
    /// @dev After sunset, STOPPED, or mint-out the module cannot be changed. A live
    /// module must first be detached by passing the zero address — replacing it
    /// directly would silently reset every power snapshot mid-challenge. This
    /// does not verify that `power` is a honest Mining Power implementation.
    /// A nonzero attach also consumes `miningPowerWasAttached`: the late
    /// activation path exists only for a module that was never attached.
    function setMiningPower(IMiningPower power) external nonReentrant {
        if (msg.sender != MINING_STOP_MULTISIG) revert UnauthorizedMiningStopCaller(msg.sender);
        uint256 timestamp = block.timestamp;
        if (timestamp > MINING_STOP_SUNSET) revert MiningStopSunsetPassed(MINING_STOP_SUNSET, timestamp);
        if (miningStopped) revert MiningAlreadyStopped();
        if (nftsMintedEver >= MAX_NFTS_EVER) revert ChallengeNotActive(ChallengeState.ENDED);
        if (address(power) != address(0) && address(miningPower) != address(0)) {
            revert MiningPowerAlreadyWired(address(miningPower));
        }
        _retireMiningPower(false);
        miningPower = power;
        if (address(power) != address(0)) {
            miningPowerWasAttached = true;
            power.snapshotChallenge(activeChallengeId);
            // A fresh module starts its unlock-delay clock at zero; sync it to
            // the real proof count so early assigners cannot skip the delay.
            power.onProofAccepted(acceptedProofs);
        }
        emit MiningPowerSet(address(power), msg.sender);
    }

    /// @notice One-time late attachment of the canonical Mining Power custody
    /// for a HUNTER token that did not exist at deployment. Independent of the
    /// stop sunset — but it is NOT a second wiring surface: it fires at most
    /// once ever, only while no module has ever been attached, and only for
    /// the reserve's recorded canonical token.
    /// @dev Authorization is the reserve's fixed TOKEN_AUTHORITY (the same
    /// launch account that recorded the token), reached through the immutable
    /// wiring chain NFT -> lifecycle -> reserve — never a caller-supplied
    /// address, so the sunsetted stop multisig gains no post-sunset power and
    /// no substitute "canonical" source can be injected. The module must be a
    /// fresh MiningPowerCustody bound to this core and to the exact canonical
    /// token. Stopped and minted-out cores cannot attach: a late module must
    /// never revive terminal mining or be installed uselessly. The bonus can
    /// never reach the already-open challenge — the module's own pending-bucket
    /// accounting matures assignments only from the next snapshot.
    function attachMiningPowerLate(MiningPowerCustody power) external nonReentrant {
        if (miningPowerWasAttached) revert MiningPowerAlreadyAttached();
        if (miningStopped) revert MiningAlreadyStopped();
        if (nftsMintedEver >= MAX_NFTS_EVER) revert ChallengeNotActive(ChallengeState.ENDED);

        IHunterTokenActivationSource source = _canonicalReserve();
        IERC20 canonical;
        address authority;
        try source.HUNTER() returns (IERC20 recorded) {
            canonical = recorded;
        } catch {
            revert InvalidCanonicalReserve();
        }
        try source.TOKEN_AUTHORITY() returns (address recorded) {
            authority = recorded;
        } catch {
            revert InvalidCanonicalReserve();
        }
        if (address(canonical) == address(0)) revert CanonicalTokenNotActivated();
        if (msg.sender != authority) revert UnauthorizedMiningPowerActivation(msg.sender);

        if (address(power) == address(0) || address(power).code.length == 0) revert InvalidMiningPowerModule();
        if (power.miningCore() != address(this)) revert MiningPowerCoreMismatch(address(this), power.miningCore());
        if (address(power.HUNTER()) != address(canonical)) {
            revert MiningPowerTokenMismatch(address(canonical), address(power.HUNTER()));
        }
        if (power.curveUnit() == 0 || power.wired() || power.totalAssigned() != 0) {
            revert InvalidMiningPowerModule();
        }

        miningPowerWasAttached = true;
        miningPower = power;
        power.snapshotChallenge(activeChallengeId);
        power.onProofAccepted(acceptedProofs);
        emit MiningPowerSet(address(power), msg.sender);
    }

    /// @dev The canonical reserve is derived, never supplied: PROOF_NFT's fixed
    /// lifecycle exposes `reserve()`, which must have code and be bound to this
    /// core's NFT. Any break in that chain is an invalid-source failure, not an
    /// opportunity to substitute another token or authority.
    function _canonicalReserve() private view returns (IHunterTokenActivationSource source) {
        try IReserveBoundLifecycle(address(PROOF_NFT.LIFECYCLE())).reserve() returns (address reserve_) {
            if (reserve_.code.length == 0) revert InvalidCanonicalReserve();
            source = IHunterTokenActivationSource(reserve_);
        } catch {
            revert InvalidCanonicalReserve();
        }
        try source.NFT() returns (HunterNFT bound) {
            if (address(bound) != address(PROOF_NFT)) revert InvalidCanonicalReserve();
        } catch {
            revert InvalidCanonicalReserve();
        }
    }

    /// @notice Permanently stops mining when called by the configured guardian before its sunset.
    /// @dev The inherited configuration rules do not verify a multisig implementation.
    function stopMining() external nonReentrant {
        if (msg.sender != MINING_STOP_MULTISIG) revert UnauthorizedMiningStopCaller(msg.sender);
        uint256 timestamp = block.timestamp;
        if (timestamp > MINING_STOP_SUNSET) revert MiningStopSunsetPassed(MINING_STOP_SUNSET, timestamp);
        if (miningStopped) revert MiningAlreadyStopped();
        if (nftsMintedEver >= MAX_NFTS_EVER) revert ChallengeNotActive(ChallengeState.ENDED);

        _stopMining(StopCause.KEYED, timestamp);
    }

    /// @notice Permanently stops mining only when a lifetime issuance counter is already violated.
    function tripMining() external nonReentrant {
        if (miningStopped) revert MiningAlreadyStopped();

        uint256 nftMints = PROOF_NFT.mintedEver();
        if (acceptedProofs == nftsMintedEver && nftMints == nftsMintedEver && nftsMintedEver <= MAX_NFTS_EVER) {
            revert NoMiningCounterViolation(acceptedProofs, nftsMintedEver, nftMints);
        }

        _stopMining(StopCause.COUNTER_VIOLATION, block.timestamp);
    }

    function _stopMining(StopCause cause, uint256 timestamp) private {
        miningStopped = true;
        // A stop is terminal like mint-out: retire the module so its frozen
        // unlock clock cannot strand assigned stake.
        _retireMiningPower(true);
        emit MiningStopped(address(this), cause, msg.sender, timestamp);
    }

    /// @dev Best-effort detach notice for the wired module. `terminal` is true
    /// when mining can never produce another proof — the module may then waive
    /// its unlock delay; a non-terminal detach (replacement) must keep it
    /// honest so stake cannot hop custodies early. A module that lacks the hook
    /// or reverts must not block detach or shutdown — failure is logged
    /// instead of swallowed silently.
    function _retireMiningPower(bool terminal) private {
        if (address(miningPower) == address(0)) return;
        try miningPower.onMiningPowerDetached(terminal) {}
        catch {
            emit MiningPowerDetachHookFailed(address(miningPower));
        }
    }

    /// @notice Advances an expired challenge to another caller-independent future seed.
    function refreshExpiredSeed() external nonReentrant {
        ChallengeState state = challengeState();
        if (state == ChallengeState.ENDED || state == ChallengeState.STOPPED) revert ChallengeNotActive(state);

        uint256 expiredSeedParentBlock = activeSeedParentBlock;
        if (
            block.number <= expiredSeedParentBlock
                || block.number - expiredSeedParentBlock <= SEED_READABLE_PARENT_BLOCKS
        ) revert SeedNotExpired(expiredSeedParentBlock, block.number);

        uint256 expiredChallengeId = activeChallengeId;
        activeChallengeId = expiredChallengeId + 1;
        activeSeedParentBlock = block.number + SEED_DELAY_PARENT_BLOCKS;

        if (address(miningPower) != address(0)) {
            miningPower.snapshotChallenge(activeChallengeId);
        }

        emit SeedRefreshed(expiredChallengeId, activeChallengeId, expiredSeedParentBlock, activeSeedParentBlock);
    }

    /// @notice Permissionlessly eases an active challenge after a complete no-proof stall interval.
    function easeDifficulty() external nonReentrant {
        ChallengeState state = challengeState();
        if (state != ChallengeState.ACTIVE) revert ChallengeNotActive(state);
        if (currentTarget == MAX_TARGET) revert DifficultyAtMaximum();

        uint256 referenceBlock = lastProofBlock > lastEaseBlock ? lastProofBlock : lastEaseBlock;
        uint256 earliestEaseBlock = referenceBlock + STALL_INTERVAL_PARENT_BLOCKS;
        if (block.number < earliestEaseBlock) {
            revert DifficultyStallIntervalNotMet(earliestEaseBlock, block.number);
        }

        uint256 oldTarget = currentTarget;
        uint256 maxTargetThreshold = Math.mulDiv(MAX_TARGET, EASE_DENOMINATOR, EASE_NUMERATOR, Math.Rounding.Ceil);
        uint256 newTarget =
            oldTarget >= maxTargetThreshold ? MAX_TARGET : Math.mulDiv(oldTarget, EASE_NUMERATOR, EASE_DENOMINATOR);

        currentTarget = newTarget;
        lastEaseBlock = block.number;
        retargetWindowProofs = 0;
        retargetWindowStartBlock = block.number;

        emit DifficultyEased(msg.sender, oldTarget, newTarget, block.number);
    }

    function _activeSeedBlockhash() private view returns (bytes32 seedBlockhash) {
        ChallengeState state = challengeState();
        if (state != ChallengeState.ACTIVE) revert ChallengeNotActive(state);
        seedBlockhash = blockhash(activeSeedParentBlock);
        if (seedBlockhash == bytes32(0)) revert SeedBlockhashUnavailable(activeSeedParentBlock);
    }

    function _recordAcceptedProofForRetarget() private {
        uint256 proofsInWindow = retargetWindowProofs + 1;
        if (proofsInWindow < RETARGET_WINDOW_PROOFS) {
            retargetWindowProofs = proofsInWindow;
            return;
        }

        uint256 oldTarget = currentTarget;
        uint256 actualParentBlocks = block.number - retargetWindowStartBlock;
        (uint256 newTarget, uint256 observedParentBlocks) = _calculateRetarget(oldTarget, actualParentBlocks);

        currentTarget = newTarget;
        retargetWindowProofs = 0;
        retargetWindowStartBlock = block.number;

        emit DifficultyRetargeted(acceptedProofs, oldTarget, newTarget, actualParentBlocks, observedParentBlocks);
    }

    function _calculateRetarget(uint256 oldTarget, uint256 actualParentBlocks)
        internal
        view
        returns (uint256 newTarget, uint256 observedParentBlocks)
    {
        observedParentBlocks =
            Math.max(MIN_OBSERVED_PARENT_BLOCKS, Math.min(actualParentBlocks, MAX_OBSERVED_PARENT_BLOCKS));
        if (observedParentBlocks > EXPECTED_RETARGET_PARENT_BLOCKS) {
            uint256 maxTargetThreshold =
                Math.mulDiv(MAX_TARGET, EXPECTED_RETARGET_PARENT_BLOCKS, observedParentBlocks, Math.Rounding.Ceil);
            if (oldTarget >= maxTargetThreshold) return (MAX_TARGET, observedParentBlocks);
        }

        newTarget = Math.mulDiv(oldTarget, observedParentBlocks, EXPECTED_RETARGET_PARENT_BLOCKS);
        newTarget = Math.max(MIN_TARGET, Math.min(newTarget, MAX_TARGET));
    }
}
