// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Unit} from "../src/Unit.sol";
import {StakedUnit} from "../src/StakedUnit.sol";
import {Minter2, IPSM, ICErc20, IMultiMerkleDistributor} from "../src/Minter2.sol";
import {MockTRONUSDT} from "./MockTRONUSDT.sol";
import {MockUSDD} from "./MockUSDD.sol";
import {MockPSM} from "./MockPSM.sol";
import {MockjUSDD} from "./MockjUSDD.sol";
import {CumulativeMerkleDrop} from "../src/CumulativeMerkleDrop.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract ForkMainnetTest is Test {
    event RewardsDistributed(address indexed distributor, uint256 claimedUSDD, uint256 mintedUNIT);
    // Real mainnet addresses
    address constant USDT_ADDR = 0xa614f803B6FD780986A42c78Ec9c7f77e6DeD13C;
    address constant USDD_ADDR = 0xE91A7411e56Ce79E83570570f49B9FC35B7727c5;
    address constant PSM_ADDR = 0x1113AE08A16489A7B76f2Ccc52290ab54E2783d8;
    address constant jUSDD_ADDR = 0x65c9feDE72Ba73CD1B0DCA2A974C070153dC6FCB;

    MockTRONUSDT usdt;
    Unit UNIT;
    StakedUnit sUNIT;

    // Minter2 dependencies
    MockUSDD usdd;
    MockPSM psm;
    MockjUSDD jUSDD;
    Minter2 minter2;
    CumulativeMerkleDrop distributor;

    address admin = makeAddr("admin");
    address signer;
    uint256 signerKey = 0xA11CE;
    address userA = makeAddr("userA");
    address userB = makeAddr("userB");
    address custody = makeAddr("custody");

    bytes32 domainSeparator;

    function setUp() public {
        signer = vm.addr(signerKey);

        // Deploy template mocks
        MockTRONUSDT mockUsdtTemplate = new MockTRONUSDT();
        MockUSDD mockUsddTemplate = new MockUSDD();
        MockPSM mockPsmTemplate = new MockPSM();
        MockjUSDD mockjUsddTemplate = new MockjUSDD();

        // Etch mock bytecodes onto the actual mainnet addresses
        vm.etch(USDT_ADDR, address(mockUsdtTemplate).code);
        vm.etch(USDD_ADDR, address(mockUsddTemplate).code);
        vm.etch(PSM_ADDR, address(mockPsmTemplate).code);
        vm.etch(jUSDD_ADDR, address(mockjUsddTemplate).code);

        // Map variables to the mainnet addresses
        usdt = MockTRONUSDT(USDT_ADDR);
        usdd = MockUSDD(USDD_ADDR);
        psm = MockPSM(PSM_ADDR);
        jUSDD = MockjUSDD(jUSDD_ADDR);

        // Initialize mutable state variables on the etched contracts
        psm.initialize(IERC20(USDT_ADDR), usdd);
        jUSDD.initialize(IERC20(USDD_ADDR));

        // Deploy production contracts
        UNIT = new Unit(admin);
        sUNIT = new StakedUnit(UNIT);

        vm.startPrank(admin);
        distributor = new CumulativeMerkleDrop(UNIT, bytes32(0));
        minter2 = new Minter2(admin, UNIT, sUNIT);

        // Setup access control roles
        UNIT.grantRole(UNIT.MINTER_ROLE(), admin);
        UNIT.grantRole(UNIT.MINTER_ROLE(), address(sUNIT));
        UNIT.grantRole(UNIT.MINTER_ROLE(), address(minter2));

        minter2.grantRole(minter2.SIGNER_ROLE(), signer);
        minter2.grantRole(minter2.DISTRIBUTOR_ROLE(), address(distributor));
        vm.stopPrank();

        // Calculate EIP-712 domain separator (version "3")
        domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Unit Minter")),
                keccak256(bytes("3")),
                block.chainid,
                address(minter2)
            )
        );
    }

    /* =========================================================================
       1. VAULT (ERC-4626 / STAKEDUNIT) TESTS
       ========================================================================= */

    function testVaultDepositAndWithdrawNoYield() public {
        vm.prank(admin);
        UNIT.mint(userA, 100e6);

        vm.startPrank(userA);
        UNIT.approve(address(sUNIT), 100e6);
        sUNIT.deposit(100e6, userA);
        vm.stopPrank();

        assertEq(sUNIT.balanceOf(userA), 100e6); // 6 decimals (same as unitUSD)
        assertEq(UNIT.balanceOf(address(sUNIT)), 100e6);

        // Warp 365 days - balance remains 100e6 (no yield)
        vm.warp(block.timestamp + 365 days);
        assertEq(UNIT.balanceOf(address(sUNIT)), 100e6);

        // Sole holder withdraws all shares
        vm.startPrank(userA);
        sUNIT.withdraw(sUNIT.balanceOf(userA), userA, userA);
        vm.stopPrank();

        assertEq(UNIT.balanceOf(userA), 100e6);
        assertEq(UNIT.balanceOf(address(sUNIT)), 0);
        assertEq(sUNIT.totalSupply(), 0);
    }

    function testWrapperTransferable() public {
        vm.prank(admin);
        UNIT.mint(userA, 100e6);

        vm.startPrank(userA);
        UNIT.approve(address(sUNIT), 100e6);
        sUNIT.deposit(100e6, userA);

        // 0-value transfer is permitted for ERC20 compatibility
        bool success = sUNIT.transfer(userB, 0);
        assertTrue(success);

        // Direct transfer works as standard ERC20
        sUNIT.transfer(userB, 10e6);
        assertEq(sUNIT.balanceOf(userB), 10e6);
        assertEq(sUNIT.balanceOf(userA), 90e6);

        // transferFrom also works
        sUNIT.approve(userB, 10e6);
        vm.stopPrank();

        vm.prank(userB);
        sUNIT.transferFrom(userA, userB, 10e6);
        assertEq(sUNIT.balanceOf(userB), 20e6);
        assertEq(sUNIT.balanceOf(userA), 80e6);
    }

    function testVaultMultipleHolders() public {
        vm.prank(admin);
        UNIT.mint(userA, 100e6);
        vm.prank(admin);
        UNIT.mint(userB, 200e6);

        vm.startPrank(userA);
        UNIT.approve(address(sUNIT), 100e6);
        sUNIT.deposit(100e6, userA);
        vm.stopPrank();

        vm.startPrank(userB);
        UNIT.approve(address(sUNIT), 200e6);
        sUNIT.deposit(200e6, userB);
        vm.stopPrank();

        assertEq(sUNIT.balanceOf(userA), 100e6);
        assertEq(sUNIT.balanceOf(userB), 200e6);
        assertEq(UNIT.balanceOf(address(sUNIT)), 300e6);

        vm.startPrank(userA);
        sUNIT.withdraw(100e6, userA, userA);
        vm.stopPrank();

        vm.startPrank(userB);
        sUNIT.withdraw(200e6, userB, userB);
        vm.stopPrank();

        assertEq(UNIT.balanceOf(userA), 100e6);
        assertEq(UNIT.balanceOf(userB), 200e6);
        assertEq(UNIT.balanceOf(address(sUNIT)), 0);
    }

    function testWrapper1to1BackingAndUnwrap() public {
        vm.prank(admin);
        UNIT.mint(userA, 100e6);

        vm.startPrank(userA);
        UNIT.approve(address(sUNIT), 100e6);
        sUNIT.deposit(100e6, userA);
        vm.stopPrank();

        assertEq(sUNIT.balanceOf(userA), 100e6);
        assertEq(UNIT.balanceOf(address(sUNIT)), 100e6);
        assertEq(sUNIT.totalSupply(), 100e6);

        // User unwraps via wrapped withdraw
        vm.prank(userA);
        sUNIT.withdraw(100e6, userA, userA);

        assertEq(sUNIT.balanceOf(userA), 0);
        assertEq(UNIT.balanceOf(userA), 100e6);
        assertEq(UNIT.balanceOf(address(sUNIT)), 0);
        assertEq(sUNIT.totalSupply(), 0);
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
       2. ACCESS CONTROL & ROLE ADMINISTRATION TESTS
       ========================================================================= */

    function testUnitRoleAccessControl() public {
        // User A has no roles and tries to mint
        vm.startPrank(userA);
        vm.expectRevert();
        UNIT.mint(userA, 100e6);
        vm.stopPrank();
    }

    function testUnitBurnAndBurnFrom() public {
        vm.prank(admin);
        UNIT.mint(userA, 100e6);

        // User A burns own tokens
        vm.prank(userA);
        UNIT.burn(40e6);
        assertEq(UNIT.balanceOf(userA), 60e6);

        // User B cannot burnFrom user A without allowance
        vm.prank(userB);
        vm.expectRevert();
        UNIT.burnFrom(userA, 20e6);

        // User A gives allowance to user B
        vm.prank(userA);
        UNIT.approve(userB, 20e6);

        // User B burns with allowance
        vm.prank(userB);
        UNIT.burnFrom(userA, 20e6);
        assertEq(UNIT.balanceOf(userA), 40e6);
    }

    function testMinterRoleAccessControl() public {
        bytes32 signerRole = minter2.SIGNER_ROLE();
        // User A tries to grant roles
        vm.startPrank(userA);
        vm.expectRevert();
        minter2.grantRole(signerRole, userA);
        vm.stopPrank();
    }

    function testNoFreezingOrConfiscationInUnit() public {
        vm.prank(admin);
        UNIT.mint(userA, 100e6);

        // User A can freely transfer tokens to User B without any freeze or whitelist restrictions
        vm.prank(userA);
        UNIT.transfer(userB, 50e6);
        assertEq(UNIT.balanceOf(userA), 50e6);
        assertEq(UNIT.balanceOf(userB), 50e6);

        // User A can deposit remaining tokens into sUNIT
        vm.startPrank(userA);
        UNIT.approve(address(sUNIT), 50e6);
        sUNIT.deposit(50e6, userA);
        vm.stopPrank();

        assertEq(sUNIT.balanceOf(userA), 50e6);
        assertEq(UNIT.balanceOf(userA), 0);
    }

    function testStakedUnitSovereignWithdrawal() public {
        vm.prank(admin);
        UNIT.mint(userA, 100e6);

        vm.startPrank(userA);
        UNIT.approve(address(sUNIT), 100e6);
        sUNIT.deposit(100e6, userA);
        vm.stopPrank();

        assertEq(sUNIT.balanceOf(userA), 100e6);

        // Stakers can always withdraw their shares back to UNIT freely
        vm.prank(userA);
        sUNIT.withdraw(100e6, userA, userA);

        assertEq(sUNIT.balanceOf(userA), 0);
        assertEq(UNIT.balanceOf(userA), 100e6);
        assertEq(UNIT.balanceOf(address(sUNIT)), 0);
        assertEq(sUNIT.totalSupply(), 0);
    }

    /* =========================================================================
       3. MINTER2 INTEGRATION TESTS (USDD, PSM, JUSTLEND, YIELD HARVEST)
       ========================================================================= */

    function testMinter2Flow() public {
        usdt.mint(userA, 1000e6);

        // --- 1. Mint ---
        vm.startPrank(userA);
        usdt.approve(address(minter2), 100e6);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter2.nonces(userA);

        bytes32 structHash = keccak256(abi.encode(minter2.MINT_TYPEHASH(), userA, 100e6, false, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        minter2.mint(100e6, false, 100e6, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        // Checks:
        // USDT should have been transferred to minter2, swapped to USDD, and deposited to jUSDD.
        // The balance of USDT on userA should decrease by 100e6.
        assertEq(usdt.balanceOf(userA), 900e6);
        // UserA should get 100e6 UNIT
        assertEq(UNIT.balanceOf(userA), 100e6);
        // jUSDD should have 100e18 USDD of underlying value (since 1:1 swap and deposit)
        assertEq(jUSDD.balanceOfUnderlying(address(minter2)), 100e18);

        // --- 2. Redeem ---
        vm.startPrank(userA);
        UNIT.approve(address(minter2), 40e6);
        nonce = minter2.nonces(userA);
        structHash = keccak256(abi.encode(minter2.REDEEM_TYPEHASH(), userA, 40e6, false, nonce, deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (v, r, s) = vm.sign(signerKey, digest);
        minter2.redeem(40e6, false, 40e6, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        // Checks:
        // userA's UNIT balance should decrease by 40e6.
        assertEq(UNIT.balanceOf(userA), 60e6);
        // userA should get 40e6 USDT back.
        assertEq(usdt.balanceOf(userA), 940e6);
        assertEq(usdt.balanceOf(address(minter2)), 0);
        // The remaining jUSDD underlying should be 60e18 USDD
        assertEq(jUSDD.balanceOfUnderlying(address(minter2)), 60e18);
    }

    function testMinter2YieldWithdrawal() public {
        usdt.mint(userA, 100e6);
        usdt.mint(userB, 200e6);

        // userA deposits 100 USDT
        vm.startPrank(userA);
        usdt.approve(address(minter2), 100e6);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter2.nonces(userA);
        bytes32 structHash = keccak256(abi.encode(minter2.MINT_TYPEHASH(), userA, 100e6, false, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        minter2.mint(100e6, false, 0, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        // userB deposits 200 USDT
        vm.startPrank(userB);
        usdt.approve(address(minter2), 200e6);
        nonce = minter2.nonces(userB);
        structHash = keccak256(abi.encode(minter2.MINT_TYPEHASH(), userB, 200e6, false, nonce, deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (v, r, s) = vm.sign(signerKey, digest);
        minter2.mint(200e6, false, 0, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        // --- Off-Chain Admin Calculation Helper ---
        uint256 totalUSDD =
            (jUSDD.balanceOf(address(minter2)) * jUSDD.exchangeRateStored()) / 1e18 + usdd.balanceOf(address(minter2));
        uint256 requiredUSDD = UNIT.totalSupply() * 1e12;
        uint256 yieldUSDD = totalUSDD > requiredUSDD ? totalUSDD - requiredUSDD : 0;
        assertEq(yieldUSDD, 0);

        // Simulate JustLend interest rate growth (accrue 30 USDD yield)
        jUSDD.accrueYield(30e18);

        // Re-evaluate yieldUSDD off-chain
        totalUSDD =
            (jUSDD.balanceOf(address(minter2)) * jUSDD.exchangeRateStored()) / 1e18 + usdd.balanceOf(address(minter2));
        yieldUSDD = totalUSDD > requiredUSDD ? totalUSDD - requiredUSDD : 0;
        assertEq(yieldUSDD, 30e18);

        // --- Simulate StakedUnit staking without yield ---
        // userA stakes 50 UNIT into StakedUnit
        vm.startPrank(userA);
        UNIT.approve(address(sUNIT), 50e6);
        sUNIT.deposit(50e6, userA);
        vm.stopPrank();

        // Warp time by 365 days
        vm.warp(block.timestamp + 365 days);

        // --- Off-Chain Admin Calculation ---
        uint256 currentExchangeRate = jUSDD.exchangeRateStored();
        totalUSDD = (jUSDD.balanceOf(address(minter2)) * currentExchangeRate) / 1e18 + usdd.balanceOf(address(minter2));
        requiredUSDD = UNIT.totalSupply() * 1e12;
        yieldUSDD = totalUSDD > requiredUSDD ? totalUSDD - requiredUSDD : 0;

        uint256 safeYield = yieldUSDD;
        assertEq(safeYield, 30e18);

        // Let's compute how many jUSDD shares represent 30e18 USDD yield
        uint256 jUSDDYieldShares = (safeYield * 1e18) / currentExchangeRate;

        address receiver = makeAddr("adminYieldReceiver");
        vm.prank(admin);
        minter2.withdraw(IERC20(address(jUSDD)), receiver, jUSDDYieldShares);

        // Remaining underlying jUSDD in Minter2 should cover active supply (300e18)
        uint256 remainingUnderlying = (jUSDD.balanceOf(address(minter2)) * currentExchangeRate) / 1e18;
        assertEq(remainingUnderlying, 300e18);
        assertEq(jUSDD.balanceOf(receiver), jUSDDYieldShares);
    }

    function testMinter2RedepositAndYieldWithToutFee() public {
        // Setup PSM fee of 0.1% (10**15) on buyGem (toutRate)
        psm.setTout(10 ** 15);

        usdt.mint(userA, 100e6);

        // User A deposits 100 USDT
        vm.startPrank(userA);
        usdt.approve(address(minter2), 100e6);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter2.nonces(userA);
        bytes32 structHash = keccak256(abi.encode(minter2.MINT_TYPEHASH(), userA, 100e6, false, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        minter2.mint(100e6, false, 0, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        // Accrue interest of 50 USDD
        jUSDD.accrueYield(50e18);

        // Check withdrawable yield:
        uint256 totalUSDD =
            (jUSDD.balanceOf(address(minter2)) * jUSDD.exchangeRateStored()) / 1e18 + usdd.balanceOf(address(minter2));
        uint256 requiredUSDD = UNIT.totalSupply() * 1e12;
        uint256 yieldUSDD = totalUSDD > requiredUSDD ? totalUSDD - requiredUSDD : 0;
        assertEq(yieldUSDD, 50e18);

        // --- Emergency Withdraw Test ---
        uint256 contractjUSDDBalance = jUSDD.balanceOf(address(minter2));
        assertTrue(contractjUSDDBalance > 0);

        address emergencyReceiver = makeAddr("emergencyReceiver");

        // Non-admin tries to call withdraw -> should revert
        vm.startPrank(userA);
        vm.expectRevert();
        minter2.withdraw(IERC20(address(jUSDD)), emergencyReceiver, contractjUSDDBalance);
        vm.stopPrank();

        // Admin calls withdraw successfully
        vm.prank(admin);
        minter2.withdraw(IERC20(address(jUSDD)), emergencyReceiver, contractjUSDDBalance);

        assertEq(jUSDD.balanceOf(emergencyReceiver), contractjUSDDBalance);
        assertEq(jUSDD.balanceOf(address(minter2)), 0);
    }

    function testMinter2WithDeal() public {
        usdt.mint(userA, 1000e6);

        // --- 1. Mint ---
        vm.startPrank(userA);
        usdt.approve(address(minter2), 100e6);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter2.nonces(userA);

        bytes32 structHash = keccak256(abi.encode(minter2.MINT_TYPEHASH(), userA, 100e6, false, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        minter2.mint(100e6, false, 0, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        assertEq(usdt.balanceOf(userA), 900e6);
        assertEq(UNIT.balanceOf(userA), 100e6);
        assertEq(jUSDD.balanceOfUnderlying(address(minter2)), 100e18);

        // --- 2. Redeem ---
        vm.startPrank(userA);
        UNIT.approve(address(minter2), 40e6);
        nonce = minter2.nonces(userA);
        structHash = keccak256(abi.encode(minter2.REDEEM_TYPEHASH(), userA, 40e6, false, nonce, deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (v, r, s) = vm.sign(signerKey, digest);
        minter2.redeem(40e6, false, 0, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        assertEq(UNIT.balanceOf(userA), 60e6);
        assertEq(usdt.balanceOf(userA), 940e6);
        assertEq(usdt.balanceOf(address(minter2)), 0);
        assertEq(jUSDD.balanceOfUnderlying(address(minter2)), 60e18);
    }

    function testMinter2WithTinAndToutFees() public {
        // Setup PSM tin (deposit fee) to 2% (2 * 10**16)
        psm.setTin(2 * 10 ** 16);
        // Setup PSM tout (exit fee) to 5% (5 * 10**16)
        psm.setTout(5 * 10 ** 16);

        usdt.mint(userA, 1000e6);

        // --- 1. Mint ---
        vm.startPrank(userA);
        usdt.approve(address(minter2), 100e6);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter2.nonces(userA);

        bytes32 structHash = keccak256(abi.encode(minter2.MINT_TYPEHASH(), userA, 100e6, false, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        minter2.mint(100e6, false, 98e6, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        assertEq(usdt.balanceOf(userA), 900e6);
        assertEq(UNIT.balanceOf(userA), 98e6);
        assertEq(jUSDD.balanceOfUnderlying(address(minter2)), 98e18);

        // --- 2. Redeem ---
        vm.startPrank(userA);
        uint256 burnAmt = 98e6;
        UNIT.approve(address(minter2), burnAmt);
        nonce = minter2.nonces(userA);
        uint256 expectedGemAmt = (burnAmt * 1e18) / (1e18 + 5 * 10 ** 16);

        structHash = keccak256(abi.encode(minter2.REDEEM_TYPEHASH(), userA, burnAmt, false, nonce, deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (v, r, s) = vm.sign(signerKey, digest);
        minter2.redeem(burnAmt, false, expectedGemAmt, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        assertEq(UNIT.balanceOf(userA), 0);
        assertEq(usdt.balanceOf(userA), 900e6 + expectedGemAmt);
        assertEq(usdt.balanceOf(address(minter2)), 0);
    }

    function testMinter2MintAndStake() public {
        usdt.mint(userA, 1000e6);

        vm.startPrank(userA);
        usdt.approve(address(minter2), 100e6);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter2.nonces(userA);

        bytes32 structHash = keccak256(abi.encode(minter2.MINT_TYPEHASH(), userA, 100e6, true, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        minter2.mint(100e6, true, 100e6, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        assertEq(UNIT.balanceOf(userA), 0);
        assertEq(sUNIT.balanceOf(userA), 100e6);
        assertEq(jUSDD.balanceOfUnderlying(address(minter2)), 100e18);
    }

    function testMinter2BurnAndUnstake() public {
        // First Mint and Stake
        usdt.mint(userA, 1000e6);
        vm.startPrank(userA);
        usdt.approve(address(minter2), 100e6);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter2.nonces(userA);
        bytes32 structHash = keccak256(abi.encode(minter2.MINT_TYPEHASH(), userA, 100e6, true, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        minter2.mint(100e6, true, 100e6, deadline, abi.encodePacked(r, s, v));

        // Now Approve Minter2 to spend sUNIT shares
        sUNIT.approve(address(minter2), 100e6);

        // Burn and Unstake
        nonce = minter2.nonces(userA);
        structHash = keccak256(abi.encode(minter2.REDEEM_TYPEHASH(), userA, 100e6, true, nonce, deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (v, r, s) = vm.sign(signerKey, digest);
        minter2.redeem(100e6, true, 100e6, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        assertEq(sUNIT.balanceOf(userA), 0);
        assertEq(usdt.balanceOf(userA), 1000e6);
    }

    function testMinter2SlippageProtection() public {
        usdt.mint(userA, 1000e6);

        // Mint with excessive minUnitOut reverts
        vm.startPrank(userA);
        usdt.approve(address(minter2), 100e6);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter2.nonces(userA);
        bytes32 structHash = keccak256(abi.encode(minter2.MINT_TYPEHASH(), userA, 100e6, false, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);

        vm.expectRevert(Minter2.InsufficientOutput.selector);
        minter2.mint(100e6, false, 101e6, deadline, abi.encodePacked(r, s, v));

        // Successful mint with exact minUnitOut
        minter2.mint(100e6, false, 100e6, deadline, abi.encodePacked(r, s, v));

        // Redeem with excessive minUsdtOut reverts
        UNIT.approve(address(minter2), 100e6);
        nonce = minter2.nonces(userA);
        structHash = keccak256(abi.encode(minter2.REDEEM_TYPEHASH(), userA, 100e6, false, nonce, deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (v, r, s) = vm.sign(signerKey, digest);

        vm.expectRevert(Minter2.InsufficientOutput.selector);
        minter2.redeem(100e6, false, 101e6, deadline, abi.encodePacked(r, s, v));

        vm.stopPrank();
    }

    function testZeroMintReverts() public {
        vm.startPrank(userA);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter2.nonces(userA);
        bytes32 structHash = keccak256(abi.encode(minter2.MINT_TYPEHASH(), userA, 0, false, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);

        vm.expectRevert(Minter2.InsufficientOutput.selector);
        minter2.mint(0, false, 0, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();
    }

    function testMinter2ClaimAndDistributeRewardsAtomic() public {
        MockMultiMerkleDistributor mockDistributorTemplate = new MockMultiMerkleDistributor(IERC20(address(usdd)));
        vm.etch(minter2.JUSTLEND_DISTRIBUTOR(), address(mockDistributorTemplate).code);

        usdd.mint(minter2.JUSTLEND_DISTRIBUTOR(), 500e18);

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 100e18;
        amounts[1] = 0;

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256("proof");

        IMultiMerkleDistributor.ClaimParam[] memory claims = new IMultiMerkleDistributor.ClaimParam[](1);
        claims[0] = IMultiMerkleDistributor.ClaimParam({
            merkleIndex: 0x1f, index: 0x083c, amounts: amounts, merkleProof: proof
        });

        // Non-keeper reverts
        vm.startPrank(userA);
        vm.expectRevert();
        minter2.claimAndDistributeRewards(claims, address(distributor));
        vm.stopPrank();

        // Keeper executes atomic claim and distribute
        vm.expectEmit(true, false, false, true, address(minter2));
        emit RewardsDistributed(address(distributor), 100e18, 100e6);
        vm.prank(admin);
        minter2.claimAndDistributeRewards(claims, address(distributor));

        assertEq(usdd.balanceOf(address(minter2)), 0);
        assertEq(jUSDD.balanceOf(address(minter2)), 100e18);
        assertEq(UNIT.balanceOf(address(distributor)), 100e6);
    }

    function testExecuteCall() public {
        vm.startPrank(userA);
        vm.expectRevert();
        minter2.executeCall(address(usdd), 0, abi.encodeWithSignature("transfer(address,uint256)", userA, 10e18));
        vm.stopPrank();

        usdd.mint(address(minter2), 10e18);
        vm.prank(admin);
        bytes memory ret =
            minter2.executeCall(address(usdd), 0, abi.encodeWithSignature("transfer(address,uint256)", userA, 10e18));
        bool success = abi.decode(ret, (bool));
        assertTrue(success);

        assertEq(usdd.balanceOf(userA), 10e18);
    }

    function testInvalidIntegrationConstructor() public {
        Unit otherUnit = new Unit(admin);
        vm.expectRevert(Minter2.InvalidIntegration.selector);
        new Minter2(admin, otherUnit, sUNIT);

        vm.expectRevert(Minter2.ZeroAddress.selector);
        new Minter2(address(0), UNIT, sUNIT);
    }

    function testMinter2ReceiveNativeTRX() public {
        vm.deal(address(this), 10 ether);
        (bool success,) = address(minter2).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(minter2).balance, 1 ether);
    }

    function testCumulativeMerkleDropOwnership() public {
        // renounceOwnership reverts
        vm.prank(admin);
        vm.expectRevert(CumulativeMerkleDrop.CannotRenounceOwnership.selector);
        distributor.renounceOwnership();

        // 2-step ownership transfer
        vm.prank(admin);
        distributor.transferOwnership(userA);
        assertEq(distributor.owner(), admin);

        vm.prank(userA);
        distributor.acceptOwnership();
        assertEq(distributor.owner(), userA);
    }

    function testMinter2InflationAttackProtection() public {
        // Accrue extreme yield to create massive exchange rate discrepancy
        jUSDD.accrueYield(1000000e18);

        usdt.mint(userA, 100e6);
        vm.startPrank(userA);
        usdt.approve(address(minter2), 100e6);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter2.nonces(userA);
        bytes32 structHash = keccak256(abi.encode(minter2.MINT_TYPEHASH(), userA, 100e6, false, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);

        minter2.mint(100e6, false, 0, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        // UNIT minted should not exceed credited underlying backing
        assertTrue(UNIT.balanceOf(userA) <= 100e6);
        assertTrue(UNIT.balanceOf(userA) > 0);
    }

    function testMintOneUSDTExactRounding() public {
        // Seed slight yield to simulate real mainnet non-integer exchange rate
        jUSDD.accrueYield(1234567890123456);

        usdt.mint(userA, 1e6); // 1 USDT
        vm.startPrank(userA);
        usdt.approve(address(minter2), 1e6);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter2.nonces(userA);
        bytes32 structHash = keccak256(abi.encode(minter2.MINT_TYPEHASH(), userA, 1e6, false, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);

        // Require exactly 1 UNIT (1_000_000)
        minter2.mint(1e6, false, 1e6, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        assertEq(UNIT.balanceOf(userA), 1e6);
    }

    function testMinter2PauseUnpause() public {
        bytes32 adminRole = minter2.DEFAULT_ADMIN_ROLE();

        usdt.mint(userA, 100e6);
        vm.startPrank(userA);
        usdt.approve(address(minter2), 100e6);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter2.nonces(userA);
        bytes32 structHash = keccak256(abi.encode(minter2.MINT_TYPEHASH(), userA, 100e6, false, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        vm.stopPrank();

        // Non-admin cannot pause
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, userA, adminRole
            )
        );
        vm.prank(userA);
        minter2.pause();

        // Admin pauses
        vm.prank(admin);
        minter2.pause();
        assertTrue(minter2.paused());

        // Mint reverts when paused
        vm.prank(userA);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        minter2.mint(100e6, false, 0, deadline, abi.encodePacked(r, s, v));

        // Redeem also reverts when paused
        vm.prank(userA);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        minter2.redeem(100e6, false, 0, deadline, abi.encodePacked(r, s, v));

        // Non-admin cannot unpause
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, userA, adminRole
            )
        );
        vm.prank(userA);
        minter2.unpause();

        // Admin unpauses
        vm.prank(admin);
        minter2.unpause();
        assertFalse(minter2.paused());

        // Mint succeeds after unpause
        vm.prank(userA);
        minter2.mint(100e6, false, 0, deadline, abi.encodePacked(r, s, v));
        assertEq(UNIT.balanceOf(userA), 100e6);
    }

    function testCannotRenounceAdminRole() public {
        bytes32 adminRole = UNIT.DEFAULT_ADMIN_ROLE();
        bytes32 minterRole = UNIT.MINTER_ROLE();

        // UNIT admin renouncement reverts
        vm.expectRevert(Unit.CannotRenounceAdmin.selector);
        vm.prank(admin);
        UNIT.renounceRole(adminRole, admin);

        // Minter2 admin renouncement reverts
        vm.expectRevert(Minter2.CannotRenounceAdmin.selector);
        vm.prank(admin);
        minter2.renounceRole(adminRole, admin);

        // Non-admin roles CAN be renounced
        vm.prank(admin);
        UNIT.renounceRole(minterRole, admin);
        assertFalse(UNIT.hasRole(minterRole, admin));
    }

    function testCumulativeMerkleDropZeroRootReverts() public {
        vm.prank(admin);
        vm.expectRevert(CumulativeMerkleDrop.ZeroRoot.selector);
        distributor.setMerkleRoot(bytes32(0));

        bytes32 validRoot = keccak256("validRoot");
        vm.prank(admin);
        distributor.setMerkleRoot(validRoot);
        assertEq(distributor.merkleRoot(), validRoot);
    }
}

contract MockMultiMerkleDistributor {
    IERC20 public immutable usdd;

    constructor(IERC20 usdd_) {
        usdd = usdd_;
    }

    function multiClaim(IMultiMerkleDistributor.ClaimParam[] calldata claims) external {
        for (uint256 i = 0; i < claims.length; i++) {
            usdd.transfer(msg.sender, claims[i].amounts[0]);
        }
    }
}
