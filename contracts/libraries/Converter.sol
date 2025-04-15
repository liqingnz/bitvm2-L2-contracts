// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Constants} from "../Constants.sol";

library Converter {
    uint8 constant BtcDecimals = 8;

    function amountFromSats(uint64 amountSats) internal pure returns(uint) {
        uint8  TokenDecimals = Constants.TokenDecimals;
        if (TokenDecimals >= BtcDecimals) {
            return uint(amountSats * uint64(10 ** (TokenDecimals - BtcDecimals))); 
        } else {
            return uint(amountSats / uint64(10 ** (BtcDecimals - TokenDecimals)));
        }
    }

    function amountToSats(uint amount) internal pure returns(uint64) {
        uint8  TokenDecimals = Constants.TokenDecimals;
        if (TokenDecimals >= BtcDecimals) {
            return uint64(amount / uint(10 ** (TokenDecimals - BtcDecimals)));
        } else {
            return uint64(amount * uint(10 ** (BtcDecimals - TokenDecimals)));
        }
    }
}
