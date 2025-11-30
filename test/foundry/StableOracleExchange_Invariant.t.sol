// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "forge-std/StdInvariant.sol";

import {StableOracleExchange} from "../../contracts/StableOracleExchange.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {StableOracleExchangeHandler} from "./StableOracleExchangeHandler.t.sol";

contract StableOracleExchange_InvariantTest is StdInvariant, Test {
    StableOracleExchangeHandler public handler;

    function setUp() public {
        handler = new StableOracleExchangeHandler();

        // Fuzz the handler's methods, not the raw exchange
        targetContract(address(handler));
    }

    /// @notice Admin (handler) must always keep DEFAULT_ADMIN_ROLE on the exchange.
    function invariant_AdminAlwaysHasDefaultAdminRole() public view {
        StableOracleExchange ex = handler.exchange();
        bytes32 adminRole = ex.DEFAULT_ADMIN_ROLE();
        assertTrue(ex.hasRole(adminRole, address(handler)), "admin role lost");
    }

    /// @notice Total token supply must never change (no mint/burn via exchange logic).
    function invariant_TotalSupplyConstant() public view {
        MockUSDC usdc = handler.usdc();
        MockUSDC usdt = handler.usdt();

        assertEq(usdc.totalSupply(), handler.initialUsdcSupply(), "USDC supply changed");
        assertEq(usdt.totalSupply(), handler.initialUsdtSupply(), "USDT supply changed");
    }

    /// @notice All USDC always lives either on handler or on the exchange.
    function invariant_USDCConservation() public view {
        StableOracleExchange ex = handler.exchange();
        MockUSDC usdc = handler.usdc();

        uint256 total =
            usdc.balanceOf(address(handler)) +
            usdc.balanceOf(address(ex));

        assertEq(total, handler.initialUsdcSupply(), "USDC leaked to a third party");
    }

    /// @notice All USDT always lives either on handler or on the exchange.
    function invariant_USDTConservation() public view {
        StableOracleExchange ex = handler.exchange();
        MockUSDC usdt = handler.usdt();

        uint256 total =
            usdt.balanceOf(address(handler)) +
            usdt.balanceOf(address(ex));

        assertEq(total, handler.initialUsdtSupply(), "USDT leaked to a third party");
    }

    /// @notice For the main test pair (USDC, USDT), handler never sets zero rate.
    function invariant_PairRateAlwaysPositive() public view {
        StableOracleExchange ex = handler.exchange();
        uint256 rate = ex.rates(address(handler.usdc()), address(handler.usdt()));
        assertTrue(rate > 0, "rate for main pair became zero");
    }
}