// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencyLibrary, Currency} from "v4-core/src/types/Currency.sol";
import {InsurancePoolHook} from "../src/InsurancePoolHook.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IERC20} from "v4-core/lib/forge-std/src/interfaces/IERC20.sol";
import {IERC3156FlashBorrower} from "openzeppelin-contracts/contracts/interfaces/IERC3156FlashBorrower.sol";

contract InsurancePoolHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // Contracts
    InsurancePoolHook hook;
    MockInsuranceCalculator calculator;
    MockFlashBorrower borrower;

    // Events (mirroring those from InsurancePoolHook for expectEmit)
    event FlashLoanExecuted(address indexed borrower, address indexed token, uint256 amount, uint256 fee);
    event InsuranceFeesCollected(address indexed token, uint256 amount, uint256 fee);
    event InsuranceFeeClaimed(address indexed user, address indexed token, uint256 amount);

    // PoolKey and identifiers
    PoolId poolId;

    function setUp() public {
        // Deploy fresh manager and tokens
        deployFreshManagerAndRouters();
        (Currency currency0, Currency currency1) = deployMintAndApprove2Currencies();

        // Calculate hook address with correct flags
        address hookAddress = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                    | Hooks.AFTER_INITIALIZE_FLAG
            )
        );

        // Deploy calculator and hook
        calculator = new MockInsuranceCalculator();
        deployCodeTo("InsurancePoolHook.sol", abi.encode(manager, address(calculator)), hookAddress);
        hook = InsurancePoolHook(hookAddress);

        // Initialize pool
        (key, poolId) = initPool(currency0, currency1, hook, 3000, SQRT_PRICE_1_1);

        // Approve tokens for the hook
        IERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);

        // Add initial liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1e18, salt: bytes32(0)}),
            abi.encode(address(this))
        );
    }

    /**
     * @notice Test that insurance fees are correctly collected during a swap.
     */
    function test_InsuranceFeeCollection() public {
        // Setup swap test settings
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Define swap parameters
        int256 amountSpecified = -100e18; // Exact input of 100e18
        bool zeroForOne = true;

        // Calculate expected fee using the mock calculator
        uint256 swapAmount = 100e18;
        uint256 expectedFee = calculator.calculateInsuranceFee(
            PoolId.unwrap(poolId),
            swapAmount,
            0, // totalContributionsToken0
            0, // totalContributionsToken1
            0, // currentPrice
            block.timestamp
        ); // Expected to be 1% of 100e18 = 1e18

        // Get initial max flash loan amount for currency0
        address token0 = Currency.unwrap(key.currency0);
        uint256 balanceBefore = hook.maxFlashLoan(token0);

        // Expect the InsuranceFeesCollected event to be emitted
        vm.expectEmit(true, true, false, true);
        emit InsuranceFeesCollected(token0, swapAmount, expectedFee);

        // Perform the swap
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        // Get max flash loan amount after swap
        uint256 balanceAfter = hook.maxFlashLoan(token0);

        // Verify that insurance fees were collected correctly
        assertEq(balanceAfter - balanceBefore, expectedFee, "Incorrect fee amount collected");
    }

    /**
     * @notice Test that flash loans execute correctly and fees are charged.
     */
    function test_FlashLoan() public {
        // Deploy a mock flash borrower
        borrower = new MockFlashBorrower();

        uint256 loanAmount = 1e18;
        uint256 expectedFee = calculator.calculateFlashLoanFee(loanAmount, 0, 0, 0); // 0.1% of 1e18 = 1e15

        // Generate fees through a swap to ensure liquidity is available for flash loans
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Perform a swap to generate fees
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -100e18, // Exact input of 100e18
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        // Add additional funds to the insurance pool to ensure sufficient liquidity
        address token0 = Currency.unwrap(key.currency0);
        deal(token0, address(hook), 10e18);

        // Calculate expected fee based on the mock calculator
        uint256 actualFee = hook.flashFee(token0, loanAmount);
        assertEq(actualFee, expectedFee, "Flash loan fee mismatch");

        // Prepare borrower with enough tokens for repayment
        deal(token0, address(borrower), loanAmount + actualFee);
        vm.startPrank(address(borrower));
        IERC20(token0).approve(address(hook), loanAmount + actualFee);
        vm.stopPrank();

        // Record initial balances
        uint256 hookBalanceBefore = hook.maxFlashLoan(token0);
        uint256 borrowerBalanceBefore = IERC20(token0).balanceOf(address(borrower));

        // Expect the FlashLoanExecuted event to be emitted
        vm.expectEmit(true, true, false, true);
        emit FlashLoanExecuted(address(borrower), token0, loanAmount, actualFee);

        // Execute flash loan
        bool success = hook.flashLoan(borrower, token0, loanAmount, "");
        assertTrue(success, "Flash loan execution failed");

        // Verify final balances
        uint256 hookBalanceAfter = hook.maxFlashLoan(token0);
        uint256 borrowerBalanceAfter = IERC20(token0).balanceOf(address(borrower));

        // The hook's balance should increase by the fee amount
        assertEq(hookBalanceAfter - hookBalanceBefore, actualFee, "Hook balance did not increase by fee");

        // The borrower should have less balance after paying the fee
        assertEq(borrowerBalanceBefore - borrowerBalanceAfter, actualFee, "Borrower did not pay the correct fee");
    }

    /**
     * @notice Test claiming insurance fees by removing liquidity.
     */
    function test_ClaimInsuranceFees() public {
        // Add additional liquidity to create a position with higher liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 10e18, salt: bytes32(0)}),
            abi.encode(address(this))
        );

        // Generate fees through a swap
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Perform a swap to generate insurance fees
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -100e18, // Exact input of 100e18
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        // Record initial token0 balance and hook's maxFlashLoan
        address token0 = Currency.unwrap(key.currency0);
        uint256 initialToken0Balance = IERC20(token0).balanceOf(address(this));
        uint256 initialHookBalance = hook.maxFlashLoan(token0);

        // Remove a portion of the liquidity to trigger fee claiming
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: -1e18, // Remove 1e18 liquidity
                salt: bytes32(0)
            }),
            abi.encode(address(this))
        );

        // Record final token0 balance and hook's maxFlashLoan
        uint256 finalToken0Balance = IERC20(token0).balanceOf(address(this));
        uint256 finalHookBalance = hook.maxFlashLoan(token0);

        // Calculate expected fee based on the mock calculator
        uint256 expectedFee = calculator.calculateInsuranceFee(
            PoolId.unwrap(poolId),
            100e18,
            0, // totalContributionsToken0 (mocked as 0)
            0, // totalContributionsToken1 (mocked as 0)
            0, // currentPrice (mocked as 0)
            block.timestamp
        ); // Expected to be 1% of 100e18 = 1e18

        // Verify that the user's token0 balance has increased by the expected fee
        assertEq(finalToken0Balance - initialToken0Balance, expectedFee, "Incorrect fee claimed");

        // Verify that the hook's maxFlashLoan has decreased by the expected fee
        assertEq(initialHookBalance - finalHookBalance, expectedFee, "Hook balance did not decrease by fee");
    }
}

/**
 * @title MockInsuranceCalculator
 * @notice A mock calculator for testing purposes, implementing the IInsuranceCalculator interface.
 */
contract MockInsuranceCalculator {
    function calculateInsuranceFee(bytes32, uint256 amount, uint256, uint256, uint256, uint256)
        external
        pure
        returns (uint256)
    {
        return amount / 100; // 1% fee
    }

    function calculateVolatility(bytes32, uint256, uint256) external pure returns (uint256) {
        return 5e16; // 5% volatility
    }

    function calculateFlashLoanFee(uint256 amount, uint256, uint256, uint256) external pure returns (uint256) {
        return amount / 1000; // 0.1% fee
    }
}

/**
 * @title MockFlashBorrower
 * @notice A mock borrower for flash loan testing, implementing the IERC3156FlashBorrower interface.
 */
contract MockFlashBorrower is IERC3156FlashBorrower {
    /**
     * @notice Callback function called by the flash lender after loan issuance.
     * @return bytes32 The keccak256 hash of the callback signature.
     */
    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata)
        external
        override
        returns (bytes32)
    {
        // Approve the repayment of the loan plus fee
        IERC20(token).approve(msg.sender, amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
