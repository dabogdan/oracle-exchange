// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockNoDecimals
 * @dev A mock ERC20 token that intentionally does NOT have a `decimals()` function.
 * This is used to test fallback logic in contracts that interact with token decimals.
 */
contract MockNoDecimals is ERC20, Ownable {
    constructor() ERC20("No Decimals Token", "NODEC") Ownable(msg.sender) {}

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
}