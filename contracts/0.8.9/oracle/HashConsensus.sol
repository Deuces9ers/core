// SPDX-FileCopyrightText: 2023 Lido <info@lido.fi>
// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.9;

import { SafeCast } from "@openzeppelin/contracts-v4.4/utils/math/SafeCast.sol";

import { Math } from "../lib/Math.sol";
import { AccessControlEnumerable } from "../utils/access/AccessControlEnumerable.sol";


/// @notice A contract that gets consensus reports (i.e. hashes) pushed to and processes them
/// asynchronously.
///
interface IReportAsyncProcessor {
    /// @notice Submits a consensus report for processing.
    ///
    /// Note that submitting the report doesn't require the processor to start processing it
    /// right away, this can happen later. Until the processing is started, HashConsensus is
    /// free to reach consensus on another report for the same reporting frame and submit it
    /// using this same function.
    ///
    function submitReport(bytes32 report, uint256 refSlot, uint256 deadline) external;

    /// @notice Returns the last reference slot for which processing of the report was started.
    ///
    function getLastProcessingRefSlot() external view returns (uint256);

    /// @notice Returns the current consensus version.
    ///
    /// Consensus version must change every time consensus rules change, meaning that
    /// an oracle looking at the same reference slot would calculate a different hash.
    ///
    function getConsensusVersion() external view returns (uint256);
}


