// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract StakedUnit is ERC4626 {
    error NonTransferable();
    error VaultInsolvent();

    constructor(IERC20 asset_) ERC20("Staked unitUSD", "sunitUSD") ERC4626(asset_) {}

    function _convertToShares(uint256 assets, Math.Rounding) internal pure override returns (uint256) {
        return assets;
    }

    function _convertToAssets(uint256 shares, Math.Rounding) internal pure override returns (uint256) {
        return shares;
    }

    function _isSolvent() internal view returns (bool) {
        return totalAssets() >= totalSupply();
    }

    function maxDeposit(address receiver) public view override returns (uint256) {
        return _isSolvent() ? super.maxDeposit(receiver) : 0;
    }

    function maxMint(address receiver) public view override returns (uint256) {
        return _isSolvent() ? super.maxMint(receiver) : 0;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        return _isSolvent() ? super.maxWithdraw(owner) : 0;
    }

    function maxRedeem(address owner) public view override returns (uint256) {
        return _isSolvent() ? super.maxRedeem(owner) : 0;
    }

    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (!_isSolvent()) revert VaultInsolvent();
        super._deposit(caller, receiver, assets, shares);
    }

    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (!_isSolvent()) revert VaultInsolvent();
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (value != 0 && from != address(0) && to != address(0)) {
            revert NonTransferable();
        }
        super._update(from, to, value);
    }
}
