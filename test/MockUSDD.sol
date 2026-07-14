// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockUSDD is ERC20 {
    constructor() ERC20("Decentralized USD", "USDD") {}

    function name() public pure override returns (string memory) {
        return "Decentralized USD";
    }

    function symbol() public pure override returns (string memory) {
        return "USDD";
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
    
    function burn(address from, uint256 amount) external {
        _burn(from, amount);
    }
}
