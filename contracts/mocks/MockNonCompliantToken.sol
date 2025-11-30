// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * @title MockNonCompliantToken
 * @dev A mock ERC20 token whose `transferFrom` function does not actually
 *      transfer tokens. This is used to test balance consistency checks.
 */
contract MockNonCompliantToken is ERC20 {
    constructor() ERC20("Non-Compliant Token", "NCT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @dev Overridden to be non-compliant. It does not perform the transfer.
     * It returns true to simulate a token that appears to succeed but does nothing.
     */
    function transferFrom(address, address, uint256) public pure override returns (bool) {
        // This function intentionally does nothing to test balance checks.
        return true;
    }
}