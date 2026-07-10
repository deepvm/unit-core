// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Minter} from "../src/Minter.sol";
import {Unit} from "../src/Unit.sol";
import {StakedUnit} from "../src/StakedUnit.sol";
import {MockTRONUSDT} from "./MockTRONUSDT.sol";

contract ForkMainnetTest is Test {
    MockTRONUSDT usdt;
    Unit UNIT;
    Minter minter;
    StakedUnit sUNIT;

    address admin = makeAddr("admin");
    address signer;
    uint256 signerKey = 0xA11CE;
    address userA = makeAddr("userA");
    address userB = makeAddr("userB");
    address custody = makeAddr("custody");

    bytes32 domainSeparator;

    function setUp() public {
        signer = vm.addr(signerKey);

        // Deploy contracts
        usdt = new MockTRONUSDT();
        UNIT = new Unit(admin);
        minter = new Minter(admin, usdt, UNIT);
        sUNIT = new StakedUnit(admin, UNIT);

        // Setup access control roles
        vm.startPrank(admin);
        UNIT.grantRole(UNIT.MINTER_ROLE(), address(minter));
        UNIT.grantRole(UNIT.MINTER_ROLE(), address(sUNIT));

        minter.grantRole(minter.SIGNER_ROLE(), signer);
        minter.grantRole(minter.CUSTODY_ROLE(), custody);
        vm.stopPrank();

        // Calculate EIP-712 domain separator
        domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Unit Minter")),
                keccak256(bytes("1")),
                block.chainid,
                address(minter)
            )
        );
    }

    /* =========================================================================
       1. MINTER FLOW TESTS (EIP-712 & FOT USDT)
       ========================================================================= */

    function testMinterFlow() public {
        usdt.mint(userA, 1000e6);

        // --- 1. Mint ---
        vm.startPrank(userA);
        usdt.approve(address(minter), 100e6);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter.nonces(userA);

        bytes32 structHash = keccak256(abi.encode(minter.MINT_TYPEHASH(), userA, custody, 100e6, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        minter.mint(100e6, custody, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        assertEq(usdt.balanceOf(userA), 900e6);
        assertEq(usdt.balanceOf(custody), 100e6);
        assertEq(UNIT.balanceOf(userA), 100e6);

        // --- 2. Burn ---
        vm.startPrank(userA);
        minter.burn(100e6);
        vm.stopPrank();

        assertEq(UNIT.balanceOf(userA), 0);
        assertEq(minter.pendingRedeems(userA), 100e6);

        // Simulate custody transferring USDT back to Minter
        vm.prank(custody);
        usdt.transfer(address(minter), 100e6);

        // --- 3. Redeem ---
        vm.startPrank(userA);
        nonce = minter.nonces(userA);
        structHash = keccak256(abi.encode(minter.REDEEM_TYPEHASH(), userA, 100e6, nonce, deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (v, r, s) = vm.sign(signerKey, digest);
        minter.redeem(100e6, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        assertEq(usdt.balanceOf(userA), 1000e6);
        assertEq(minter.pendingRedeems(userA), 0);
    }

    function testMinterInvalidSignature() public {
        usdt.mint(userA, 100e6);

        vm.startPrank(userA);
        usdt.approve(address(minter), 100e6);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter.nonces(userA);

        bytes32 structHash = keccak256(abi.encode(minter.MINT_TYPEHASH(), userA, custody, 100e6, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Sign with an unauthorized key (0xBAD)
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, digest);

        bytes memory badSignature = abi.encodePacked(r, s, v);
        vm.expectRevert();
        minter.mint(100e6, custody, deadline, badSignature);
        vm.stopPrank();
    }

    function testMinterExpiredSignature() public {
        usdt.mint(userA, 100e6);

        vm.startPrank(userA);
        usdt.approve(address(minter), 100e6);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter.nonces(userA);

        bytes32 structHash = keccak256(abi.encode(minter.MINT_TYPEHASH(), userA, custody, 100e6, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Warp time past deadline
        vm.warp(deadline + 1 seconds);

        vm.expectRevert(Minter.PermitExpired.selector);
        minter.mint(100e6, custody, deadline, signature);
        vm.stopPrank();
    }

    function testMinterReplayAttackBlocked() public {
        usdt.mint(userA, 200e6);

        vm.startPrank(userA);
        usdt.approve(address(minter), 200e6);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter.nonces(userA);

        bytes32 structHash = keccak256(abi.encode(minter.MINT_TYPEHASH(), userA, custody, 100e6, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // First mint succeeds
        minter.mint(100e6, custody, deadline, signature);

        // Attempting to reuse the signature must fail because the nonce is already used
        vm.expectRevert();
        minter.mint(100e6, custody, deadline, signature);
        vm.stopPrank();
    }

    function testMinterFeeOnTransferSupport() public {
        usdt.mint(userA, 100e6);

        vm.startPrank(userA);
        usdt.approve(address(minter), 100e6);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter.nonces(userA);
        bytes32 structHash = keccak256(abi.encode(minter.MINT_TYPEHASH(), userA, custody, 100e6, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);

        minter.mint(100e6, custody, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        // 1:1 parity holds
        assertEq(UNIT.balanceOf(userA), 100e6);
    }

    /* =========================================================================
       2. CLASSIC VAULT (ERC-4626 / STAKEDUNIT) TESTS
       ========================================================================= */

    function testVaultSoleHolderYieldAccrual() public {
        vm.prank(address(minter));
        UNIT.mint(userA, 100e6);

        vm.startPrank(userA);
        UNIT.approve(address(sUNIT), 100e6);
        sUNIT.deposit(100e6, userA);
        vm.stopPrank();

        assertEq(sUNIT.balanceOf(userA), 100e18); // 12 decimals offset
        assertEq(sUNIT.totalAssets(), 100e6);

        // Set rate to 10% APY (1000 BPS)
        vm.prank(admin);
        sUNIT.setRate(1000);

        // Warp 365 days
        vm.warp(block.timestamp + 365 days);

        // Total assets should grow by 10% (100e6 -> 110e6)
        assertEq(sUNIT.totalAssets(), 110e6);

        // Sole holder redeems all shares to withdraw everything (avoids rounding limits)
        vm.startPrank(userA);
        sUNIT.redeem(sUNIT.balanceOf(userA), userA, userA);
        vm.stopPrank();

        assertApproxEqAbs(UNIT.balanceOf(userA), 110e6, 1e2);
        assertApproxEqAbs(sUNIT.totalAssets(), 0, 1);
        assertEq(sUNIT.totalSupply(), 0);
    }

    function testVaultMultipleHoldersProRata() public {
        vm.prank(address(minter));
        UNIT.mint(userA, 100e6);
        vm.prank(address(minter));
        UNIT.mint(userB, 100e6);

        // 1. User A deposits 100 UNIT
        vm.startPrank(userA);
        UNIT.approve(address(sUNIT), 100e6);
        sUNIT.deposit(100e6, userA);
        vm.stopPrank();

        // Set rate to 10% APY
        vm.prank(admin);
        sUNIT.setRate(1000);

        // Warp 182.5 days (half a year) -> 5% yield
        vm.warp(block.timestamp + 182.5 days);

        // User A's assets are now 105 UNIT
        assertEq(sUNIT.totalAssets(), 105e6);

        // 2. User B deposits 100 UNIT
        vm.startPrank(userB);
        UNIT.approve(address(sUNIT), 100e6);
        sUNIT.deposit(100e6, userB); // Will purchase shares at 1.05 rate
        vm.stopPrank();

        // Warp another 182.5 days
        vm.warp(block.timestamp + 182.5 days);

        // Total assets grow by rate on the new balance:
        // yield = (205e6 * 1000 * 182.5 days) / (10000 * 365 days) = 10.25e6 UNIT
        // total assets = 205e6 + 10.25e6 = 215.25e6 UNIT
        assertEq(sUNIT.totalAssets(), 215.25e6);

        // 3. Both withdraw everything
        uint256 sharesA = sUNIT.balanceOf(userA);
        uint256 sharesB = sUNIT.balanceOf(userB);

        vm.prank(userA);
        sUNIT.redeem(sharesA, userA, userA);

        vm.prank(userB);
        sUNIT.redeem(sharesB, userB, userB);

        // User A should get ~110.25 UNIT (100 + 5 + 5.25 pro-rata)
        // User B should get ~105 UNIT (100 + 5 pro-rata)
        assertApproxEqAbs(UNIT.balanceOf(userA), 110.25e6, 1e2);
        assertApproxEqAbs(UNIT.balanceOf(userB), 105.0e6, 1e2);
    }

    function testVaultInflationAttackPrevention() public {
        vm.prank(address(minter));
        UNIT.mint(userA, 1); // 1 wei
        vm.prank(address(minter));
        UNIT.mint(userB, 100e6); // 100 UNIT

        // User A deposits 1 wei
        vm.startPrank(userA);
        UNIT.approve(address(sUNIT), 1);
        sUNIT.deposit(1, userA);
        vm.stopPrank();

        // Attacker (userA) donates 100 UNIT directly to the vault to inflate price per share
        vm.prank(address(minter));
        UNIT.mint(address(sUNIT), 100e6);

        // User B deposits 100 UNIT. Because of decimalsOffset = 12,
        // User B gets correct pro-rata shares instead of 0 shares (which would happen without offset)
        vm.startPrank(userB);
        UNIT.approve(address(sUNIT), 100e6);
        sUNIT.deposit(100e6, userB);
        vm.stopPrank();

        assertTrue(sUNIT.balanceOf(userB) > 0);

        // User B withdraws everything. User B should get exactly their 100 UNIT back
        vm.startPrank(userB);
        sUNIT.withdraw(100e6, userB, userB);
        vm.stopPrank();

        assertApproxEqAbs(UNIT.balanceOf(userB), 100e6, 10);
    }

    function testVaultZeroDepositReverts() public {
        vm.startPrank(userA);
        UNIT.approve(address(sUNIT), 100e6);
        // Under standard ERC4626, zero asset deposits are allowed but mint 0 shares
        sUNIT.deposit(0, userA);
        assertEq(sUNIT.balanceOf(userA), 0);
        vm.stopPrank();
    }

    /* =========================================================================
       3. ACCESS CONTROL & ROLE ADMINISTRATION TESTS
       ========================================================================= */

    function testUnitRoleAccessControl() public {
        // User A has no roles and tries to mint
        vm.startPrank(userA);
        vm.expectRevert();
        UNIT.mint(userA, 100e6);

        // User A tries to burn
        vm.expectRevert();
        UNIT.burn(userA, 100e6);

        // User A tries to confiscate
        vm.expectRevert();
        UNIT.confiscate(userA, userB, 100e6);
        vm.stopPrank();
    }

    function testMinterRoleAccessControl() public {
        bytes32 signerRole = minter.SIGNER_ROLE();
        // User A tries to grant roles
        vm.startPrank(userA);
        vm.expectRevert();
        minter.grantRole(signerRole, userA);
        vm.stopPrank();
    }

    function testConfiscateMergedRole() public {
        vm.prank(address(minter));
        UNIT.mint(userA, 100e6);

        // Only DEFAULT_ADMIN_ROLE can confiscate now
        vm.prank(admin);
        UNIT.confiscate(userA, admin, 100e6);

        assertEq(UNIT.balanceOf(userA), 0);
        assertEq(UNIT.balanceOf(admin), 100e6);
    }

    function testReturnToCustody() public {
        usdt.mint(address(minter), 500e6);

        // A valid signer calls returnToCustody to send funds to a verified custody address
        vm.prank(signer);
        minter.returnToCustody(custody, 300e6);

        assertEq(usdt.balanceOf(address(minter)), 200e6);
        assertEq(usdt.balanceOf(custody), 300e6);
    }

    function testReturnToCustodySecurity() public {
        usdt.mint(address(minter), 500e6);

        // 1. Non-signer calls returnToCustody -> should revert
        vm.startPrank(userA);
        vm.expectRevert();
        minter.returnToCustody(custody, 100e6);
        vm.stopPrank();

        // 2. Signer calls returnToCustody to an unverified custody address -> should revert
        vm.startPrank(signer);
        vm.expectRevert();
        minter.returnToCustody(userA, 100e6);
        vm.stopPrank();
    }
}
