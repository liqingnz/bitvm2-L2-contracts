// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IBitcoinSPV {
    function blockHash(uint256 height) external view returns (bytes32);
}
