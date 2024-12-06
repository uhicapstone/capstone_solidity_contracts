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
import {IInsuranceCalculator} from "../src/interfaces/IInsuranceCalculator.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {MockInsuranceCalculator} from "./mocks/MockInsuranceCalculator.sol";
import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MockFlashBorrower is IERC3156FlashBorrower {
    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    address public immutable hook;
    bool public shouldRepay;

    constructor(address _hook) {
        hook = _hook;
    }

    function setShouldRepay(bool _shouldRepay) external {
        shouldRepay = _shouldRepay;
    }

    function onFlashLoan(address, address token, uint256 amount, uint256 fee, bytes calldata)
        external
        override
        returns (bytes32)
    {
        if (shouldRepay) {
            // Approve repayment
            IERC20(token).approve(hook, amount + fee);
        }
        return CALLBACK_SUCCESS;
    }
}

contract InsurancePoolHookTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    InsurancePoolHook hook;
    IInsuranceCalculator calculator;
    PoolId poolId;
    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;
    MockFlashBorrower flashBorrower;

    event InsuranceFeesCollected(address indexed token, uint256 amount, uint256 fee);
    event InsuranceFeeClaimed(address indexed user, address indexed token, uint256 amount);
    event FlashLoanExecuted(address indexed borrower, address indexed token, uint256 amount, uint256 fee);
    event LiquidityUpdated(address indexed user, address indexed token, uint256 amount, bool isAdd);

    function setUp() public {
        // Deploy the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);

        // Deploy mock calculator first
        calculator = new MockInsuranceCalculator();

        // Deploy hook with correct flags and namespace
        address hookAddr = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
                    | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            ) ^ (0x4444 << 144)
        );

        deployCodeTo("InsurancePoolHook.sol", abi.encode(manager), hookAddr);
        hook = InsurancePoolHook(hookAddr);
        flashBorrower = new MockFlashBorrower(address(hook));

        // Set the mock calculator
        hook.setCalculator(address(calculator));

        // Initialize pool
        (key, poolId) = initPool(currency0, currency1, hook, 3000, SQRT_PRICE_1_1);

        // Add initial liquidity
        _addInitialLiquidity();

        // Approve tokens for hook and flash borrower
        MockERC20(Currency.unwrap(currency0)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency1)).approve(address(hook), type(uint256).max);
        MockERC20(Currency.unwrap(currency0)).transfer(address(flashBorrower), 1000e18);
        MockERC20(Currency.unwrap(currency1)).transfer(address(flashBorrower), 1000e18);
    }

    function _addInitialLiquidity() internal {
        tickLower = -60;
        tickUpper = 60;
        uint128 initialLiquidity = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            initialLiquidity
        );

        amount0Expected = amount0Expected * 2;
        amount1Expected = amount1Expected * 2;

        (tokenId,) = posm.mint(
            key,
            tickLower,
            tickUpper,
            initialLiquidity,
            amount0Expected,
            amount1Expected,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
    }

    function test_AddLiquidity_UpdatesTracking() public {
        uint128 liquidityToAdd = 0.1e18;
        (uint256 amount0Min, uint256 amount1Min) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityToAdd
        );

        uint256 expectedAmount0 = amount0Min * 2;
        uint256 expectedAmount1 = amount1Min * 2;

        vm.expectEmit(true, true, true, true);
        emit LiquidityUpdated(address(posm), Currency.unwrap(currency0), expectedAmount0, true);
        vm.expectEmit(true, true, true, true);
        emit LiquidityUpdated(address(posm), Currency.unwrap(currency1), expectedAmount1, true);

        posm.increaseLiquidity(tokenId, liquidityToAdd, amount0Min * 2, amount1Min * 2, block.timestamp, ZERO_BYTES);

        (,,,, uint256 totalLiquidityToken0, uint256 totalLiquidityToken1,,) = hook.poolDataMap(poolId);
        assertGt(totalLiquidityToken0, 0);
        assertGt(totalLiquidityToken1, 0);
    }

    function test_SwapCollectsInsuranceFees() public {
        uint256 swapAmount = 1e18;
        PoolSwapTest.TestSettings memory testSettings =
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: true,
            amountSpecified: -int256(swapAmount),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        vm.expectEmit(true, true, true, true);
        emit InsuranceFeesCollected(Currency.unwrap(currency0), swapAmount, 1e16);

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);

        // Verify insurance fees were collected and claim tokens minted
        (,,,,,, uint256 insuranceFees0, uint256 insuranceFees1) = hook.poolDataMap(poolId);
        assertGt(insuranceFees0, 0);
        assertEq(insuranceFees1, 0);
        assertGt(manager.balanceOf(address(hook), currency0.toId()), 0);
    }

    function test_ClaimInsuranceFees_DistributesCorrectly() public {
        // First do a swap to collect fees
        test_SwapCollectsInsuranceFees();

        uint256 initialBalance0 = currency0.balanceOfSelf();
        uint256 initialBalance1 = currency1.balanceOfSelf();

        vm.expectEmit(true, true, true, true);
        emit InsuranceFeeClaimed(address(this), Currency.unwrap(currency0), 1e16);

        hook.claimInsuranceFees(key);

        assertGt(currency0.balanceOfSelf(), initialBalance0);
        assertEq(currency1.balanceOfSelf(), initialBalance1);
    }

    function test_FlashLoan_SucceedsWithRepayment() public {
        // First collect some fees through swaps
        test_SwapCollectsInsuranceFees();

        uint256 loanAmount = 0.1e18;
        flashBorrower.setShouldRepay(true);

        vm.expectEmit(true, true, true, true);
        emit FlashLoanExecuted(address(flashBorrower), Currency.unwrap(currency0), loanAmount, 0.001e18);

        bool success = hook.flashLoan(flashBorrower, Currency.unwrap(currency0), loanAmount, "");
        assertTrue(success);
    }

    function test_FlashLoan_FailsWithoutRepayment() public {
        test_SwapCollectsInsuranceFees();

        uint256 loanAmount = 0.1e18;
        flashBorrower.setShouldRepay(false);

        vm.expectRevert(InsurancePoolHook.RepaymentFailed.selector);
        hook.flashLoan(flashBorrower, Currency.unwrap(currency0), loanAmount, "");
    }

    function test_FlashLoan_RevertsWithInsufficientLiquidity() public {
        uint256 loanAmount = 1000e18; // Very large amount
        flashBorrower.setShouldRepay(true);

        vm.expectRevert(abi.encodeWithSelector(InsurancePoolHook.InsufficientLiquidity.selector, loanAmount, 0));
        hook.flashLoan(flashBorrower, Currency.unwrap(currency0), loanAmount, "");
    }
}
