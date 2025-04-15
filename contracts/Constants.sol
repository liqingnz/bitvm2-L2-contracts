// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

library Constants {
    bytes8 constant magic_bytes = 0x3437353435343336; // hex(hex("GTT6")) Testnet
    // bytes8 magic_bytes = 0x3437353435363336; // hex(hex("GTV6")) Mainnet

    uint8 constant TokenDecimals = 18; // TODO, update decimals before compile 
}