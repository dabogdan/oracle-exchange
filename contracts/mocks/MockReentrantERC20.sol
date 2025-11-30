// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {StableOracleExchange} from "../StableOracleExchange.sol";

contract MockReentrantERC20 {
    string public name = "Reentrant Token";
    string public symbol = "REENT";
    uint8 public constant decimals = 6;

    uint256 public totalSupply;
    mapping(address => uint256) internal _balances;
    mapping(address => mapping(address => uint256)) internal _allowances;

    address public reenterTarget;
    address public reenterTokenOut;
    bool public reenterFlag;
    bool public callSwapWithDeadline;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        _balances[to] += amount;
    }

    function setReenterTarget(address target, address tokenOut) external {
        reenterTarget = target;
        reenterTokenOut = tokenOut;
    }

    function setReenterFlag(bool flag) external {
        reenterFlag = flag;
    }

    function setCallSwapWithDeadline(bool flag) external {
        callSwapWithDeadline = flag;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function approve(address spender, uint256 value) external returns (bool) {
        _allowances[msg.sender][spender] = value;
        return true;
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed != type(uint256).max) {
            _allowances[from][msg.sender] = allowed - value;
        }
        _transfer(from, to, value);
        return true;
    }

    function _transfer(address from, address to, uint256 value) internal {
        _balances[from] -= value;
        _balances[to] += value;

        if (reenterFlag && to == reenterTarget) {
            if (callSwapWithDeadline) {
                StableOracleExchange(reenterTarget).swapWithDeadline(address(this), reenterTokenOut, 1, 0, block.timestamp + 3600);
            } else {
                StableOracleExchange(reenterTarget).swap(address(this), reenterTokenOut, 1, 0);
            }
        }
    }
}