// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


abstract contract TokenWrapper {
    using SafeERC20 for IERC20;

    IERC20 public perezosoToken = IERC20(0x53Ff62409B219CcAfF01042Bb2743211bB99882e);

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    function totalSupply() public view virtual returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view virtual returns (uint256) {
        return _balances[account];
    }

    function stake(uint256 amount) public virtual {
        _totalSupply = _totalSupply + (amount);
        _balances[msg.sender] = _balances[msg.sender] + (amount);
        perezosoToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 amount) public virtual {
        _totalSupply = _totalSupply - (amount);
        _balances[msg.sender] = _balances[msg.sender] - (amount);
        perezosoToken.safeTransfer(msg.sender, amount);
    }
}