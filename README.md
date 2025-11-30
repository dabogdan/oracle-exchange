# StableOracleExchange

A decentralized exchange (DEX) smart contract for swapping stablecoins and other ERC-20 tokens at predetermined, admin-set rates.

---

## Table of Contents

- [Overview](#overview)
- [Key Features](#key-features)
- [Contract Architecture](#contract-architecture)
- [Security Model](#security-model)
  - [On-Chain Protections](#on-chain-protections)
  - [Trust Assumptions](#trust-assumptions)
- [Local Development](#local-development)
  - [Prerequisites](#prerequisites)
  - [Installation](#installation)
  - [Compilation](#compilation)
  - [Testing](#testing)
  - [Coverage](#coverage)
- [License](#license)

## Overview

`StableOracleExchange` is a decentralized exchange (DEX) smart contract designed for swapping stablecoins and other ERC-20 tokens at predetermined rates. The system is administered by a designated admin role that controls exchange rates, user permissions, and contract lifecycle operations.

The contract is built with a strong emphasis on security, featuring robust checks against malicious or non-compliant tokens, reentrancy protection, and decimal-aware calculations to handle a wide variety of ERC-20 tokens safely.

## Key Features

- **Role-Based Access Control**: Utilizes a two-tiered role system (`DEFAULT_ADMIN_ROLE` and `CAN_DO_EXCHANGE`) to separate administrative functions from user-level swap permissions.
- **Admin-Controlled Rates**: The administrator can manually set and update exchange rates for any token pair.
- **Oracle Integration**: Includes an optional interface to an on-chain oracle for synchronizing rates, providing a path for automated rate updates.
- **Pausable Contract**: Implements emergency-stop functionality, allowing the admin to pause all swap operations in response to a threat.
- **Decimal-Aware Calculations**: Automatically normalizes token amounts to handle swaps between tokens with different decimal precisions (e.g., USDC with 6 decimals and DAI with 18 decimals).
- **Robust Security Protections**:
  - **Reentrancy Guard**: Prevents reentrancy attacks on swap functions.
  - **Balance Integrity Checks**: Verifies the exact change in token balances before and after transfers to protect against fee-on-transfer tokens and other malicious token behaviors.
  - **Slippage Protection**: Allows users to specify a minimum output amount for their swaps.
  - **Deadline Support**: Protects users from front-running and unfavorable execution of long-pending transactions.

## Contract Architecture

The core logic is contained within `StableOracleExchange.sol`. The contract inherits from OpenZeppelin's battle-tested implementations for security and functionality:

- `AccessControl`: For managing roles and permissions.
- `Pausable`: For the emergency-stop mechanism.
- `ReentrancyGuard`: For preventing reentrancy attacks.
- `SafeERC20`: For safe interactions with ERC-20 tokens.

The project also includes a comprehensive suite of mock contracts used for testing various scenarios, including malicious token behavior, reentrancy attacks, and oracle interactions.

## Security Model

The security of the StableOracleExchange relies on both its on-chain logic and the operational security of its administrator.

On-Chain Protections

- **Access Control**: All sensitive functions are restricted to the `DEFAULT_ADMIN_ROLE`. Swaps are restricted to users with the `CAN_DO_EXCHANGE` role.
- **Balance Checks**: The `_swap` function performs strict balance checks before and after token transfers (reverting with `InputBalanceMismatch` and `OutputBalanceMismatch` errors). This is a critical security feature that mitigates risks from tokens that do not conform to the standard ERC-20 behavior, such as those that take a fee on transfer.
- **Oracle Validation**: When syncing from an oracle, the contract verifies that the oracle provides a valid, non-zero rate before updating its internal state.
- **Input Validation**: All functions include checks for zero addresses, zero amounts, and other invalid inputs.

Trust Assumptions

The integrity of the entire system is critically dependent on the security of the account(s) holding the `DEFAULT_ADMIN_ROLE`. A compromised admin account can lead to a complete loss of funds.

> **Recommendation for Production:** The `DEFAULT_ADMIN_ROLE` should be assigned to a multi-signature wallet (e.g., **Gnosis Safe**) requiring a threshold of independent parties to approve any administrative action. For further security, a **Timelock** contract should be placed in front of critical functions like `setRateOracle` and `withdraw`.

## Local Development

### Prerequisites

- **Foundry**
- **Node.js**
- **Yarn** or **NPM**

### Installation

1.  Install Foundry Libraries:
    ```bash
    forge install
    ```
2.  Install Node.js Dependencies:
    ```bash
    npm install
    ```

### Compilation

1.  **Foundry**:
    ```bash
    forge build
    ```
2.  **Hardhat** (for `TypeChain` types):
    ```bash
    npx hardhat compile
    ```

### Testing

The project includes comprehensive test suites in both Foundry and Hardhat, achieving 100% line and branch coverage for StableOracleExchange.sol.

1.  Run Foundry Tests:
    ```bash
    forge test
    ```
2.  Run Hardhat Tests:
    ```bash
    npx hardhat test
    ```

### Coverage

1.  Foundry Coverage:
    ```bash
    forge coverage
    ```
2.  Hardhat Coverage:
    ```bash
    npx hardhat coverage
    ```

## License

This project is licensed under the MIT License. See the SPDX-License-Identifier in the contract files for more details.