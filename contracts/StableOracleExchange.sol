// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

interface IRateOracle {
    /**
     * @notice Returns the rate for a token pair and a validity flag.
     * @dev Rate must be expressed with RATE_PRECISION (1e18).
     */
    function getRate(address tokenIn, address tokenOut)
        external
        view
        returns (uint256 rate, bool valid);
}

/**
 * @title StableOracleExchange
 * @notice An oracle-driven exchange for swapping stablecoins at admin-defined rates.
 *
 * @dev This contract facilitates swaps between whitelisted ERC-20 tokens based on exchange rates
 * set by an administrator. It includes role-based access control for swaps, pausable functionality
 * for emergencies, and robust balance-checking mechanisms to protect against malicious or
 * non-compliant tokens. The contract is designed to handle tokens with different decimal precisions
 * by normalizing amounts during rate calculations.
 *
 * Exchange rates are managed with 1e18 precision. The core calculation is:
 * `amountOut = (amountIn * rate) / 1e18`, with adjustments for token decimals.
 */
contract StableOracleExchange is AccessControl, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // -----------------------------------------------------------------------
    //                                CONSTANTS
    // -----------------------------------------------------------------------

    /// @notice The precision factor for exchange rates (1e18).
    uint256 public constant RATE_PRECISION = 1e18;
    /// @notice The role identifier required for an account to execute swaps.
    bytes32 public constant CAN_DO_EXCHANGE = keccak256("CAN_DO_EXCHANGE");

    // -----------------------------------------------------------------------
    //                                 ERRORS
    // -----------------------------------------------------------------------

    /// @notice Reverts when an address parameter is the zero address.
    error ZeroAddress();
    /// @notice Reverts when the input and output tokens are the same.
    error SameToken();
    /// @notice Reverts when an amount parameter is zero.
    error ZeroAmount();
    /// @notice Reverts when no exchange rate is set for a given token pair.
    /// @param tokenIn The address of the input token.
    /// @param tokenOut The address of the output token.
    error RateNotSet(address tokenIn, address tokenOut);
    /// @notice Reverts when an oracle-related function is called but no oracle is set.
    error OracleNotSet();
    /// @notice Reverts when the configured oracle returns an invalid or zero rate.
    /// @param tokenIn The address of the input token.
    /// @param tokenOut The address of the output token.
    error OracleRateInvalid(address tokenIn, address tokenOut);
    /// @notice Reverts when the calculated output amount is less than the user's specified minimum.
    /// @param expected The calculated amount of tokens to be received.
    /// @param minAmountOut The minimum amount of tokens the user is willing to accept.
    error SlippageExceeded(uint256 expected, uint256 minAmountOut);
    /// @notice Reverts when the user's balance of the input token is insufficient.
    /// @param balance The user's current balance of the input token.
    /// @param required The required amount of the input token for the swap.
    error InsufficientInputBalance(uint256 balance, uint256 required);
    /// @notice Reverts when the contract does not have enough liquidity of the output token.
    /// @param balance The contract's current balance of the output token.
    /// @param required The required amount of the output token for the swap.
    error InsufficientLiquidity(uint256 balance, uint256 required);
    /// @notice Reverts if the user's input token balance does not decrease by the expected amount.
    /// @dev Protects against malicious tokens that may not transfer the correct amount.
    /// @param beforeBalance The user's balance before the transfer.
    /// @param afterBalance The user's balance after the transfer.
    /// @param expectedDelta The amount that was supposed to be transferred.
    error InputBalanceMismatch(uint256 beforeBalance, uint256 afterBalance, uint256 expectedDelta);
    /// @notice Reverts if a balance does not change by the expected amount after a transfer out.
    /// @dev Protects against malicious tokens that may not transfer correctly or have unexpected behavior.
    /// @param beforeBalance The balance before the transfer.
    /// @param afterBalance The balance after the transfer.
    /// @param expectedDelta The amount that was supposed to be transferred.
    error OutputBalanceMismatch(uint256 beforeBalance, uint256 afterBalance, uint256 expectedDelta);
    /// @notice Reverts if a swap with a deadline is attempted after the deadline has passed.
    /// @param deadline The specified deadline timestamp.
    /// @param currentTime The current block timestamp.
    error ExpiredQuote(uint256 deadline, uint256 currentTime);

    // -----------------------------------------------------------------------
    //                                STORAGE
    // -----------------------------------------------------------------------

    /// @notice Stores the admin-defined exchange rates for each token pair.
    /// @dev The mapping is structured as `rates[tokenInAddress][tokenOutAddress]`. Rates use `RATE_PRECISION`.
    mapping(address => mapping(address => uint256)) public rates;

    /// @notice The address of the optional external oracle contract used for rate synchronization.
    IRateOracle public rateOracle;

    // -----------------------------------------------------------------------
    //                                 EVENTS
    // -----------------------------------------------------------------------

    /// @notice Emitted when the exchange rate for a token pair is updated.
    /// @param tokenIn The address of the input token.
    /// @param tokenOut The address of the output token.
    /// @param oldRate The previous exchange rate.
    /// @param newRate The new exchange rate.
    /// @param updater The address of the account that updated the rate.
    event RateUpdated(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 oldRate,
        uint256 newRate,
        address indexed updater
    );

    /// @notice Emitted when an account's permission to perform swaps is granted or revoked.
    /// @param account The address of the user account.
    /// @param canExchange The new permission status (`true` if granted, `false` if revoked).
    /// @param admin The address of the admin who performed the update.
    event ExchangeRoleUpdated(
        address indexed account,
        bool canExchange,
        address indexed admin
    );

    /// @notice Emitted when a token swap is successfully executed.
    /// @param user The address of the user who performed the swap.
    /// @param tokenIn The address of the input token.
    /// @param tokenOut The address of the output token.
    /// @param amountIn The amount of `tokenIn` swapped.
    /// @param amountOut The amount of `tokenOut` received.
    /// @param rate The exchange rate used for the swap.
    event TokensExchanged(
        address indexed user,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 rate
    );

    /// @notice Emitted when the rate oracle contract address is updated.
    /// @param oldOracle The address of the previous oracle contract.
    /// @param newOracle The address of the new oracle contract.
    /// @param admin The address of the admin who performed the update.
    event OracleUpdated(
        address indexed oldOracle,
        address indexed newOracle,
        address indexed admin
    );

    // -----------------------------------------------------------------------
    //                               CONSTRUCTOR
    // -----------------------------------------------------------------------

    /// @notice Initializes the contract and grants the `DEFAULT_ADMIN_ROLE` to the provided admin address.
    /// @param admin The address to be set as the initial administrator.
    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // -----------------------------------------------------------------------
    //                           ORACLE ADMINISTRATION
    // -----------------------------------------------------------------------

    /**
     * @notice Sets a new oracle contract used for rate synchronization.
     * @dev Only callable by an account with the `DEFAULT_ADMIN_ROLE`.
     * @param newOracle The address of the new oracle contract. Must not be the zero address.
     */
    function setRateOracle(address newOracle) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newOracle == address(0)) revert ZeroAddress();

        address oldOracle = address(rateOracle);
        rateOracle = IRateOracle(newOracle);

        emit OracleUpdated(oldOracle, newOracle, msg.sender);
    }

    /**
     * @notice Pulls the rate for a given pair from the external oracle
     *         and stores it in the local rates mapping.
     *
     * @dev This keeps on-chain auditability for actual applied rates
     *      while letting the oracle drive pricing logic off-chain.
     *      Only callable by an account with the `DEFAULT_ADMIN_ROLE`.
     * @param tokenIn The address of the input token.
     * @param tokenOut The address of the output token.
     */
    function syncRateFromOracle(address tokenIn, address tokenOut)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (tokenIn == address(0) || tokenOut == address(0)) revert ZeroAddress();
        if (tokenIn == tokenOut) revert SameToken();
        if (address(rateOracle) == address(0)) revert OracleNotSet();

        (uint256 newRate, bool valid) = rateOracle.getRate(tokenIn, tokenOut);
        if (!valid || newRate == 0) {
            revert OracleRateInvalid(tokenIn, tokenOut);
        }

        uint256 oldRate = rates[tokenIn][tokenOut];
        rates[tokenIn][tokenOut] = newRate;

        emit RateUpdated(tokenIn, tokenOut, oldRate, newRate, msg.sender);
    }

    // -----------------------------------------------------------------------
    //                            MANUAL RATE MANAGEMENT
    // -----------------------------------------------------------------------

    /**
     * @notice Sets or updates the exchange rate for a token pair manually.
     * @dev This can be used in parallel with oracle-based sync or as a fallback.
     *      Only callable by an account with the `DEFAULT_ADMIN_ROLE`.
     * @param tokenIn The address of the input token.
     * @param tokenOut The address of the output token.
     * @param rate The new exchange rate, formatted with `RATE_PRECISION`.
     */
    function setRate(
        address tokenIn,
        address tokenOut,
        uint256 rate
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (tokenIn == address(0) || tokenOut == address(0)) revert ZeroAddress();
        if (tokenIn == tokenOut) revert SameToken();

        uint256 oldRate = rates[tokenIn][tokenOut];
        rates[tokenIn][tokenOut] = rate;

        emit RateUpdated(tokenIn, tokenOut, oldRate, rate, msg.sender);
    }

    // -----------------------------------------------------------------------
    //                             ROLE MANAGEMENT
    // -----------------------------------------------------------------------

    /**
     * @notice Grants or revokes the `CAN_DO_EXCHANGE` role for a given account.
     * @dev Only callable by an account with the `DEFAULT_ADMIN_ROLE`.
     * @param account The address of the account to modify.
     * @param canExchange `true` to grant the role, `false` to revoke it.
     */
    function setCanDoExchange(
        address account,
        bool canExchange
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) revert ZeroAddress();

        if (canExchange) {
            _grantRole(CAN_DO_EXCHANGE, account);
        } else {
            _revokeRole(CAN_DO_EXCHANGE, account);
        }

        emit ExchangeRoleUpdated(account, canExchange, msg.sender);
    }

    // -----------------------------------------------------------------------
    //                                 PAUSING
    // -----------------------------------------------------------------------

    /// @notice Pauses the contract, disabling all swap functionality.
    /// @dev Only callable by an account with the `DEFAULT_ADMIN_ROLE`.
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /// @notice Unpauses the contract, re-enabling all swap functionality.
    /// @dev Only callable by an account with the `DEFAULT_ADMIN_ROLE`.
    ///      The contract must be in a paused state.
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // -----------------------------------------------------------------------
    //                                  SWAPS
    // -----------------------------------------------------------------------

    /**
     * @notice Swaps tokenIn for tokenOut using current stored rate.
     * @dev The core swap logic is protected by a `nonReentrant` guard in the internal `_swap` function.
     * @param tokenIn The address of the token being sent by the user.
     * @param tokenOut The address of the token to be received.
     * @param amountIn The amount of `tokenIn` to swap.
     * @param minAmountOut The minimum amount of `tokenOut` the user is willing to accept.
     */
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    )
        external
        whenNotPaused
        onlyRole(CAN_DO_EXCHANGE)
    {
        _swap(
            tokenIn,
            tokenOut,
            amountIn,
            minAmountOut,
            type(uint256).max,   // no deadline
            msg.sender
        );
    }

    /**
     * @notice Swaps tokenIn for tokenOut, but reverts if the transaction is executed after the deadline.
     * @dev This provides protection against long-pending transactions being executed at a disadvantageous time.
     * @param tokenIn The address of the token being sent by the user.
     * @param tokenOut The address of the token to be received.
     * @param amountIn The amount of `tokenIn` to swap.
     * @param minAmountOut The minimum amount of `tokenOut` the user is willing to accept.
     * @param deadline A Unix timestamp after which the transaction will revert.
     */
    function swapWithDeadline(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    )
        external
        whenNotPaused
        onlyRole(CAN_DO_EXCHANGE)
    {
        _swap(
            tokenIn,
            tokenOut,
            amountIn,
            minAmountOut,
            deadline,
            msg.sender
        );
    }
    
    /**
     * @dev Internal function that handles the core swap logic.
     * @param tokenIn The address of the input token.
     * @param tokenOut The address of the output token.
     * @param amountIn The amount of `tokenIn` to swap.
     * @param minAmountOut The minimum acceptable amount of `tokenOut`.
     * @param deadline The deadline for `swapWithDeadline`, or `type(uint256).max` for `swap`.
     * @param user The address of the user performing the swap.
     */
    function _swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline,
        address user
    ) private nonReentrant {
        if (block.timestamp > deadline) {
            revert ExpiredQuote(deadline, block.timestamp);
        }

        if (tokenIn == address(0) || tokenOut == address(0)) revert ZeroAddress();
        if (tokenIn == tokenOut) revert SameToken();
        if (amountIn == 0) revert ZeroAmount();

        uint256 rate = rates[tokenIn][tokenOut];
        if (rate == 0) revert RateNotSet(tokenIn, tokenOut);

        // USE DECIMAL-AWARE OUTPUT COMPUTATION
        uint256 amountOut = _computeAmountOutDecimals(tokenIn, tokenOut, amountIn, rate);

        if (amountOut == 0) revert ZeroAmount();
        if (amountOut < minAmountOut) {
            revert SlippageExceeded(amountOut, minAmountOut);
        }

        IERC20 inToken = IERC20(tokenIn);
        IERC20 outToken = IERC20(tokenOut);

        {
            uint256 userInBefore = inToken.balanceOf(user);
            if (userInBefore < amountIn) {
                revert InsufficientInputBalance(userInBefore, amountIn);
            }

            uint256 contractOutBalance = outToken.balanceOf(address(this));
            if (contractOutBalance < amountOut) {
                revert InsufficientLiquidity(contractOutBalance, amountOut);
            }

            uint256 userOutBefore = outToken.balanceOf(user);

            inToken.safeTransferFrom(user, address(this), amountIn);
            outToken.safeTransfer(user, amountOut);

            uint256 userInAfter = inToken.balanceOf(user);
            uint256 inDelta = userInBefore - userInAfter;
            if (inDelta != amountIn) {
                revert InputBalanceMismatch(userInBefore, userInAfter, amountIn);
            }

            uint256 userOutAfter = outToken.balanceOf(user);
            uint256 outDelta = userOutAfter - userOutBefore;
            if (outDelta != amountOut) {
                revert OutputBalanceMismatch(userOutBefore, userOutAfter, amountOut);
            }
        }

        emit TokensExchanged(
            user,
            tokenIn,
            tokenOut,
            amountIn,
            amountOut,
            rate
        );
    }

    /**
     * @dev Calculates the output amount, adjusting for different token decimal precisions.
     * @param tokenIn The address of the input token.
     * @param tokenOut The address of the output token.
     * @param amountIn The amount of the input token.
     * @param rate The exchange rate, formatted with `RATE_PRECISION`.
     * @return amountOut The calculated amount of the output token.
     */
    function _computeAmountOutDecimals(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 rate
    ) internal view returns (uint256) {

        uint8 decIn = _safeDecimals(tokenIn);
        uint8 decOut = _safeDecimals(tokenOut);

        // normalize amountIn to 1e18
        uint256 scaledIn;
        if (decIn >= 18) {
            scaledIn = amountIn / (10 ** (decIn - 18));
        } else {
            scaledIn = amountIn * (10 ** (18 - decIn));
        }

        // apply rate (rate uses 1e18 precision)
        uint256 scaledOut = (scaledIn * rate) / RATE_PRECISION;

        // scale output to tokenOut decimals
        uint256 amountOut;
        if (decOut >= 18) {
            amountOut = scaledOut * (10 ** (decOut - 18));
        } else {
            amountOut = scaledOut / (10 ** (18 - decOut));
        }

        return amountOut;
    }

    /**
     * @dev Safely retrieves the `decimals` of an ERC20 token.
     * @notice If the token contract does not have a `decimals()` function or if the call reverts,
     * this function returns a default value of 18.
     * @param token The address of the ERC20 token.
     * @return The token's decimals, or 18 as a fallback.
     */
    function _safeDecimals(address token) internal view returns (uint8) {
        try IERC20Metadata(token).decimals() returns (uint8 dec) {
            return dec;
        } catch {
            // Token does not implement decimals()
            return 18;
        }
    }

    // -----------------------------------------------------------------------
    //                           LIQUIDITY MANAGEMENT
    // -----------------------------------------------------------------------

    /**
     * @notice Helper to fund contract liquidity for a given token.
     * @dev The caller (admin) must approve this contract to spend the tokens beforehand.
     *      Only callable by an account with the `DEFAULT_ADMIN_ROLE`.
     * @param token The address of the token to fund.
     * @param amount The amount of the token to add as liquidity.
     */
    function fundLiquidity(address token, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Allows the admin to withdraw liquidity tokens from the contract.
     * @dev This is a privileged operation for liquidity management. The recipient of the tokens
     *      is the `msg.sender` (the admin).
     * @param token The address of the token to withdraw.
     * @param amount The amount of the token to withdraw.
     */
    function withdraw(address token, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(msg.sender, amount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));

        uint256 delta = balanceBefore - balanceAfter;
        if (delta != amount) {
            revert OutputBalanceMismatch(balanceBefore, balanceAfter, amount);
        }
    }
}