// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract Unit is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");

    event Confiscated(address indexed from, address indexed to, uint256 value);

    error ZeroAddress();

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

    function burn(address from, uint256 assets) external onlyRole(MINTER_ROLE) {
        _burn(from, assets);
    }

    function confiscate(address from, address to, uint256 value) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        _transfer(from, to, value);
        emit Confiscated(from, to, value);
    }
}
