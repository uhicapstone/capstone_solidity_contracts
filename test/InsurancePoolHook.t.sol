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

    InsurancePoolHook hook;
    MockInsuranceCalculator calculator;
    MockFlashBorrower borrower;

    event FlashLoanExecuted(address indexed borrower, address indexed token, uint256 amount, uint256 fee);
    event InsuranceFeesCollected(address indexed token, uint256 amount, uint256 fee);
    event InsuranceFeeClaimed(address indexed user, address indexed token, uint256 amount);

    function setUp() public {
        // Deploy fresh manager and tokens
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

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
        (key,) = initPool(currency0, currency1, hook, 3000, SQRT_PRICE_1_1);

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

    function test_InsuranceFeeCollection() public {
        // Setup swap test settings
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        // Get initial balance - using maxFlashLoan instead of direct mapping access
        uint256 balanceBefore = hook.maxFlashLoan(Currency.unwrap(currency0));

        // Expect event emission
        vm.expectEmit(true, true, false, true);
        emit InsuranceFeesCollected(Currency.unwrap(currency0), 100e18, 1e18); // 1% fee on 100e18

        // Perform swap
        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -100e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        uint256 balanceAfter = hook.maxFlashLoan(Currency.unwrap(currency0));
        assertGt(balanceAfter, balanceBefore, "Insurance fees not collected");
        assertEq(balanceAfter - balanceBefore, 1e18, "Incorrect fee amount"); // 1% of 100e18
    }

    function test_FlashLoan() public {
        borrower = new MockFlashBorrower();
        uint256 loanAmount = 1e18;

        // Add funds to the insurance pool
        deal(Currency.unwrap(currency0), address(hook), 10e18);

        // Expect event emission
        vm.expectEmit(true, true, false, true);
        emit FlashLoanExecuted(
            address(borrower),
            Currency.unwrap(currency0),
            loanAmount,
            hook.flashFee(Currency.unwrap(currency0), loanAmount)
        );

        bool success = hook.flashLoan(borrower, Currency.unwrap(currency0), loanAmount, "");
        assertTrue(success, "Flash loan failed");
    }

    function test_ClaimInsuranceFees() public {
        // Generate fees through swap
        PoolSwapTest.TestSettings memory settings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -100e18,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            settings,
            ZERO_BYTES
        );

        // Get initial balances
        uint256 initialToken0Balance = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));

        // Expect event emission
        vm.expectEmit(true, true, false, true);
        emit InsuranceFeeClaimed(address(this), Currency.unwrap(currency0), 1e18); // 1% fee

        // Remove liquidity to trigger fee claim
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: -1e18, salt: bytes32(0)}),
            abi.encode(address(this))
        );

        uint256 finalToken0Balance = IERC20(Currency.unwrap(currency0)).balanceOf(address(this));
        assertGt(finalToken0Balance, initialToken0Balance, "No fees claimed");
    }
}

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

contract MockFlashBorrower is IERC3156FlashBorrower {
    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata)
        external
        returns (bytes32)
    {
        IERC20(token).approve(msg.sender, amount + fee);
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
