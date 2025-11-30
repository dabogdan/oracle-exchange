// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract MockRevertingDecimals is ERC20, Ownable {
    constructor() ERC20("Reverting Decimals", "REV") Ownable(msg.sender) {}

    function decimals() public pure override returns (uint8) {
        revert("Decimals function intentionally reverts");
    }

    function mint(address to, uint256 amount) public onlyOwner {
        _mint(to, amount);
    }
}