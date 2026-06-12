// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {JustLendAdapter, ITRC20JToken} from "../src/JustLendAdapter.sol";
import {Minter} from "../src/Minter.sol";
import {AUSD} from "../src/aUSD.sol";
import {MockTRONUSDT} from "./MockTRONUSDT.sol";
import {MockjUSDT} from "./JustLendAdapter.t.sol";

contract ForkMainnetTest is Test {
    MockTRONUSDT usdt;
    MockjUSDT jUSDT;
    AUSD ausd;
    Minter minter;
    JustLendAdapter adapter;

    address admin = makeAddr("admin");
    address operator = makeAddr("operator");
    address signer;
    address user = makeAddr("user");

    function setUp() public {
        signer = vm.addr(1);

        // Deploy contracts
        usdt = new MockTRONUSDT();
        jUSDT = new MockjUSDT(address(usdt));
        ausd = new AUSD(admin);
        minter = new Minter(admin, usdt, ausd);
        adapter = new JustLendAdapter(admin, operator, address(minter), address(usdt), address(jUSDT));

        // Setup roles
        vm.startPrank(admin);
        ausd.grantRole(ausd.MINTER_ROLE(), address(minter));
        minter.grantRole(minter.CUSTODY_ROLE(), address(adapter));
        minter.grantRole(minter.SIGNER_ROLE(), signer);
        minter.grantRole(minter.OPERATOR_ROLE(), operator);
        vm.stopPrank();
    }

    function testForkFlow() public {
        usdt.mint(user, 1000e6);

        assertEq(usdt.balanceOf(user), 1000e6);

        // 1. User approves Minter to spend USDT
        vm.startPrank(user);
        usdt.approve(address(minter), 1000e6);

        // 2. Mint aUSD (User deposits USDT, gets aUSD)
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter.nonces(user);

        bytes32 domainSeparator = keccak256(
            abi.encode(
                bytes32(
                    keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
                ),
                bytes32(keccak256(bytes("aUSD Minter"))),
                bytes32(keccak256(bytes("1"))),
                block.chainid,
                address(minter)
            )
        );

        bytes32 structHash =
            keccak256(abi.encode(minter.MINT_TYPEHASH(), user, address(adapter), 100e6, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        // Sign the digest
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(1, digest);

        // Call mint
        minter.mint(100e6, address(adapter), signer, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        // Check balances
        assertEq(usdt.balanceOf(user), 900e6);
        assertEq(usdt.balanceOf(address(adapter)), 100e6);
        assertEq(ausd.balanceOf(user), 100e6);

        // 3. Operator calls deposit on JustLendAdapter
        vm.prank(operator);
        adapter.deposit(100e6);

        // Check balances: USDT in adapter should be deposited into JustLend
        assertEq(usdt.balanceOf(address(adapter)), 0);
        assertEq(usdt.balanceOf(address(jUSDT)), 100e6);
        assertEq(jUSDT.balanceOf(address(adapter)), 100e6);

        // 4. Operator calls withdraw on JustLendAdapter
        vm.prank(operator);
        adapter.withdraw(100e6);

        // Check balances: USDT should be returned to Minter
        assertEq(usdt.balanceOf(address(minter)), 100e6);

        // 5. User redeems aUSD (burns aUSD, gets USDT)
        vm.startPrank(user);
        nonce = minter.nonces(user);
        structHash = keccak256(abi.encode(minter.REDEEM_TYPEHASH(), user, 100e6, nonce, deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (v, r, s) = vm.sign(1, digest);

        minter.redeem(100e6, signer, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        // Check final balances
        assertEq(usdt.balanceOf(user), 1000e6);
        assertEq(ausd.balanceOf(user), 0);
        assertEq(usdt.balanceOf(address(minter)), 0);
    }
}
