// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract AUSD is ERC20, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BLACKLISTER_ROLE = keccak256("BLACKLISTER_ROLE");

    mapping(address => bool) public isBlacklisted;

    event BlacklistUpdated(address indexed account, bool state);

    error ZeroAddress();
    error AccountBlacklisted(address account);

    constructor(address admin_) ERC20("Altitude USD", "aUSD") {
        if (admin_ == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(BLACKLISTER_ROLE, admin_);
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

    function setBlacklist(address account, bool state) external onlyRole(BLACKLISTER_ROLE) {
        if (account == address(0)) revert ZeroAddress();
        isBlacklisted[account] = state;
        emit BlacklistUpdated(account, state);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (isBlacklisted[from]) revert AccountBlacklisted(from);
        if (isBlacklisted[to]) revert AccountBlacklisted(to);
        super._update(from, to, value);
    }
}
