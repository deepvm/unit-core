// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Unit} from "../src/Unit.sol";
import {Minter2, IPSM, ICErc20} from "../src/Minter2.sol";
import {RewardWrapper} from "../src/RewardWrapper.sol";
import {CumulativeMerkleDrop} from "../src/CumulativeMerkleDrop.sol";
import {MockTRONUSDT} from "./MockTRONUSDT.sol";
import {MockUSDD} from "./MockUSDD.sol";
import {MockPSM} from "./MockPSM.sol";
import {MockjUSDD} from "./MockjUSDD.sol";

contract RewardWrapperTest is Test {
    address constant USDT_ADDR = 0xa614f803B6FD780986A42c78Ec9c7f77e6DeD13C;
    address constant USDD_ADDR = 0xE91A7411e56Ce79E83570570f49B9FC35B7727c5;
    address constant PSM_ADDR = 0xB50Eb419ebeBA06c80Df5e9AaeC494Cef4297879;
    address constant jUSDD_ADDR = 0xE7F8A90ede3d84c7c0166BD84A4635E4675aCcfC;

    MockTRONUSDT usdt;
    MockUSDD usdd;
    MockPSM psm;
    MockjUSDD jUSDD;

    Unit unit;
    Minter2 minter2;
    RewardWrapper wrapper;
    CumulativeMerkleDrop distributor;

    address admin = makeAddr("admin");
    address userA = makeAddr("userA");
    address receiver = makeAddr("receiver");

    function setUp() public {
        // Deploy mocks
        MockTRONUSDT mockUsdtTemplate = new MockTRONUSDT();
        MockUSDD mockUsddTemplate = new MockUSDD();
        MockPSM mockPsmTemplate = new MockPSM();
        MockjUSDD mockjUsddTemplate = new MockjUSDD();

        vm.etch(USDT_ADDR, address(mockUsdtTemplate).code);
        vm.etch(USDD_ADDR, address(mockUsddTemplate).code);
        vm.etch(PSM_ADDR, address(mockPsmTemplate).code);
        vm.etch(jUSDD_ADDR, address(mockjUsddTemplate).code);

        usdt = MockTRONUSDT(USDT_ADDR);
        usdd = MockUSDD(USDD_ADDR);
        psm = MockPSM(PSM_ADDR);
        jUSDD = MockjUSDD(jUSDD_ADDR);

        psm.initialize(IERC20(USDT_ADDR), usdd);
        jUSDD.initialize(IERC20(USDD_ADDR));

        // Deploy production contracts
        unit = new Unit(admin);
        minter2 = new Minter2(admin, IERC20(USDT_ADDR), unit, IERC20(USDD_ADDR), IPSM(PSM_ADDR), ICErc20(jUSDD_ADDR));

        wrapper = new RewardWrapper(
            admin,
            IERC20(USDD_ADDR),
            ICErc20(jUSDD_ADDR),
            minter2,
            unit
        );

        // Deploy CumulativeMerkleDrop (initially empty root)
        vm.prank(admin);
        distributor = new CumulativeMerkleDrop(IERC20(address(unit)), bytes32(0));

        // Setup AccessControl roles
        vm.startPrank(admin);
        // Grant minter role to Minter2, RewardWrapper and admin
        unit.grantRole(unit.MINTER_ROLE(), address(minter2));
        unit.grantRole(unit.MINTER_ROLE(), address(wrapper));
        unit.grantRole(unit.MINTER_ROLE(), admin);

        // Grant DEFAULT_ADMIN_ROLE of Minter2 to RewardWrapper so it can call withdraw and manage roles
        minter2.grantRole(minter2.DEFAULT_ADMIN_ROLE(), address(wrapper));
        vm.stopPrank();
    }

    function testRoleForwarding() public {
        bytes32 testRole = keccak256("TEST_ROLE");

        // Verify userA does not have testRole on Minter2 initially
        assertFalse(minter2.hasRole(testRole, userA));

        // Grant role via RewardWrapper forwarding
        vm.prank(admin);
        wrapper.grantRoleOnMinter2(testRole, userA);
        assertTrue(minter2.hasRole(testRole, userA));

        // Revoke role via RewardWrapper forwarding
        vm.prank(admin);
        wrapper.revokeRoleOnMinter2(testRole, userA);
        assertFalse(minter2.hasRole(testRole, userA));
    }

    function testDistributeRewardsFlow() public {
        uint256 rewardAmount = 1000e18; // 1000 USDD

        // Simulate rewards landing on Minter2 address
        usdd.mint(address(minter2), rewardAmount);
        assertEq(usdd.balanceOf(address(minter2)), rewardAmount);

        // Verify initial state
        assertEq(IERC20(address(jUSDD)).balanceOf(address(minter2)), 0);
        assertEq(unit.balanceOf(address(distributor)), 0);

        // Execute reward distribution
        vm.prank(admin);
        wrapper.distributeRewards(rewardAmount, address(distributor));

        // Verify USDD has been withdrawn and wrapped
        assertEq(usdd.balanceOf(address(minter2)), 0);
        
        // Verify Minter2 received the wrapped jUSDD (mock yields 1:1 in our MockjUSDD)
        assertEq(IERC20(address(jUSDD)).balanceOf(address(minter2)), rewardAmount);

        // Verify UNIT has been minted directly into the distributor contract (with 1e12 offset)
        assertEq(unit.balanceOf(address(distributor)), 1000e6);
    }

    function testCumulativeClaim() public {
        // Generate Merkle proof for userA claiming 100 UNIT
        // Leaf = keccak256(userA, 100e6)
        bytes32 leaf = keccak256(abi.encodePacked(userA, uint256(100e6)));
        
        // Root is just the leaf itself for single-leaf tree
        bytes32 root = leaf;
        
        // Set new root on distributor
        vm.prank(admin);
        distributor.setMerkleRoot(root);

        // Mint UNIT into the distributor simulating distributed rewards
        vm.prank(admin);
        unit.mint(address(distributor), 100e6);

        // Generate empty proof because single-node tree verify works with empty proof array
        bytes32[] memory proof = new bytes32[](0);

        assertEq(unit.balanceOf(userA), 0);

        // UserA claims
        distributor.claim(userA, 100e6, root, proof);

        // Verify userA received the tokens and cumulative state updated
        assertEq(unit.balanceOf(userA), 100e6);
        assertEq(distributor.cumulativeClaimed(userA), 100e6);
    }

    function testWithdrawOnMinter2() public {
        uint256 amount = 500e18;
        usdd.mint(address(minter2), amount);

        assertEq(usdd.balanceOf(address(minter2)), amount);
        assertEq(usdd.balanceOf(receiver), 0);

        vm.prank(admin);
        wrapper.withdrawOnMinter2(IERC20(USDD_ADDR), receiver, amount);

        assertEq(usdd.balanceOf(address(minter2)), 0);
        assertEq(usdd.balanceOf(receiver), amount);
    }

    function testWithdrawOnWrapper() public {
        uint256 amount = 300e18;
        usdd.mint(address(wrapper), amount);

        assertEq(usdd.balanceOf(address(wrapper)), amount);
        assertEq(usdd.balanceOf(receiver), 0);

        vm.prank(admin);
        wrapper.withdraw(IERC20(USDD_ADDR), receiver, amount);

        assertEq(usdd.balanceOf(address(wrapper)), 0);
        assertEq(usdd.balanceOf(receiver), amount);
    }
}
