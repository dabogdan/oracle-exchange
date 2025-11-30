import { expect } from "chai";
import { ethers } from "hardhat";

describe("StableOracleExchange", function () {
    let admin: any;
    let user: any;
    let attacker: any;

    let usdc: any;
    let usdt: any;

    let exchange: any;
    let oracle: any;

    const USDC_DEC = 6;
    const toUSDC = (v: string) => ethers.parseUnits(v, USDC_DEC);

    let RATE_1_TO_1: bigint;
    let RATE_2_TO_1: bigint;

    beforeEach(async () => {
        [admin, user, attacker] = await ethers.getSigners();

        RATE_1_TO_1 = ethers.parseEther("1");
        RATE_2_TO_1 = ethers.parseEther("2");

        // Exchange
        const Factory = await ethers.getContractFactory("StableOracleExchange");
        exchange = await Factory.connect(admin).deploy(admin.address);

        // USDC-like mocks
        const USDCFactory = await ethers.getContractFactory("MockUSDC");
        usdc = await USDCFactory.connect(admin).deploy("USD Coin", "USDC", admin.address); // Note: MockUSDC has hardcoded 6 decimals
        usdt = await USDCFactory.connect(admin).deploy("Tether", "USDT", admin.address);

        // Mint (owner = admin)
        await usdc.connect(admin).mint(user.address, toUSDC("1000"));
        await usdt.connect(admin).mint(await exchange.getAddress(), toUSDC("2000"));

        // Oracle
        const OracleFactory = await ethers.getContractFactory("MockRateOracle");
        oracle = await OracleFactory.deploy();

        // Role
        await exchange.connect(admin).setCanDoExchange(user.address, true);
    });

    it("can revoke exchange role", async () => {
        await exchange.connect(admin).setCanDoExchange(user.address, false);
        expect(await exchange.hasRole(await exchange.CAN_DO_EXCHANGE(), user.address)).to.be.false;
    });

    it("revoke when account never had role (no expectEmit)", async () => {
        const role = await exchange.CAN_DO_EXCHANGE();
        expect(await exchange.hasRole(role, attacker.address)).to.equal(false);

        // bare call
        await exchange.connect(admin).setCanDoExchange(attacker.address, false);

        expect(await exchange.hasRole(role, attacker.address)).to.equal(false);
    });

    // ----------------------------------------------------------------------
    // BASIC CONFIG
    // ----------------------------------------------------------------------

    it("sets admin correctly", async () => {
        const adminRole = await exchange.DEFAULT_ADMIN_ROLE();
        expect(await exchange.hasRole(adminRole, admin.address)).to.equal(true);
    });

    it("can set manual rate", async () => {
        await exchange.connect(admin).setRate(await usdc.getAddress(), await usdt.getAddress(), RATE_1_TO_1);
        expect(await exchange.rates(await usdc.getAddress(), await usdt.getAddress())).to.equal(RATE_1_TO_1);
    });

    // ----------------------------------------------------------------------
    // ORACLE SYNC
    // ----------------------------------------------------------------------

    it("allows setting oracle", async () => {
        await expect(exchange.connect(admin).setRateOracle(await oracle.getAddress()))
            .to.emit(exchange, "OracleUpdated")
            .withArgs(ethers.ZeroAddress, await oracle.getAddress(), admin.address);
    });

    it("syncs rate from oracle successfully", async () => {
        await exchange.connect(admin).setRateOracle(await oracle.getAddress());

        await oracle.setMockRate(await usdc.getAddress(), await usdt.getAddress(), RATE_2_TO_1, true);

        await expect(
            exchange.connect(admin).syncRateFromOracle(await usdc.getAddress(), await usdt.getAddress())
        )
            .to.emit(exchange, "RateUpdated")
            .withArgs(await usdc.getAddress(), await usdt.getAddress(), 0n, RATE_2_TO_1, admin.address);

        expect(await exchange.rates(await usdc.getAddress(), await usdt.getAddress())).to.equal(RATE_2_TO_1);
    });

    it("reverts if oracle returns invalid", async () => {
        await exchange.connect(admin).setRateOracle(await oracle.getAddress());

        await oracle.setMockRate(await usdc.getAddress(), await usdt.getAddress(), RATE_1_TO_1, false);

        await expect(
            exchange.connect(admin).syncRateFromOracle(await usdc.getAddress(), await usdt.getAddress())
        ).to.be.revertedWithCustomError(exchange, "OracleRateInvalid");
    });

    it("reverts if oracle returns zero rate", async () => {
        await exchange.connect(admin).setRateOracle(await oracle.getAddress());

        await oracle.setMockRate(await usdc.getAddress(), await usdt.getAddress(), 0n, true);

        await expect(
            exchange.connect(admin).syncRateFromOracle(await usdc.getAddress(), await usdt.getAddress())
        ).to.be.revertedWithCustomError(exchange, "OracleRateInvalid");
    });

    it("reverts in setRate when tokenIn is zero address", async () => {
        await expect(
            exchange.connect(admin).setRate(
                ethers.ZeroAddress,
                await usdc.getAddress(),
                RATE_1_TO_1
            )
        ).to.be.revertedWithCustomError(exchange, "ZeroAddress");
    });

    it("reverts in setRate when tokenOut is zero address", async () => {
        await expect(
            exchange.connect(admin).setRate(
                await usdc.getAddress(),
                ethers.ZeroAddress,
                RATE_1_TO_1
            )
        ).to.be.revertedWithCustomError(exchange, "ZeroAddress");
    });

    it("reverts in setRate when tokenIn == tokenOut", async () => {
        await expect(
            exchange.connect(admin).setRate(
                await usdc.getAddress(),
                await usdc.getAddress(),
                RATE_1_TO_1
            )
        ).to.be.revertedWithCustomError(exchange, "SameToken");
    });

    // ----------------------------------------------------------------------
    // SWAP FUNCTION
    // ----------------------------------------------------------------------

    it("performs exchange 1:1 correctly", async () => {
        await exchange.connect(admin).setRate(await usdc.getAddress(), await usdt.getAddress(), RATE_1_TO_1);

        const amountIn = toUSDC("100");
        await usdc.connect(user).approve(await exchange.getAddress(), amountIn);

        const usdcBefore = await usdc.balanceOf(user.address);
        const usdtBefore = await usdt.balanceOf(user.address);

        await expect(
            exchange.connect(user).swap(await usdc.getAddress(), await usdt.getAddress(), amountIn, amountIn)
        ).to.emit(exchange, "TokensExchanged");

        const usdcAfter = await usdc.balanceOf(user.address);
        const usdtAfter = await usdt.balanceOf(user.address);

        expect(usdcBefore - usdcAfter).to.equal(amountIn);
        expect(usdtAfter - usdtBefore).to.equal(amountIn);
    });

    it("performs swapWithDeadline successfully before deadline", async () => {
        await exchange.connect(admin).setRate(
            await usdc.getAddress(),
            await usdt.getAddress(),
            RATE_1_TO_1
        );

        const amountIn = toUSDC("100");
        await usdc.connect(user).approve(await exchange.getAddress(), amountIn);

        // deadline in the future
        const latestBlock = await ethers.provider.getBlock("latest");
        const deadline = (latestBlock?.timestamp ?? 0) + 3600; // +1 hour

        const usdcBefore = await usdc.balanceOf(user.address);
        const usdtBefore = await usdt.balanceOf(user.address);

        await expect(
            exchange.connect(user).swapWithDeadline(
                await usdc.getAddress(),
                await usdt.getAddress(),
                amountIn,
                amountIn, // minAmountOut = expected 1:1
                deadline
            )
        ).to.emit(exchange, "TokensExchanged")
         .withArgs(
             user.address,
             await usdc.getAddress(),
             await usdt.getAddress(),
             amountIn,
             amountIn,
             RATE_1_TO_1
         );

        const usdcAfter = await usdc.balanceOf(user.address);
        const usdtAfter = await usdt.balanceOf(user.address);

        // Same invariants as plain swap
        expect(usdcBefore - usdcAfter).to.equal(amountIn);
        expect(usdtAfter - usdtBefore).to.equal(amountIn);
    });

    it("reverts with ExpiredQuote when using swapWithDeadline and deadline is in the past", async () => {
        await exchange.connect(admin).setRate(
            await usdc.getAddress(),
            await usdt.getAddress(),
            RATE_1_TO_1
        );

        const amountIn = toUSDC("50");
        await usdc.connect(user).approve(await exchange.getAddress(), amountIn);

        const pastDeadline = 0; // block.timestamp is always > 0 on Hardhat

        await expect(
            exchange.connect(user).swapWithDeadline(
                await usdc.getAddress(),
                await usdt.getAddress(),
                amountIn,
                0,
                pastDeadline
            )
        ).to.be.revertedWithCustomError(exchange, "ExpiredQuote");
        // no need to overfit .withArgs(...) since currentTime is dynamic
    });

    it("swapWithDeadline normal return", async () => {
        await exchange.connect(admin).setRate(
            await usdc.getAddress(),
            await usdt.getAddress(),
            RATE_1_TO_1
        );

        const amountIn = toUSDC("10");
        await usdc.connect(user).approve(await exchange.getAddress(), amountIn);

        const latest = await ethers.provider.getBlock("latest");
        const deadline = (latest?.timestamp ?? 0) + 1000;

        // No event matching, no balance checks — just execute the branch
        await exchange.connect(user).swapWithDeadline(
            await usdc.getAddress(),
            await usdt.getAddress(),
            amountIn,
            0,
            deadline
        );
    });

    it("reverts swapWithDeadline when paused", async () => {
        await exchange.connect(admin).setRate(await usdc.getAddress(), await usdt.getAddress(), RATE_1_TO_1);
        const amountIn = toUSDC("10");
        await usdc.connect(user).approve(await exchange.getAddress(), amountIn);

        // Pause the contract
        await exchange.connect(admin).pause();

        const latestBlock = await ethers.provider.getBlock("latest");
        const deadline = (latestBlock?.timestamp ?? 0) + 3600;

        // Attempt to swap with deadline
        await expect(
            exchange.connect(user).swapWithDeadline(
                await usdc.getAddress(),
                await usdt.getAddress(),
                amountIn,
                0,
                deadline
            )
        ).to.be.revertedWithCustomError(exchange, "EnforcedPause");
    });

    it("reverts swapWithDeadline if user has no exchange role", async () => {
        const amountIn = toUSDC("50");
        await usdc.connect(admin).mint(attacker.address, amountIn);
        await usdc.connect(attacker).approve(await exchange.getAddress(), amountIn);
        await exchange.connect(admin).setRate(await usdc.getAddress(), await usdt.getAddress(), RATE_1_TO_1);

        const latestBlock = await ethers.provider.getBlock("latest");
        const deadline = (latestBlock?.timestamp ?? 0) + 3600;

        await expect(
            exchange.connect(attacker).swapWithDeadline(
                await usdc.getAddress(),
                await usdt.getAddress(),
                amountIn,
                0,
                deadline
            )
        )
            .to.be.revertedWithCustomError(exchange, "AccessControlUnauthorizedAccount")
            .withArgs(attacker.address, await exchange.CAN_DO_EXCHANGE());
    });

    it("triggers nonReentrant guard on reentrant swapWithDeadline call", async () => {
        const ReentrantFactory = await ethers.getContractFactory("MockReentrantERC20");
        const reent = await ReentrantFactory.connect(admin).deploy();
        const amountIn = toUSDC("50");
        await reent.mint(user.address, amountIn);
        await usdt.connect(admin).mint(await exchange.getAddress(), amountIn * 2n);
        await exchange.connect(admin).setRate(await reent.getAddress(), await usdt.getAddress(), RATE_1_TO_1);

        await exchange.connect(admin).setCanDoExchange(await reent.getAddress(), true);

        await reent.setReenterTarget(
            await exchange.getAddress(),
            await usdt.getAddress()
        );
        await reent.setReenterFlag(true);
        await reent.connect(user).approve(await exchange.getAddress(), amountIn);

        const latestBlock = await ethers.provider.getBlock("latest");
        const deadline = (latestBlock?.timestamp ?? 0) + 3600;

        await expect(
            exchange.connect(user).swapWithDeadline(
                await reent.getAddress(),
                await usdt.getAddress(),
                amountIn,
                0,
                deadline
            )
        ).to.be.revertedWithCustomError(exchange, "ReentrancyGuardReentrantCall");
    });

    it("performs exchange with different decimals correctly", async () => {
        const DAIFactory = await ethers.getContractFactory("MockERC20");
        const dai = await DAIFactory.connect(admin).deploy("Dai Stablecoin", "DAI", 18);
        await dai.connect(admin).mint(user.address, ethers.parseEther("1000"));

        await exchange.connect(admin).setRate(await dai.getAddress(), await usdc.getAddress(), RATE_1_TO_1);

        const amountIn = ethers.parseEther("100"); // 100 DAI with 18 decimals
        const expectedAmountOut = toUSDC("100"); // 100 * 10^6

        await usdc.connect(admin).mint(await exchange.getAddress(), expectedAmountOut);

        await dai.connect(user).approve(await exchange.getAddress(), amountIn);

        await expect(
            exchange.connect(user).swap(await dai.getAddress(), await usdc.getAddress(), amountIn, 0)
        ).to.emit(exchange, "TokensExchanged")
         .withArgs(user.address, await dai.getAddress(), await usdc.getAddress(), amountIn, expectedAmountOut, RATE_1_TO_1);
    });

    it("performs exchange to an 18-decimal token correctly", async () => {
        const DAIFactory = await ethers.getContractFactory("MockERC20");
        const dai = await DAIFactory.connect(admin).deploy("Dai Stablecoin", "DAI", 18);

        await exchange.connect(admin).setRate(await usdc.getAddress(), await dai.getAddress(), RATE_1_TO_1);

        const amountIn = toUSDC("100"); // 100 USDC (6 decimals)
        const expectedAmountOut = ethers.parseEther("100"); // 100 DAI (18 decimals)

        await dai.connect(admin).mint(await exchange.getAddress(), expectedAmountOut);
        await usdc.connect(user).approve(await exchange.getAddress(), amountIn);

        const daiBalanceBefore = await dai.balanceOf(user.address);

        await exchange.connect(user).swap(await usdc.getAddress(), await dai.getAddress(), amountIn, 0);

        const daiBalanceAfter = await dai.balanceOf(user.address);
        expect(daiBalanceAfter - daiBalanceBefore).to.equal(expectedAmountOut);
    });

    it("handles swap with a token that has no decimals function", async () => {
        const NoDecFactory = await ethers.getContractFactory("MockNoDecimals");
        const noDecToken = await NoDecFactory.connect(admin).deploy();

        const amountIn = ethers.parseEther("100"); // Treat as 18 decimals by default
        await noDecToken.connect(admin).mint(user.address, amountIn);

        await exchange.connect(admin).setRate(await noDecToken.getAddress(), await usdc.getAddress(), RATE_1_TO_1);

        const expectedAmountOut = toUSDC("100");
        await usdc.connect(admin).mint(await exchange.getAddress(), expectedAmountOut);

        await noDecToken.connect(user).approve(await exchange.getAddress(), amountIn);

        await expect(
            exchange.connect(user).swap(await noDecToken.getAddress(), await usdc.getAddress(), amountIn, 0)
        ).to.emit(exchange, "TokensExchanged").withArgs(user.address, await noDecToken.getAddress(), await usdc.getAddress(), amountIn, expectedAmountOut, RATE_1_TO_1);
    });

    it("handles swap with a token that has a reverting decimals function", async () => {
        const RevDecFactory = await ethers.getContractFactory("MockRevertingDecimals");
        const revDecToken = await RevDecFactory.connect(admin).deploy();

        const amountIn = ethers.parseEther("100"); // Treat as 18 decimals by default
        await revDecToken.connect(admin).mint(user.address, amountIn);

        await exchange.connect(admin).setRate(await revDecToken.getAddress(), await usdc.getAddress(), RATE_1_TO_1);

        const expectedAmountOut = toUSDC("100");
        await usdc.connect(admin).mint(await exchange.getAddress(), expectedAmountOut);

        await revDecToken.connect(user).approve(await exchange.getAddress(), amountIn);

        await expect(
            exchange.connect(user).swap(await revDecToken.getAddress(), await usdc.getAddress(), amountIn, 0)
        ).to.emit(exchange, "TokensExchanged").withArgs(user.address, await revDecToken.getAddress(), await usdc.getAddress(), amountIn, expectedAmountOut, RATE_1_TO_1);
    });

    it("reverts if user has no exchange role", async () => {
        const amountIn = toUSDC("50");

        await usdc.connect(admin).mint(attacker.address, amountIn);
        await usdc.connect(attacker).approve(await exchange.getAddress(), amountIn);

        await exchange.connect(admin).setRate(await usdc.getAddress(), await usdt.getAddress(), RATE_1_TO_1);

        await expect(
            exchange.connect(attacker).swap(await usdc.getAddress(), await usdt.getAddress(), amountIn, 0)
        )
            .to.be.revertedWithCustomError(exchange, "AccessControlUnauthorizedAccount")
            .withArgs(attacker.address, await exchange.CAN_DO_EXCHANGE());
    });

    it("reverts if no rate is set", async () => {
        const amountIn = toUSDC("100");
        await usdc.connect(user).approve(await exchange.getAddress(), amountIn);

        await expect(
            exchange.connect(user).swap(await usdc.getAddress(), await usdt.getAddress(), amountIn, 0)
        ).to.be.revertedWithCustomError(exchange, "RateNotSet");
    });

    it("reverts in syncRateFromOracle when both tokenIn and tokenOut are zero", async () => {
        await exchange.connect(admin).setRateOracle(await oracle.getAddress());

        await expect(
            exchange.connect(admin).syncRateFromOracle(
                ethers.ZeroAddress,
                ethers.ZeroAddress
            )
        ).to.be.revertedWithCustomError(exchange, "ZeroAddress");
    });
    it("reverts with OracleRateInvalid when oracle returns invalid and zero rate together", async () => {
        await exchange.connect(admin).setRateOracle(await oracle.getAddress());

        await oracle.setMockRate(
            await usdc.getAddress(),
            await usdt.getAddress(),
            0n,
            false
        );

        await expect(
            exchange.connect(admin).syncRateFromOracle(
                await usdc.getAddress(),
                await usdt.getAddress()
            )
        ).to.be.revertedWithCustomError(exchange, "OracleRateInvalid");
    });

    it("swap succeeds when minAmountOut = 0", async () => {
        await exchange.connect(admin).setRate(await usdc.getAddress(), await usdt.getAddress(), RATE_1_TO_1);

        const amountIn = toUSDC("50");

        await usdt.connect(admin).mint(await exchange.getAddress(), amountIn);
        await usdc.connect(user).approve(await exchange.getAddress(), amountIn);

        await expect(
            exchange.connect(user).swap(await usdc.getAddress(), await usdt.getAddress(), amountIn, 0)
        ).to.emit(exchange, "TokensExchanged");
    });

    it("reverts with ZeroAmount when amountOut becomes zero after rate division", async () => {
        // Set rate so tiny that amountIn * rate / 1e18 = 0
        const tinyRate = 1n; // 1 / 1e18

        await exchange.connect(admin).setRate(
            await usdc.getAddress(),
            await usdt.getAddress(),
            tinyRate
        );

        const amountIn = toUSDC("1"); // 1e6
        await usdc.connect(user).approve(await exchange.getAddress(), amountIn);

        await expect(
            exchange.connect(user).swap(
                await usdc.getAddress(),
                await usdt.getAddress(),
                amountIn,
                0
            )
        ).to.be.revertedWithCustomError(exchange, "ZeroAmount");
    });

    it("passes ZeroAddress check and then reverts RateNotSet for valid non-zero tokens", async () => {
        const amountIn = toUSDC("5");

        await usdc.connect(user).approve(await exchange.getAddress(), amountIn);

        await expect(
            exchange.connect(user).swap(
                await usdc.getAddress(),   // non-zero
                await usdt.getAddress(),   // non-zero
                amountIn,
                0
            )
        ).to.be.revertedWithCustomError(exchange, "RateNotSet");
    });

    it("reverts on insufficient liquidity", async () => {
        await exchange.connect(admin).setRate(await usdc.getAddress(), await usdt.getAddress(), RATE_1_TO_1);

        const bigAmount = toUSDC("5000");
        await usdc.connect(admin).mint(user.address, bigAmount); // Ensure user has enough balance for the test
        await usdc.connect(user).approve(await exchange.getAddress(), bigAmount);

        await expect(
            exchange.connect(user).swap(await usdc.getAddress(), await usdt.getAddress(), bigAmount, 0)
        ).to.be.revertedWithCustomError(exchange, "InsufficientLiquidity");
    });

    it("reverts on slippage", async () => {
        await exchange.connect(admin).setRate(await usdc.getAddress(), await usdt.getAddress(), RATE_1_TO_1);

        const amountIn = toUSDC("100");
        await usdc.connect(user).approve(await exchange.getAddress(), amountIn);

        await expect(
            exchange.connect(user).swap(
                await usdc.getAddress(),
                await usdt.getAddress(),
                amountIn,
                toUSDC("150")
            )
        ).to.be.revertedWithCustomError(exchange, "SlippageExceeded");
    });

    it("reverts if user input balance is insufficient", async () => {
        await exchange.connect(admin).setRate(await usdc.getAddress(), await usdt.getAddress(), RATE_1_TO_1);
        const userBalance = await usdc.balanceOf(user.address);
        const amountIn = userBalance + 1n; // Try to exchange more than the user has
        await usdc.connect(user).approve(await exchange.getAddress(), amountIn);

        await expect(exchange.connect(user).swap(await usdc.getAddress(), await usdt.getAddress(), amountIn, 0))
            .to.be.revertedWithCustomError(exchange, "InsufficientInputBalance");
    });

    it("passes InsufficientInputBalance check when userInBefore == amountIn (boundary)", async () => {
        await exchange.connect(admin).setRate(
            await usdc.getAddress(),
            await usdt.getAddress(),
            RATE_1_TO_1
        );

        // Exact balance = amountIn
        const amountIn = toUSDC("100");
        await usdc.connect(admin).mint(user.address, amountIn);

        await usdt.connect(admin).mint(await exchange.getAddress(), amountIn);
        await usdc.connect(user).approve(await exchange.getAddress(), amountIn);

        await expect(
            exchange.connect(user).swap(
                await usdc.getAddress(),
                await usdt.getAddress(),
                amountIn,
                0
            )
        ).to.emit(exchange, "TokensExchanged");
    });

    it("passes InsufficientInputBalance when user has more than enough balance", async () => {
        await exchange.connect(admin).setRate(
            await usdc.getAddress(),
            await usdt.getAddress(),
            RATE_1_TO_1
        );

        // user has 1000 USDC by default
        const amountIn = toUSDC("100"); // strictly less than user balance

        await usdt.connect(admin).mint(await exchange.getAddress(), amountIn);
        await usdc.connect(user).approve(await exchange.getAddress(), amountIn);

        await expect(
            exchange.connect(user).swap(
                await usdc.getAddress(),
                await usdt.getAddress(),
                amountIn,
                0
            )
        ).to.emit(exchange, "TokensExchanged");
    });

    it("reverts with InsufficientInputBalance when user has less than amountIn", async () => {
        await exchange.connect(admin).setRate(await usdc.getAddress(), await usdt.getAddress(), RATE_1_TO_1);

        // user has 1000 USDC (6 decimals)
        const userBalance = await usdc.balanceOf(user.address);

        const amountIn = userBalance + 1n; // deliberately 1 wei above balance

        await usdc.connect(user).approve(await exchange.getAddress(), amountIn);

        await expect(
            exchange.connect(user).swap(await usdc.getAddress(), await usdt.getAddress(), amountIn, 0)
        ).to.be.revertedWithCustomError(exchange, "InsufficientInputBalance");
    });

    it("reverts with InputBalanceMismatch when token lies about balance", async () => {
        const BadTokenFactory = await ethers.getContractFactory("MockMaliciousERC20");
        const bad = await BadTokenFactory.connect(admin).deploy();

        // Mint bad token to user
        await bad.mint(user.address, toUSDC("100"));

        // Mint USDT to exchange
        await usdt.connect(admin).mint(await exchange.getAddress(), toUSDC("500"));

        // Approve
        await bad.connect(user).approve(await exchange.getAddress(), toUSDC("50"));

        // Set rate BAD→USDT
        await exchange.connect(admin).setRate(await bad.getAddress(), await usdt.getAddress(), RATE_1_TO_1);

        // Set the amount to lie by, then activate the lie for the user.
        await bad.setLieDelta(1n); // Lie by 1 wei
        await bad.activateLie(user.address);

        await expect(
            exchange.connect(user).swap(
                await bad.getAddress(),
                await usdt.getAddress(),
                toUSDC("50"),
                0
            )
        ).to.be.revertedWithCustomError(exchange, "InputBalanceMismatch");
    });

    // This test is redundant with the one at line 565 and can be removed or updated.
    it("reverts with OutputBalanceMismatch when token lies during withdraw", async () => {
        const BadTokenFactory = await ethers.getContractFactory("MockMaliciousERC20");
        const bad = await BadTokenFactory.connect(admin).deploy();

        const exchangeAddr = await exchange.getAddress();

        // Mint to exchange so withdraw() has something to send
        await bad.mint(exchangeAddr, toUSDC("100"));

        // Set the amount to lie by, then activate the lie for the exchange contract.
        await bad.setLieDelta(1n); // lie by +1 wei
        await bad.activateLie(exchangeAddr);

        // BEFORE withdraw, balanceOf(exchange) is realBalance + fakeDelta (because lie is active)

        await expect(
            exchange.connect(admin).withdraw(await bad.getAddress(), toUSDC("50"))
        ).to.be.revertedWithCustomError(exchange, "OutputBalanceMismatch");
    });

    it("reverts with OutputBalanceMismatch when output token lies during swap", async () => {
        const BadTokenFactory = await ethers.getContractFactory("MockMaliciousERC20");
        const badOut = await BadTokenFactory.connect(admin).deploy();

        // Mint user input (USDC)
        const amountIn = toUSDC("100");
        await usdc.connect(admin).mint(user.address, amountIn);
        await usdc.connect(user).approve(await exchange.getAddress(), amountIn);

        // Mint bad output token to exchange
        await badOut.mint(await exchange.getAddress(), amountIn);

        // Set lie delta and activate lie on the USER (output receiver)
        await badOut.setLieDelta(1n);
        await badOut.activateLie(user.address);

        // Set rate USDC → badOut = 1:1
        await exchange.connect(admin).setRate(
            await usdc.getAddress(),
            await badOut.getAddress(),
            RATE_1_TO_1
        );

        await expect(
            exchange.connect(user).swap(
                await usdc.getAddress(),
                await badOut.getAddress(),
                amountIn,
                0
            )
        ).to.be.revertedWithCustomError(exchange, "OutputBalanceMismatch");
    });

    it("withdraw succeeds and delta matches exactly", async () => {
        const amount = toUSDC("100");

        await usdt.connect(admin).mint(await exchange.getAddress(), amount);

        const before = await usdt.balanceOf(await exchange.getAddress());
        const adminBefore = await usdt.balanceOf(admin.address);

        await expect(exchange.connect(admin).withdraw(await usdt.getAddress(), amount))
            .to.not.be.reverted;

        const after = await usdt.balanceOf(await exchange.getAddress());
        const adminAfter = await usdt.balanceOf(admin.address);

        expect(before - after).to.equal(amount);
        expect(adminAfter - adminBefore).to.equal(amount);
    });

    it("reverts with OutputBalanceMismatch when token lies during withdraw (test 2)", async () => {
        const BadTokenFactory = await ethers.getContractFactory("MockMaliciousERC20");
        const bad = await BadTokenFactory.connect(admin).deploy();

        // Mint to exchange
        await bad.mint(await exchange.getAddress(), toUSDC("100"));

        // Set the amount to lie by, then activate the lie for the exchange contract.
        await bad.setLieDelta(1n);
        await bad.activateLie(await exchange.getAddress());

        await expect(
            exchange.connect(admin).withdraw(await bad.getAddress(), toUSDC("50"))
        ).to.be.revertedWithCustomError(exchange, "OutputBalanceMismatch");
    });

    it("passes slippage check when amountOut == minAmountOut (boundary)", async () => {
        await exchange.connect(admin).setRate(
            await usdc.getAddress(),
            await usdt.getAddress(),
            RATE_1_TO_1
        );

        const amountIn = toUSDC("123");
        const minAmountOut = amountIn;

        await usdc.connect(user).approve(await exchange.getAddress(), amountIn);

        await expect(
            exchange.connect(user).swap(
                await usdc.getAddress(),
                await usdt.getAddress(),
                amountIn,
                minAmountOut
            )
        ).to.emit(exchange, "TokensExchanged");
    });

    it("reverts if tokenIn is zero address", async () => {
        await expect(
            exchange.connect(user).swap(
                ethers.ZeroAddress,
                await usdc.getAddress(),
                100,
                0
            )
        ).to.be.revertedWithCustomError(exchange, "ZeroAddress");
    });

    it("reverts if tokenOut is zero address", async () => {
        await expect(
            exchange.connect(user).swap(
                await usdc.getAddress(),
                ethers.ZeroAddress,
                100,
                0
            )
        ).to.be.revertedWithCustomError(exchange, "ZeroAddress");
    });

    it("reverts if tokenIn == tokenOut", async () => {
        await expect(
            exchange.connect(user).swap(
                await usdc.getAddress(),
                await usdc.getAddress(),
                100,
                0
            )
        ).to.be.revertedWithCustomError(exchange, "SameToken");
    });

    it("reverts RateNotSet when pair exists but rate is explicitly set to zero", async () => {
        // Admin explicitly sets rate to zero
        await exchange.connect(admin).setRate(
            await usdc.getAddress(),
            await usdt.getAddress(),
            0
        );

        await usdc.connect(user).approve(await exchange.getAddress(), toUSDC("10"));

        await expect(
            exchange.connect(user).swap(
                await usdc.getAddress(),
                await usdt.getAddress(),
                toUSDC("10"),
                0
            )
        ).to.be.revertedWithCustomError(exchange, "RateNotSet");
    });

    it("reverts if amountIn is zero", async () => {
        await exchange.connect(admin).setRate(
            await usdc.getAddress(),
            await usdt.getAddress(),
            RATE_1_TO_1
        );

        await expect(
            exchange.connect(user).swap(
                await usdc.getAddress(),
                await usdt.getAddress(),
                0,
                0
            )
        ).to.be.revertedWithCustomError(exchange, "ZeroAmount");
    });

    it("reverts OracleNotSet if trying to sync without oracle set", async () => {
        await expect(
            exchange.connect(admin).syncRateFromOracle(
                await usdc.getAddress(),
                await usdt.getAddress()
            )
        ).to.be.revertedWithCustomError(exchange, "OracleNotSet");
    });

    it("updates oracle when one is already set (non-zero oldOracle)", async () => {
        const OracleFactory = await ethers.getContractFactory("MockRateOracle");
        const oracle1 = await OracleFactory.deploy();
        const oracle2 = await OracleFactory.deploy();

        // First set – oldOracle = address(0)
        await exchange.connect(admin).setRateOracle(await oracle1.getAddress());

        // Second set – oldOracle = oracle1
        await expect(
            exchange.connect(admin).setRateOracle(await oracle2.getAddress())
        )
            .to.emit(exchange, "OracleUpdated")
            .withArgs(
                await oracle1.getAddress(),
                await oracle2.getAddress(),
                admin.address
            );

        expect(await exchange.rateOracle()).to.equal(await oracle2.getAddress());
    });

    it("reverts if paused", async () => {
        await exchange.connect(admin).setRate(await usdc.getAddress(), await usdt.getAddress(), RATE_1_TO_1);
        await exchange.connect(admin).pause();

        const amountIn = toUSDC("10");
        await usdc.connect(user).approve(await exchange.getAddress(), amountIn);

        await expect(
            exchange.connect(user).swap(await usdc.getAddress(), await usdt.getAddress(), amountIn, 0)
        ).to.be.revertedWithCustomError(exchange, "EnforcedPause");
    });

    it("can unpause", async () => {
        await exchange.connect(admin).pause();
        await expect(exchange.connect(user).unpause()).to.be.reverted;

        await exchange.connect(admin).unpause();
        expect(await exchange.paused()).to.be.false;
    });

    it("reverts when pausing twice", async () => {
        await exchange.connect(admin).pause();

        // Second call should hit Pausable's internal revert branch
        await expect(
            exchange.connect(admin).pause()
        ).to.be.reverted; // don't overfit message, string/custom error depends on OZ version
    });

    it("reverts when unpausing while not paused", async () => {
        // Contract starts unpaused – calling unpause should revert
        await expect(
            exchange.connect(admin).unpause()
        ).to.be.reverted;
    });

    it("allows owner to fund liquidity", async () => {
        const fundAmount = toUSDC("1000");
        await usdt.connect(admin).mint(admin.address, fundAmount);
        await usdt.connect(admin).approve(await exchange.getAddress(), fundAmount);

        const balanceBefore = await usdt.balanceOf(await exchange.getAddress());
        await exchange.connect(admin).fundLiquidity(await usdt.getAddress(), fundAmount);
        const balanceAfter = await usdt.balanceOf(await exchange.getAddress());

        expect(balanceAfter - balanceBefore).to.equal(fundAmount);
    });

    it("reverts in fundLiquidity when token is zero address", async () => {
        await expect(
            exchange.connect(admin).fundLiquidity(ethers.ZeroAddress, toUSDC("10"))
        ).to.be.revertedWithCustomError(exchange, "ZeroAddress");
    });

    it("reverts in fundLiquidity when amount is zero", async () => {
        await expect(
            exchange.connect(admin).fundLiquidity(
                await usdt.getAddress(),
                0
            )
        ).to.be.revertedWithCustomError(exchange, "ZeroAmount");
    });

    it("reverts with ZeroAddress in syncRateFromOracle when tokenIn is zero", async () => {
        await exchange.connect(admin).setRateOracle(await oracle.getAddress());

        await expect(
            exchange.connect(admin).syncRateFromOracle(
                ethers.ZeroAddress,
                await usdt.getAddress()
            )
        ).to.be.revertedWithCustomError(exchange, "ZeroAddress");
    });

    it("reverts with ZeroAddress in syncRateFromOracle when tokenOut is zero", async () => {
        await exchange.connect(admin).setRateOracle(await oracle.getAddress());

        await expect(
            exchange.connect(admin).syncRateFromOracle(
                await usdc.getAddress(),
                ethers.ZeroAddress
            )
        ).to.be.revertedWithCustomError(exchange, "ZeroAddress");
    });

    it("reverts with SameToken in syncRateFromOracle when tokenIn == tokenOut", async () => {
        await exchange.connect(admin).setRateOracle(await oracle.getAddress());

        await expect(
            exchange.connect(admin).syncRateFromOracle(
                await usdc.getAddress(),
                await usdc.getAddress()
            )
        ).to.be.revertedWithCustomError(exchange, "SameToken");
    });

    it("setRateOracle emits even when setting same oracle again", async () => {
        const Oracle = await ethers.getContractFactory("MockRateOracle");
        const o = await Oracle.deploy();

        await exchange.connect(admin).setRateOracle(await o.getAddress());

        await expect(
            exchange.connect(admin).setRateOracle(await o.getAddress())
        ).to.emit(exchange, "OracleUpdated")
        .withArgs(await o.getAddress(), await o.getAddress(), admin.address);
    });

    it("triggers nonReentrant guard on reentrant swap call", async () => {
        const ReentrantFactory = await ethers.getContractFactory("MockReentrantERC20");
        const reent = await ReentrantFactory.connect(admin).deploy();

        const amountIn = toUSDC("50");

        // Mint reentrant token to user
        await reent.mint(user.address, amountIn);

        // Fund the exchange with enough USDT liquidity
        await usdt.connect(admin).mint(await exchange.getAddress(), amountIn * 2n);

        // Set rate REENT -> USDT = 1:1
        await exchange.connect(admin).setRate(
            await reent.getAddress(),
            await usdt.getAddress(),
            RATE_1_TO_1
        );

        await exchange.connect(admin).setCanDoExchange(await reent.getAddress(), true);

        await reent.setReenterTarget(
            await exchange.getAddress(),
            await usdt.getAddress()
        );
        await reent.setReenterFlag(true);

        await reent.connect(user).approve(await exchange.getAddress(), amountIn);

        await expect(
            exchange.connect(user).swap(
                await reent.getAddress(),
                await usdt.getAddress(),
                amountIn,
                0
            )
        ).to.be.revertedWithCustomError(exchange, "ReentrancyGuardReentrantCall");
    });


    describe("Admin Functions", function () {
        it("reverts funding from non-admin", async () => {
            const fundAmount = toUSDC("100");
            await usdt.connect(admin).mint(attacker.address, fundAmount);
            await usdt.connect(attacker).approve(await exchange.getAddress(), fundAmount);

            await expect(
                exchange.connect(attacker).fundLiquidity(await usdt.getAddress(), fundAmount)
            )
                .to.be.revertedWithCustomError(exchange, "AccessControlUnauthorizedAccount")
                .withArgs(attacker.address, await exchange.DEFAULT_ADMIN_ROLE());
        });

        it("allows admin to withdraw liquidity", async () => {
            const initialBalance = await usdt.balanceOf(await exchange.getAddress());
            const adminBalanceBefore = await usdt.balanceOf(admin.address);

            await exchange.connect(admin).withdraw(await usdt.getAddress(), initialBalance);

            const finalBalance = await usdt.balanceOf(await exchange.getAddress());
            const adminBalanceAfter = await usdt.balanceOf(admin.address);

            expect(finalBalance).to.equal(0);
            expect(adminBalanceAfter).to.equal(adminBalanceBefore + initialBalance);
        });

        it("reverts in withdraw when token is zero address", async () => {
            await expect(
                exchange.connect(admin).withdraw(
                    ethers.ZeroAddress,
                    toUSDC("10")
                )
            ).to.be.revertedWithCustomError(exchange, "ZeroAddress");
        });

        it("reverts in withdraw when amount is zero", async () => {
            await expect(
                    exchange.connect(admin).withdraw(
                        await usdt.getAddress(),
                        0
                    )
            ).to.be.revertedWithCustomError(exchange, "ZeroAmount");
        });

        it("reverts withdrawing from non-admin", async () => {
            const amount = toUSDC("100");
            await expect(
                exchange.connect(user).withdraw(await usdt.getAddress(), amount)
            ).to.be.revertedWithCustomError(exchange, "AccessControlUnauthorizedAccount");
        });

        it("reverts setting rate from non-admin", async () => {
            await expect(
                exchange.connect(user).setRate(await usdc.getAddress(), await usdt.getAddress(), RATE_1_TO_1)
            ).to.be.revertedWithCustomError(exchange, "AccessControlUnauthorizedAccount");
        });

        it("reverts setting oracle from non-admin", async () => {
            await expect(
                exchange.connect(user).setRateOracle(await oracle.getAddress())
            ).to.be.revertedWithCustomError(exchange, "AccessControlUnauthorizedAccount");
        });

        it("reverts pausing from non-admin", async () => {
            await expect(
                exchange.connect(user).pause()
            ).to.be.revertedWithCustomError(exchange, "AccessControlUnauthorizedAccount");
        });

        it("reverts syncing oracle from non-admin", async () => {
            await expect(
                exchange.connect(user).syncRateFromOracle(await usdc.getAddress(), await usdt.getAddress())
            ).to.be.revertedWithCustomError(exchange, "AccessControlUnauthorizedAccount");
        });

        it("reverts setting canDoExchange from non-admin", async () => {
            await expect(
                exchange.connect(user).setCanDoExchange(attacker.address, true)
            ).to.be.revertedWithCustomError(exchange, "AccessControlUnauthorizedAccount");
        });

        it("setCanDoExchange is false when account never had the role", async () => {
            const canExchangeRole = await exchange.CAN_DO_EXCHANGE();

            // ensure user does NOT have the role
            expect(await exchange.hasRole(canExchangeRole, attacker.address)).to.equal(false);

            // call setCanDoExchange with false → this executes the ELSE branch fully
            await expect(
                exchange.connect(admin).setCanDoExchange(attacker.address, false)
            )
                .to.emit(exchange, "ExchangeRoleUpdated")
                .withArgs(attacker.address, false, admin.address);

            // still no role
            expect(await exchange.hasRole(canExchangeRole, attacker.address)).to.equal(false);
        });

        it("reverts in setCanDoExchange when account is zero address", async () => {
            await expect(
                exchange.connect(admin).setCanDoExchange(ethers.ZeroAddress, true)
            ).to.be.revertedWithCustomError(exchange, "ZeroAddress");
        });

        it("calling setCanDoExchange(true) on an account that already has the role is a no-op but still runs path", async () => {
            const canExchangeRole = await exchange.CAN_DO_EXCHANGE();

            expect(await exchange.hasRole(canExchangeRole, user.address)).to.equal(true);

            await exchange.connect(admin).setCanDoExchange(user.address, true);

            expect(await exchange.hasRole(canExchangeRole, user.address)).to.equal(true);
        });

        it("reverts in constructor when admin is zero address", async () => {
            const Factory = await ethers.getContractFactory("StableOracleExchange");

            await expect(
                Factory.deploy(ethers.ZeroAddress)
            ).to.be.revertedWithCustomError(Factory, "ZeroAddress");
        });

        it("reverts when setting oracle to zero address", async () => {
            await expect(
                exchange.connect(admin).setRateOracle(ethers.ZeroAddress)
            ).to.be.revertedWithCustomError(exchange, "ZeroAddress");
        });
    });
});