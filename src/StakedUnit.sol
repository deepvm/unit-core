// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20Wrapper} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Wrapper.sol";

contract StakedUnit is ERC20Wrapper {
    using SafeERC20 for IERC20;

    constructor(IERC20 underlyingToken) ERC20("Staked unitUSD", "sunitUSD") ERC20Wrapper(underlyingToken) {}

    function asset() external view returns (address) {
        return address(underlying());
    }

    function deposit(uint256 amount, address receiver) external returns (bool) {
        return depositFor(receiver, amount);
    }

    function withdraw(uint256 amount, address receiver, address owner) external returns (bool) {
        if (owner != msg.sender) {
            _spendAllowance(owner, msg.sender, amount);
        }
        _burn(owner, amount);
        SafeERC20.safeTransfer(underlying(), receiver, amount);
        return true;
    }
}
