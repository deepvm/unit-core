// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IERC20, ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Unit} from "./Unit.sol";

contract StakedUnit is ERC4626, Ownable {
    uint256 private constant BPS = 10_000;

    uint256 public lastUpdate;
    uint256 public rate;
    uint256 public totalAssetBalance;

    error ZeroAddress();
    error InvalidRate();

    constructor(address admin_, IERC20 asset_) ERC20("Staked unitUSD", "sunitUSD") ERC4626(asset_) Ownable(admin_) {
        lastUpdate = block.timestamp;
    }

    function setRate(uint256 rate_) external onlyOwner {
        if (rate_ > BPS) revert InvalidRate();
        _sync();
        rate = rate_;
    }

    function totalAssets() public view override returns (uint256 assets) {
        assets = totalAssetBalance;
        uint256 timeElapsed = block.timestamp - lastUpdate;
        if (timeElapsed > 0 && assets > 0) {
            assets += (assets * rate * timeElapsed) / (BPS * 365 days);
        }
    }

    function _transferIn(address from, uint256 assets) internal override {
        _sync();
        super._transferIn(from, assets);
        totalAssetBalance += assets;
    }

    function _transferOut(address to, uint256 assets) internal override {
        _sync();
        super._transferOut(to, assets);
        totalAssetBalance -= assets;
    }

    function _decimalsOffset() internal view virtual override returns (uint8) {
        return 12;
    }

    function _sync() private {
        uint256 timeElapsed = block.timestamp - lastUpdate;
        if (totalAssetBalance == 0) {
            lastUpdate = block.timestamp;
        } else {
            uint256 yield = (totalAssetBalance * rate * timeElapsed) / (BPS * 365 days);
            if (yield > 0) {
                lastUpdate = block.timestamp;
                totalAssetBalance += yield;
                Unit(address(asset())).mint(address(this), yield);
            }
        }
    }
}
