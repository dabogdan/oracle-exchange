// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

contract MockMaliciousERC20 {
    string public name = "BadToken";
    string public symbol = "BAD";
    uint8 public constant decimals = 6;

    uint256 public totalSupply;
    mapping(address => uint256) internal _balances;
    mapping(address => mapping(address => uint256)) internal _allowances;

    uint256 public fakeDelta;
    mapping(address => bool) internal _lieActivated;

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        _balances[to] += amount;

        // IMPORTANT: do NOT activate lying on mint
    }

    function setLieDelta(uint256 delta) external {
        fakeDelta = delta;
    }

    function activateLie(address account) external {
        _lieActivated[account] = true;
    }

    function balanceOf(address account) public view returns (uint256) {
        uint256 real = _balances[account];
        if (_lieActivated[account] && fakeDelta > 0) {
            return real + fakeDelta;
        }
        return real;
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
        unchecked {
            _balances[from] -= value;
            _balances[to] += value;
        }

        // Deactivate the lie for the sender after a transfer.
        // Also deactivate for the receiver to handle output token checks.
        if (_lieActivated[from]) { _lieActivated[from] = false; }
        if (_lieActivated[to])   { _lieActivated[to] = false; }
    }
}