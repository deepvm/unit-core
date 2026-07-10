// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Unit} from "./Unit.sol";

contract Minter is AccessControl, EIP712, Nonces {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");
    bytes32 public constant CUSTODY_ROLE = keccak256("CUSTODY_ROLE");

    bytes32 public constant MINT_TYPEHASH =
        keccak256("Mint(address account,address custody,uint256 assets,uint256 nonce,uint256 deadline)");
    bytes32 public constant REDEEM_TYPEHASH =
        keccak256("Redeem(address account,uint256 assets,uint256 nonce,uint256 deadline)");

    IERC20 public immutable USDT;
    Unit public immutable UNIT;

    mapping(address => uint256) public pendingRedeems;

    event Minted(address indexed account, address indexed custody, uint256 assets);
    event Burned(address indexed account, uint256 assets);
    event Redeemed(address indexed account, uint256 assets);

    error ZeroAddress();
    error PermitExpired();
    error InsufficientBalance();
    error InsufficientPendingRedeem();

    constructor(address admin_, IERC20 usdt_, Unit unit_) EIP712("Unit Minter", "1") {
        if (admin_ == address(0) || address(usdt_) == address(0) || address(unit_) == address(0)) {
            revert ZeroAddress();
        }
        USDT = usdt_;
        UNIT = unit_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin_);

        USDT.forceApprove(address(this), type(uint256).max);
    }

    function mint(uint256 assets, address custody, uint256 deadline, bytes calldata signature) external {
        _checkRole(CUSTODY_ROLE, custody);
        _checkPermit(
            _hashTypedDataV4(
                keccak256(abi.encode(MINT_TYPEHASH, msg.sender, custody, assets, _useNonce(msg.sender), deadline))
            ),
            deadline,
            signature
        );
        uint256 balanceBefore = USDT.balanceOf(custody);
        USDT.safeTransferFrom(msg.sender, custody, assets);
        uint256 received = USDT.balanceOf(custody) - balanceBefore;
        UNIT.mint(msg.sender, received);
        emit Minted(msg.sender, custody, received);
    }

    function burn(uint256 assets) external {
        pendingRedeems[msg.sender] += assets;
        UNIT.burn(msg.sender, assets);
        emit Burned(msg.sender, assets);
    }

    function redeem(uint256 assets, uint256 deadline, bytes calldata signature) external {
        _checkPermit(
            _hashTypedDataV4(
                keccak256(abi.encode(REDEEM_TYPEHASH, msg.sender, assets, _useNonce(msg.sender), deadline))
            ),
            deadline,
            signature
        );
        if (pendingRedeems[msg.sender] < assets) revert InsufficientPendingRedeem();
        pendingRedeems[msg.sender] -= assets;
        USDT.safeTransferFrom(address(this), msg.sender, assets);
        emit Redeemed(msg.sender, assets);
    }

    function returnToCustody(address custody, uint256 assets) external onlyRole(SIGNER_ROLE) {
        _checkRole(CUSTODY_ROLE, custody);
        USDT.safeTransferFrom(address(this), custody, assets);
    }

    function _checkPermit(bytes32 digest, uint256 deadline, bytes calldata signature) private view {
        if (block.timestamp > deadline) revert PermitExpired();
        _checkRole(SIGNER_ROLE, digest.recover(signature));
    }
}
