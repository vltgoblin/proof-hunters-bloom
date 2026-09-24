// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ILiveHuntNFT} from "./ILiveHuntNFT.sol";

/// @title Proof Hunters Live Hunt module
/// @notice Records fully funded ETH offers and pays all owed ETH through pull credits.
contract LiveHunt is IERC721Receiver, ReentrancyGuard {
    error InvalidMinimumOffer(uint256 supplied);
    error InvalidMinimumHuntDuration(uint256 supplied);
    error InvalidMaximumHuntDuration(uint256 supplied);
    error InvalidFeeRate(uint256 supplied);
    error InvalidMaximumFeeRate(uint256 supplied);
    error FeeRateExceedsMaximum(uint256 feeBps, uint256 maxFeeBps);
    error InvalidFeeRecipient(address supplied);
    error OfferBelowMinimum(uint256 supplied, uint256 minimum);
    error HuntDurationOutOfBounds(uint256 supplied, uint256 minimum, uint256 maximum);
    error InvalidCriteria();
    error HuntDoesNotExist(uint256 huntId);
    error HuntNotOpen(uint256 huntId, HuntStatus status);
    error NotHuntCollector(address caller, uint256 huntId, address collector);
    error NoCredit(address account);
    error FeeRecipientClaimBlockedDuringShortfall();
    error EthTransferFailed(address account, uint256 amount);
    error UnauthorizedProofNftCaller(address caller);
    error FillInitiatedByOperator(address operator, address owner);
    error TokenReleasedThisTransaction(uint256 tokenId);
    error SelfFill(address owner, uint256 huntId);
    error HuntExpired(uint256 huntId, uint256 deadline);
    error CriteriaMismatch(uint256 huntId, uint256 tokenId);
    error InvalidModuleStopMultisig(address supplied, address deployingAccount);
    error InvalidModuleStopSunset(uint256 supplied, uint256 earliestAllowed, uint256 latestAllowed);
    error UnauthorizedModuleStopCaller(address caller);
    error ModuleStopSunsetPassed(uint256 sunset, uint256 currentTimestamp);
    error EntryAlreadyStopped();
    error EntryIsStopped();
    error NoShortfall(uint256 balance, uint256 recordedLiabilities);

    enum HuntStatus {
        Open,
        Filled,
        Cancelled
    }

    enum StopCause {
        KEYED,
        SHORTFALL
    }

    struct Hunt {
        uint256 id;
        address collector;
        uint256 offer;
        uint256 createdAt;
        uint256 deadline;
        HuntStatus status;
        uint256 criteria;
    }

    struct Criteria {
        uint256 tierMask;
        uint256 artVersion;
        uint256 faceFamilyMask;
        uint256 ageMask;
        uint256 hairOrHeadwearMask;
        uint256 eyesAndBrowsMask;
        uint256 noseMask;
        uint256 mouthMask;
        uint256 faceDetailMask;
        uint256 earDetailMask;
        uint256 eyewearMask;
        uint256 hoodShellMask;
        uint256 hoodLiningMask;
        uint256 signalMask;
        uint256 deepMask;
        uint256 apexMask;
    }

    uint256 public constant FEE_DENOMINATOR = 10_000;
    bytes32 public constant BIRTH_TYPEHASH = 0x2b141cf79819efe2ca06c649f4e26b57cd017a0d356821a7ab879fff7e749e46;
    bytes32 public constant TRAIT_TYPEHASH = 0xd12a2a5075494eab11277e33f55b50fec2f4dba7b80510cad896f000f422e5dd;

    uint256 private constant _MIN_OFFER_LOWER_BOUND = 0.005 ether;
    uint256 private constant _MIN_OFFER_UPPER_BOUND = 0.05 ether;
    uint256 private constant _MIN_DURATION_LOWER_BOUND = 1 days;
    uint256 private constant _MIN_DURATION_UPPER_BOUND = 7 days;
    uint256 private constant _MAX_DURATION_LOWER_BOUND = 90 days;
    uint256 private constant _MAX_DURATION_UPPER_BOUND = 900 days;
    uint256 private constant _FEE_BPS_UPPER_BOUND = 500;
    uint256 private constant _MAX_FEE_BPS_LOWER_BOUND = 500;
    uint256 private constant _MAX_FEE_BPS_UPPER_BOUND = 2_000;
    uint256 private constant _MODULE_STOP_SUNSET_MIN_DELAY = 360 days;
    uint256 private constant _MODULE_STOP_SUNSET_MAX_DELAY = 730 days;

    // Ticket 21 section 3.6 fixes one 124-bit criteria word in this order:
    // tier (4), art version (32), Face Family (6), Age (4), Hair or Headwear (10),
    // Eyes and Brows (6), Nose (6), Mouth (7), Face Detail (6), Ear Detail (5),
    // Eyewear value (5), Hood Shell (8), Hood Lining (9), Signal (6), Deep (6), Apex (4).
    uint256 private constant _ART_VERSION_OFFSET = 4;
    uint256 private constant _FACE_FAMILY_OFFSET = 36;
    uint256 private constant _AGE_OFFSET = 42;
    uint256 private constant _HAIR_OR_HEADWEAR_OFFSET = 46;
    uint256 private constant _EYES_AND_BROWS_OFFSET = 56;
    uint256 private constant _NOSE_OFFSET = 62;
    uint256 private constant _MOUTH_OFFSET = 68;
    uint256 private constant _FACE_DETAIL_OFFSET = 75;
    uint256 private constant _EAR_DETAIL_OFFSET = 81;
    uint256 private constant _EYEWEAR_OFFSET = 86;
    uint256 private constant _HOOD_SHELL_OFFSET = 91;
    uint256 private constant _HOOD_LINING_OFFSET = 99;
    uint256 private constant _SIGNAL_OFFSET = 108;
    uint256 private constant _DEEP_OFFSET = 114;
    uint256 private constant _APEX_OFFSET = 120;
    uint256 private constant _V1_ART_VERSION = 1;
    uint256 private constant _UNCOMMON_TIER_MASK = 1 << 1;
    uint256 private constant _RARE_TIER_MASK = 1 << 2;
    uint256 private constant _LEGENDARY_TIER_MASK = 1 << 3;

    uint16 internal constant _FACE_FAMILY_TRAIT_ID = 1;
    uint16 internal constant _AGE_TRAIT_ID = 3;
    uint16 internal constant _HAIR_OR_HEADWEAR_TRAIT_ID = 4;
    uint16 internal constant _EYES_AND_BROWS_TRAIT_ID = 5;
    uint16 internal constant _NOSE_TRAIT_ID = 6;
    uint16 internal constant _MOUTH_TRAIT_ID = 7;
    uint16 internal constant _FACE_DETAIL_TRAIT_ID = 8;
    uint16 internal constant _EAR_DETAIL_TRAIT_ID = 9;
    uint16 internal constant _EYEWEAR_TRAIT_ID = 10;
    uint16 internal constant _HOOD_SHELL_TRAIT_ID = 11;
    uint16 internal constant _HOOD_LINING_TRAIT_ID = 12;
    uint16 internal constant _SIGNAL_TRAIT_ID = 14;
    uint16 internal constant _DEEP_TRAIT_ID = 15;
    uint16 internal constant _APEX_TRAIT_ID = 16;

    ILiveHuntNFT public immutable PROOF_NFT;
    uint256 public immutable MIN_OFFER;
    uint256 public immutable MIN_HUNT_DURATION;
    uint256 public immutable MAX_HUNT_DURATION;
    uint256 public immutable FEE_BPS;
    uint256 public immutable MAX_FEE_BPS;
    address public immutable FEE_RECIPIENT;
    address public immutable MODULE_STOP_MULTISIG;
    uint256 public immutable MODULE_STOP_SUNSET;

    mapping(uint256 huntId => Hunt record) public hunts;
    mapping(address account => uint256 amount) private _credits;

    uint256 public totalEscrowed;
    uint256 public totalCredited;
    bool public entryStopped;

    uint256 private _nextHuntId = 1;

    event HuntCreated(
        uint256 indexed huntId,
        address indexed collector,
        uint256 offer,
        uint256 createdAt,
        uint256 deadline,
        HuntStatus status,
        uint256 criteria
    );
    event HuntWithdrawn(
        uint256 indexed huntId, address indexed collector, uint256 offer, HuntStatus status, bool deadlinePassed
    );
    event HuntFilled(
        uint256 indexed huntId,
        address indexed collector,
        uint256 offer,
        HuntStatus status,
        uint256 indexed tokenId,
        address owner,
        uint256 proceeds,
        uint256 fee
    );
    event CreditClaimed(address indexed account, uint256 amount);
    event EntryStopped(address indexed module, StopCause indexed cause, address indexed caller, uint256 timestamp);

    constructor(
        ILiveHuntNFT proofNft,
        uint256 minOffer,
        uint256 minHuntDuration,
        uint256 maxHuntDuration,
        uint256 feeBps,
        uint256 maxFeeBps,
        address feeRecipient,
        address moduleStopMultisig,
        uint256 moduleStopSunset
    ) {
        if (minOffer < _MIN_OFFER_LOWER_BOUND || minOffer > _MIN_OFFER_UPPER_BOUND) {
            revert InvalidMinimumOffer(minOffer);
        }
        if (minHuntDuration < _MIN_DURATION_LOWER_BOUND || minHuntDuration > _MIN_DURATION_UPPER_BOUND) {
            revert InvalidMinimumHuntDuration(minHuntDuration);
        }
        if (maxHuntDuration < _MAX_DURATION_LOWER_BOUND || maxHuntDuration > _MAX_DURATION_UPPER_BOUND) {
            revert InvalidMaximumHuntDuration(maxHuntDuration);
        }
        if (feeBps > maxFeeBps || maxFeeBps >= FEE_DENOMINATOR) {
            revert FeeRateExceedsMaximum(feeBps, maxFeeBps);
        }
        if (feeBps > _FEE_BPS_UPPER_BOUND) revert InvalidFeeRate(feeBps);
        if (maxFeeBps < _MAX_FEE_BPS_LOWER_BOUND || maxFeeBps > _MAX_FEE_BPS_UPPER_BOUND) {
            revert InvalidMaximumFeeRate(maxFeeBps);
        }
        if (feeRecipient == address(0) || feeRecipient == address(this) || feeRecipient == msg.sender) {
            revert InvalidFeeRecipient(feeRecipient);
        }
        if (moduleStopMultisig == address(0) || moduleStopMultisig == msg.sender) {
            revert InvalidModuleStopMultisig(moduleStopMultisig, msg.sender);
        }

        // The inclusive 360-to-730-day union covers every plausible reading of the recorded
        // 12-to-24-month range. These bounds catch deployment typos; they do not choose the
        // owner's launch value. The wider ten-day edge cannot admit a realistic typo, while a
        // narrower edge could reject a legitimate launch choice.
        uint256 earliestModuleStopSunset = block.timestamp + _MODULE_STOP_SUNSET_MIN_DELAY;
        uint256 latestModuleStopSunset = block.timestamp + _MODULE_STOP_SUNSET_MAX_DELAY;
        if (moduleStopSunset < earliestModuleStopSunset || moduleStopSunset > latestModuleStopSunset) {
            revert InvalidModuleStopSunset(moduleStopSunset, earliestModuleStopSunset, latestModuleStopSunset);
        }

        PROOF_NFT = proofNft;
        MIN_OFFER = minOffer;
        MIN_HUNT_DURATION = minHuntDuration;
        MAX_HUNT_DURATION = maxHuntDuration;
        FEE_BPS = feeBps;
        MAX_FEE_BPS = maxFeeBps;
        FEE_RECIPIENT = feeRecipient;
        MODULE_STOP_MULTISIG = moduleStopMultisig;
        MODULE_STOP_SUNSET = moduleStopSunset;
    }

    /// @notice Returns the complete entry-only stoppable set.
    function pausableSelectors() external pure returns (bytes4[2] memory selectors) {
        selectors[0] = LiveHunt.createHunt.selector;
        selectors[1] = IERC721Receiver.onERC721Received.selector;
    }

    /// @notice Permanently closes entry when called by the recorded key before its sunset.
    function stopEntry() external nonReentrant {
        if (msg.sender != MODULE_STOP_MULTISIG) revert UnauthorizedModuleStopCaller(msg.sender);
        // Ticket 22 fixes module sunsets to the block timestamp and no other clock.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > MODULE_STOP_SUNSET) {
            revert ModuleStopSunsetPassed(MODULE_STOP_SUNSET, block.timestamp);
        }
        if (entryStopped) revert EntryAlreadyStopped();

        entryStopped = true;
        emit EntryStopped(address(this), StopCause.KEYED, msg.sender, block.timestamp);
    }

    /// @notice Permanently closes entry only when recorded ETH liabilities exceed the held balance.
    function assertBacked() external nonReentrant {
        if (entryStopped) revert EntryAlreadyStopped();

        uint256 recordedLiabilities = totalEscrowed + totalCredited;
        uint256 balance = address(this).balance;
        if (balance >= recordedLiabilities) revert NoShortfall(balance, recordedLiabilities);

        entryStopped = true;
        emit EntryStopped(address(this), StopCause.SHORTFALL, msg.sender, block.timestamp);
    }

    function createHunt(Criteria calldata criteria, uint256 duration)
        external
        payable
        nonReentrant
        returns (uint256 huntId)
    {
        _requireEntryOpen();
        if (msg.value < MIN_OFFER) revert OfferBelowMinimum(msg.value, MIN_OFFER);
        if (duration < MIN_HUNT_DURATION || duration > MAX_HUNT_DURATION) {
            revert HuntDurationOutOfBounds(duration, MIN_HUNT_DURATION, MAX_HUNT_DURATION);
        }
        uint256 criteriaWord = _validateAndPackCriteria(criteria);

        huntId = _nextHuntId;
        _nextHuntId = huntId + 1;

        uint256 createdAt = block.timestamp;
        uint256 deadline = createdAt + duration;
        hunts[huntId] = Hunt({
            id: huntId,
            collector: msg.sender,
            offer: msg.value,
            createdAt: createdAt,
            deadline: deadline,
            status: HuntStatus.Open,
            criteria: criteriaWord
        });
        totalEscrowed += msg.value;

        emit HuntCreated(huntId, msg.sender, msg.value, createdAt, deadline, HuntStatus.Open, criteriaWord);
    }

    function withdrawOffer(uint256 huntId) public nonReentrant {
        _withdrawOffer(huntId);
    }

    /// @notice Ticket 22's convenience wrapper; it adds no authority or payment destination.
    function withdrawOfferAndClaim(uint256 huntId) external {
        withdrawOffer(huntId);
        claim();
    }

    function credit(address account) external view returns (uint256) {
        return _credits[account];
    }

    /// @notice Returns the same immutable birth-data match answer used by settlement.
    function matches(uint256 tokenId, uint256 huntId) external view returns (bool) {
        (uint32 artVersion, bytes32 proofDigest, uint256 challengeId, uint8 proofTier) = PROOF_NFT.birthData(tokenId);
        return _matchesBirthData(artVersion, proofDigest, challengeId, proofTier, hunts[huntId].criteria);
    }

    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        nonReentrant
        returns (bytes4)
    {
        if (msg.sender != address(PROOF_NFT)) revert UnauthorizedProofNftCaller(msg.sender);
        _requireEntryOpen();

        uint256 huntId = abi.decode(data, (uint256));
        if (operator != from) revert FillInitiatedByOperator(operator, from);
        if (PROOF_NFT.wasReleasedThisTransaction(tokenId)) revert TokenReleasedThisTransaction(tokenId);

        Hunt storage record = hunts[huntId];
        if (huntId == 0 || record.id != huntId) revert HuntDoesNotExist(huntId);
        if (record.status != HuntStatus.Open) revert HuntNotOpen(huntId, record.status);
        if (from == record.collector) revert SelfFill(from, huntId);
        // Ticket 22 fixes module deadlines to the block timestamp and no other clock.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > record.deadline) revert HuntExpired(huntId, record.deadline);

        _requireMatch(tokenId, huntId, record.criteria);
        _settle(record, huntId, tokenId, from);
        return IERC721Receiver.onERC721Received.selector;
    }

    function claim() public nonReentrant {
        uint256 amount = _credits[msg.sender];
        if (amount == 0) revert NoCredit(msg.sender);
        if (msg.sender == FEE_RECIPIENT && address(this).balance < totalEscrowed + totalCredited) {
            revert FeeRecipientClaimBlockedDuringShortfall();
        }

        _credits[msg.sender] = 0;
        totalCredited -= amount;

        (bool success,) = payable(msg.sender).call{value: amount}("");
        if (!success) revert EthTransferFailed(msg.sender, amount);

        emit CreditClaimed(msg.sender, amount);
    }

    function _withdrawOffer(uint256 huntId) private {
        Hunt storage record = hunts[huntId];
        if (huntId == 0 || record.id != huntId) revert HuntDoesNotExist(huntId);
        if (record.status != HuntStatus.Open) revert HuntNotOpen(huntId, record.status);
        if (msg.sender != record.collector) {
            revert NotHuntCollector(msg.sender, huntId, record.collector);
        }

        uint256 offer = record.offer;
        // Ticket 22 fixes module deadlines to the block timestamp and no other clock.
        // forge-lint: disable-next-line(block-timestamp)
        bool deadlinePassed = block.timestamp > record.deadline;

        record.status = HuntStatus.Cancelled;
        totalEscrowed -= offer;
        _credits[msg.sender] += offer;
        totalCredited += offer;

        emit HuntWithdrawn(huntId, msg.sender, offer, HuntStatus.Cancelled, deadlinePassed);
    }

    function _requireEntryOpen() private view {
        if (entryStopped) revert EntryIsStopped();
    }

    function _requireMatch(uint256 tokenId, uint256 huntId, uint256 criteriaWord) private view {
        (uint32 artVersion, bytes32 proofDigest, uint256 challengeId, uint8 proofTier) = PROOF_NFT.birthData(tokenId);
        if (!_matchesBirthData(artVersion, proofDigest, challengeId, proofTier, criteriaWord)) {
            revert CriteriaMismatch(huntId, tokenId);
        }
    }

    function _settle(Hunt storage record, uint256 huntId, uint256 tokenId, address owner) private {
        uint256 offer = record.offer;
        uint256 fee = Math.mulDiv(offer, FEE_BPS, FEE_DENOMINATOR);
        // The division truncates the fee. Subtraction sends every rounding remainder to the owner.
        uint256 proceeds = offer - fee;
        assert(proceeds + fee == offer);

        record.status = HuntStatus.Filled;
        totalEscrowed -= offer;
        _credits[owner] += proceeds;
        if (fee != 0) _credits[FEE_RECIPIENT] += fee;
        totalCredited += offer;

        emit HuntFilled(huntId, record.collector, offer, HuntStatus.Filled, tokenId, owner, proceeds, fee);

        PROOF_NFT.safeTransferFrom(address(this), record.collector, tokenId);
    }

    function _validateAndPackCriteria(Criteria calldata criteria) private pure returns (uint256 criteriaWord) {
        if (
            criteria.tierMask >= 1 << 4 || criteria.artVersion != _V1_ART_VERSION || criteria.faceFamilyMask >= 1 << 6
                || criteria.ageMask >= 1 << 4 || criteria.hairOrHeadwearMask >= 1 << 10
                || criteria.eyesAndBrowsMask >= 1 << 6 || criteria.noseMask >= 1 << 6 || criteria.mouthMask >= 1 << 7
                || criteria.faceDetailMask >= 1 << 6 || criteria.earDetailMask >= 1 << 5
                || criteria.eyewearMask >= 1 << 5 || criteria.hoodShellMask >= 1 << 8
                || criteria.hoodLiningMask >= 1 << 9 || criteria.signalMask >= 1 << 6 || criteria.deepMask >= 1 << 6
                || criteria.apexMask >= 1 << 4
        ) revert InvalidCriteria();

        if (criteria.signalMask != 0 && criteria.tierMask != _UNCOMMON_TIER_MASK) revert InvalidCriteria();
        if (criteria.deepMask != 0 && criteria.tierMask != _RARE_TIER_MASK) revert InvalidCriteria();
        if (criteria.apexMask != 0 && criteria.tierMask != _LEGENDARY_TIER_MASK) revert InvalidCriteria();

        criteriaWord = criteria.tierMask;
        criteriaWord |= criteria.artVersion << _ART_VERSION_OFFSET;
        criteriaWord |= criteria.faceFamilyMask << _FACE_FAMILY_OFFSET;
        criteriaWord |= criteria.ageMask << _AGE_OFFSET;
        criteriaWord |= criteria.hairOrHeadwearMask << _HAIR_OR_HEADWEAR_OFFSET;
        criteriaWord |= criteria.eyesAndBrowsMask << _EYES_AND_BROWS_OFFSET;
        criteriaWord |= criteria.noseMask << _NOSE_OFFSET;
        criteriaWord |= criteria.mouthMask << _MOUTH_OFFSET;
        criteriaWord |= criteria.faceDetailMask << _FACE_DETAIL_OFFSET;
        criteriaWord |= criteria.earDetailMask << _EAR_DETAIL_OFFSET;
        criteriaWord |= criteria.eyewearMask << _EYEWEAR_OFFSET;
        criteriaWord |= criteria.hoodShellMask << _HOOD_SHELL_OFFSET;
        criteriaWord |= criteria.hoodLiningMask << _HOOD_LINING_OFFSET;
        criteriaWord |= criteria.signalMask << _SIGNAL_OFFSET;
        criteriaWord |= criteria.deepMask << _DEEP_OFFSET;
        criteriaWord |= criteria.apexMask << _APEX_OFFSET;
    }

    function _matchesBirthData(
        uint32 artVersion,
        bytes32 proofDigest,
        uint256 challengeId,
        uint8 proofTier,
        uint256 criteriaWord
    ) internal pure returns (bool) {
        uint256 criteriaArtVersion = (criteriaWord >> _ART_VERSION_OFFSET) & type(uint32).max;
        if (uint256(artVersion) != criteriaArtVersion) return false;

        uint256 tierMask = criteriaWord & 0x0f;
        if (tierMask != 0) {
            if (proofTier == 0 || proofTier > 4 || tierMask & (2 ** (proofTier - 1)) == 0) return false;
        }

        bytes32 birthSeed = _birthSeed(artVersion, proofDigest, challengeId);
        return _matchesTrait(criteriaWord, _FACE_FAMILY_OFFSET, 6, birthSeed, _FACE_FAMILY_TRAIT_ID, 6)
            && _matchesTrait(criteriaWord, _AGE_OFFSET, 4, birthSeed, _AGE_TRAIT_ID, 4)
            && _matchesTrait(criteriaWord, _HAIR_OR_HEADWEAR_OFFSET, 10, birthSeed, _HAIR_OR_HEADWEAR_TRAIT_ID, 10)
            && _matchesTrait(criteriaWord, _EYES_AND_BROWS_OFFSET, 6, birthSeed, _EYES_AND_BROWS_TRAIT_ID, 6)
            && _matchesTrait(criteriaWord, _NOSE_OFFSET, 6, birthSeed, _NOSE_TRAIT_ID, 6)
            && _matchesTrait(criteriaWord, _MOUTH_OFFSET, 7, birthSeed, _MOUTH_TRAIT_ID, 7)
            && _matchesTrait(criteriaWord, _FACE_DETAIL_OFFSET, 6, birthSeed, _FACE_DETAIL_TRAIT_ID, 6)
            && _matchesTrait(criteriaWord, _EAR_DETAIL_OFFSET, 5, birthSeed, _EAR_DETAIL_TRAIT_ID, 5)
            && _matchesEyewear(criteriaWord, birthSeed)
            && _matchesTrait(criteriaWord, _HOOD_SHELL_OFFSET, 8, birthSeed, _HOOD_SHELL_TRAIT_ID, 8)
            && _matchesTrait(criteriaWord, _HOOD_LINING_OFFSET, 9, birthSeed, _HOOD_LINING_TRAIT_ID, 9)
            && _matchesTrait(criteriaWord, _SIGNAL_OFFSET, 6, birthSeed, _SIGNAL_TRAIT_ID, 6)
            && _matchesTrait(criteriaWord, _DEEP_OFFSET, 6, birthSeed, _DEEP_TRAIT_ID, 6)
            && _matchesTrait(criteriaWord, _APEX_OFFSET, 4, birthSeed, _APEX_TRAIT_ID, 4);
    }

    function _matchesTrait(
        uint256 criteriaWord,
        uint256 offset,
        uint256 valueCount,
        bytes32 birthSeed,
        uint16 traitId,
        uint256 optionCount
    ) private pure returns (bool) {
        uint256 mask = (criteriaWord >> offset) & ((2 ** valueCount) - 1);
        return mask == 0 || mask & (2 ** _traitIndex(birthSeed, traitId, optionCount)) != 0;
    }

    function _matchesEyewear(uint256 criteriaWord, bytes32 birthSeed) private pure returns (bool) {
        uint256 mask = (criteriaWord >> _EYEWEAR_OFFSET) & 0x1f;
        if (mask == 0) return true;

        uint256 index = _traitIndex(birthSeed, _EYEWEAR_TRAIT_ID, 7);
        uint256 value = index < 5 ? index : 0;
        return mask & (2 ** value) != 0;
    }

    function _birthSeed(uint32 artVersion, bytes32 proofDigest, uint256 challengeId) internal pure returns (bytes32) {
        return keccak256(abi.encode(BIRTH_TYPEHASH, artVersion, proofDigest, challengeId));
    }

    function _traitIndex(bytes32 birthSeed, uint16 traitId, uint256 optionCount) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(TRAIT_TYPEHASH, birthSeed, traitId))) % optionCount;
    }
}
