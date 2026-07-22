// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Unit} from "./Unit.sol";
import {Minter2, ICErc20} from "./Minter2.sol";

contract RewardWrapper is AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");

    IERC20 public immutable USDD;
    ICErc20 public immutable jUSDD;
    Minter2 public immutable minter2;
    Unit public immutable UNIT;

    error ZeroAddress();
    error MintFailed();

    constructor(address admin_, IERC20 usdd_, ICErc20 jUsdd_, Minter2 minter2_, Unit unit_) {
        if (
            admin_ == address(0) || address(usdd_) == address(0) || address(jUsdd_) == address(0)
                || address(minter2_) == address(0) || address(unit_) == address(0)
        ) revert ZeroAddress();

        USDD = usdd_;
        jUSDD = jUsdd_;
        minter2 = minter2_;
        UNIT = unit_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(DISTRIBUTOR_ROLE, admin_);

        USDD.forceApprove(address(jUsdd_), type(uint256).max);
    }

    function distributeRewards(uint256 usddAmount, address distributor) external onlyRole(DISTRIBUTOR_ROLE) {
        if (distributor == address(0)) revert ZeroAddress();
        if (usddAmount == 0) return;

        minter2.withdraw(USDD, address(this), usddAmount);

        if (jUSDD.mint(usddAmount) != 0) revert MintFailed();

        uint256 jUsddBalance = IERC20(address(jUSDD)).balanceOf(address(this));
        if (jUsddBalance > 0) {
            IERC20(address(jUSDD)).safeTransfer(address(minter2), jUsddBalance);
        }

        uint256 unitAmount = usddAmount / 1e12;
        UNIT.mint(distributor, unitAmount);
    }

    /// @notice AccessControl forwarding to manage roles on Minter2
    function grantRoleOnMinter2(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minter2.grantRole(role, account);
    }

    function revokeRoleOnMinter2(bytes32 role, address account) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minter2.revokeRole(role, account);
    }

    /// @notice Forward withdraw to withdraw assets from Minter2
    function withdrawOnMinter2(IERC20 token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        minter2.withdraw(token, to, amount);
    }

    /// @notice Withdraw assets from RewardWrapper itself
    function withdraw(IERC20 token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        token.forceApprove(address(this), type(uint256).max);
        token.safeTransferFrom(address(this), to, amount);
    }
}
