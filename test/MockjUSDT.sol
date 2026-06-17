// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockjUSDT is ERC20 {
    using SafeERC20 for IERC20;

    IERC20 public immutable USDT;

    error ZeroAddress();

    constructor(address usdt_) ERC20("JustLend USDT Mock", "jUSDT") {
        if (usdt_ == address(0)) revert ZeroAddress();
        USDT = IERC20(usdt_);
    }

    function decimals() public pure override returns (uint8) {
        return 8;
    }

    uint256 public simulatedInterest;

    function setSimulatedInterest(uint256 amount) external {
        simulatedInterest = amount;
    }

    function balanceOfUnderlying(address owner) external returns (uint256) {
        simulatedInterest = simulatedInterest; // mute compiler warning
        return balanceOf(owner) + simulatedInterest;
    }

    function mint(uint256 mintAmount) external returns (uint256) {
        if (mintAmount > 0) {
            USDT.safeTransferFrom(msg.sender, address(this), mintAmount);
            _mint(msg.sender, mintAmount);
        }
        return 0;
    }

    function redeemUnderlying(uint256 redeemAmount) external returns (uint256) {
        if (redeemAmount > 0) {
            uint256 jTokenToBurn = balanceOf(msg.sender) >= redeemAmount ? redeemAmount : balanceOf(msg.sender);
            _burn(msg.sender, jTokenToBurn);
            (bool success,) =
                address(USDT).call(abi.encodeWithSelector(IERC20.transfer.selector, msg.sender, redeemAmount));
            require(success, "USDT transfer failed");
        }
        return 0;
    }
}
