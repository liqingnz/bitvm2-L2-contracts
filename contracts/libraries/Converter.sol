// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

library Converter {
    uint8 constant TokenDecimals = 18; // TODO, update decimals before compile
    uint8 constant BtcDecimals = 8;

    function amountFromSats(uint64 amountSats) internal pure returns (uint) {
        // return uint(amountSats / uint64(10 ** (BtcDecimals - TokenDecimals))); // if TokenDecimals < 8
        return uint(amountSats * uint64(10 ** (TokenDecimals - BtcDecimals)));
    }

    function amountToSats(uint amount) internal pure returns (uint64) {
        // return uint(amountSats * uint64(10 ** (BtcDecimals - TokenDecimals))); // if TokenDecimals < 8
        return uint64(amount / uint(10 ** (TokenDecimals - BtcDecimals)));
    }
}
