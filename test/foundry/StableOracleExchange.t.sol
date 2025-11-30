// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
 
import {StableOracleExchange} from "../../contracts/StableOracleExchange.sol";
import {MockUSDC} from "../../contracts/mocks/MockUSDC.sol";
import {MockRateOracle} from "../../contracts/mocks/MockRateOracle.sol";
import {MockReentrantERC20} from "../../contracts/mocks/MockReentrantERC20.sol";
import {MockMaliciousERC20} from "../../contracts/mocks/MockMaliciousToken.sol";
import {MockNoDecimals} from "../../contracts/mocks/MockNoDecimals.sol";
import {MockERC20} from "../../contracts/mocks/MockERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MockRevertingDecimals} from "../../contracts/mocks/MockRevertingDecimals.sol";

contract StableOracleExchangeTest is Test {
    // actors
    address admin;
    address user;
    address attacker;

    // contracts
    StableOracleExchange exchange;
    MockUSDC usdc;
    MockUSDC usdt;
    MockRateOracle oracle;

    uint256 constant USDC_DEC = 6;

    uint256 RATE_1_TO_1;
    uint256 RATE_2_TO_1;

    function toUSDC(uint256 v) internal pure returns (uint256) {
        return v * 10**USDC_DEC;
    }

    function setUp() public {
        admin = address(0xA11CE);
        user = address(0xB0B);
        attacker = address(0xBAD);

        vm.label(admin, "ADMIN");
        vm.label(user, "USER");
        vm.label(attacker, "ATTACKER");

        vm.startPrank(admin);

        RATE_1_TO_1 = 1e18;
        RATE_2_TO_1 = 2e18;

        exchange = new StableOracleExchange(admin);

        usdc = new MockUSDC("USD Coin", "USDC", admin);
        usdt = new MockUSDC("Tether", "USDT", admin);

        usdc.mint(user, toUSDC(1000));
        usdt.mint(address(exchange), toUSDC(2000));

        oracle = new MockRateOracle();

        exchange.setCanDoExchange(user, true);

        vm.stopPrank();
    }

    // ---------------------------------------------------------
    // BASIC CONFIG
    // ---------------------------------------------------------

    function testRevokeRole() public {
        vm.prank(admin);
        exchange.setCanDoExchange(user, false);
        bool has = exchange.hasRole(exchange.CAN_DO_EXCHANGE(), user);
        assertFalse(has);
    }

    function testRevokeNonExistingRole() public {
        bytes32 role = exchange.CAN_DO_EXCHANGE();
        assertFalse(exchange.hasRole(role, attacker));

        vm.prank(admin);
        exchange.setCanDoExchange(attacker, false);

        assertFalse(exchange.hasRole(role, attacker));
    }

    function testAdminCorrect() public view {
        bytes32 adminRole = exchange.DEFAULT_ADMIN_ROLE();
        assertTrue(exchange.hasRole(adminRole, admin));
    }

    function testSetManualRate() public {
        vm.prank(admin);
        exchange.setRate(address(usdc), address(usdt), RATE_1_TO_1);

        assertEq(exchange.rates(address(usdc), address(usdt)), RATE_1_TO_1);
    }

    // ---------------------------------------------------------
    // ORACLE SYNC
    // ---------------------------------------------------------

    function testSetOracle() public {
        vm.expectEmit(true,true,true,true);
        emit StableOracleExchange.OracleUpdated(
            address(0),
            address(oracle),
            admin
        );
        vm.prank(admin);
        exchange.setRateOracle(address(oracle));
    }

    function testSyncOracleSuccess() public {
        vm.prank(admin);
        exchange.setRateOracle(address(oracle));

        oracle.setMockRate(address(usdc), address(usdt), RATE_2_TO_1, true);

        vm.expectEmit(true,true,true,true);
        emit StableOracleExchange.RateUpdated(
            address(usdc),
            address(usdt),
            0,
            RATE_2_TO_1,
            admin
        );

        vm.prank(admin);
        exchange.syncRateFromOracle(address(usdc), address(usdt));

        assertEq(exchange.rates(address(usdc), address(usdt)), RATE_2_TO_1);
    }

    function testSyncOracleInvalid() public {
        vm.prank(admin);
        exchange.setRateOracle(address(oracle));

        oracle.setMockRate(address(usdc), address(usdt), RATE_1_TO_1, false);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(
            StableOracleExchange.OracleRateInvalid.selector,
            address(usdc),
            address(usdt)
        ));
        exchange.syncRateFromOracle(address(usdc), address(usdt));
    }

    function testSyncOracleZeroRate() public {
        vm.prank(admin);
        exchange.setRateOracle(address(oracle));

        oracle.setMockRate(address(usdc), address(usdt), 0, true);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(
            StableOracleExchange.OracleRateInvalid.selector,
            address(usdc),
            address(usdt)
        ));
        exchange.syncRateFromOracle(address(usdc), address(usdt));
    }

    function testSetRateTokenInZero() public {
        vm.prank(admin);
        vm.expectRevert(StableOracleExchange.ZeroAddress.selector);
        exchange.setRate(address(0), address(usdc), RATE_1_TO_1);
    }

    function testSetRateTokenOutZero() public {
        vm.prank(admin);
        vm.expectRevert(StableOracleExchange.ZeroAddress.selector);
        exchange.setRate(address(usdc), address(0), RATE_1_TO_1);
    }

    function testSetRateSameToken() public {
        vm.prank(admin);
        vm.expectRevert(StableOracleExchange.SameToken.selector);
        exchange.setRate(address(usdc), address(usdc), RATE_1_TO_1);
    }

    // ---------------------------------------------------------
    // SWAP
    // ---------------------------------------------------------

    function testSwap1to1() public {
        vm.startPrank(admin);
        exchange.setRate(address(usdc), address(usdt), RATE_1_TO_1);
        vm.stopPrank();

        uint256 amountIn = toUSDC(100);

        vm.startPrank(user);
        usdc.approve(address(exchange), amountIn);

        uint256 usdcBefore = usdc.balanceOf(user);
        uint256 usdtBefore = usdt.balanceOf(user);

        vm.expectEmit(true,true,true,true);
        emit StableOracleExchange.TokensExchanged(
            user, address(usdc), address(usdt), amountIn, amountIn, RATE_1_TO_1
        );

        exchange.swap(address(usdc), address(usdt), amountIn, amountIn);

        uint256 usdcAfter = usdc.balanceOf(user);
        uint256 usdtAfter = usdt.balanceOf(user);

        assertEq(usdcBefore - usdcAfter, amountIn);
        assertEq(usdtAfter - usdtBefore, amountIn);
        vm.stopPrank();
    }

    function testSwapWithDeadlineBeforeDeadline() public {
        vm.startPrank(admin);
        exchange.setRate(address(usdc), address(usdt), RATE_1_TO_1);
        vm.stopPrank();

        uint256 amountIn = toUSDC(100);

        vm.startPrank(user);
        usdc.approve(address(exchange), amountIn);

        uint256 deadline = block.timestamp + 3600;

        uint256 usdcBefore = usdc.balanceOf(user);
        uint256 usdtBefore = usdt.balanceOf(user);

        vm.expectEmit(true,true,true,true);
        emit StableOracleExchange.TokensExchanged(
            user, address(usdc), address(usdt), amountIn, amountIn, RATE_1_TO_1
        );

        exchange.swapWithDeadline(address(usdc), address(usdt), amountIn, amountIn, deadline);

        uint256 usdcAfter = usdc.balanceOf(user);
        uint256 usdtAfter = usdt.balanceOf(user);

        assertEq(usdcBefore - usdcAfter, amountIn);
        assertEq(usdtAfter - usdtBefore, amountIn);

        vm.stopPrank();
    }

    function testSwapWithDeadlineExpired() public {
        vm.startPrank(admin);
        exchange.setRate(address(usdc), address(usdt), RATE_1_TO_1);
        vm.stopPrank();

        uint256 amountIn = toUSDC(50);

        vm.startPrank(user);
        usdc.approve(address(exchange), amountIn);

        uint256 pastDeadline = 0;

        vm.expectRevert(
            abi.encodeWithSelector(
                StableOracleExchange.ExpiredQuote.selector,
                pastDeadline,
                block.timestamp
            )
        );
        exchange.swapWithDeadline(address(usdc), address(usdt), amountIn, 0, pastDeadline);

        vm.stopPrank();
    }

    // swapWithDeadline normal branch (just executing)
    function testSwapWithDeadlineNormal() public {
        vm.prank(admin);
        exchange.setRate(address(usdc), address(usdt), RATE_1_TO_1);

        vm.startPrank(user);
        uint256 amountIn = toUSDC(10);
        usdc.approve(address(exchange), amountIn);

        uint256 deadline = block.timestamp + 1000;
        exchange.swapWithDeadline(address(usdc), address(usdt), amountIn, 0, deadline);
        vm.stopPrank();
    }

    function testSwapWithDeadlinePaused() public {
        vm.prank(admin);
        exchange.setRate(address(usdc), address(usdt), RATE_1_TO_1);

        uint256 amountIn = toUSDC(10);

        vm.startPrank(user);
        usdc.approve(address(exchange), amountIn);
        vm.stopPrank();

        vm.prank(admin);
        exchange.pause();

        uint256 deadline = block.timestamp + 3600;

        vm.prank(user);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        exchange.swapWithDeadline(address(usdc), address(usdt), amountIn, 0, deadline);
    }

    function testSwapWithDeadlineNoRole() public {
        vm.prank(admin);
        exchange.setRate(address(usdc), address(usdt), RATE_1_TO_1);

        uint256 amountIn = toUSDC(50);

        vm.prank(admin);
        usdc.mint(attacker, amountIn);

        vm.startPrank(attacker);
        usdc.approve(address(exchange), amountIn);

        uint256 deadline = block.timestamp + 3600;

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                attacker,
                exchange.CAN_DO_EXCHANGE()
            )
        );

        exchange.swapWithDeadline(address(usdc), address(usdt), amountIn, 0, deadline);

        vm.stopPrank();
    }

    // -------------------------------
    // reentrancy on swapWithDeadline
    // -------------------------------
    function testReentrancySwapWithDeadline() public {
        MockReentrantERC20 reent = new MockReentrantERC20();
        vm.prank(admin);
        reent.mint(user, toUSDC(50));

        vm.prank(admin);
        usdt.mint(address(exchange), toUSDC(100));

        vm.prank(admin);
        exchange.setRate(address(reent), address(usdt), RATE_1_TO_1);

        vm.prank(admin);
        exchange.setCanDoExchange(address(reent), true); // Grant role to the malicious contract

        vm.prank(user);
        reent.approve(address(exchange), toUSDC(50));

        reent.setReenterTarget(address(exchange), address(usdt));
        reent.setReenterFlag(true);
        reent.setCallSwapWithDeadline(true);

        uint256 deadline = block.timestamp + 3600;

        vm.startPrank(user);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        exchange.swapWithDeadline(address(reent), address(usdt), toUSDC(50), 0, deadline);
        vm.stopPrank();
    }

    // ---------------------------------------------------------
    // decimals mismatch bug test
    // ---------------------------------------------------------
    function testSwapDifferentDecimals() public {
        MockERC20 dai = new MockERC20("Dai Stablecoin", "DAI", 18);
        vm.prank(admin);
        dai.mint(user, 100 ether);

        vm.prank(admin);
        exchange.setRate(address(dai), address(usdc), RATE_1_TO_1);

        uint256 amountIn = 100 ether;

        uint8 daiDecimals = 18;
        uint8 usdcDecimals = 6;
        uint256 expectedOut = (amountIn * RATE_1_TO_1 * (10**usdcDecimals)) / (exchange.RATE_PRECISION() * (10**daiDecimals));

        vm.prank(admin);
        usdc.mint(address(exchange), expectedOut);

        vm.startPrank(user);
        dai.approve(address(exchange), amountIn);

        uint256 usdcBefore = usdc.balanceOf(user);

        vm.expectEmit(true,true,true,true);
        emit StableOracleExchange.TokensExchanged(
            user, address(dai), address(usdc), amountIn, expectedOut, RATE_1_TO_1
        );

        exchange.swap(address(dai), address(usdc), amountIn, 0);
        vm.stopPrank();

        uint256 usdcAfter = usdc.balanceOf(user);
        assertEq(usdcAfter - usdcBefore, expectedOut, "User should receive the correctly calculated amount");
    }

    function testSwapWithNoDecimalsToken() public {
        vm.prank(admin);
        MockNoDecimals noDec = new MockNoDecimals();

        vm.prank(admin);
        noDec.mint(user, 100 ether); // Mint 100 tokens (defaults to 18 decimals logic)

        vm.prank(admin);
        exchange.setRate(address(noDec), address(usdc), RATE_1_TO_1);

        uint256 amountIn = 100 ether;

        uint256 expectedOut = toUSDC(100);

        vm.prank(admin);
        usdc.mint(address(exchange), expectedOut);

        uint256 usdcBefore = usdc.balanceOf(user);

        vm.startPrank(user);
        noDec.approve(address(exchange), amountIn);

        exchange.swap(address(noDec), address(usdc), amountIn, 0);
        vm.stopPrank();

        uint256 usdcAfter = usdc.balanceOf(user);
        assertEq(usdcAfter - usdcBefore, expectedOut, "User should receive correct amount for no-decimals token");
    }

    function testSwapTo18DecimalToken() public {
        MockERC20 dai = new MockERC20("Dai Stablecoin", "DAI", 18);

        vm.prank(admin);
        exchange.setRate(address(usdc), address(dai), RATE_1_TO_1);

        uint256 amountIn = toUSDC(100); // 100 USDC (6 decimals)
        uint256 expectedOut = 100 ether;

        vm.prank(admin);
        dai.mint(address(exchange), expectedOut);

        vm.startPrank(user);
        usdc.approve(address(exchange), amountIn);

        uint256 daiBefore = dai.balanceOf(user);
        exchange.swap(address(usdc), address(dai), amountIn, 0);
        uint256 daiAfter = dai.balanceOf(user);

        assertEq(daiAfter - daiBefore, expectedOut, "User should receive correct amount of 18-decimal token");
        vm.stopPrank();
    }

    function testCoverage_SwapWithRevertingDecimalsToken() public {
        vm.prank(admin);
        MockRevertingDecimals revDec = new MockRevertingDecimals();

        vm.prank(admin);
        revDec.mint(user, 100 ether); // Mint 100 tokens

        vm.prank(admin);
        exchange.setRate(address(revDec), address(usdc), RATE_1_TO_1);

        uint256 amountIn = 100 ether;

        uint256 expectedOut = toUSDC(100);

        vm.prank(admin);
        usdc.mint(address(exchange), expectedOut);

        vm.startPrank(user);
        revDec.approve(address(exchange), amountIn);
        exchange.swap(address(revDec), address(usdc), amountIn, 0);
    }

    // ---------------------------------------------------------
    // Missing Rate, Slippage, Liquidity, InputBalance
    // ---------------------------------------------------------

    function testSwapNoRateSet() public {
        uint256 amountIn = toUSDC(100);

        vm.startPrank(user);
        usdc.approve(address(exchange), amountIn);

        vm.expectRevert(abi.encodeWithSelector(
            StableOracleExchange.RateNotSet.selector,
            address(usdc),
            address(usdt)
        ));
        exchange.swap(address(usdc), address(usdt), amountIn, 0);

        vm.stopPrank();
    }

    function testZeroAddressSwap() public {
        uint256 amountIn = toUSDC(5);

        vm.startPrank(user);
        usdc.approve(address(exchange), amountIn);

        vm.expectRevert(StableOracleExchange.ZeroAddress.selector);
        exchange.swap(address(0), address(usdc), amountIn, 0);

        vm.expectRevert(StableOracleExchange.ZeroAddress.selector);
        exchange.swap(address(usdc), address(0), amountIn, 0);

        vm.stopPrank();
    }

    function testSameTokenSwap() public {
        uint256 amountIn = toUSDC(5);

        vm.startPrank(user);
        usdc.approve(address(exchange), amountIn);

        vm.expectRevert(StableOracleExchange.SameToken.selector);
        exchange.swap(address(usdc), address(usdc), amountIn, 0);

        vm.stopPrank();
    }

    function testSlippageExceeded() public {
        vm.prank(admin);
        exchange.setRate(address(usdc), address(usdt), RATE_1_TO_1);

        uint256 amountIn = toUSDC(100);

        vm.startPrank(user);
        usdc.approve(address(exchange), amountIn);

        vm.expectRevert(abi.encodeWithSelector(
            StableOracleExchange.SlippageExceeded.selector,
            amountIn, // expected amountOut with 1:1 rate
            toUSDC(150)
        ));
        exchange.swap(address(usdc), address(usdt), amountIn, toUSDC(150));

        vm.stopPrank();
    }

    function testInsufficientLiquidity() public {
        vm.prank(admin);
        exchange.setRate(address(usdc), address(usdt), RATE_1_TO_1);

        uint256 bigAmount = toUSDC(5000);

        vm.prank(admin);
        usdc.mint(user, bigAmount);

        vm.startPrank(user);
        usdc.approve(address(exchange), bigAmount);

        vm.expectRevert(abi.encodeWithSelector(
            StableOracleExchange.InsufficientLiquidity.selector,
            usdt.balanceOf(address(exchange)),
            bigAmount
        ));
        exchange.swap(address(usdc), address(usdt), bigAmount, 0);

        vm.stopPrank();
    }

    function testInsufficientInputBalance() public {
        vm.prank(admin);
        exchange.setRate(address(usdc), address(usdt), RATE_1_TO_1);

        uint256 bal = usdc.balanceOf(user);
        uint256 amountIn = bal + 1;

        vm.startPrank(user);
        usdc.approve(address(exchange), amountIn);

        vm.expectRevert(abi.encodeWithSelector(
            StableOracleExchange.InsufficientInputBalance.selector,
            bal,
            amountIn
        ));
        exchange.swap(address(usdc), address(usdt), amountIn, 0);

        vm.stopPrank();
    }

    function testInputBalanceBoundary() public {
        vm.prank(admin);
        exchange.setRate(address(usdc), address(usdt), RATE_1_TO_1);

        uint256 amountIn = toUSDC(100);
        vm.prank(admin);
        usdc.mint(user, amountIn);

        vm.prank(admin);
        usdt.mint(address(exchange), amountIn);

        vm.startPrank(user);
        usdc.approve(address(exchange), amountIn);

        exchange.swap(address(usdc), address(usdt), amountIn, 0);

        vm.stopPrank();
    }

    // ---------------------------------------------------------
    // malicious input token (InputBalanceMismatch)
    // ---------------------------------------------------------

    function testInputBalanceMismatch() public {
        MockMaliciousERC20 bad = new MockMaliciousERC20();
        bad.mint(user, toUSDC(100));

        vm.prank(admin);
        usdt.mint(address(exchange), toUSDC(500));

        vm.prank(admin);
        exchange.setRate(address(bad), address(usdt), RATE_1_TO_1);

        vm.startPrank(user);
        bad.approve(address(exchange), toUSDC(50));

        uint256 lieDelta = 1;
        bad.setLieDelta(lieDelta);
        bad.activateLie(user);

        uint256 amountIn = toUSDC(50);
        uint256 beforeBalance = bad.balanceOf(user); // 100e6 + 1
        uint256 afterBalance = beforeBalance - amountIn - lieDelta; // 50e6

        vm.expectRevert(abi.encodeWithSelector(
            StableOracleExchange.InputBalanceMismatch.selector,
            beforeBalance,
            afterBalance,
            amountIn
        ));

        exchange.swap(address(bad), address(usdt), amountIn, 0);

        vm.stopPrank();
    }

    // ---------------------------------------------------------
    // malicious OUTPUT token (OutputBalanceMismatch)
    // ---------------------------------------------------------

    function testOutputBalanceMismatchWithdraw() public {
        MockMaliciousERC20 bad = new MockMaliciousERC20();

        uint256 mintAmount = toUSDC(100);
        bad.mint(address(exchange), mintAmount);

        uint256 lieDelta = 1;
        bad.setLieDelta(lieDelta);
        bad.activateLie(address(exchange));

        uint256 withdrawAmount = toUSDC(50);
        uint256 beforeBalance = bad.balanceOf(address(exchange)); // 100e6 + 1
        uint256 afterBalance = beforeBalance - withdrawAmount - lieDelta; // 50e6

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(
            StableOracleExchange.OutputBalanceMismatch.selector, beforeBalance, afterBalance, withdrawAmount
        ));
        exchange.withdraw(address(bad), withdrawAmount);
    }

    function testOutputBalanceMismatchDuringSwap() public {
        MockMaliciousERC20 badOut = new MockMaliciousERC20();

        uint256 amountIn = toUSDC(100);

        vm.prank(admin);
        usdc.mint(user, amountIn);

        vm.startPrank(user);
        usdc.approve(address(exchange), amountIn);
        vm.stopPrank();

        badOut.mint(address(exchange), amountIn);

        uint256 lieDelta = 1;
        badOut.setLieDelta(lieDelta);
        badOut.activateLie(user);

        vm.prank(admin);
        exchange.setRate(address(usdc), address(badOut), RATE_1_TO_1);

        uint256 beforeBalance = badOut.balanceOf(user); // 0 + 1
        uint256 afterBalance = beforeBalance + amountIn - lieDelta; // 100e6

        vm.startPrank(user);
        vm.expectRevert(abi.encodeWithSelector(
            StableOracleExchange.OutputBalanceMismatch.selector,
            beforeBalance,
            afterBalance,
            amountIn));
        exchange.swap(address(usdc), address(badOut), amountIn, 0);
        vm.stopPrank();
    }

    function testWithdrawSuccess() public {
        uint256 amount = toUSDC(100);

        vm.prank(admin);
        usdt.mint(address(exchange), amount);

        uint256 beforeEx = usdt.balanceOf(address(exchange));
        uint256 beforeAd = usdt.balanceOf(admin);

        vm.prank(admin);
        exchange.withdraw(address(usdt), amount);

        uint256 afterEx = usdt.balanceOf(address(exchange));
        uint256 afterAd = usdt.balanceOf(admin);

        assertEq(beforeEx - afterEx, amount);
        assertEq(afterAd - beforeAd, amount);
    }

    // duplicate withdraw mismatch test
    function testOutputBalanceMismatchWithdraw2() public {
        MockMaliciousERC20 bad = new MockMaliciousERC20();
        uint256 mintAmount = toUSDC(100);
        bad.mint(address(exchange), mintAmount);

        uint256 lieDelta = 1;
        bad.setLieDelta(lieDelta);
        bad.activateLie(address(exchange));

        uint256 withdrawAmount = toUSDC(50);
        uint256 beforeBalance = bad.balanceOf(address(exchange)); // 100e6 + 1
        uint256 afterBalance = beforeBalance - withdrawAmount - lieDelta; // 50e6

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(
            StableOracleExchange.OutputBalanceMismatch.selector, beforeBalance, afterBalance, withdrawAmount
        ));
        exchange.withdraw(address(bad), withdrawAmount);
    }

    // ---------------------------------------------------------
    // SLIPPAGE BOUNDARY
    // ---------------------------------------------------------

    function testSlippageBoundary() public {
        vm.prank(admin);
        exchange.setRate(address(usdc), address(usdt), RATE_1_TO_1);

        uint256 amountIn = toUSDC(123);

        vm.startPrank(user);
        usdc.approve(address(exchange), amountIn);

        exchange.swap(address(usdc), address(usdt), amountIn, amountIn);

        vm.stopPrank();
    }

    // ---------------------------------------------------------
    // ZERO AMOUNTS & ZERO ADDRESSES
    // ---------------------------------------------------------

    function testZeroAmountSwap() public {
        vm.prank(admin);
        exchange.setRate(address(usdc), address(usdt), RATE_1_TO_1);

        vm.prank(user);
        vm.expectRevert(StableOracleExchange.ZeroAmount.selector);
        exchange.swap(address(usdc), address(usdt), 0, 0);
    }

    function testZeroAmountOutSwap() public {
        uint256 smallRate = 0.5e18;
        vm.prank(admin);
        exchange.setRate(address(usdc), address(usdt), smallRate);

        uint256 tinyAmountIn = 1; // 1 wei

        vm.prank(user);
        vm.expectRevert(StableOracleExchange.ZeroAmount.selector);
        exchange.swap(address(usdc), address(usdt), tinyAmountIn, 0);
    }

    // ---------------------------------------------------------
    // ORACLE NOT SET
    // ---------------------------------------------------------

    function testOracleNotSet() public {
        vm.prank(admin);
        vm.expectRevert(StableOracleExchange.OracleNotSet.selector);
        exchange.syncRateFromOracle(address(usdc), address(usdt));
    }

    function testOracleReplace() public {
        MockRateOracle oracle1 = new MockRateOracle();
        MockRateOracle oracle2 = new MockRateOracle();

        vm.prank(admin);
        exchange.setRateOracle(address(oracle1));

        vm.expectEmit(true,true,true,true);
        emit StableOracleExchange.OracleUpdated(
            address(oracle1),
            address(oracle2),
            admin
        );

        vm.prank(admin);
        exchange.setRateOracle(address(oracle2));

        assertEq(address(exchange.rateOracle()), address(oracle2));
    }

    // ---------------------------------------------------------
    // PAUSE / UNPAUSE
    // ---------------------------------------------------------

    function testPauseSwapRevert() public {
        vm.prank(admin);
        exchange.setRate(address(usdc), address(usdt), RATE_1_TO_1);

        vm.prank(admin);
        exchange.pause();

        uint256 amountIn = toUSDC(10);

        vm.startPrank(user);
        usdc.approve(address(exchange), amountIn);

        vm.expectRevert(Pausable.EnforcedPause.selector);
        exchange.swap(address(usdc), address(usdt), amountIn, 0);

        vm.stopPrank();
    }

    function testUnpause() public {
        vm.prank(admin);
        exchange.pause();

        vm.prank(user);
        vm.expectRevert();
        exchange.unpause();

        vm.prank(admin);
        exchange.unpause();

        assertFalse(exchange.paused());
    }

    function testPauseTwice() public {
        vm.prank(admin);
        exchange.pause();

        vm.prank(admin);
        vm.expectRevert();
        exchange.pause();
    }

    function testUnpauseNotPaused() public {
        vm.prank(admin);
        vm.expectRevert();
        exchange.unpause();
    }

    // ---------------------------------------------------------
    // FUND LIQUIDITY
    // ---------------------------------------------------------

    function testFundLiquidity() public {
        uint256 fundAmount = toUSDC(1000);

        vm.prank(admin);
        usdt.mint(admin, fundAmount);
        vm.prank(admin);
        usdt.approve(address(exchange), fundAmount);

        uint256 beforeBal = usdt.balanceOf(address(exchange));

        vm.prank(admin);
        exchange.fundLiquidity(address(usdt), fundAmount);

        uint256 afterBal = usdt.balanceOf(address(exchange));

        assertEq(afterBal - beforeBal, fundAmount);
    }

    function testFundLiquidityZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(StableOracleExchange.ZeroAddress.selector);
        exchange.fundLiquidity(address(0), 10);
    }

    function testFundLiquidityZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert(StableOracleExchange.ZeroAmount.selector);
        exchange.fundLiquidity(address(usdt), 0);
    }

    // ---------------------------------------------------------
    // SYNC RATE FROM ORACLE
    // ---------------------------------------------------------

    function testSyncRateTokenInZero() public {
        vm.prank(admin);
        exchange.setRateOracle(address(oracle));

        vm.prank(admin);
        vm.expectRevert(StableOracleExchange.ZeroAddress.selector);
        exchange.syncRateFromOracle(address(0), address(usdt));
    }

    function testSyncRateTokenOutZero() public {
        vm.prank(admin);
        exchange.setRateOracle(address(oracle));

        vm.prank(admin);
        vm.expectRevert(StableOracleExchange.ZeroAddress.selector);
        exchange.syncRateFromOracle(address(usdc), address(0));
    }

    function testSyncRateSameToken() public {
        vm.prank(admin);
        exchange.setRateOracle(address(oracle));

        vm.prank(admin);
        vm.expectRevert(StableOracleExchange.SameToken.selector);
        exchange.syncRateFromOracle(address(usdc), address(usdc));
    }

    function testSetSameOracleAgain() public {
        MockRateOracle o = new MockRateOracle();

        vm.prank(admin);
        exchange.setRateOracle(address(o));

        vm.expectEmit(true,true,true,true);
        emit StableOracleExchange.OracleUpdated(
            address(o), address(o), admin
        );

        vm.prank(admin);
        exchange.setRateOracle(address(o));
    }

    // ---------------------------------------------------------
    // REENTRANCY (simple swap)
    // ---------------------------------------------------------

    function testReentrancySwap() public {
        MockReentrantERC20 reent = new MockReentrantERC20();

        vm.prank(admin);
        reent.mint(user, toUSDC(50));

        vm.prank(admin);
        usdt.mint(address(exchange), toUSDC(100));

        vm.prank(admin);
        exchange.setRate(address(reent), address(usdt), RATE_1_TO_1);

        vm.prank(admin);
        exchange.setCanDoExchange(address(reent), true); // Grant role to the malicious contract

        reent.setReenterTarget(address(exchange), address(usdt));
        reent.setReenterFlag(true);

        vm.startPrank(user);
        reent.approve(address(exchange), toUSDC(50));

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        exchange.swap(address(reent), address(usdt), toUSDC(50), 0);

        vm.stopPrank();
    }

    // ---------------------------------------------------------
    // ADMIN FUNCTIONS
    // ---------------------------------------------------------

    function testFundNonAdminRevert() public {
        uint256 fundAmount = toUSDC(100);

        vm.prank(admin);
        usdt.mint(attacker, fundAmount);

        vm.startPrank(attacker);
        usdt.approve(address(exchange), fundAmount);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                attacker,
                exchange.DEFAULT_ADMIN_ROLE()
            )
        );
        exchange.fundLiquidity(address(usdt), fundAmount);

        vm.stopPrank();
    }

    function testWithdrawByAdmin() public {
        uint256 initial = usdt.balanceOf(address(exchange));

        uint256 beforeAdm = usdt.balanceOf(admin);

        vm.prank(admin);
        exchange.withdraw(address(usdt), initial);

        uint256 afterAdm = usdt.balanceOf(admin);

        assertEq(usdt.balanceOf(address(exchange)), 0);
        assertEq(afterAdm - beforeAdm, initial);
    }

    function testWithdrawZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(StableOracleExchange.ZeroAddress.selector);
        exchange.withdraw(address(0), toUSDC(10));
    }

    function testWithdrawZeroAmount() public {
        vm.prank(admin);
        vm.expectRevert(StableOracleExchange.ZeroAmount.selector);
        exchange.withdraw(address(usdt), 0);
    }

    function testWithdrawNonAdmin() public {
        vm.startPrank(user);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user,
                exchange.DEFAULT_ADMIN_ROLE()
            )
        );
        exchange.withdraw(address(usdt), toUSDC(10));

        vm.stopPrank();
    }

    function testSetRateNonAdmin() public {
        vm.startPrank(user);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user,
                exchange.DEFAULT_ADMIN_ROLE()
            )
        );
        exchange.setRate(address(usdc), address(usdt), RATE_1_TO_1);

        vm.stopPrank();
    }

    function testSetOracleNonAdmin() public {
        vm.startPrank(user);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user,
                exchange.DEFAULT_ADMIN_ROLE()
            )
        );
        exchange.setRateOracle(address(oracle));

        vm.stopPrank();
    }

    function testPauseNonAdmin() public {
        vm.startPrank(user);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user,
                exchange.DEFAULT_ADMIN_ROLE()
            )
        );
        exchange.pause();

        vm.stopPrank();
    }

    function testSyncOracleNonAdmin() public {
        vm.startPrank(user);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user,
                exchange.DEFAULT_ADMIN_ROLE()
            )
        );
        exchange.syncRateFromOracle(address(usdc), address(usdt));

        vm.stopPrank();
    }

    function testSetCanDoExchangeNonAdmin() public {
        vm.startPrank(user);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector,
                user,
                exchange.DEFAULT_ADMIN_ROLE()
            )
        );
        exchange.setCanDoExchange(attacker, true);

        vm.stopPrank();
    }

    function testSetCanDoExchangeNeverHad() public {
        bytes32 role = exchange.CAN_DO_EXCHANGE();

        assertFalse(exchange.hasRole(role, attacker));

        vm.expectEmit(true,true,true,true);
        emit StableOracleExchange.ExchangeRoleUpdated(attacker, false, admin);

        vm.prank(admin);
        exchange.setCanDoExchange(attacker, false);

        assertFalse(exchange.hasRole(role, attacker));
    }

    function testSetCanDoExchangeZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(StableOracleExchange.ZeroAddress.selector);
        exchange.setCanDoExchange(address(0), true);
    }

    function testSetCanDoExchangeAlreadyHasRole() public {
        bytes32 role = exchange.CAN_DO_EXCHANGE();

        assertTrue(exchange.hasRole(role, user));

        vm.prank(admin);
        exchange.setCanDoExchange(user, true);

        assertTrue(exchange.hasRole(role, user));
    }

    function testConstructorZeroAdmin() public {
        vm.expectRevert(StableOracleExchange.ZeroAddress.selector);
        new StableOracleExchange(address(0));
    }

    function testSetOracleZeroAddress() public {
        vm.prank(admin);
        vm.expectRevert(StableOracleExchange.ZeroAddress.selector);
        exchange.setRateOracle(address(0));
    }

    // ---------------------------------------------------------
    // COVERAGE TESTS FOR ACCESS CONTROL
    // ---------------------------------------------------------

    /// @notice This test covers the internal `else` branch of `_grantRole`
    /// by attempting to grant a role to an account that already has it.
    function testCoverage_GrantExistingRole() public {
        bytes32 role = exchange.CAN_DO_EXCHANGE();
        assertTrue(exchange.hasRole(role, user), "Precondition failed: user should have role.");

        vm.prank(admin);
        exchange.setCanDoExchange(user, true);
    }

    /// @notice This test covers the internal `else` branch of `_revokeRole`
    /// by attempting to revoke a role from an account that does not have it.
    function testCoverage_RevokeNonExistentRole() public {
        bytes32 role = exchange.CAN_DO_EXCHANGE();
        assertFalse(exchange.hasRole(role, attacker), "Precondition failed: attacker should not have role.");

        vm.prank(admin);
        exchange.setCanDoExchange(attacker, false);
    }

    // ---------------------------------------------------------
    // COVERAGE TESTS FOR RENOUNCE ROLE
    // ---------------------------------------------------------

    /// @notice This test covers the successful path of `renounceRole`.
    function testCoverage_RenounceRoleSuccess() public {
        bytes32 role = exchange.CAN_DO_EXCHANGE();
        assertTrue(exchange.hasRole(role, user), "Precondition: user should have role");
        vm.prank(user);
        exchange.renounceRole(role, user);

        assertFalse(exchange.hasRole(role, user), "User should no longer have the role");
    }

    /// @notice This test covers the revert path of `renounceRole` when confirmation fails.
    function testCoverage_RenounceRoleBadConfirmation() public {
        bytes32 role = exchange.CAN_DO_EXCHANGE();
        vm.prank(user);
        vm.expectRevert(IAccessControl.AccessControlBadConfirmation.selector);
        exchange.renounceRole(role, attacker); // User tries to renounce but provides wrong confirmation address
    }
}