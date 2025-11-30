// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";

import {StableOracleExchange} from "../../contracts/StableOracleExchange.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {MockRateOracle} from "../../contracts/mocks/MockRateOracle.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract StableOracleExchange_FuzzTest is Test {
    StableOracleExchange exchange;
    MockUSDC usdc;
    MockUSDC usdt;
    MockRateOracle oracle;

    address admin;
    address user;
    address attacker;

    uint256 constant USDC_DEC = 6;
    uint256 constant RATE_PRECISION = 1e18;

    function toUSDC(uint256 v) internal pure returns (uint256) {
        return v * 10**USDC_DEC;
    }

    function setUp() public {
        admin    = address(0xA11CE);
        user     = address(0xB0B);
        attacker = address(0xBAD);

        vm.startPrank(admin);

        exchange = new StableOracleExchange(admin);
        usdc = new MockUSDC("USD Coin", "USDC", admin);
        usdt = new MockUSDC("Tether", "USDT", admin);
        oracle = new MockRateOracle();

        // basic bootstrap: give user some USDC, pool some USDT, give user swap role
        usdc.mint(user, toUSDC(1_000_000));
        usdt.mint(address(exchange), toUSDC(1_000_000));
        exchange.setCanDoExchange(user, true);

        vm.stopPrank();
    }

    /// @notice Fuzz: when swap succeeds, it must pay exact amountOut = amountIn * rate / 1e18
    function testFuzz_Swap_RespectsRateAndMinOut(uint96 amountInRaw, uint96 rateRaw) public {
        uint256 amountIn = uint256(amountInRaw) % toUSDC(10_000);
        if (amountIn == 0) amountIn = 1;

        uint256 rate = uint256(rateRaw) % (100 * RATE_PRECISION); // up to 100x
        if (rate == 0) rate = RATE_PRECISION; // default 1:1

        vm.prank(admin);
        exchange.setRate(address(usdc), address(usdt), rate);
        uint256 expectedOut = (amountIn * rate) / RATE_PRECISION;
        if (expectedOut == 0) return;

        vm.prank(admin);
        usdt.mint(address(exchange), expectedOut);

        vm.startPrank(user);
        usdc.approve(address(exchange), amountIn);

        uint256 usdtBefore = usdt.balanceOf(user);

        uint256 minOut = expectedOut == 0 ? 0 : expectedOut - (expectedOut / 10); // <= expectedOut
        exchange.swap(address(usdc), address(usdt), amountIn, minOut);

        uint256 usdtAfter = usdt.balanceOf(user);
        vm.stopPrank();

        assertEq(usdtAfter - usdtBefore, expectedOut, "amountOut must match formula");
    }

    /// @notice Fuzz: if minAmountOut > expectedOut, swap must revert with SlippageExceeded
    function testFuzz_Swap_RevertsOnSlippage(uint96 amountInRaw, uint96 rateRaw) public {
        uint256 amountIn = uint256(amountInRaw) % toUSDC(10_000);
        if (amountIn == 0) amountIn = 1;

        uint256 rate = uint256(rateRaw) % (100 * RATE_PRECISION);
        if (rate == 0) rate = RATE_PRECISION;

        vm.prank(admin);
        exchange.setRate(address(usdc), address(usdt), rate);

        uint256 expectedOut = (amountIn * rate) / RATE_PRECISION;

        vm.prank(admin);
        usdt.mint(address(exchange), expectedOut);

        vm.startPrank(user);
        usdc.approve(address(exchange), amountIn);

        uint256 minOut = expectedOut + 1;

        if (expectedOut == 0) {
            vm.expectRevert(StableOracleExchange.ZeroAmount.selector);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(
                    StableOracleExchange.SlippageExceeded.selector,
                    expectedOut,
                    minOut
                )
            );
        }

        exchange.swap(address(usdc), address(usdt), amountIn, minOut);
        vm.stopPrank();
    }

    /// @notice Fuzz: syncing rate from oracle should store exactly what oracle returns (if valid & non-zero)
    function testFuzz_SyncRateFromOracle(uint96 rateRaw) public {
        uint256 rate = uint256(rateRaw) % (1_000 * RATE_PRECISION);
        if (rate == 0) rate = RATE_PRECISION; // avoid zero

        vm.prank(admin);
        exchange.setRateOracle(address(oracle));

        // oracle returns rate + valid=true
        oracle.setMockRate(address(usdc), address(usdt), rate, true);

        vm.prank(admin);
        exchange.syncRateFromOracle(address(usdc), address(usdt));

        assertEq(exchange.rates(address(usdc), address(usdt)), rate);
    }

    /// @notice Fuzz: no one without CAN_DO_EXCHANGE role can ever swap
    function testFuzz_Swap_RevertsWithoutRole(uint96 amountInRaw) public {
        uint256 amountIn = uint256(amountInRaw) % toUSDC(10_000);
        if (amountIn == 0) amountIn = 1;

        vm.startPrank(admin);
        exchange.setRate(address(usdc), address(usdt), RATE_PRECISION);
        usdc.mint(attacker, amountIn);
        usdt.mint(address(exchange), amountIn);
        vm.stopPrank();

        vm.startPrank(attacker);
        usdc.approve(address(exchange), amountIn);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                attacker,
                exchange.CAN_DO_EXCHANGE()
            )
        );
        exchange.swap(address(usdc), address(usdt), amountIn, 0);
        vm.stopPrank();
    }

    function testFuzz_Swap_DifferentDecimalsFormula(uint96 amountInRaw, uint96 rateRaw) public {
        MockERC20 dai = new MockERC20("Dai Stable", "DAI", 18);

        uint256 amountIn = uint256(amountInRaw) % (100_000 ether);
        if (amountIn == 0) amountIn = 1 ether;

        uint256 rate = uint256(rateRaw) % (10 * RATE_PRECISION);
        if (rate == 0) rate = RATE_PRECISION;

        vm.startPrank(admin);
        dai.mint(user, amountIn);
        exchange.setRate(address(dai), address(usdc), rate);

        uint8 inDec = dai.decimals();
        uint8 outDec = usdc.decimals();
        uint256 expectedOut =
            (amountIn * rate * (10 ** outDec)) /
            (RATE_PRECISION * (10 ** inDec));

        if (expectedOut > 0) {
            usdc.mint(address(exchange), expectedOut);
        }
        vm.stopPrank();

        vm.startPrank(user);
        dai.approve(address(exchange), amountIn);

        if (expectedOut == 0) {
            vm.expectRevert(StableOracleExchange.ZeroAmount.selector);
            exchange.swap(address(dai), address(usdc), amountIn, 0);
            vm.stopPrank();
            return;
        }

        uint256 before = usdc.balanceOf(user);
        exchange.swap(address(dai), address(usdc), amountIn, 0);
        uint256 afterSwap = usdc.balanceOf(user);
        vm.stopPrank();

        assertEq(afterSwap - before, expectedOut, "correct decimals conversion must match expectedOut");
    }
}