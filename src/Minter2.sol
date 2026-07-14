// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Unit} from "./Unit.sol";

interface IPSM {
    function sellGem(address usr, uint256 gemAmt) external;
    function buyGem(address usr, uint256 gemAmt) external;
    function tout() external view returns (uint256);
    function gemJoin() external view returns (address);
}

interface ICErc20 {
    function mint(uint256 mintAmount) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
}

contract Minter2 is AccessControl, EIP712, Nonces {
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
    IERC20 public immutable USDD;
    IPSM public immutable PSM;
    ICErc20 public immutable jUSDD;

    mapping(address => uint256) public pendingRedeems;

    event Minted(address indexed account, address indexed custody, uint256 assets);
    event Burned(address indexed account, uint256 assets);
    event Redeemed(address indexed account, uint256 assets);

    error ZeroAddress();
    error PermitExpired();
    error InsufficientPendingRedeem();
    error OperationFailed();

    constructor(address admin_, IERC20 usdt_, Unit unit_, IERC20 usdd_, IPSM psm_, ICErc20 jUsdd_)
        EIP712("Unit Minter", "2")
    {
        if (
            admin_ == address(0) || address(usdt_) == address(0) || address(unit_) == address(0)
                || address(usdd_) == address(0) || address(psm_) == address(0) || address(jUsdd_) == address(0)
        ) {
            revert ZeroAddress();
        }
        USDT = usdt_;
        UNIT = unit_;
        USDD = usdd_;
        PSM = psm_;
        jUSDD = jUsdd_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(CUSTODY_ROLE, address(usdd_));

        USDT.forceApprove(address(this), type(uint256).max);
        USDT.forceApprove(psm_.gemJoin(), type(uint256).max);
        USDD.forceApprove(address(jUsdd_), type(uint256).max);
        USDD.forceApprove(address(psm_), type(uint256).max);
    }

    function mint(uint256 assets, address custody_, uint256 deadline, bytes calldata signature) external {
        _checkRole(CUSTODY_ROLE, custody_);
        _checkPermit(
            _hashTypedDataV4(
                keccak256(abi.encode(MINT_TYPEHASH, msg.sender, custody_, assets, _useNonce(msg.sender), deadline))
            ),
            deadline,
            signature
        );

        USDT.safeTransferFrom(msg.sender, address(this), assets);
        PSM.sellGem(address(this), assets);

        if (jUSDD.mint(assets * 1e12) != 0) revert OperationFailed();

        UNIT.mint(msg.sender, assets);
        emit Minted(msg.sender, custody_, assets);
    }

    function burn(uint256 assets) external {
        pendingRedeems[msg.sender] += assets;
        UNIT.burn(msg.sender, assets);
        emit Burned(msg.sender, assets);

        uint256 usddRequired = assets * 1e12 + (assets * PSM.tout()) / 1e6;
        uint256 usddBalance = USDD.balanceOf(address(this));
        if (usddRequired > usddBalance) {
            if (jUSDD.redeemUnderlying(usddRequired - usddBalance) != 0) revert OperationFailed();
        }

        PSM.buyGem(address(this), assets);
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

    function withdraw(IERC20 token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        token.forceApprove(address(this), amount);
        token.safeTransferFrom(address(this), to, amount);
    }

    function _checkPermit(bytes32 digest, uint256 deadline, bytes calldata signature) private view {
        if (block.timestamp > deadline) revert PermitExpired();
        _checkRole(SIGNER_ROLE, digest.recover(signature));
    }
}
