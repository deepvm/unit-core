// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20, ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Unit} from "./Unit.sol";

contract StakedUnit is ERC4626, AccessControl {
    uint256 private constant BPS = 10_000;

    uint256 public lastUpdate;
    uint256 public apy;

    error ZeroAddress();
    error InvalidAPY();

    constructor(address admin_, IERC20 asset_) ERC20("Staked Unit", "sUNIT") ERC4626(asset_) {
        if (admin_ == address(0)) {
            revert ZeroAddress();
        }
        lastUpdate = block.timestamp;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    function setAPY(uint256 apy_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (apy_ > BPS) revert InvalidAPY();
        _sync();
        apy = apy_;
    }

    function totalAssets() public view override returns (uint256 assets) {
        assets = super.totalAssets();
        uint256 timeElapsed = block.timestamp - lastUpdate;
        if (timeElapsed > 0 && assets > 0) {
            assets += (assets * apy * timeElapsed) / (BPS * 365 days);
        }
    }

    function _transferIn(address from, uint256 assets) internal override {
        _sync();
        super._transferIn(from, assets);
    }

    function _transferOut(address to, uint256 assets) internal override {
        _sync();
        super._transferOut(to, assets);
    }

    function _decimalsOffset() internal view virtual override returns (uint8) {
        return 12;
    }

    function _sync() private {
        uint256 timeElapsed = block.timestamp - lastUpdate;
        if (timeElapsed > 0) {
            lastUpdate = block.timestamp;
            uint256 yield = (super.totalAssets() * apy * timeElapsed) / (BPS * 365 days);
            if (yield > 0) Unit(address(asset())).mint(address(this), yield);
        }
    }
}
