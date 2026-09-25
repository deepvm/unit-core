// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Nonces} from "@openzeppelin/contracts/utils/Nonces.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Unit} from "./Unit.sol";
import {StakedUnit} from "./StakedUnit.sol";

interface IPSM {
    function sellGem(address usr, uint256 gemAmt) external;
    function buyGem(address usr, uint256 gemAmt) external;
    function tout() external view returns (uint256);
    function gemJoin() external view returns (address);
}

interface ICErc20 {
    function mint(uint256 mintAmount) external returns (uint256);
    function redeemUnderlying(uint256 redeemAmount) external returns (uint256);
    function underlying() external view returns (address);
    function balanceOf(address owner) external view returns (uint256);
    function exchangeRateStored() external view returns (uint256);
}

interface IGemJoin {
    function gem() external view returns (address);
}

interface IERC20Metadata {
    function decimals() external view returns (uint8);
}

interface IMultiMerkleDistributor {
    struct ClaimParam {
        uint256 merkleIndex;
        uint256 index;
        uint256[] amounts;
        bytes32[] merkleProof;
    }

    function multiClaim(ClaimParam[] calldata claims) external;
}

contract Minter2 is AccessControl, EIP712, Nonces, Pausable {
    using SafeERC20 for IERC20;
    using SafeERC20 for Unit;
    using ECDSA for bytes32;

    bytes32 public constant SIGNER_ROLE = keccak256("SIGNER_ROLE");
    bytes32 public constant DISTRIBUTOR_ROLE = keccak256("DISTRIBUTOR_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    address public constant JUSTLEND_DISTRIBUTOR = 0xcF6CC9591f7B424295294D8138A8b2EDBAFc6Ee8; // TUsyCPRyQdMsn9WnJcssBFXtzg6bUVbty6
    IERC20 public constant USDT = IERC20(0xa614f803B6FD780986A42c78Ec9c7f77e6DeD13C); // TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t
    IERC20 public constant USDD = IERC20(0xE91A7411e56Ce79E83570570f49B9FC35B7727c5); // TXDk8mbtRbXeYuMNS83CfKPaYYT8XWv9Hz
    IPSM public constant PSM = IPSM(0x1113AE08A16489A7B76f2Ccc52290ab54E2783d8); // TBXW4hS5KYjjbJXDpnrPf4zhkLwrpUjbyz
    ICErc20 public constant jUSDD = ICErc20(0x65c9feDE72Ba73CD1B0DCA2A974C070153dC6FCB); // TKFRELGGoRgiayhwJTNNLqCNjFoLBh3Mnf

    bytes32 public constant MINT_TYPEHASH =
        keccak256("Mint(address account,uint256 assets,bool stake,uint256 nonce,uint256 deadline)");
    bytes32 public constant REDEEM_TYPEHASH =
        keccak256("Redeem(address account,uint256 assets,bool unstake,uint256 nonce,uint256 deadline)");

    Unit public immutable UNIT;
    StakedUnit public immutable stakedUnit;

    event Minted(address indexed account, uint256 assets);
    event Redeemed(address indexed account, uint256 assets);
    event NativeValueReceived(address indexed sender, uint256 amount);
    event RewardsDistributed(address indexed distributor, uint256 claimedUSDD, uint256 mintedUNIT);

    error ZeroAddress();
    error PermitExpired();
    error OperationFailed();
    error InvalidIntegration();
    error InsufficientOutput();
    error CannotRenounceAdmin();

    constructor(address admin_, Unit unit_, StakedUnit stakedUnit_) EIP712("Unit Minter", "3") {
        if (admin_ == address(0) || address(unit_) == address(0) || address(stakedUnit_) == address(0)) {
            revert ZeroAddress();
        }

        if (stakedUnit_.asset() != address(unit_)) revert InvalidIntegration();
        if (unit_.decimals() != 6 || stakedUnit_.decimals() != 6) revert InvalidIntegration();
        if (IERC20Metadata(address(USDT)).decimals() != 6 || IERC20Metadata(address(USDD)).decimals() != 18) {
            revert InvalidIntegration();
        }

        address gemJoin = PSM.gemJoin();
        if (jUSDD.underlying() != address(USDD) || IGemJoin(gemJoin).gem() != address(USDT)) {
            revert InvalidIntegration();
        }

        UNIT = unit_;
        stakedUnit = stakedUnit_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(KEEPER_ROLE, admin_);

        USDT.forceApprove(address(this), type(uint256).max);
        USDT.forceApprove(gemJoin, type(uint256).max);
        UNIT.forceApprove(address(stakedUnit_), type(uint256).max);
    }

    receive() external payable {
        emit NativeValueReceived(msg.sender, msg.value);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    function renounceRole(bytes32 role, address callerConfirmation) public override {
        if (role == DEFAULT_ADMIN_ROLE) revert CannotRenounceAdmin();
        super.renounceRole(role, callerConfirmation);
    }

    function mint(uint256 assets, bool stake, uint256 minUnitOut, uint256 deadline, bytes calldata signature)
        external
        whenNotPaused
    {
        _checkPermit(
            _hashTypedDataV4(
                keccak256(abi.encode(MINT_TYPEHASH, msg.sender, assets, stake, _useNonce(msg.sender), deadline))
            ),
            deadline,
            signature
        );
        uint256 unitToMint = _mintInternal(assets);
        if (assets == 0 || unitToMint == 0 || unitToMint < minUnitOut) revert InsufficientOutput();

        if (stake) {
            UNIT.mint(address(this), unitToMint);
            stakedUnit.deposit(unitToMint, msg.sender);
        } else {
            UNIT.mint(msg.sender, unitToMint);
        }
        emit Minted(msg.sender, unitToMint);
    }

    function redeem(uint256 assets, bool unstake, uint256 minUsdtOut, uint256 deadline, bytes calldata signature)
        external
        whenNotPaused
    {
        _checkPermit(
            _hashTypedDataV4(
                keccak256(abi.encode(REDEEM_TYPEHASH, msg.sender, assets, unstake, _useNonce(msg.sender), deadline))
            ),
            deadline,
            signature
        );
        if (unstake) {
            stakedUnit.withdraw(assets, address(this), msg.sender);
            UNIT.burn(assets);
        } else {
            UNIT.burnFrom(msg.sender, assets);
        }
        uint256 balanceBefore = USDT.balanceOf(msg.sender);
        _redeemInternal(assets);
        uint256 actualOut = USDT.balanceOf(msg.sender) - balanceBefore;
        if (assets == 0 || actualOut == 0 || actualOut < minUsdtOut) revert InsufficientOutput();
    }

    /// @notice Atomically claims rewards from JustLend, wraps them to jUSDD, and mints UNIT to the distributor.
    function claimAndDistributeRewards(IMultiMerkleDistributor.ClaimParam[] calldata claims, address distributor)
        external
        onlyRole(KEEPER_ROLE)
    {
        _checkRole(DISTRIBUTOR_ROLE, distributor);
        uint256 balanceBefore = USDD.balanceOf(address(this));
        IMultiMerkleDistributor(JUSTLEND_DISTRIBUTOR).multiClaim(claims);
        uint256 claimed = USDD.balanceOf(address(this)) - balanceBefore;
        if (claimed == 0) return;

        uint256 unitToMint = _depositToJustLend(claimed);
        if (unitToMint > 0) {
            UNIT.mint(distributor, unitToMint);
            emit RewardsDistributed(distributor, claimed, unitToMint);
        }
    }

    function withdraw(IERC20 token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        token.forceApprove(address(this), type(uint256).max);
        token.safeTransferFrom(address(this), to, amount);
    }

    function executeCall(address target, uint256 value, bytes calldata data)
        external
        payable
        onlyRole(DEFAULT_ADMIN_ROLE)
        returns (bytes memory)
    {
        if (target == address(0)) revert ZeroAddress();

        (bool success, bytes memory returndata) = target.call{value: value}(data);
        if (!success) revert OperationFailed();
        return returndata;
    }

    function _mintInternal(uint256 assets) private returns (uint256) {
        USDT.safeTransferFrom(msg.sender, address(this), assets);

        uint256 usddBefore = USDD.balanceOf(address(this));
        PSM.sellGem(address(this), assets);
        uint256 usddReceived = USDD.balanceOf(address(this)) - usddBefore;

        uint256 unitToMint = _depositToJustLend(usddReceived);
        if (assets > 0 && unitToMint == 0) revert OperationFailed();
        return unitToMint;
    }

    function _depositToJustLend(uint256 usddAmount) private returns (uint256) {
        if (usddAmount == 0) return 0;
        uint256 sharesBefore = jUSDD.balanceOf(address(this));
        USDD.forceApprove(address(jUSDD), usddAmount);
        if (jUSDD.mint(usddAmount) != 0) revert OperationFailed();
        USDD.forceApprove(address(jUSDD), 0);
        uint256 sharesReceived = jUSDD.balanceOf(address(this)) - sharesBefore;
        if (sharesReceived == 0) revert OperationFailed();

        uint256 rate = jUSDD.exchangeRateStored();
        uint256 creditedBacking = Math.mulDiv(sharesReceived, rate, 1e18);
        uint256 nominalUnits = usddAmount / 1e12;
        uint256 nominalBacking = nominalUnits * 1e12;

        uint256 maxLoss = Math.min(Math.ceilDiv(rate, 1e18), 1e12 - 1);
        if (nominalBacking > creditedBacking) {
            uint256 loss = nominalBacking - creditedBacking;
            if (loss > maxLoss) revert OperationFailed();
        }

        uint256 backing = USDD.balanceOf(address(this)) + Math.mulDiv(jUSDD.balanceOf(address(this)), rate, 1e18);
        uint256 required = (UNIT.totalSupply() + nominalUnits) * 1e12;
        if (backing + maxLoss < required) revert OperationFailed();

        return nominalUnits;
    }

    function _redeemInternal(uint256 assets) private {
        uint256 tout = PSM.tout();
        uint256 gemAmt = (assets * 1e18) / (1e18 + tout);
        uint256 usddRequired = gemAmt * 1e12 + (gemAmt * tout) / 1e6;
        uint256 usddBalance = USDD.balanceOf(address(this));
        if (usddRequired > usddBalance && jUSDD.redeemUnderlying(usddRequired - usddBalance) != 0) {
            revert OperationFailed();
        }
        USDD.forceApprove(address(PSM), usddRequired);
        PSM.buyGem(address(this), gemAmt);
        USDD.forceApprove(address(PSM), 0);
        USDT.safeTransferFrom(address(this), msg.sender, gemAmt);
        emit Redeemed(msg.sender, gemAmt);
    }

    function _checkPermit(bytes32 digest, uint256 deadline, bytes calldata signature) private view {
        if (block.timestamp > deadline) revert PermitExpired();
        _checkRole(SIGNER_ROLE, digest.recover(signature));
    }
}
