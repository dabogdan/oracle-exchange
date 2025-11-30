// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";

import {StableOracleExchange} from "../../contracts/StableOracleExchange.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";

contract StableOracleExchangeHandler {
    StableOracleExchange public exchange;
    MockUSDC public usdc;
    MockUSDC public usdt;

    uint256 public initialUsdcSupply;
    uint256 public initialUsdtSupply;

    uint256 public constant USDC_DEC = 6;
    uint256 public constant RATE_PRECISION = 1e18;

    constructor() {
        // handler itself is admin
        exchange = new StableOracleExchange(address(this));

        usdc = new MockUSDC("USDC", "USDC", address(this));
        usdt = new MockUSDC("USDT", "USDT", address(this));

        // initial liquidity:
        uint256 usdcAmt = 1_000_000 * 10**USDC_DEC;
        uint256 usdtAmt = 1_000_000 * 10**USDC_DEC;

        usdc.mint(address(this), usdcAmt);
        usdt.mint(address(exchange), usdtAmt);

        initialUsdcSupply = usdc.totalSupply();
        initialUsdtSupply = usdt.totalSupply();

        exchange.setCanDoExchange(address(this), true);
        exchange.setRate(address(usdc), address(usdt), RATE_PRECISION); // 1:1 to start
    }

    function _boundUint(uint256 x, uint256 minVal, uint256 maxVal) internal pure returns (uint256) {
        if (maxVal == minVal) return minVal;
        uint256 range = maxVal - minVal;
        return minVal + (x % (range + 1));
    }

    /// @notice Random swap as "user" (handler is the user)
    function swapSome(uint96 amountInRaw, uint96 minOutRaw) external {
        // amountIn in [1, initialUsdcSupply/10]
        uint256 maxIn = initialUsdcSupply / 10;
        if (maxIn == 0) maxIn = 1;
        uint256 amountIn = _boundUint(uint256(amountInRaw), 1, maxIn);

        // minOut in [0, amountIn]
        uint256 minOut = _boundUint(uint256(minOutRaw), 0, amountIn);

        usdc.approve(address(exchange), amountIn);

        // Ignore failures – invariant runner will explore many sequences
        try exchange.swap(address(usdc), address(usdt), amountIn, minOut) {
        } catch {
        }
    }

    /// @notice Randomly change rate to a positive number
    function changeRate(uint96 rateRaw) external {
        uint256 rate = _boundUint(uint256(rateRaw), 1, 100 * RATE_PRECISION);
        exchange.setRate(address(usdc), address(usdt), rate);
    }

    /// @notice Flip pause state: if paused, try unpause; if not, try pause.
    function flipPause() external {
        if (exchange.paused()) {
            try exchange.unpause() {} catch {}
        } else {
            try exchange.pause() {} catch {}
        }
    }
}