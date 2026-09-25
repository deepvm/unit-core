// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract Unit is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    error ZeroAddress();
    error CannotRenounceAdmin();

    constructor(address admin_) ERC20("Unit USD", "unitUSD") {
        if (admin_ == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 assets) external onlyRole(MINTER_ROLE) {
        _mint(to, assets);
    }

    function burn(uint256 assets) external {
        _burn(msg.sender, assets);
    }

    function burnFrom(address from, uint256 assets) external {
        _spendAllowance(from, msg.sender, assets);
        _burn(from, assets);
    }

    function renounceRole(bytes32 role, address callerConfirmation) public override {
        if (role == DEFAULT_ADMIN_ROLE) revert CannotRenounceAdmin();
        super.renounceRole(role, callerConfirmation);
    }
}
