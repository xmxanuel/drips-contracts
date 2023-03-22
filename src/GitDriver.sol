// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.19;

import {
    DripsHub,
    DripsReceiver,
    IERC20,
    SafeERC20,
    SplitsReceiver,
    UserMetadata
} from "./DripsHub.sol";
import {Managed} from "./Managed.sol";
import {ERC2771Context} from "openzeppelin-contracts/metatx/ERC2771Context.sol";

contract GitDriver is Managed, ERC2771Context {
    using SafeERC20 for IERC20;

    /// @notice The DripsHub address used by this driver.
    DripsHub public immutable dripsHub;
    /// @notice The driver ID which this driver uses when calling DripsHub.
    uint32 public immutable driverId;

    event ProjectIdVerified(
        string indexed gitUrl, bytes32 indexed projectId, address indexed owner
    );

    mapping(uint256 => address) public projectOwner;

    address public immutable oracle;

    modifier onlyOracle() {
        require(oracle == _msgSender(), "GitDriver: not oracle");
        _;
    }

    modifier onlyProjectOwner(uint256 projectId) {
        require(projectOwner[projectId] == _msgSender(), "GitDriver: not project owner");
        _;
    }

    /// @param _dripsHub The drips hub to use.
    /// @param forwarder The ERC-2771 forwarder to trust. May be the zero address.
    /// @param _driverId The driver ID to use when calling DripsHub.
    constructor(DripsHub _dripsHub, address forwarder, uint32 _driverId, address _oracle)
        ERC2771Context(forwarder)
    {
        dripsHub = _dripsHub;
        driverId = _driverId;
        oracle = _oracle;
    }

    /// @notice Calculates the user ID for an address.
    /// Every user ID is a 256-bit integer constructed by concatenating:
    /// `driverId (32 bits) | zeros (64 bits) | userAddr (160 bits)`.
    /// @param gitUrl The user string
    /// @return projectId The user ID
    function calcProjectId(string memory gitUrl) public view returns (uint256 projectId) {
        // By assignment we get `projectId` value:
        // `zeros (224 bits) | driverId (32 bits)`
        projectId = driverId;
        // By bit shifting we get `projectId` value:
        // `driverId (32 bits) | zeros (224 bits)`
        // By bit masking we get `projectId` value:
        // `driverId (32 bits) | zeros (64 bits) | userAddr (160 bits)`
        projectId =
            (projectId << 224) | uint160(uint256(bytes32(keccak256(abi.encodePacked(gitUrl)))));
    }

    /// @notice Verifies the github identity of the project owner.
    /// @param gitUrl the url to the git project (for example github url)
    /// @param owner the owner of the project
    function verifyProjectId(string memory gitUrl, address owner) public onlyOracle {
        uint256 projectId = calcProjectId(gitUrl);
        require(projectOwner[projectId] == address(0), "GitDriver: projectId already verified");
        projectOwner[projectId] = owner;
        emit ProjectIdVerified(gitUrl, bytes32(projectId), owner);
    }

    /// @notice Collects the user's received already split funds
    /// and transfers them out of the drips hub contract.
    /// @param projectId the project id of the git project
    /// @param erc20 The used ERC-20 token.
    /// It must preserve amounts, so if some amount of tokens is transferred to
    /// an address, then later the same amount must be transferable from that address.
    /// Tokens which rebase the holders' balances, collect taxes on transfers,
    /// or impose any restrictions on holding or transferring tokens are not supported.
    /// If you use such tokens in the protocol, they can get stuck or lost.
    /// @param transferTo The address to send collected funds to
    /// @return amt The collected amount
    function collect(uint256 projectId, IERC20 erc20, address transferTo)
        public
        whenNotPaused
        onlyProjectOwner(projectId)
        returns (uint128 amt)
    {
        amt = dripsHub.collect(projectId, erc20);
        if (amt > 0) dripsHub.withdraw(erc20, transferTo, amt);
    }

    /// @notice Gives funds from the message sender to the receiver.
    /// The receiver can split and collect them immediately.
    /// Transfers the funds to be given from the message sender's wallet to the drips hub contract.
    /// @param projectId the project id of the git project
    /// @param receiver The receiver
    /// @param erc20 The used ERC-20 token.
    /// It must preserve amounts, so if some amount of tokens is transferred to
    /// an address, then later the same amount must be transferable from that address.
    /// Tokens which rebase the holders' balances, collect taxes on transfers,
    /// or impose any restrictions on holding or transferring tokens are not supported.
    /// If you use such tokens in the protocol, they can get stuck or lost.
    /// @param amt The given amount
    function give(uint256 projectId, uint256 receiver, IERC20 erc20, uint128 amt)
        public
        whenNotPaused
        onlyProjectOwner(projectId)
    {
        if (amt > 0) _transferFromCaller(erc20, amt);
        dripsHub.give(projectId, receiver, erc20, amt);
    }

    /// @notice Sets the message sender's drips configuration.
    /// Transfers funds between the message sender's wallet and the drips hub contract
    /// to fulfil the change of the drips balance.
    /// @param projectId the project id of the git project
    /// @param erc20 The used ERC-20 token.
    /// It must preserve amounts, so if some amount of tokens is transferred to
    /// an address, then later the same amount must be transferable from that address.
    /// Tokens which rebase the holders' balances, collect taxes on transfers,
    /// or impose any restrictions on holding or transferring tokens are not supported.
    /// If you use such tokens in the protocol, they can get stuck or lost.
    /// @param currReceivers The current drips receivers list.
    /// It must be exactly the same as the last list set for the sender with `setDrips`.
    /// If this is the first update, pass an empty array.
    /// @param balanceDelta The drips balance change to be applied.
    /// Positive to add funds to the drips balance, negative to remove them.
    /// @param newReceivers The list of the drips receivers of the sender to be set.
    /// Must be sorted by the receivers' addresses, deduplicated and without 0 amtPerSecs.
    /// @param maxEndHint1 An optional parameter allowing gas optimization, pass `0` to ignore it.
    /// The first hint for finding the maximum end time when all drips stop due to funds
    /// running out after the balance is updated and the new receivers list is applied.
    /// Hints have no effect on the results of calling this function, except potentially saving gas.
    /// Hints are Unix timestamps used as the starting points for binary search for the time
    /// when funds run out in the range of timestamps from the current block's to `2^32`.
    /// Hints lower than the current timestamp are ignored.
    /// You can provide zero, one or two hints. The order of hints doesn't matter.
    /// Hints are the most effective when one of them is lower than or equal to
    /// the last timestamp when funds are still dripping, and the other one is strictly larger
    /// than that timestamp,the smaller the difference between such hints, the higher gas savings.
    /// The savings are the highest possible when one of the hints is equal to
    /// the last timestamp when funds are still dripping, and the other one is larger by 1.
    /// It's worth noting that the exact timestamp of the block in which this function is executed
    /// may affect correctness of the hints, especially if they're precise.
    /// Hints don't provide any benefits when balance is not enough to cover
    /// a single second of dripping or is enough to cover all drips until timestamp `2^32`.
    /// Even inaccurate hints can be useful, and providing a single hint
    /// or two hints that don't enclose the time when funds run out can still save some gas.
    /// Providing poor hints that don't reduce the number of binary search steps
    /// may cause slightly higher gas usage than not providing any hints.
    /// @param maxEndHint2 An optional parameter allowing gas optimization, pass `0` to ignore it.
    /// The second hint for finding the maximum end time, see `maxEndHint1` docs for more details.
    /// @param transferTo The address to send funds to in case of decreasing balance
    /// @return realBalanceDelta The actually applied drips balance change.
    function setDrips(
        uint256 projectId,
        IERC20 erc20,
        DripsReceiver[] calldata currReceivers,
        int128 balanceDelta,
        DripsReceiver[] calldata newReceivers,
        // slither-disable-next-line similar-names
        uint32 maxEndHint1,
        uint32 maxEndHint2,
        address transferTo
    ) public whenNotPaused onlyProjectOwner(projectId) returns (int128 realBalanceDelta) {
        if (balanceDelta > 0) _transferFromCaller(erc20, uint128(balanceDelta));
        realBalanceDelta = dripsHub.setDrips(
            projectId, erc20, currReceivers, balanceDelta, newReceivers, maxEndHint1, maxEndHint2
        );
        if (realBalanceDelta < 0) dripsHub.withdraw(erc20, transferTo, uint128(-realBalanceDelta));
    }

    /// @notice Sets user splits configuration. The configuration is common for all assets.
    /// Nothing happens to the currently splittable funds, but when they are split
    /// after this function finishes, the new splits configuration will be used.
    /// Because anybody can call `split` on `DripsHub`, calling this function may be frontrun
    /// and all the currently splittable funds will be split using the old splits configuration.
    /// @param projectId the project id of the git project
    /// @param receivers The list of the user's splits receivers to be set.
    /// Must be sorted by the splits receivers' addresses, deduplicated and without 0 weights.
    /// Each splits receiver will be getting `weight / TOTAL_SPLITS_WEIGHT`
    /// share of the funds collected by the user.
    /// If the sum of weights of all receivers is less than `_TOTAL_SPLITS_WEIGHT`,
    /// some funds won't be split, but they will be left for the user to collect.
    /// It's valid to include the user's own `userId` in the list of receivers,
    /// but funds split to themselves return to their splittable balance and are not collectable.
    /// This is usually unwanted, because if splitting is repeated,
    /// funds split to themselves will be again split using the current configuration.
    /// Splitting 100% to self effectively blocks splitting unless the configuration is updated.
    function setSplits(uint256 projectId, SplitsReceiver[] calldata receivers)
        public
        whenNotPaused
        onlyProjectOwner(projectId)
    {
        dripsHub.setSplits(projectId, receivers);
    }

    /// @notice Emits the user metadata for the message sender.
    /// @param projectId the project id of the git project
    /// The keys and the values are not standardized by the protocol, it's up to the user
    /// to establish and follow conventions to ensure compatibility with the consumers.
    /// @param userMetadata The list of user metadata.
    function emitUserMetadata(uint256 projectId, UserMetadata[] calldata userMetadata)
        public
        whenNotPaused
        onlyProjectOwner(projectId)
    {
        dripsHub.emitUserMetadata(projectId, userMetadata);
    }

    function _transferFromCaller(IERC20 erc20, uint128 amt) internal {
        erc20.safeTransferFrom(_msgSender(), address(dripsHub), amt);
    }
}