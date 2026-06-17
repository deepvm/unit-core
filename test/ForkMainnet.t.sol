// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CustodyMinter} from "../src/CustodyMinter.sol";
import {JustLendMinter, ITRC20JToken} from "../src/JustLendMinter.sol";
import {UNIT} from "../src/UNIT.sol";
import {MockTRONUSDT} from "./MockTRONUSDT.sol";
import {MockjUSDT} from "../src/MockjUSDT.sol";

contract ForkMainnetTest is Test {
    MockTRONUSDT usdt;
    MockjUSDT jUSDT;
    UNIT unitToken;
    CustodyMinter custodyMinter;
    JustLendMinter justLendMinter;

    address admin = makeAddr("admin");
    address signer;
    address user = makeAddr("user");
    address custody = makeAddr("custody");

    function setUp() public {
        signer = vm.addr(1);

        // Deploy contracts
        usdt = new MockTRONUSDT();
        jUSDT = new MockjUSDT(address(usdt));
        unitToken = new UNIT(admin);

        custodyMinter = new CustodyMinter(admin, usdt, unitToken);
        justLendMinter = new JustLendMinter(admin, usdt, unitToken, ITRC20JToken(address(jUSDT)));

        // Setup roles
        vm.startPrank(admin);
        unitToken.grantRole(unitToken.MINTER_ROLE(), address(custodyMinter));
        unitToken.grantRole(unitToken.MINTER_ROLE(), address(justLendMinter));

        custodyMinter.grantRole(custodyMinter.SIGNER_ROLE(), signer);
        custodyMinter.grantRole(custodyMinter.CUSTODY_ROLE(), custody);
        justLendMinter.grantRole(justLendMinter.SIGNER_ROLE(), signer);
        vm.stopPrank();
    }

    function testCustodyMinterFlow() public {
        usdt.mint(user, 1000e6);
        assertEq(usdt.balanceOf(user), 1000e6);

        // 1. Mint
        vm.startPrank(user);
        usdt.approve(address(custodyMinter), 100e6);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = custodyMinter.nonces(user);

        bytes32 domainSeparator = keccak256(
            abi.encode(
                bytes32(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
                ),
                bytes32(keccak256(bytes("UNIT CustodyMinter"))),
                bytes32(keccak256(bytes("1"))),
                block.chainid,
                address(custodyMinter)
            )
        );

        bytes32 structHash = keccak256(abi.encode(custodyMinter.MINT_TYPEHASH(), user, custody, 100e6, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(1, digest);
        custodyMinter.mint(100e6, custody, signer, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        assertEq(usdt.balanceOf(user), 900e6);
        assertEq(usdt.balanceOf(address(custodyMinter)), 0);
        assertEq(usdt.balanceOf(custody), 100e6);
        assertEq(unitToken.balanceOf(user), 100e6);

        // 2. Burn (signature required)
        vm.startPrank(user);
        nonce = custodyMinter.nonces(user);
        structHash = keccak256(abi.encode(custodyMinter.BURN_TYPEHASH(), user, 100e6, nonce, deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (v, r, s) = vm.sign(1, digest);

        custodyMinter.burn(100e6, signer, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        assertEq(unitToken.balanceOf(user), 0);
        assertEq(custodyMinter.pendingRedeems(user), 100e6);

        // Simulate custody transferring USDT to CustodyMinter after burn
        vm.prank(custody);
        usdt.transfer(address(custodyMinter), 100e6);

        // 3. Redeem (signature released)
        vm.startPrank(user);
        nonce = custodyMinter.nonces(user);
        structHash = keccak256(abi.encode(custodyMinter.REDEEM_TYPEHASH(), user, 100e6, nonce, deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (v, r, s) = vm.sign(1, digest);

        custodyMinter.redeem(user, 100e6, signer, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        assertEq(usdt.balanceOf(user), 1000e6);
        assertEq(usdt.balanceOf(address(custodyMinter)), 0);
        assertEq(custodyMinter.pendingRedeems(user), 0);
    }

    function testJustLendMinterFlow() public {
        usdt.mint(user, 1000e6);
        assertEq(usdt.balanceOf(user), 1000e6);

        // 1. Mint
        vm.startPrank(user);
        usdt.approve(address(justLendMinter), 100e6);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = justLendMinter.nonces(user);

        bytes32 domainSeparator = keccak256(
            abi.encode(
                bytes32(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
                ),
                bytes32(keccak256(bytes("UNIT JustLendMinter"))),
                bytes32(keccak256(bytes("1"))),
                block.chainid,
                address(justLendMinter)
            )
        );

        bytes32 structHash = keccak256(abi.encode(justLendMinter.MINT_TYPEHASH(), user, 100e6, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(1, digest);
        justLendMinter.mint(100e6, signer, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        // Check balances:
        // User has 900e6 USDT and 100e6 UNIT
        // JustLendMinter has 100e6 jUSDT (deposited into jUSDT)
        // jUSDT contract has 100e6 USDT
        assertEq(usdt.balanceOf(user), 900e6);
        assertEq(usdt.balanceOf(address(justLendMinter)), 0);
        assertEq(jUSDT.balanceOf(address(justLendMinter)), 100e6);
        assertEq(usdt.balanceOf(address(jUSDT)), 100e6);
        assertEq(unitToken.balanceOf(user), 100e6);

        // 2. Redeem (burns UNIT, redeems jUSDT, sends USDT to user)
        vm.startPrank(user);
        nonce = justLendMinter.nonces(user);
        structHash = keccak256(abi.encode(justLendMinter.REDEEM_TYPEHASH(), user, 100e6, nonce, deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (v, r, s) = vm.sign(1, digest);

        justLendMinter.redeem(100e6, signer, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        assertEq(usdt.balanceOf(user), 1000e6);
        assertEq(unitToken.balanceOf(user), 0);
        assertEq(jUSDT.balanceOf(address(justLendMinter)), 0);
        assertEq(usdt.balanceOf(address(jUSDT)), 0);

        // 3. Profit withdrawal test
        // Let's mint again so we have a backing requirement
        vm.startPrank(user);
        usdt.approve(address(justLendMinter), 100e6);
        nonce = justLendMinter.nonces(user);
        structHash = keccak256(abi.encode(justLendMinter.MINT_TYPEHASH(), user, 100e6, nonce, deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (v, r, s) = vm.sign(1, digest);
        justLendMinter.mint(100e6, signer, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        // Now backingRequired is 100e6.
        // Let's simulate that jUSDT accrued 10e6 interest by transferring 10e6 USDT directly to jUSDT contract,
        // and setting the simulated interest on MockjUSDT to 10e6.
        usdt.mint(address(jUSDT), 10e6);
        jUSDT.setSimulatedInterest(10e6);

        // Call withdrawProfit to admin's custom address
        address profitRecipient = makeAddr("profitRecipient");
        vm.prank(admin);
        justLendMinter.withdrawProfit(profitRecipient);

        // Verify profit was received
        assertEq(usdt.balanceOf(profitRecipient), 10e6);
        // Verify backing is still intact
        assertEq(unitToken.totalSupply(), 100e6);
    }

    function testConfiscate() public {
        // 1. Mint some UNIT to user
        vm.prank(address(custodyMinter));
        unitToken.mint(user, 100e6);
        assertEq(unitToken.balanceOf(user), 100e6);

        // 2. Confiscate user's UNIT
        vm.prank(admin);
        unitToken.confiscate(user, admin, 100e6);

        // 3. Verify balances
        assertEq(unitToken.balanceOf(user), 0);
        assertEq(unitToken.balanceOf(admin), 100e6);
    }
}
