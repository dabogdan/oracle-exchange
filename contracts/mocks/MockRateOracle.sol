// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IRateOracle} from "../StableOracleExchange.sol";

/**
 * @title MockRateOracle
 * @dev A mock oracle for testing purposes. Allows setting a mock rate and validity
 *      for any given token pair.
 */
contract MockRateOracle is IRateOracle {
    mapping(address => mapping(address => uint256)) private _mockRates;
    mapping(address => mapping(address => bool)) private _mockValidity;

    function setMockRate(address tokenIn, address tokenOut, uint256 rate, bool valid) external {
        _mockRates[tokenIn][tokenOut] = rate;
        _mockValidity[tokenIn][tokenOut] = valid;
    }

    function getRate(address tokenIn, address tokenOut) external view returns (uint256 rate, bool valid) {
        return (_mockRates[tokenIn][tokenOut], _mockValidity[tokenIn][tokenOut]);
    }
}