// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MockUSDD} from "./MockUSDD.sol";

contract MockPSM {
    IERC20 public gem; // USDT
    MockUSDD public usdd;
    
    uint256 public toutRate = 0; // WAD
    uint256 public tinRate = 0; // WAD

    constructor() {}

    function initialize(IERC20 gem_, MockUSDD usdd_) external {
        gem = gem_;
        usdd = usdd_;
    }

    function gemJoin() external view returns (address) {
        return address(this);
    }

    function tout() external view returns (uint256) {
        return toutRate;
    }

    function tin() external view returns (uint256) {
        return tinRate;
    }

    function setTout(uint256 toutRate_) external {
        toutRate = toutRate_;
    }

    function setTin(uint256 tinRate_) external {
        tinRate = tinRate_;
    }

    function sellGem(address usr, uint256 gemAmt) external {
        // Pull USDT (gem) from msg.sender to gemJoin (address(this))
        // Note: TRON USDT does not return a value, so we use safeTransferFrom style or just transferFrom
        gem.transferFrom(msg.sender, address(this), gemAmt);
        
        // Calculate USDD to mint (6 decimals -> 18 decimals)
        // If there's tin: usddAmount = gemAmt * 10**12 - fee
        uint256 fee = (gemAmt * 10**12 * tinRate) / 1e18;
        uint256 usddAmount = gemAmt * 10**12 - fee;
        
        usdd.mint(usr, usddAmount);
    }

    function buyGem(address usr, uint256 gemAmt) external {
        // Calculate USDD required: gemAmt * 10**12 + fee
        uint256 fee = (gemAmt * 10**12 * toutRate) / 1e18;
        uint256 usddRequired = gemAmt * 10**12 + fee;
        
        // Pull USDD from msg.sender and burn it
        usdd.transferFrom(msg.sender, address(this), usddRequired);
        usdd.burn(address(this), usddRequired);
        
        // Release USDT (gem) from this contract to usr
        // Standard TRON compatibility: we must support transfer
        // Note: we can just call transfer. In our mock, gem is MockTRONUSDT.
        // MockTRONUSDT.transfer returns false on success but performs the transfer.
        // Wait! In Minter2, does the contract call USDT.transfer?
        // No, Minter2 calls `USDT.safeTransferFrom(address(this), receiver, gemAmt)`.
        // But what does the PSM do? The PSM contract is external.
        // In the real TRON network, the PSM releases USDT via the GemJoin adapter.
        // We can just use standard transfer here since it's a mock.
        // Wait, standard transfer of MockTRONUSDT returns false. So if we use transfer, we should ignore the return value or use low-level call.
        // Let's do a low-level call to gem.transfer to avoid reverting on returning false.
        (bool success, ) = address(gem).call(
            abi.encodeWithSignature("transfer(address,uint256)", usr, gemAmt)
        );
        require(success, "USDT transfer failed");
    }
}