/// @notice A contract managing oracle members committee and allowing the members to reach
/// consensus on a hash for each reporting frame.
///
/// Time is divided in frames of equal length, each having reference slot and processing
/// deadline. Report data must be gathered by looking at the world state at the moment of
/// the frame's reference slot (including any state changes made in that slot), and must
/// be processed before the frame's processing deadline.
///
/// Frame length is defined in Ethereum consensus layer epochs. Reference slot for each
/// frame is set to the last slot of the epoch preceding the frame's first epoch. The
/// processing deadline is set to the last slot of the last epoch of the frame.
///
/// This means that all state changes a report processing could entail are guaranteed to be
/// observed while gathering data for the next frame's report. This is an important property
/// given that oracle reports sometimes have to contain diffs instead of the full state which
/// might be impractical or even impossible to transmit and process.
///
contract HashConsensus is AccessControlEnumerable {
    using SafeCast for uint256;

    error NumericOverflow();
    error AdminCannotBeZero();
    error DuplicateMember();
    error AddressCannotBeZero();
    error InitialEpochIsYetToArrive();
    error EpochsPerFrameCannotBeZero();
    error NonMember();
    error UnexpectedConsensusVersion(uint256 expected, uint256 received);
    error QuorumTooSmall(uint256 minQuorum, uint256 receivedQuorum);
    error InvalidSlot();
    error DuplicateReport();
    error EmptyReport();
    error StaleReport();
    error NonFastLaneMemberCannotReportWithinFastLaneInterval();
    error NewProcessorCannotBeTheSame();
    error ConsensusReportAlreadyProcessing();

    event FrameConfigSet(uint256 newInitialEpoch, uint256 newEpochsPerFrame);
    event FastLaneConfigSet(uint256 fastLaneLengthSlots);
    event MemberAdded(address indexed addr, uint256 newTotalMembers, uint256 newQuorum);
    event MemberRemoved(address indexed addr, uint256 newTotalMembers, uint256 newQuorum);
    event QuorumSet(uint256 newQuorum, uint256 totalMembers, uint256 prevQuorum);
    event ReportReceived(uint256 indexed refSlot, address indexed member, bytes32 report);
    event ConsensusReached(uint256 indexed refSlot, bytes32 report, uint256 support);
    event ReportProcessorSet(address indexed processor, address indexed prevProcessor);

    struct FrameConfig {
        uint64 initialEpoch;
        uint64 epochsPerFrame;
        uint64 fastLaneLengthSlots;
    }

    /// @dev Oracle reporting is divided into frames, each lasting the same number of slots
    struct ConsensusFrame {
        // frame index; increments by 1 with each frame but resets to zero on frame size change
        uint256 index;
        // the slot at which to read the state around which consensus is being reached;
        // if the slot contains a block, the state should include all changes from that block
        uint256 refSlot;
        // the last slot at which a report can be processed
        uint256 reportProcessingDeadlineSlot;
    }

    struct ReportingState {
        // the last reference slot any report was received for
        uint64 lastReportRefSlot;
        // the last reference slot a consensus was reached for
        uint64 lastConsensusRefSlot;
        // the last consensus variant index
        uint64 lastConsensusVariantIndex;
    }

    struct MemberState {
        // the last reference slot a report from this member was received for
        uint64 lastReportRefSlot;
        // the variant index of the last report from this member
        uint64 lastReportVariantIndex;
    }

    struct ReportVariant {
        bytes32 hash;
        uint64 support;
    }

    /// @notice An ACL role granting the permission to modify members list members and
    /// change the quorum by calling addMember, removeMember, and setQuorum functions.
    bytes32 public constant MANAGE_MEMBERS_AND_QUORUM_ROLE =
        keccak256("MANAGE_MEMBERS_AND_QUORUM_ROLE");

    /// @notice An ACL role granting the permission to disable the consensus by calling
    /// the disableConsensus function. Enabling the consensus back requires the possession
    /// of the MANAGE_QUORUM_ROLE.
    bytes32 public constant DISABLE_CONSENSUS_ROLE = keccak256("DISABLE_CONSENSUS_ROLE");

    /// @notice An ACL role granting the permission to change reporting interval
    /// duration by calling setEpochsPerFrame.
    bytes32 public constant MANAGE_FRAME_CONFIG_ROLE = keccak256("MANAGE_FRAME_CONFIG_ROLE");

    /// @notice An ACL role granting the permission to change fast lane reporting interval
    /// length by calling setFastLaneLengthSlots.
    bytes32 public constant MANAGE_FAST_LANE_CONFIG_ROLE = keccak256("MANAGE_FAST_LANE_CONFIG_ROLE");

    /// @notice An ACL role granting the permission to change еру report processor
    /// contract by calling setReportProcessor.
    bytes32 public constant MANAGE_REPORT_PROCESSOR_ROLE = keccak256("MANAGE_REPORT_PROCESSOR_ROLE");

    /// Chain specification
    uint64 internal immutable SLOTS_PER_EPOCH;
    uint64 internal immutable SECONDS_PER_SLOT;
    uint64 internal immutable GENESIS_TIME;

    /// @dev A quorum value that effectively disables the oracle.
    uint256 internal constant UNREACHABLE_QUORUM = type(uint256).max;
    bytes32 internal constant ZERO_HASH = bytes32(0);

    /// @dev Reporting frame configuration
    FrameConfig internal _frameConfig;

    /// @dev Oracle committee members states array
    MemberState[] internal _memberStates;

    /// @dev Oracle committee members' addresses array
    address[] internal _memberAddresses;

    /// @dev Mapping from an oracle committee member address to the 1-based index in the
    /// members array
    mapping(address => uint256) internal _memberIndices1b;

    /// @dev A structure containing the last reference slot any report was received for, the last
    /// reference slot consensus report was achieved for, and the last consensus variant index
    ReportingState internal _reportingState;

    /// @dev Oracle committee members quorum value, must be larger than totalMembers // 2
    uint256 internal _quorum;

    /// @dev Mapping from a report variant index to the ReportVariant structure
    mapping(uint256 => ReportVariant) internal _reportVariants;

    /// @dev The number of report variants
    uint256 internal _reportVariantsLength;

    /// @dev The address of the report processor contract
    address internal _reportProcessor;

    ///
    /// Initialization
    ///

    constructor(
        uint256 slotsPerEpoch,
        uint256 secondsPerSlot,
        uint256 genesisTime,
        uint256 epochsPerFrame,
        uint256 initialEpoch,
        uint256 fastLaneLengthSlots,
        address admin,
        address reportProcessor
    ) {
        SLOTS_PER_EPOCH = slotsPerEpoch.toUint64();
        SECONDS_PER_SLOT = secondsPerSlot.toUint64();
        GENESIS_TIME = genesisTime.toUint64();

        if (admin == address(0)) revert AdminCannotBeZero();
        _setupRole(DEFAULT_ADMIN_ROLE, admin);
        _setFrameConfig(initialEpoch, epochsPerFrame);
        _setFastLaneConfig(fastLaneLengthSlots);
        // zero address is allowed here, meaning "no processor"
        _reportProcessor = reportProcessor;
    }

    ///
    /// Time
    ///

    /// @notice Returns the chain configuration required to calculate
    /// epoch and slot given a timestamp.
    ///
    function getChainConfig() external view returns (
        uint256 slotsPerEpoch,
        uint256 secondsPerSlot,
        uint256 genesisTime
    ) {
        return (SLOTS_PER_EPOCH, SECONDS_PER_SLOT, GENESIS_TIME);
    }

    /// @notice Returns the parameters required to calculate reporting frame given an epoch.
    ///
    function getFrameConfig() external view returns (uint256 initialEpoch, uint256 epochsPerFrame) {
        return (_frameConfig.initialEpoch, _frameConfig.epochsPerFrame);
    }

    /// @notice Returns the current reporting frame.
    ///
    function getCurrentFrame() external view returns (
        uint256 refSlot,
        uint256 reportProcessingDeadlineSlot
    ) {
        ConsensusFrame memory frame = _getCurrentFrame();
        return (frame.refSlot, frame.reportProcessingDeadlineSlot);
    }

    function setEpochsPerFrame(uint256 epochsPerFrame)
        external onlyRole(MANAGE_FRAME_CONFIG_ROLE)
    {
        // Updates epochsPerFrame in a way that either keeps the current reference slot the same
        // or increases it by at least the minimum of old and new frame sizes.
        uint256 timestamp = _getTime();
        uint256 currentFrameStartEpoch = _computeFrameStartEpoch(timestamp, _frameConfig);
        _setFrameConfig(currentFrameStartEpoch, epochsPerFrame);
    }

    ///
    /// Members
    ///

    function getIsMember(address addr) external view returns (bool) {
        return _isMember(addr);
    }

    /// @notice Returns whether the given address is a fast lane member for the current reporting
    /// frame.
    ///
    /// Fast lane members can, and expected to, submit a report during the first part of the frame
    /// defined via `setFastLaneConfig`. Non-fast-lane members are only allowed to submit a report
    /// after the "fast-lane" part of the frame passes.
    ///
    /// This is done to encourage each oracle from the full set to participate in reporting on a
    /// regular basis, and identify any malfunctioning members.
    ///
    function getIsFastLaneMember(address addr) external view returns (bool) {
        uint256 index1b = _memberIndices1b[addr];
        unchecked {
            return index1b > 0 && _isFastLaneMember(index1b - 1, _getCurrentFrame().index);
        }
    }

    function getMembers() external view returns (
        address[] memory addresses,
        uint256[] memory lastReportedRefSlots
    ) {
        return _getMembers(false);
    }

    /// @notice Returns the subset of oracle committee members (consisting of `quorum` items) that
    /// changes on each frame. See `getIsFastLaneMember`.
    ///
    function getFastLaneMembers() external view returns (
        address[] memory addresses,
        uint256[] memory lastReportedRefSlots
    ) {
        return _getMembers(true);
    }

    /// @notice Returns the extended information related to an oracle committee member with the
    /// given address.
    ///
    /// @param addr The member address.
    ///
    /// @return isMember Whether the provided address is a member of the oracle.
    ///
    /// @return isFastLane Whether the oracle member is in the fast lane members subset of the
    ///         current reporting frame. See `getIsFastLaneMember`.
    ///
    /// @return canReport Whether the oracle member is allowed to submit a report at the moment
    ///         of the call.
    ///
    /// @return lastReportRefSlot The last reference slot for which the member reported a data hash.
    ///
    /// @return currentRefSlot Current reference slot.
    ///
    /// @return memberReportForCurrentRefSlot The hash reported by the member for the current
    ///         reference slot. Set to zero bytes if no report was received for the current
    ///         reference slot.
    ///
    function getMemberInfo(address addr) external view returns (
        bool isMember,
        bool isFastLane,
        bool canReport,
        uint256 lastReportRefSlot,
        uint256 currentRefSlot,
        bytes32 memberReportForCurrentRefSlot
    ) {
        ConsensusFrame memory frame = _getCurrentFrame();
        currentRefSlot = frame.refSlot;

        uint256 index = _memberIndices1b[addr];
        isMember = index != 0;

        if (isMember) {
            unchecked { --index; } // convert to 0-based
            MemberState memory memberState = _memberStates[index];
            lastReportRefSlot = memberState.lastReportRefSlot;
            memberReportForCurrentRefSlot = lastReportRefSlot == frame.refSlot
                ? _reportVariants[memberState.lastReportVariantIndex].hash
                : ZERO_HASH;
            uint256 slot = _computeSlotAtTimestamp(_getTime());
            canReport = slot <= frame.reportProcessingDeadlineSlot &&
                frame.refSlot > _getLastProcessingRefSlot();
            isFastLane = _isFastLaneMember(index, frame.index);
            if (!isFastLane && canReport) {
                canReport = slot > frame.refSlot + _frameConfig.fastLaneLengthSlots;
            }
        }
    }

    /// @notice Sets the duration of the interval starting at the beginning of the frame during
    /// which only the selected "fast lane" subset of oracle committee memebrs can (and expected
    /// to) submit a report.
    ///
    /// The fast lane subset is a subset consisting of `quorum` oracles that changes on each frame.
    /// This is done to encourage each oracle from the full set to participate in reporting on a
    /// regular basis, and identify any malfunctioning members.
    ///
    /// The subset selection is implemented as a sliding window of the `quorum` width over member
    /// indices (mod total members). The window advances by one index each reporting frame.
    ///
    /// @param fastLaneLengthSlots The length of the fast lane reporting interval in slots. Setting
    ///        it to zero disables the fast lane subset, alloing any oracle to report starting from
    ///        the first slot of a frame and until the frame's reporting deadline.
    ///
    function setFastLaneLengthSlots(uint256 fastLaneLengthSlots)
        external onlyRole(MANAGE_FAST_LANE_CONFIG_ROLE)
    {
        _setFastLaneConfig(fastLaneLengthSlots);
    }

    function addMember(address addr, uint256 quorum)
        external
        onlyRole(MANAGE_MEMBERS_AND_QUORUM_ROLE)
    {
        _addMember(addr, quorum);
    }

    function removeMember(address addr, uint256 quorum)
        external
        onlyRole(MANAGE_MEMBERS_AND_QUORUM_ROLE)
    {
        _removeMember(addr, quorum);
    }

    function getQuorum() external view returns (uint256) {
        return _quorum;
    }

    function setQuorum(uint256 quorum) external {
        // access control is performed inside the next call
        _setQuorumAndCheckConsensus(quorum, _memberStates.length);
    }

    /// @notice Disables the oracle by setting the quorum to an unreachable value.
    ///
    function disableConsensus() external {
        // access control is performed inside the next call
        _setQuorumAndCheckConsensus(UNREACHABLE_QUORUM, _memberStates.length);
    }

    ///
    /// Report processor
    ///

    function setReportProcessor(address newProcessor)
        external
        onlyRole(MANAGE_REPORT_PROCESSOR_ROLE)
    {
        _setReportProcessor(newProcessor);
    }

    ///
    /// Consensus
    ///

    /// @notice Returns info about the current frame and consensus state in that frame.
    ///
    /// @return frame Current reporting frame.
    ///
    /// @return consensusReport Consensus report for the current frame, if any.
    ///         Zero bytes otherwise.
    ///
    /// @return isReportProcessing If consensus report for the current frame is already
    ///         being processed. Consensus can be changed before the processing starts.
    ///
    function getConsensusState() external view returns (
        ConsensusFrame memory frame,
        bytes32 consensusReport,
        bool isReportProcessing
    ) {
        frame = _getCurrentFrame();
        (consensusReport,,) = _getConsensusReport(frame.refSlot, _quorum);
        isReportProcessing = _getLastProcessingRefSlot() == frame.refSlot;
    }

    /// @notice Returns report variants and their support for the current reference slot.
    ///
    function getReportVariants() external view returns (
        bytes32[] memory variants,
        uint256[] memory support
    ) {
        if (_reportingState.lastReportRefSlot != _getCurrentFrame().refSlot) {
            return (variants, support);
        }

        uint256 variantsLength = _reportVariantsLength;
        variants = new bytes32[](variantsLength);
        support = new uint256[](variantsLength);

        for (uint256 i = 0; i < variantsLength; ++i) {
            ReportVariant memory variant = _reportVariants[i];
            variants[i] = variant.hash;
            support[i] = variant.support;
        }
    }

    /// @notice Used by oracle members to submit hash of the data calculated for the given
    /// reference slot.
    ///
    /// @param slot The reference slot the data was calculated for. Reverts if doesn't match
    ///        the current reference slot.
    ///
    /// @param report Hash of the data calculated for the given reference slot.
    ///
    /// @param consensusVersion Version of the oracle consensus rules. Reverts if doesn't
    ///        match the version returned by the currently set consensus report processor,
    ///        or zero if no report processor is set.
    ///
    function submitReport(uint256 slot, bytes32 report, uint256 consensusVersion) external {
        _submitReport(slot, report, consensusVersion);
    }

    ///
    /// Implementation: time
    ///

    function _setFrameConfig(uint256 initialEpoch, uint256 epochsPerFrame) internal {
        if (epochsPerFrame == 0) revert EpochsPerFrameCannotBeZero();
        _frameConfig = FrameConfig(
            initialEpoch.toUint64(),
            epochsPerFrame.toUint64(),
            _frameConfig.fastLaneLengthSlots
        );
        emit FrameConfigSet(initialEpoch, epochsPerFrame);
    }

    function _getCurrentFrame() internal view returns (ConsensusFrame memory) {
        return _getCurrentFrame(_frameConfig);
    }

    function _getCurrentFrame(FrameConfig memory config) internal view returns (ConsensusFrame memory) {
        return _getFrameAtTimestamp(_getTime(), config);
    }

    function _getFrameAtTimestamp(uint256 timestamp, FrameConfig memory config)
        internal view returns (ConsensusFrame memory)
    {
        uint256 frameIndex = _computeFrameIndex(timestamp, config);
        uint256 frameStartEpoch = _computeStartEpochOfFrameWithIndex(frameIndex, config);
        uint256 frameStartSlot = _computeStartSlotAtEpoch(frameStartEpoch);
        uint256 nextFrameStartSlot = frameStartSlot + config.epochsPerFrame * SLOTS_PER_EPOCH;

        return ConsensusFrame({
            index: frameIndex,
            refSlot: uint64(frameStartSlot - 1),
            reportProcessingDeadlineSlot: uint64(nextFrameStartSlot - 1)
        });
    }

    function _computeFrameStartEpoch(uint256 timestamp, FrameConfig memory config)
        internal view returns (uint256)
    {
        return _computeStartEpochOfFrameWithIndex(_computeFrameIndex(timestamp, config), config);
    }

    function _computeStartEpochOfFrameWithIndex(uint256 frameIndex, FrameConfig memory config)
        internal pure returns (uint256)
    {
        return config.initialEpoch + frameIndex * config.epochsPerFrame;
    }

    function _computeFrameIndex(uint256 timestamp, FrameConfig memory config)
        internal view returns (uint256)
    {
        uint256 epoch = _computeEpochAtTimestamp(timestamp);
        if (epoch < config.initialEpoch) {
            revert InitialEpochIsYetToArrive();
        }
        return (epoch - config.initialEpoch) / config.epochsPerFrame;
    }

    function _computeTimestampAtSlot(uint256 slot) internal view returns (uint256) {
        // See: github.com/ethereum/consensus-specs/blob/dev/specs/bellatrix/beacon-chain.md#compute_timestamp_at_slot
        return GENESIS_TIME + slot * SECONDS_PER_SLOT;
    }

    function _computeSlotAtTimestamp(uint256 timestamp) internal view returns (uint256) {
        return (timestamp - GENESIS_TIME) / SECONDS_PER_SLOT;
    }

    function _computeEpochAtSlot(uint256 slot) internal view returns (uint256) {
        // See: github.com/ethereum/consensus-specs/blob/dev/specs/phase0/beacon-chain.md#compute_epoch_at_slot
        return slot / SLOTS_PER_EPOCH;
    }

    function _computeEpochAtTimestamp(uint256 timestamp) internal view returns (uint256) {
        return _computeEpochAtSlot(_computeSlotAtTimestamp(timestamp));
    }

    function _computeStartSlotAtEpoch(uint256 epoch) internal view returns (uint256) {
        // See: github.com/ethereum/consensus-specs/blob/dev/specs/phase0/beacon-chain.md#compute_start_slot_at_epoch
        return epoch * SLOTS_PER_EPOCH;
    }

    function _getTime() internal virtual view returns (uint256) {
        return block.timestamp; // solhint-disable-line not-rely-on-time
    }

    ///
    /// Implementation: members
    ///

    function _isMember(address addr) internal view returns (bool) {
        return _memberIndices1b[addr] != 0;
    }

    function _getMemberIndex(address addr) internal view returns (uint256) {
        uint256 index1b = _memberIndices1b[addr];
        if (index1b == 0) {
            revert NonMember();
        }
        unchecked {
            return uint256(index1b - 1);
        }
    }

    function _addMember(address addr, uint256 quorum) internal {
        if (_isMember(addr)) revert DuplicateMember();
        if (addr == address(0)) revert AddressCannotBeZero();

        _memberStates.push(MemberState(0, 0));
        _memberAddresses.push(addr);

        uint256 newTotalMembers = _memberStates.length;
        _memberIndices1b[addr] = newTotalMembers;

        emit MemberAdded(addr, newTotalMembers, quorum);

        _setQuorumAndCheckConsensus(quorum, newTotalMembers);
    }

    function _removeMember(address addr, uint256 quorum) internal {
        uint256 index = _getMemberIndex(addr);
        uint256 newTotalMembers = _memberStates.length - 1;

        assert(index <= newTotalMembers);
        MemberState memory memberState = _memberStates[index];

        if (index != newTotalMembers) {
            address addrToMove = _memberAddresses[newTotalMembers];
            _memberAddresses[index] = addrToMove;
            _memberStates[index] = _memberStates[newTotalMembers];
            _memberIndices1b[addrToMove] = index + 1;
        }

        _memberStates.pop();
        _memberAddresses.pop();
        _memberIndices1b[addr] = 0;

        emit MemberRemoved(addr, newTotalMembers, quorum);

        ConsensusFrame memory frame = _getCurrentFrame();

        if (memberState.lastReportRefSlot == frame.refSlot &&
            _getLastProcessingRefSlot() < frame.refSlot
        ) {
            // member reported for the current ref. slot and the consensus report
            // is not processing yet => need to cancel the member's report
            --_reportVariants[memberState.lastReportVariantIndex].support;
        }

        _setQuorumAndCheckConsensus(quorum, newTotalMembers);
    }

    function _setFastLaneConfig(uint256 fastLaneLengthSlots) internal {
        if (fastLaneLengthSlots != _frameConfig.fastLaneLengthSlots) {
            _frameConfig.fastLaneLengthSlots = fastLaneLengthSlots.toUint64();
            emit FastLaneConfigSet(fastLaneLengthSlots);
        }
    }

    /// @dev Returns start and past-end incides (mod totalMembers) of the fast lane members subset.
    ///
    function _getFastLaneSubset(uint256 frameIndex, uint256 totalMembers)
        internal view returns (uint256 startIndex, uint256 pastEndIndex)
    {
        startIndex = frameIndex % totalMembers;
        pastEndIndex = startIndex + _quorum;
    }

    /// @dev Tests whether the member with the given `index` is in the fast lane subset for the
    /// given reporting `frameIndex`.
    ///
    function _isFastLaneMember(uint256 index, uint256 frameIndex) internal view returns (bool) {
        uint256 totalMembers = _memberStates.length;
        (uint256 flLeft, uint256 flPastRight) = _getFastLaneSubset(frameIndex, totalMembers);
        return Math.pointInHalfOpenIntervalModN(index, flLeft, flPastRight, totalMembers);
    }

    function _getMembers(bool fastLane) internal view returns (
        address[] memory addresses,
        uint256[] memory lastReportedRefSlots
    ) {
        uint256 totalMembers = _memberStates.length;
        uint256 left;
        uint256 right;

        if (fastLane) {
            (left, right) = _getFastLaneSubset(_getCurrentFrame().index, totalMembers);
        } else {
            right = totalMembers;
        }

        addresses = new address[](right - left);
        lastReportedRefSlots = new uint256[](addresses.length);

        for (uint256 i = left; i < right; ++i) {
            uint256 iModTotal = i % totalMembers;
            MemberState memory memberState = _memberStates[iModTotal];
            uint256 k = i - left;
            addresses[k] = _memberAddresses[iModTotal];
            lastReportedRefSlots[k] = memberState.lastReportRefSlot;
        }
    }

    ///
    /// Implementation: consensus
    ///

    function _submitReport(uint256 slot, bytes32 report, uint256 consensusVersion) internal {
        if (slot > type(uint64).max) revert NumericOverflow();

        uint256 memberIndex = _getMemberIndex(_msgSender());
        MemberState memory memberState = _memberStates[memberIndex];

        uint256 expectedConsensusVersion = _getConsensusVersion();
        if (consensusVersion != expectedConsensusVersion) {
            revert UnexpectedConsensusVersion(expectedConsensusVersion, consensusVersion);
        }

        uint256 timestamp = _getTime();
        uint256 currentSlot = _computeSlotAtTimestamp(timestamp);
        FrameConfig memory config = _frameConfig;
        ConsensusFrame memory frame = _getFrameAtTimestamp(timestamp, config);

        if (report == ZERO_HASH) revert EmptyReport();
        if (slot != frame.refSlot) revert InvalidSlot();
        if (currentSlot > frame.reportProcessingDeadlineSlot) revert StaleReport();

        if (currentSlot <= frame.refSlot + config.fastLaneLengthSlots &&
            !_isFastLaneMember(memberIndex, frame.index)
        ) {
            revert NonFastLaneMemberCannotReportWithinFastLaneInterval();
        }

        if (slot <= _getLastProcessingRefSlot()) {
            // consensus for the ref. slot was already reached and consensus report is processing
            if (slot == memberState.lastReportRefSlot) {
                // member sends a report for the same slot => let them know via a revert
                revert ConsensusReportAlreadyProcessing();
            } else {
                // member hasn't sent a report for this slot => normal operation, do nothing
                return;
            }
        }

        uint256 variantsLength;

        if (_reportingState.lastReportRefSlot != slot) {
            // first report for a new slot => clear report variants
            _reportingState.lastReportRefSlot = uint64(slot);
            variantsLength = 0;
        } else {
            variantsLength = _reportVariantsLength;
        }

        uint64 varIndex = 0;
        uint64 support;

        while (varIndex < variantsLength && _reportVariants[varIndex].hash != report) {
            ++varIndex;
        }

        if (slot == memberState.lastReportRefSlot) {
            uint64 prevVarIndex = memberState.lastReportVariantIndex;
            assert(prevVarIndex < variantsLength);
            if (varIndex == prevVarIndex) {
                revert DuplicateReport();
            } else {
                --_reportVariants[prevVarIndex].support;
            }
        }

        if (varIndex < variantsLength) {
            support = ++_reportVariants[varIndex].support;
        } else {
            support = 1;
            _reportVariants[varIndex] = ReportVariant({hash: report, support: 1});
            _reportVariantsLength = ++variantsLength;
        }

        _memberStates[memberIndex] = MemberState({
            lastReportRefSlot: uint64(slot),
            lastReportVariantIndex: varIndex
        });

        emit ReportReceived(slot, _msgSender(), report);

        if (support >= _quorum) {
            _consensusReached(frame, report, varIndex, support);
        }
    }

    function _consensusReached(
        ConsensusFrame memory frame,
        bytes32 report,
        uint256 variantIndex,
        uint256 support
    ) internal {
        if (_reportingState.lastConsensusRefSlot != frame.refSlot ||
            _reportingState.lastConsensusVariantIndex != variantIndex
        ) {
            _reportingState.lastConsensusRefSlot = uint64(frame.refSlot);
            _reportingState.lastConsensusVariantIndex = uint64(variantIndex);

            _submitReportForProcessing(frame, report);

            emit ConsensusReached(frame.refSlot, report, support);
        }
    }

    function _setQuorumAndCheckConsensus(uint256 quorum, uint256 totalMembers) internal {
        if (quorum <= totalMembers / 2) {
            revert QuorumTooSmall(totalMembers / 2 + 1, quorum);
        }

        // we're explicitly allowing quorum values greater than the number of members to
        // allow effectively disabling the oracle in case something unpredictable happens

        uint256 prevQuorum = _quorum;
        if (quorum != prevQuorum) {
            _checkRole(
                quorum == UNREACHABLE_QUORUM ? DISABLE_CONSENSUS_ROLE : MANAGE_MEMBERS_AND_QUORUM_ROLE,
                _msgSender()
            );
            _quorum = quorum;
            emit QuorumSet(quorum, totalMembers, prevQuorum);
        }

        if (quorum < prevQuorum) {
            // consensus can only change as the result of the quorum being decreased
            _checkConsensus(quorum);
        }
    }

    function _checkConsensus(uint256 quorum) internal {
        uint256 timestamp = _getTime();
        ConsensusFrame memory frame = _getFrameAtTimestamp(timestamp, _frameConfig);

        if (_computeSlotAtTimestamp(timestamp) > frame.reportProcessingDeadlineSlot) {
            // reference slot is not reportable anymore
            return;
        }

        if (_getLastProcessingRefSlot() >= frame.refSlot) {
            // consensus report for the current ref. slot already processing
            return;
        }

        (bytes32 consensusReport, int256 consensusVariantIndex, uint256 support) =
            _getConsensusReport(frame.refSlot, quorum);

        if (consensusVariantIndex >= 0) {
            _consensusReached(frame, consensusReport, uint256(consensusVariantIndex), support);
        }
    }

    function _getConsensusReport(uint256 currentRefSlot, uint256 quorum)
        internal view returns (bytes32 report, int256 variantIndex, uint256 support)
    {
        if (_reportingState.lastReportRefSlot != currentRefSlot) {
            // there were no reports for the current ref. slot
            return (ZERO_HASH, -1, 0);
        }

        uint256 variantsLength = _reportVariantsLength;
        variantIndex = -1;
        report = ZERO_HASH;
        support = 0;

        for (uint256 i = 0; i < variantsLength && report == ZERO_HASH; ++i) {
            uint256 iSupport = _reportVariants[i].support;
            if (iSupport >= quorum) {
                variantIndex = int256(i);
                report = _reportVariants[i].hash;
                support = iSupport;
            }
        }

        return (report, variantIndex, support);
    }

    ///
    /// Implementation: report processing
    ///

    function _setReportProcessor(address newProcessor) internal {
        address prevProcessor = _reportProcessor;
        if (newProcessor == address(0)) revert AddressCannotBeZero();
        if (newProcessor == prevProcessor) revert NewProcessorCannotBeTheSame();

        _reportProcessor = newProcessor;
        emit ReportProcessorSet(newProcessor, prevProcessor);

        ConsensusFrame memory frame = _getCurrentFrame();
        uint256 lastConsensusRefSlot = _reportingState.lastConsensusRefSlot;

        uint256 processingRefSlot = prevProcessor == address(0)
            ? lastConsensusRefSlot
            : IReportAsyncProcessor(prevProcessor).getLastProcessingRefSlot();

        if (processingRefSlot < frame.refSlot && lastConsensusRefSlot == frame.refSlot) {
            bytes32 report = _reportVariants[_reportingState.lastConsensusVariantIndex].hash;
            _submitReportForProcessing(frame, report);
        }
    }

    function _getLastProcessingRefSlot() internal view returns (uint256) {
        address processor = _reportProcessor;
        return processor == address(0)
            ? _reportingState.lastConsensusRefSlot
            : IReportAsyncProcessor(processor).getLastProcessingRefSlot();
    }

    function _submitReportForProcessing(ConsensusFrame memory frame, bytes32 report) internal {
        address processor = _reportProcessor;
        if (processor == address(0)) return;
        uint256 deadline = _computeTimestampAtSlot(frame.reportProcessingDeadlineSlot);
        IReportAsyncProcessor(processor).submitReport(report, frame.refSlot, deadline);
    }

    function _getConsensusVersion() internal view returns (uint256) {
        address processor = _reportProcessor;
        return processor == address(0) ? 0 : IReportAsyncProcessor(processor).getConsensusVersion();
    }
}
