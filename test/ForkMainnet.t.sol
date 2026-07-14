// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Minter} from "../src/Minter.sol";
import {Unit} from "../src/Unit.sol";
import {StakedUnit} from "../src/StakedUnit.sol";
import {Minter2, IPSM, ICErc20} from "../src/Minter2.sol";
import {MockTRONUSDT} from "./MockTRONUSDT.sol";
import {MockUSDD} from "./MockUSDD.sol";
import {MockPSM} from "./MockPSM.sol";
import {MockjUSDD} from "./MockjUSDD.sol";

contract ForkMainnetTest is Test {
    // Real mainnet addresses
    address constant USDT_ADDR = 0xa614f803B6FD780986A42c78Ec9c7f77e6DeD13C;
    address constant USDD_ADDR = 0xE91A7411e56Ce79E83570570f49B9FC35B7727c5;
    address constant PSM_ADDR = 0xB50Eb419ebeBA06c80Df5e9AaeC494Cef4297879;
    address constant jUSDD_ADDR = 0xE7F8A90ede3d84c7c0166BD84A4635E4675aCcfC;

    MockTRONUSDT usdt;
    Unit UNIT;
    Minter minter;
    StakedUnit sUNIT;

    // Minter2 dependencies
    MockUSDD usdd;
    MockPSM psm;
    MockjUSDD jUSDD;
    Minter2 minter2;

    address admin = makeAddr("admin");
    address signer;
    uint256 signerKey = 0xA11CE;
    address userA = makeAddr("userA");
    address userB = makeAddr("userB");
    address custody = makeAddr("custody");

    bytes32 domainSeparator;
    bytes32 domainSeparator2;

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
        minter = new Minter(admin, IERC20(USDT_ADDR), UNIT);
        sUNIT = new StakedUnit(admin, UNIT);
        minter2 = new Minter2(
            admin,
            IERC20(USDT_ADDR),
            UNIT,
            IERC20(USDD_ADDR),
            IPSM(PSM_ADDR),
            ICErc20(jUSDD_ADDR)
        );

        // Setup access control roles
        vm.startPrank(admin);
        UNIT.grantRole(UNIT.MINTER_ROLE(), address(minter));
        UNIT.grantRole(UNIT.MINTER_ROLE(), address(sUNIT));
        UNIT.grantRole(UNIT.MINTER_ROLE(), address(minter2));

        minter.grantRole(minter.SIGNER_ROLE(), signer);
        minter.grantRole(minter.CUSTODY_ROLE(), custody);

        minter2.grantRole(minter2.SIGNER_ROLE(), signer);
        vm.stopPrank();

        // Calculate EIP-712 domain separators
        domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Unit Minter")),
                keccak256(bytes("1")),
                block.chainid,
                address(minter)
            )
        );

        domainSeparator2 = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Unit Minter")),
                keccak256(bytes("2")),
                block.chainid,
                address(minter2)
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

    /* =========================================================================
       4. MINTER2 INTEGRATION TESTS (USDD, PSM, JUSTLEND, YIELD HARVEST)
       ========================================================================= */

    function testMinter2Flow() public {
        usdt.mint(userA, 1000e6);

        // --- 1. Mint ---
        vm.startPrank(userA);
        usdt.approve(address(minter2), 100e6);

        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter2.nonces(userA);

        bytes32 structHash = keccak256(abi.encode(minter2.MINT_TYPEHASH(), userA, USDD_ADDR, 100e6, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator2, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        minter2.mint(100e6, USDD_ADDR, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        // Checks:
        // USDT should have been transferred to minter2, swapped to USDD, and deposited to jUSDD.
        // The balance of USDT on userA should decrease by 100e6.
        assertEq(usdt.balanceOf(userA), 900e6);
        // UserA should get 100e6 UNIT
        assertEq(UNIT.balanceOf(userA), 100e6);
        // jUSDD should have 100e18 USDD of underlying value (since 1:1 swap and deposit)
        assertEq(jUSDD.balanceOfUnderlying(address(minter2)), 100e18);

        // --- 2. Burn ---
        vm.startPrank(userA);
        minter2.burn(40e6);
        vm.stopPrank();

        // Checks:
        // userA's UNIT balance should decrease by 40e6.
        assertEq(UNIT.balanceOf(userA), 60e6);
        // pendingRedeems of userA should increase by 40e6.
        assertEq(minter2.pendingRedeems(userA), 40e6);
        // 40e6 USDT should be redeemed back from JustLend/PSM and sit on Minter2's balance
        assertEq(usdt.balanceOf(address(minter2)), 40e6);
        // The remaining jUSDD underlying should be 60e18 USDD
        assertEq(jUSDD.balanceOfUnderlying(address(minter2)), 60e18);

        // --- 3. Redeem ---
        vm.startPrank(userA);
        nonce = minter2.nonces(userA);
        structHash = keccak256(abi.encode(minter2.REDEEM_TYPEHASH(), userA, 40e6, nonce, deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator2, structHash));

        (v, r, s) = vm.sign(signerKey, digest);
        minter2.redeem(40e6, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        // Checks:
        // userA should get 40e6 USDT back.
        assertEq(usdt.balanceOf(userA), 940e6);
        assertEq(minter2.pendingRedeems(userA), 0);
        assertEq(usdt.balanceOf(address(minter2)), 0);
    }

    function testMinter2YieldWithdrawal() public {
        usdt.mint(userA, 100e6);
        usdt.mint(userB, 200e6);

        // userA deposits 100 USDT
        vm.startPrank(userA);
        usdt.approve(address(minter2), 100e6);
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = minter2.nonces(userA);
        bytes32 structHash = keccak256(abi.encode(minter2.MINT_TYPEHASH(), userA, USDD_ADDR, 100e6, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator2, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        minter2.mint(100e6, USDD_ADDR, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        // userB deposits 200 USDT
        vm.startPrank(userB);
        usdt.approve(address(minter2), 200e6);
        nonce = minter2.nonces(userB);
        structHash = keccak256(abi.encode(minter2.MINT_TYPEHASH(), userB, USDD_ADDR, 200e6, nonce, deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator2, structHash));
        (v, r, s) = vm.sign(signerKey, digest);
        minter2.mint(200e6, USDD_ADDR, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        // --- Off-Chain Admin Calculation Helper ---
        // totalUSDD = (jUSDD.balanceOf(address(minter2)) * jUSDD.exchangeRateStored()) / 1e18 + usdd.balanceOf(address(minter2))
        // requiredUSDD = UNIT.totalSupply() * 1e12
        // yieldUSDD = totalUSDD - requiredUSDD
        uint256 totalUSDD = (jUSDD.balanceOf(address(minter2)) * jUSDD.exchangeRateStored()) / 1e18 + usdd.balanceOf(address(minter2));
        uint256 requiredUSDD = UNIT.totalSupply() * 1e12;
        uint256 yieldUSDD = totalUSDD > requiredUSDD ? totalUSDD - requiredUSDD : 0;
        assertEq(yieldUSDD, 0);

        // Simulate JustLend interest rate growth (accrue 30 USDD yield)
        jUSDD.accrueYield(30e18);

        // Re-evaluate yieldUSDD off-chain
        totalUSDD = (jUSDD.balanceOf(address(minter2)) * jUSDD.exchangeRateStored()) / 1e18 + usdd.balanceOf(address(minter2));
        yieldUSDD = totalUSDD > requiredUSDD ? totalUSDD - requiredUSDD : 0;
        assertEq(yieldUSDD, 30e18);

        // --- Simulate StakedUnit Yield Accrual (from other activity/independent) ---
        // userA stakes 50 UNIT into StakedUnit
        vm.startPrank(userA);
        UNIT.approve(address(sUNIT), 50e6);
        sUNIT.deposit(50e6, userA);
        vm.stopPrank();

        // StakedUnit rate set to 10% (1000 BPS)
        vm.prank(admin);
        sUNIT.setRate(1000);

        // Warp time by 365 days to accrue yield inside StakedUnit (5 UNIT interest = 5e18 USDD equivalent)
        vm.warp(block.timestamp + 365 days);

        // --- Off-Chain Admin Calculation ---
        // The admin runs the off-chain formula:
        uint256 currentExchangeRate = jUSDD.exchangeRateStored();
        totalUSDD = (jUSDD.balanceOf(address(minter2)) * currentExchangeRate) / 1e18 + usdd.balanceOf(address(minter2));
        requiredUSDD = UNIT.totalSupply() * 1e12;
        yieldUSDD = totalUSDD > requiredUSDD ? totalUSDD - requiredUSDD : 0;

        // unSyncedYield = StakedUnit.totalAssets() - UNIT.balanceOf(StakedUnit) = 55e6 - 50e6 = 5e6
        uint256 unSyncedYield = sUNIT.totalAssets() - UNIT.balanceOf(address(sUNIT));
        // safeYield = yieldUSDD - unSyncedYield * 1e12 = 30e18 - 5e18 = 25e18
        uint256 safeYield = yieldUSDD - unSyncedYield * 1e12;
        assertEq(safeYield, 25e18);

        // Let's compute how many jUSDD shares represent 25e18 USDD yield
        uint256 jUSDDYieldShares = (safeYield * 1e18) / currentExchangeRate;

        address receiver = makeAddr("adminYieldReceiver");
        vm.prank(admin);
        minter2.withdraw(IERC20(address(jUSDD)), receiver, jUSDDYieldShares);

        // Remaining underlying jUSDD in Minter2 should cover the outstanding active supply (300e18) plus the stakers' 5e18 yield
        uint256 remainingUnderlying = (jUSDD.balanceOf(address(minter2)) * currentExchangeRate) / 1e18;
        assertEq(remainingUnderlying, 305e18);
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
        bytes32 structHash = keccak256(abi.encode(minter2.MINT_TYPEHASH(), userA, USDD_ADDR, 100e6, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator2, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        minter2.mint(100e6, USDD_ADDR, deadline, abi.encodePacked(r, s, v));
        vm.stopPrank();

        // Accrue interest of 50 USDD
        jUSDD.accrueYield(50e18);

        // Check withdrawable yield:
        // Debt is 100e6 USDT. Required USDD = 100e18.
        // Total USDD = 150e18.
        // Yield should be exactly 150e18 - 100e18 = 50e18 USDD.
        uint256 totalUSDD = (jUSDD.balanceOf(address(minter2)) * jUSDD.exchangeRateStored()) / 1e18 + usdd.balanceOf(address(minter2));
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

        assertEq(jUSDD.balanceOf(address(minter2)), 0);
        assertEq(jUSDD.balanceOf(emergencyReceiver), contractjUSDDBalance);
    }

    function testMinter2WithDeal() public {
        // Demonstrate direct manipulation of balances on the real USDT address using deal
        deal(USDT_ADDR, userA, 500e6);
        assertEq(usdt.balanceOf(userA), 500e6);

        deal(USDD_ADDR, userB, 1000e18);
        assertEq(usdd.balanceOf(userB), 1000e18);
    }
}
