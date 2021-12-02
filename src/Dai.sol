// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.7;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

interface IDai is IERC20 {
    function permit(
        address holder,
        address spender,
        uint256 nonce,
        uint256 expiry,
        bool allowed,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}
