// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

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
    address user = makeAddr("user");
    address custody = makeAddr("custody");

    function setUp() public {
        signer = vm.addr(1);

        // Deploy contracts
        usdt = new MockTRONUSDT();
        UNIT = new Unit(admin);

        minter = new Minter(admin, usdt, UNIT);
        sUNIT = new StakedUnit(admin, UNIT);

        // Setup roles
        vm.startPrank(admin);
        UNIT.grantRole(UNIT.MINTER_ROLE(), address(minter));
        UNIT.grantRole(UNIT.MINTER_ROLE(), address(sUNIT));

        minter.grantRole(minter.SIGNER_ROLE(), signer);
        minter.grantRole(minter.CUSTODY_ROLE(), custody);

        vm.stopPrank();
    }

    function testMinterFlow() public {
        usdt.mint(user, 1000e6);
        assertEq(usdt.balanceOf(user), 1000e6);

        // 1. Mint
        vm.startPrank(user);
        usdt.approve(address(minter), 100e6);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter.nonces(user);

        bytes32 domainSeparator = keccak256(
            abi.encode(
                bytes32(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
                ),
                bytes32(keccak256(bytes("Unit Minter"))),
                bytes32(keccak256(bytes("1"))),
                block.chainid,
                address(minter)
            )
        );

        bytes32 structHash = keccak256(abi.encode(minter.MINT_TYPEHASH(), user, custody, 100e6, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(1, digest);
        minter.mint(100e6, custody, signer, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        assertEq(usdt.balanceOf(user), 900e6);
        assertEq(usdt.balanceOf(address(minter)), 0);
        assertEq(usdt.balanceOf(custody), 100e6);
        assertEq(UNIT.balanceOf(user), 100e6);

        // 2. Burn (simplified: signature NOT required)
        vm.startPrank(user);
        minter.burn(100e6);
        vm.stopPrank();

        assertEq(UNIT.balanceOf(user), 0);
        assertEq(minter.pendingRedeems(user), 100e6);

        // Simulate custody transferring USDT to Minter after burn
        vm.prank(custody);
        usdt.transfer(address(minter), 100e6);

        // 3. Redeem (signature released)
        vm.startPrank(user);
        nonce = minter.nonces(user);
        structHash = keccak256(abi.encode(minter.REDEEM_TYPEHASH(), user, 100e6, nonce, deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (v, r, s) = vm.sign(1, digest);

        minter.redeem(user, 100e6, signer, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        assertEq(usdt.balanceOf(user), 1000e6);
        assertEq(usdt.balanceOf(address(minter)), 0);
        assertEq(minter.pendingRedeems(user), 0);
    }

    function testConfiscate() public {
        // 1. Mint some Unit to user
        vm.prank(address(minter));
        UNIT.mint(user, 100e6);
        assertEq(UNIT.balanceOf(user), 100e6);

        // 2. Confiscate user's Unit
        vm.prank(admin);
        UNIT.confiscate(user, admin, 100e6);

        // 3. Verify balances
        assertEq(UNIT.balanceOf(user), 0);
        assertEq(UNIT.balanceOf(admin), 100e6);
    }

    function testsUNITDepositWithdrawAndRate() public {
        // Mint some Unit to user
        vm.prank(address(minter));
        UNIT.mint(user, 200e6);

        // Approve and deposit to sUNIT
        vm.startPrank(user);
        UNIT.approve(address(sUNIT), 200e6);
        sUNIT.deposit(100e6, user);
        vm.stopPrank();

        assertEq(sUNIT.balanceOf(user), 100e18);
        assertEq(UNIT.balanceOf(user), 100e6);

        // Set rate to 10% (1000 BPS)
        vm.prank(admin);
        sUNIT.setRate(1000);

        // Wrap forward 365 days
        vm.warp(block.timestamp + 365 days);

        // Verify total assets grew by 10% (from 100e6 to 110e6)
        assertEq(sUNIT.totalAssets(), 110e6);

        // Deposit again to trigger sync and yield minting
        vm.startPrank(user);
        sUNIT.deposit(100e6, user);
        vm.stopPrank();

        // Check that the yield (10e6) was minted and added to the vault
        assertEq(UNIT.balanceOf(address(sUNIT)), 210e6);
    }

    function testYieldRemainderAccumulation() public {
        // Mint some Unit to user
        vm.prank(address(minter));
        UNIT.mint(user, 200e6);

        vm.startPrank(user);
        UNIT.approve(address(sUNIT), 200e6);
        sUNIT.deposit(100e6, user);
        vm.stopPrank();

        vm.prank(admin);
        sUNIT.setRate(1000); // 10% rate

        // Run multiple rapid sync calls (simulating frequent syncs)
        for (uint256 i = 0; i < 10; i++) {
            vm.warp(block.timestamp + 1 days);
            vm.prank(admin);
            sUNIT.setRate(1000);
        }

        // Verify yield is correctly accumulated and total assets grew
        assertTrue(sUNIT.totalAssets() > 100e6);
    }
}
