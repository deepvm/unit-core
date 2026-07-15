// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockjUSDD is ERC20 {
    IERC20 public underlying;
    uint256 public totalUnderlying;

    constructor() ERC20("JustLend USDD", "jUSDD") {}

    function name() public pure override returns (string memory) {
        return "JustLend USDD";
    }

    function symbol() public pure override returns (string memory) {
        return "jUSDD";
    }

    function initialize(IERC20 underlying_) external {
        underlying = underlying_;
    }

    function exchangeRateStored() public view returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) {
            return 1e18; // 1:1 initial exchange rate
        }
        return (totalUnderlying * 1e18) / supply;
    }

    function mint(uint256 mintAmount) external returns (uint256) {
        uint256 rate = exchangeRateStored();

        // Transfer underlying USDD from caller to this contract
        underlying.transferFrom(msg.sender, address(this), mintAmount);

        // Calculate shares to mint
        uint256 shares = (mintAmount * 1e18) / rate;
        _mint(msg.sender, shares);

        totalUnderlying += mintAmount;
        return 0; // Success
    }

    function redeem(uint256 redeemTokens) external returns (uint256) {
        uint256 rate = exchangeRateStored();
        uint256 underlyingAmount = (redeemTokens * rate) / 1e18;

        _burn(msg.sender, redeemTokens);
        totalUnderlying -= underlyingAmount;

        underlying.transfer(msg.sender, underlyingAmount);
        return 0; // Success
    }

    function redeemUnderlying(uint256 redeemAmount) external returns (uint256) {
        uint256 rate = exchangeRateStored();
        uint256 shares = (redeemAmount * 1e18) / rate;

        _burn(msg.sender, shares);
        totalUnderlying -= redeemAmount;

        underlying.transfer(msg.sender, redeemAmount);
        return 0; // Success
    }

    function balanceOfUnderlying(address owner) external view returns (uint256) {
        uint256 rate = exchangeRateStored();
        return (balanceOf(owner) * rate) / 1e18;
    }

    // Helper to simulate JustLend interest rate growth (accruing yield)
    function accrueYield(uint256 amount) external {
        // Mock interest accrual by minting underlying to the contract and increasing tracked totalUnderlying
        // In actual JustLend, this is done by borrowers paying interest.
        // We can just mint or transfer underlying to the contract, and increment totalUnderlying.
        // Let's assume the caller has already transferred underlying or we can just mint it.
        // Let's mint it to this contract.
        (bool success,) =
            address(underlying).call(abi.encodeWithSignature("mint(address,uint256)", address(this), amount));
        require(success, "Failed to mint underlying yield");
        totalUnderlying += amount;
    }
}
