// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.7;

import {DSTest} from "ds-test/test.sol";
import {DripsHubUser} from "./DripsHubUser.t.sol";
import {DripsReceiver, DripsHub, Receiver} from "../DripsHub.sol";

abstract contract DripsHubUserUtils is DSTest {
    mapping(DripsHubUser => bytes) internal senderStates;
    mapping(DripsHubUser => mapping(uint256 => bytes)) internal subSenderStates;
    mapping(DripsHubUser => bytes) internal currDripsReceivers;

    function getSenderState(DripsHubUser user)
        internal
        returns (
            uint64 lastUpdate,
            uint128 lastBalance,
            Receiver[] memory currReceivers
        )
    {
        (lastUpdate, lastBalance, currReceivers) = decodeSenderState(senderStates[user]);
        assertSenderState(user, lastUpdate, lastBalance, currReceivers);
    }

    function getSenderState(DripsHubUser user, uint256 subSenderId)
        internal
        returns (
            uint64 lastUpdate,
            uint128 lastBalance,
            Receiver[] memory currReceivers
        )
    {
        (lastUpdate, lastBalance, currReceivers) = decodeSenderState(
            subSenderStates[user][subSenderId]
        );
        assertSenderState(user, subSenderId, lastUpdate, lastBalance, currReceivers);
    }

    function setSenderState(
        DripsHubUser user,
        uint128 newBalance,
        Receiver[] memory newReceivers
    ) internal {
        uint64 currTimestamp = uint64(block.timestamp);
        assertSenderState(user, currTimestamp, newBalance, newReceivers);
        senderStates[user] = abi.encode(currTimestamp, newBalance, newReceivers);
    }

    function setSenderState(
        DripsHubUser user,
        uint256 subSenderId,
        uint128 newBalance,
        Receiver[] memory newReceivers
    ) internal {
        uint64 currTimestamp = uint64(block.timestamp);
        assertSenderState(user, subSenderId, currTimestamp, newBalance, newReceivers);
        subSenderStates[user][subSenderId] = abi.encode(currTimestamp, newBalance, newReceivers);
    }

    function decodeSenderState(bytes storage encoded)
        internal
        view
        returns (
            uint64 lastUpdate,
            uint128 lastBalance,
            Receiver[] memory
        )
    {
        if (encoded.length == 0) {
            return (0, 0, new Receiver[](0));
        } else {
            return abi.decode(encoded, (uint64, uint128, Receiver[]));
        }
    }

    function getCurrDripsReceivers(DripsHubUser user)
        internal
        view
        returns (DripsReceiver[] memory)
    {
        bytes storage encoded = currDripsReceivers[user];
        if (encoded.length == 0) {
            return new DripsReceiver[](0);
        } else {
            return abi.decode(encoded, (DripsReceiver[]));
        }
    }

    function setCurrDripsReceivers(DripsHubUser user, DripsReceiver[] memory newReceivers)
        internal
    {
        currDripsReceivers[user] = abi.encode(newReceivers);
    }

    function receivers() internal pure returns (Receiver[] memory list) {
        list = new Receiver[](0);
    }

    function receivers(DripsHubUser user, uint128 amtPerSec)
        internal
        pure
        returns (Receiver[] memory list)
    {
        list = new Receiver[](1);
        list[0] = Receiver(address(user), amtPerSec);
    }

    function receivers(
        DripsHubUser user1,
        uint128 amtPerSec1,
        DripsHubUser user2,
        uint128 amtPerSec2
    ) internal pure returns (Receiver[] memory list) {
        list = new Receiver[](2);
        list[0] = Receiver(address(user1), amtPerSec1);
        list[1] = Receiver(address(user2), amtPerSec2);
    }

    function updateSender(
        DripsHubUser user,
        uint128 balanceFrom,
        uint128 balanceTo,
        Receiver[] memory newReceivers
    ) internal {
        int128 balanceDelta = int128(balanceTo) - int128(balanceFrom);
        uint256 expectedBalance = uint256(int256(user.balance()) - balanceDelta);
        (uint64 lastUpdate, uint128 lastBalance, Receiver[] memory currReceivers) = getSenderState(
            user
        );

        (uint128 newBalance, int128 realBalanceDelta) = user.updateSender(
            lastUpdate,
            lastBalance,
            currReceivers,
            balanceDelta,
            newReceivers
        );

        setSenderState(user, newBalance, newReceivers);
        assertEq(newBalance, balanceTo, "Invalid sender balance");
        assertEq(realBalanceDelta, balanceDelta, "Invalid real balance delta");
        assertBalance(user, expectedBalance);
    }

    function assertSenderState(
        DripsHubUser user,
        uint64 lastUpdate,
        uint128 balance,
        Receiver[] memory currReceivers
    ) internal {
        bytes32 actual = user.senderStateHash();
        bytes32 expected = user.hashSenderState(lastUpdate, balance, currReceivers);
        assertEq(actual, expected, "Invalid sender state");
    }

    function assertSenderBalance(DripsHubUser user, uint128 expected) internal {
        changeBalance(user, expected, expected);
    }

    function changeBalance(
        DripsHubUser user,
        uint128 balanceFrom,
        uint128 balanceTo
    ) internal {
        (, , Receiver[] memory currReceivers) = getSenderState(user);
        updateSender(user, balanceFrom, balanceTo, currReceivers);
    }

    function assertSetReceiversReverts(
        DripsHubUser user,
        Receiver[] memory newReceivers,
        string memory expectedReason
    ) internal {
        (uint64 lastUpdate, uint128 lastBalance, Receiver[] memory currReceivers) = getSenderState(
            user
        );
        assertUpdateSenderReverts(
            user,
            lastUpdate,
            lastBalance,
            currReceivers,
            0,
            newReceivers,
            expectedReason
        );
    }

    function assertUpdateSenderReverts(
        DripsHubUser user,
        uint64 lastUpdate,
        uint128 lastBalance,
        Receiver[] memory currReceivers,
        int128 balanceDelta,
        Receiver[] memory newReceivers,
        string memory expectedReason
    ) internal {
        try user.updateSender(lastUpdate, lastBalance, currReceivers, balanceDelta, newReceivers) {
            assertTrue(false, "Sender update hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, expectedReason, "Invalid sender update revert reason");
        }
    }

    function updateSender(
        DripsHubUser user,
        uint256 subSenderId,
        uint128 balanceFrom,
        uint128 balanceTo,
        Receiver[] memory newReceivers
    ) internal {
        int128 balanceDelta = int128(balanceTo) - int128(balanceFrom);
        uint256 expectedBalance = uint256(int256(user.balance()) - balanceDelta);
        (uint64 lastUpdate, uint128 lastBalance, Receiver[] memory currReceivers) = getSenderState(
            user,
            subSenderId
        );

        (uint128 newBalance, int128 realBalanceDelta) = user.updateSender(
            subSenderId,
            lastUpdate,
            lastBalance,
            currReceivers,
            balanceDelta,
            newReceivers
        );

        setSenderState(user, subSenderId, newBalance, newReceivers);
        assertEq(newBalance, balanceTo, "Invalid sender balance");
        assertEq(realBalanceDelta, balanceDelta, "Invalid real balance delta");
        assertBalance(user, expectedBalance);
    }

    function assertSenderState(
        DripsHubUser user,
        uint256 subSenderId,
        uint64 lastUpdate,
        uint128 lastBalance,
        Receiver[] memory currReceivers
    ) internal {
        bytes32 actual = user.senderStateHash(subSenderId);
        bytes32 expected = user.hashSenderState(lastUpdate, lastBalance, currReceivers);
        assertEq(actual, expected, "Invalid sub-sender state");
    }

    function changeBalance(
        DripsHubUser user,
        uint256 subSenderId,
        uint128 balanceFrom,
        uint128 balanceTo
    ) internal {
        (, , Receiver[] memory curr) = getSenderState(user, subSenderId);
        updateSender(user, subSenderId, balanceFrom, balanceTo, curr);
    }

    function dripsReceivers() internal pure returns (DripsReceiver[] memory list) {
        list = new DripsReceiver[](0);
    }

    function dripsReceivers(DripsHubUser user, uint32 weight)
        internal
        pure
        returns (DripsReceiver[] memory list)
    {
        list = new DripsReceiver[](1);
        list[0] = DripsReceiver(address(user), weight);
    }

    function dripsReceivers(
        DripsHubUser user1,
        uint32 weight1,
        DripsHubUser user2,
        uint32 weight2
    ) internal pure returns (DripsReceiver[] memory list) {
        list = new DripsReceiver[](2);
        list[0] = DripsReceiver(address(user1), weight1);
        list[1] = DripsReceiver(address(user2), weight2);
    }

    function setDripsReceivers(DripsHubUser user, DripsReceiver[] memory newReceivers) internal {
        setDripsReceivers(user, newReceivers, 0, 0);
    }

    function setDripsReceivers(
        DripsHubUser user,
        DripsReceiver[] memory newReceivers,
        uint128 expectedCollected,
        uint128 expectedDripped
    ) internal {
        DripsReceiver[] memory curr = getCurrDripsReceivers(user);
        assertDripsReceivers(user, curr);
        assertCollectable(user, expectedCollected, expectedDripped);
        uint256 expectedBalance = user.balance() + expectedCollected;

        (uint128 collected, uint128 dripped) = user.setDripsReceivers(curr, newReceivers);

        setCurrDripsReceivers(user, newReceivers);
        assertDripsReceivers(user, newReceivers);
        assertEq(collected, expectedCollected, "Invalid collected amount");
        assertEq(dripped, expectedDripped, "Invalid dripped amount");
        assertCollectable(user, 0, 0);
        assertBalance(user, expectedBalance);
    }

    function assertSetDripsReceiversReverts(
        DripsHubUser user,
        DripsReceiver[] memory newReceivers,
        string memory expectedReason
    ) internal {
        DripsReceiver[] memory curr = getCurrDripsReceivers(user);
        assertDripsReceivers(user, curr);
        try user.setDripsReceivers(curr, newReceivers) {
            assertTrue(false, "Drips receivers update hasn't reverted");
        } catch Error(string memory reason) {
            assertEq(reason, expectedReason, "Invalid drips receivers update revert reason");
        }
    }

    function assertDripsReceivers(DripsHubUser user, DripsReceiver[] memory expectedReceivers)
        internal
    {
        bytes32 actual = user.dripsReceiversHash();
        bytes32 expected = user.hashDripsReceivers(expectedReceivers);
        assertEq(actual, expected, "Invalid drips receivers list hash");
    }

    function collect(DripsHubUser user, uint128 expectedAmt) internal {
        collect(user, user, expectedAmt, 0);
    }

    function collect(
        DripsHubUser user,
        uint128 expectedCollected,
        uint128 expectedDripped
    ) internal {
        collect(user, user, expectedCollected, expectedDripped);
    }

    function collect(
        DripsHubUser user,
        DripsHubUser collected,
        uint128 expectedAmt
    ) internal {
        collect(user, collected, expectedAmt, 0);
    }

    function collect(
        DripsHubUser user,
        DripsHubUser collected,
        uint128 expectedCollected,
        uint128 expectedDripped
    ) internal {
        assertCollectable(collected, expectedCollected, expectedDripped);
        uint256 expectedBalance = collected.balance() + expectedCollected;

        (uint128 collectedAmt, uint128 drippedAmt) = user.collect(
            address(collected),
            getCurrDripsReceivers(user)
        );

        assertEq(collectedAmt, expectedCollected, "Invalid collected amount");
        assertEq(drippedAmt, expectedDripped, "Invalid dripped amount");
        assertCollectable(collected, 0);
        assertBalance(collected, expectedBalance);
    }

    function assertCollectable(DripsHubUser user, uint128 expected) internal {
        assertCollectable(user, expected, 0);
    }

    function assertCollectable(
        DripsHubUser user,
        uint128 expectedCollected,
        uint128 expectedDripped
    ) internal {
        (uint128 actualCollected, uint128 actualDripped) = user.collectable(
            getCurrDripsReceivers(user)
        );
        assertEq(actualCollected, expectedCollected, "Invalid collectable");
        assertEq(actualDripped, expectedDripped, "Invalid drippable");
    }

    function flushCycles(
        DripsHubUser user,
        uint64 expectedFlushableBefore,
        uint64 maxCycles,
        uint64 expectedFlushableAfter
    ) internal {
        assertFlushableCycles(user, expectedFlushableBefore);
        uint64 flushableLeft = user.flushCycles(maxCycles);
        assertEq(flushableLeft, expectedFlushableAfter, "Invalid flushable cycles left");
        assertFlushableCycles(user, expectedFlushableAfter);
    }

    function assertFlushableCycles(DripsHubUser user, uint64 expectedFlushable) internal {
        uint64 actualFlushable = user.flushableCycles();
        assertEq(actualFlushable, expectedFlushable, "Invalid flushable cycles");
    }

    function assertBalance(DripsHubUser user, uint256 expected) internal {
        assertEq(user.balance(), expected, "Invalid balance");
    }
}