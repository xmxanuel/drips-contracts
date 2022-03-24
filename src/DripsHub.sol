// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.7;

import {Drips, DripsReceiver} from "./Drips.sol";
import {Splits, SplitsReceiver} from "./Splits.sol";

/// @notice Drips hub contract. Automatically drips and splits funds between users.
///
/// The user can transfer some funds to their drips balance in the contract
/// and configure a list of receivers, to whom they want to drip these funds.
/// As soon as the drips balance is enough to cover at least 1 second of dripping
/// to the configured receivers, the funds start dripping automatically.
/// Every second funds are deducted from the drips balance and moved to their receivers' accounts.
/// The process stops automatically when the drips balance is not enough to cover another second.
///
/// The user can have any number of independent configurations and drips balances by using accounts.
/// An account is identified by the user address and an account identifier.
/// Accounts of different users are separate entities, even if they have the same identifiers.
/// An account can be used to drip or give, but not to receive funds.
///
/// Every user has a receiver balance, in which they have funds received from other users.
/// The dripped funds are added to the receiver balances in global cycles.
/// Every `cycleSecs` seconds the drips hub adds dripped funds to the receivers' balances,
/// so recently dripped funds may not be collectable immediately.
/// `cycleSecs` is a constant configured when the drips hub is deployed.
/// The receiver balance is independent from the drips balance,
/// to drip received funds they need to be first collected and then added to the drips balance.
///
/// The user can share collected funds with other users by using splits.
/// When collecting, the user gives each of their splits receivers a fraction of the received funds.
/// Funds received from splits are available for collection immediately regardless of the cycle.
/// They aren't exempt from being split, so they too can be split when collected.
/// Users can build chains and networks of splits between each other.
/// Anybody can request collection of funds for any user,
/// which can be used to enforce the flow of funds in the network of splits.
///
/// The concept of something happening periodically, e.g. every second or every `cycleSecs` are
/// only high-level abstractions for the user, Ethereum isn't really capable of scheduling work.
/// The actual implementation emulates that behavior by calculating the results of the scheduled
/// events based on how many seconds have passed and only when the user needs their outcomes.
///
/// The contract assumes that all amounts in the system can be stored in signed 128-bit integers.
/// It's guaranteed to be safe only when working with assets with supply lower than `2 ^ 127`.
abstract contract DripsHub {
    /// @notice On every timestamp `T`, which is a multiple of `cycleSecs`, the receivers
    /// gain access to drips collected during `T - cycleSecs` to `T - 1`.
    uint64 public immutable cycleSecs;
    /// @notice Timestamp at which all drips must be finished
    uint64 internal constant MAX_TIMESTAMP = type(uint64).max - 2;
    /// @notice Maximum number of drips receivers of a single user.
    /// Limits cost of changes in drips configuration.
    uint32 public constant MAX_DRIPS_RECEIVERS = 100;
    /// @notice Maximum number of splits receivers of a single user.
    /// Limits cost of collecting.
    uint32 public constant MAX_SPLITS_RECEIVERS = 200;
    /// @notice The total splits weight of a user
    uint32 public constant TOTAL_SPLITS_WEIGHT = 1_000_000;
    /// @notice Number of bits in the sub-account part of userId
    uint256 public constant BITS_SUB_ACCOUNT = 224;

    /// @notice Emitted when an account is created
    /// @param accountId The account ID
    /// @param owner The account owner
    event AccountCreated(uint32 indexed accountId, address indexed owner);

    /// @notice Emitted when an account ownership is transferred.
    /// @param accountId The account ID
    /// @param previousOwner The previous account owner
    /// @param newOwner The new account owner
    event AccountTransferred(
        uint32 indexed accountId,
        address indexed previousOwner,
        address indexed newOwner
    );

    struct DripsHubStorage {
        /// @notice The drips storage
        Drips.Storage drips;
        /// @notice The splits storage
        Splits.Storage splits;
        /// @notice The next created account ID.
        uint32 nextAccountId;
        /// @notice Account owners. The key is the account ID, the value is the owner address.
        mapping(uint32 => address) accountsOwners;
    }

    /// @param _cycleSecs The length of cycleSecs to be used in the contract instance.
    /// Low value makes funds more available by shortening the average time of funds being frozen
    /// between being taken from the users' drips balances and being collectable by their receivers.
    /// High value makes collecting cheaper by making it process less cycles for a given time range.
    constructor(uint64 _cycleSecs) {
        cycleSecs = _cycleSecs;
    }

    modifier onlyAccountOwner(uint256 userId) {
        uint32 accountId = uint32(userId >> BITS_SUB_ACCOUNT);
        _assertCallerIsAccountOwner(accountId);
        _;
    }

    function _assertCallerIsAccountOwner(uint32 accountId) internal view {
        require(
            accountOwner(accountId) == msg.sender,
            "Callable only by the owner of the user account"
        );
    }

    /// @notice Creates an account.
    /// Assigns it an ID and lets its owner perform actions on behalf of all its sub-accounts.
    /// Multiple accounts can be registered for a single address, it will own all of them.
    /// @return accountId The new account ID.
    function createAccount(address owner) public virtual returns (uint32 accountId) {
        DripsHubStorage storage dripsHubStorage = _dripsHubStorage();
        accountId = dripsHubStorage.nextAccountId++;
        dripsHubStorage.accountsOwners[accountId] = owner;
        emit AccountCreated(accountId, owner);
    }

    /// @notice Returns account owner.
    /// @param accountId The account to look up.
    /// @return owner The owner of the account. If the account doesn't exist, returns address 0.
    function accountOwner(uint32 accountId) public view returns (address owner) {
        return _dripsHubStorage().accountsOwners[accountId];
    }

    /// @notice Transfers the account ownership to a new address.
    /// Must be called by the current account owner.
    /// @param accountId The account which ownership is transferred
    /// @param newOwner The new account owner
    function transferAccount(uint32 accountId, address newOwner) public {
        _assertCallerIsAccountOwner(accountId);
        _dripsHubStorage().accountsOwners[accountId] = newOwner;
        emit AccountTransferred(accountId, msg.sender, newOwner);
    }

    /// @notice Returns the ID which will be assigned for the next created account.
    /// @return accountId The account ID.
    function nextAccountId() public view returns (uint32 accountId) {
        return _dripsHubStorage().nextAccountId;
    }

    /// @notice Returns the contract storage.
    /// @return dripsHubStorage The storage.
    function _dripsHubStorage()
        internal
        view
        virtual
        returns (DripsHubStorage storage dripsHubStorage);

    /// @notice Returns amount of received funds available for collection for a user.
    /// @param userId The user ID
    /// @param assetId The used asset ID
    /// @param currReceivers The list of the user's current splits receivers.
    /// @return collectedAmt The collected amount
    /// @return splitAmt The amount split to the user's splits receivers
    function collectableAll(
        uint256 userId,
        uint256 assetId,
        SplitsReceiver[] memory currReceivers
    ) public view returns (uint128 collectedAmt, uint128 splitAmt) {
        // Collectable from cycles
        (collectedAmt, ) = Drips.receivableDrips(
            _dripsHubStorage().drips,
            cycleSecs,
            userId,
            assetId,
            type(uint64).max
        );
        // Collectable independently from cycles
        collectedAmt += Splits.splittable(_dripsHubStorage().splits, userId, assetId);
        // Split when collected
        (collectedAmt, splitAmt) = Splits.splitResults(
            _dripsHubStorage().splits,
            userId,
            currReceivers,
            collectedAmt
        );
        // Already split
        collectedAmt += Splits.collectable(_dripsHubStorage().splits, userId, assetId);
    }

    /// @notice Collects all received funds available for the user
    /// and transfers them out of the drips hub contract to msg.sender.
    /// @param userId The user ID
    /// @param assetId The used asset ID
    /// @param currReceivers The list of the user's current splits receivers.
    /// @return collectedAmt The collected amount
    /// @return splitAmt The amount split to the user's splits receivers
    function collectAll(
        uint256 userId,
        uint256 assetId,
        SplitsReceiver[] memory currReceivers
    ) public virtual returns (uint128 collectedAmt, uint128 splitAmt) {
        receiveDrips(userId, assetId, type(uint64).max);
        (, splitAmt) = split(userId, assetId, currReceivers);
        collectedAmt = collect(userId, assetId);
    }

    /// @notice Counts cycles from which drips can be collected.
    /// This function can be used to detect that there are
    /// too many cycles to analyze in a single transaction.
    /// @param userId The user ID
    /// @param assetId The used asset ID
    /// @return cycles The number of cycles which can be flushed
    function receivableDripsCycles(uint256 userId, uint256 assetId)
        public
        view
        returns (uint64 cycles)
    {
        return Drips.receivableDripsCycles(_dripsHubStorage().drips, cycleSecs, userId, assetId);
    }

    /// @notice Calculate effects of calling `receiveDrips` with the given parameters.
    /// @param userId The user ID
    /// @param assetId The used asset ID
    /// @param maxCycles The maximum number of received drips cycles.
    /// If too low, receiving will be cheap, but may not cover many cycles.
    /// If too high, receiving may become too expensive to fit in a single transaction.
    /// @return receivableAmt The amount which would be received
    /// @return receivableCycles The number of cycles which would still be receivable after the call
    function receivableDrips(
        uint256 userId,
        uint256 assetId,
        uint64 maxCycles
    ) public view returns (uint128 receivableAmt, uint64 receivableCycles) {
        return
            Drips.receivableDrips(_dripsHubStorage().drips, cycleSecs, userId, assetId, maxCycles);
    }

    /// @notice Receive drips from uncollected cycles of the user.
    /// Received drips cycles won't need to be analyzed ever again.
    /// Calling this function does not collect but makes the funds ready to be split and collected.
    /// @param userId The user ID
    /// @param assetId The used asset ID
    /// @param maxCycles The maximum number of received drips cycles.
    /// If too low, receiving will be cheap, but may not cover many cycles.
    /// If too high, receiving may become too expensive to fit in a single transaction.
    /// @return receivedAmt The received amount
    /// @return receivableCycles The number of cycles which still can be received
    function receiveDrips(
        uint256 userId,
        uint256 assetId,
        uint64 maxCycles
    ) public virtual returns (uint128 receivedAmt, uint64 receivableCycles) {
        (receivedAmt, receivableCycles) = Drips.receiveDrips(
            _dripsHubStorage().drips,
            cycleSecs,
            userId,
            assetId,
            maxCycles
        );
        if (receivedAmt > 0) {
            Splits.give(_dripsHubStorage().splits, userId, userId, assetId, receivedAmt);
        }
    }

    /// @notice Returns user's received but not split yet funds.
    /// @param userId The user ID
    /// @param assetId The used asset ID.
    /// @return amt The amount received but not split yet.
    function splittable(uint256 userId, uint256 assetId) public view returns (uint128 amt) {
        return Splits.splittable(_dripsHubStorage().splits, userId, assetId);
    }

    /// @notice Splits user's received but not split yet funds among receivers.
    /// @param userId The user ID
    /// @param assetId The used asset ID
    /// @param currReceivers The list of the user's current splits receivers.
    /// @return collectableAmt The amount made collectable for the user
    /// on top of what was collectable before.
    /// @return splitAmt The amount split to the user's splits receivers
    function split(
        uint256 userId,
        uint256 assetId,
        SplitsReceiver[] memory currReceivers
    ) public virtual returns (uint128 collectableAmt, uint128 splitAmt) {
        return Splits.split(_dripsHubStorage().splits, userId, assetId, currReceivers);
    }

    /// @notice Returns user's received funds already split and ready to be collected.
    /// @param userId The user ID
    /// @param assetId The used asset ID.
    /// @return amt The collectable amount.
    function collectable(uint256 userId, uint256 assetId) public view returns (uint128 amt) {
        return Splits.collectable(_dripsHubStorage().splits, userId, assetId);
    }

    /// @notice Collects user's received already split funds
    /// and transfers them out of the drips hub contract to msg.sender.
    /// @param userId The user ID
    /// @param assetId The used asset ID
    /// @return amt The collected amount
    function collect(uint256 userId, uint256 assetId)
        public
        virtual
        onlyAccountOwner(userId)
        returns (uint128 amt)
    {
        amt = Splits.collect(_dripsHubStorage().splits, userId, assetId);
        _transfer(assetId, int128(amt));
    }

    /// @notice Gives funds from the user or their account to the receiver.
    /// The receiver can collect them immediately.
    /// Transfers the funds to be given from the user's wallet to the drips hub contract.
    /// @param userId The user ID
    /// @param receiver The receiver
    /// @param assetId The used asset ID
    /// @param amt The given amount
    function _give(
        uint256 userId,
        uint256 receiver,
        uint256 assetId,
        uint128 amt
    ) internal onlyAccountOwner(userId) {
        Splits.give(_dripsHubStorage().splits, userId, receiver, assetId, amt);
        _transfer(assetId, -int128(amt));
    }

    /// @notice Current user drips hash, see `hashDrips`.
    /// @param userId The user ID
    /// @param assetId The used asset ID
    /// @return currDripsHash The current user account's drips hash
    function dripsHash(uint256 userId, uint256 assetId)
        public
        view
        returns (bytes32 currDripsHash)
    {
        return Drips.dripsHash(_dripsHubStorage().drips, userId, assetId);
    }

    /// @notice Sets the user's or the account's drips configuration.
    /// Transfers funds between the user's wallet and the drips hub contract
    /// to fulfill the change of the drips balance.
    /// @param userId The user ID
    /// @param assetId The used asset ID
    /// @param lastUpdate The timestamp of the last drips update of the user or the account.
    /// If this is the first update, pass zero.
    /// @param lastBalance The drips balance after the last drips update of the user or the account.
    /// If this is the first update, pass zero.
    /// @param currReceivers The list of the drips receivers set in the last drips update
    /// of the user or the account.
    /// If this is the first update, pass an empty array.
    /// @param balanceDelta The drips balance change to be applied.
    /// Positive to add funds to the drips balance, negative to remove them.
    /// @param newReceivers The list of the drips receivers of the user or the account to be set.
    /// Must be sorted by the receivers' addresses, deduplicated and without 0 amtPerSecs.
    /// @return newBalance The new drips balance of the user or the account.
    /// Pass it as `lastBalance` when updating that user or the account for the next time.
    /// @return realBalanceDelta The actually applied drips balance change.
    function _setDrips(
        uint256 userId,
        uint256 assetId,
        uint64 lastUpdate,
        uint128 lastBalance,
        DripsReceiver[] memory currReceivers,
        int128 balanceDelta,
        DripsReceiver[] memory newReceivers
    ) internal onlyAccountOwner(userId) returns (uint128 newBalance, int128 realBalanceDelta) {
        (newBalance, realBalanceDelta) = Drips.setDrips(
            _dripsHubStorage().drips,
            cycleSecs,
            userId,
            assetId,
            lastUpdate,
            lastBalance,
            currReceivers,
            balanceDelta,
            newReceivers
        );
        _transfer(assetId, -realBalanceDelta);
    }

    /// @notice Calculates the hash of the drips configuration.
    /// It's used to verify if drips configuration is the previously set one.
    /// @param update The timestamp of the drips update.
    /// If the drips have never been updated, pass zero.
    /// @param balance The drips balance.
    /// If the drips have never been updated, pass zero.
    /// @param receivers The list of the drips receivers.
    /// Must be sorted by the receivers' addresses, deduplicated and without 0 amtPerSecs.
    /// If the drips have never been updated, pass an empty array.
    /// @return dripsConfigurationHash The hash of the drips configuration
    function hashDrips(
        uint64 update,
        uint128 balance,
        DripsReceiver[] memory receivers
    ) public pure returns (bytes32 dripsConfigurationHash) {
        return Drips.hashDrips(update, balance, receivers);
    }

    /// @notice Sets user splits configuration.
    /// @param userId The user ID
    /// @param receivers The list of the user's splits receivers to be set.
    /// Must be sorted by the splits receivers' addresses, deduplicated and without 0 weights.
    /// Each splits receiver will be getting `weight / TOTAL_SPLITS_WEIGHT`
    /// share of the funds collected by the user.
    function _setSplits(uint256 userId, SplitsReceiver[] memory receivers)
        internal
        onlyAccountOwner(userId)
    {
        Splits.setSplits(_dripsHubStorage().splits, userId, receivers);
    }

    /// @notice Current user's splits hash, see `hashSplits`.
    /// @param userId The user ID
    /// @return currSplitsHash The current user's splits hash
    function splitsHash(uint256 userId) public view returns (bytes32 currSplitsHash) {
        return Splits.splitsHash(_dripsHubStorage().splits, userId);
    }

    /// @notice Calculates the hash of the list of splits receivers.
    /// @param receivers The list of the splits receivers.
    /// Must be sorted by the splits receivers' addresses, deduplicated and without 0 weights.
    /// @return receiversHash The hash of the list of splits receivers.
    function hashSplits(SplitsReceiver[] memory receivers)
        public
        pure
        returns (bytes32 receiversHash)
    {
        return Splits.hashSplits(receivers);
    }

    /// @notice Called when funds need to be transferred between the user and the drips hub.
    /// The function must be called no more than once per transaction.
    /// @param assetId The used asset ID
    /// @param amt The transferred amount.
    /// Positive to transfer funds to the user, negative to transfer from them.
    function _transfer(uint256 assetId, int128 amt) internal virtual;
}
