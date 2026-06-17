// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";
import {UNIT} from "./UNIT.sol";

interface ITRC20JToken {
    function mint(uint256 mintAmount) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function balanceOfUnderlying(address owner) external returns (uint256);
}

contract JustLendMinter is AccessControl, EIP712, Nonces {
    using SafeERC20 for IERC20;

    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");

    bytes32 public constant MINT_TYPEHASH =
        keccak256("Mint(address account,uint256 assets,uint256 nonce,uint256 deadline)");
    bytes32 public constant REDEEM_TYPEHASH =
        keccak256("Redeem(address account,uint256 assets,uint256 nonce,uint256 deadline)");

    IERC20 public immutable USDT;
    UNIT public immutable UNITToken;
    ITRC20JToken public immutable jUSDT;

    event Minted(address indexed account, uint256 assets);
    event Redeemed(address indexed account, uint256 assets);
    event ProfitWithdrawn(address indexed to, uint256 amount);

    error ZeroAddress();
    error PermitExpired();
    error InvalidSignature();
    error MintFailed(uint256 errorCode);
    error RedeemFailed(uint256 errorCode);

    constructor(address admin_, IERC20 usdt_, UNIT unit_, ITRC20JToken jUsdt_) EIP712("UNIT JustLendMinter", "1") {
        if (
            admin_ == address(0) || address(usdt_) == address(0) || address(unit_) == address(0)
                || address(jUsdt_) == address(0)
        ) {
            revert ZeroAddress();
        }
        USDT = usdt_;
        UNITToken = unit_;
        jUSDT = jUsdt_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);

        USDT.forceApprove(address(jUsdt_), type(uint256).max);
        USDT.forceApprove(address(this), type(uint256).max);
    }

    function mint(uint256 assets, address signer, uint256 deadline, bytes calldata signature) external {
        _checkPermit(
            signer,
            _hashTypedDataV4(keccak256(abi.encode(MINT_TYPEHASH, msg.sender, assets, _useNonce(msg.sender), deadline))),
            deadline,
            signature
        );
        USDT.safeTransferFrom(msg.sender, address(this), assets);
        uint256 err = jUSDT.mint(assets);
        if (err != 0) revert MintFailed(err);
        UNITToken.mint(msg.sender, assets);
        emit Minted(msg.sender, assets);
    }

    function redeem(uint256 assets, address signer, uint256 deadline, bytes calldata signature) external {
        _checkPermit(
            signer,
            _hashTypedDataV4(
                keccak256(abi.encode(REDEEM_TYPEHASH, msg.sender, assets, _useNonce(msg.sender), deadline))
            ),
            deadline,
            signature
        );
        UNITToken.burn(msg.sender, assets);
        uint256 err = jUSDT.redeemUnderlying(assets);
        if (err != 0) revert RedeemFailed(err);
        USDT.safeTransferFrom(address(this), msg.sender, assets);
        emit Redeemed(msg.sender, assets);
    }

    function withdrawProfit(address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        uint256 totalUnderlying = jUSDT.balanceOfUnderlying(address(this));
        uint256 backingRequired = UNITToken.totalSupply();
        if (totalUnderlying > backingRequired) {
            uint256 profit = totalUnderlying - backingRequired;
            uint256 err = jUSDT.redeemUnderlying(profit);
            if (err != 0) revert RedeemFailed(err);
            USDT.safeTransferFrom(address(this), to, profit);
            emit ProfitWithdrawn(to, profit);
        }
    }

    function _checkPermit(address signer, bytes32 digest, uint256 deadline, bytes calldata signature) private view {
        if (block.timestamp > deadline) revert PermitExpired();
        _checkRole(SIGNER_ROLE, signer);
        if (!SignatureChecker.isValidSignatureNowCalldata(signer, digest, signature)) revert InvalidSignature();
    }
}
