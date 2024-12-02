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
import {FlashLender} from "../src/FlashLender.sol";
import {LiquidityAmounts} from "v4-core/test/utils/LiquidityAmounts.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {EasyPosm} from "./utils/EasyPosm.sol";
import {Fixtures} from "./utils/Fixtures.sol";

contract InsurancePoolHookTest is Test, Fixtures {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    InsurancePoolHook hook;
    FlashLender flashLender;
    PoolId poolId;
    uint256 tokenId;
    int24 tickLower;
    int24 tickUpper;

    function setUp() public {
        // Deploy the pool manager, utility routers, and test tokens
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();
        deployAndApprovePosm(manager);

        // First deploy flash lender with a temporary hook address and 0.1% fee
        flashLender = new FlashLender(address(0), 10); // 10 basis points = 0.1%

        // Deploy hook with correct flags
        address hookAddr = address(
            uint160(
                Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG
                    | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG
            ) ^ (0x4444 << 144)
        );

        // Deploy the hook to the computed address with flash lender address
        deployCodeTo("InsurancePoolHook.sol", abi.encode(address(manager), address(flashLender)), hookAddr);
        hook = InsurancePoolHook(hookAddr);

        // Update flash lender with the correct hook address
        flashLender = new FlashLender(address(hook), 10);

        // Create the pool
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        poolId = key.toId();
        manager.initialize(key, SQRT_PRICE_1_1);

        // Provide full-range liquidity to the pool
        tickLower = TickMath.minUsableTick(key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(key.tickSpacing);

        uint128 liquidityAmount = 100e18;

        (uint256 amount0Expected, uint256 amount1Expected) = LiquidityAmounts.getAmountsForLiquidity(
            SQRT_PRICE_1_1,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            liquidityAmount
        );

        (tokenId,) = posm.mint(
            key,
            tickLower,
            tickUpper,
            liquidityAmount,
            amount0Expected + 1,
            amount1Expected + 1,
            address(this),
            block.timestamp,
            ZERO_BYTES
        );
    }

    function test_InsuranceFeeCollection() public {
        // Perform a test swap
        bool zeroForOne = true;
        int256 amountSpecified = -1e18; // negative number indicates exact input swap
        BalanceDelta swapDelta = swap(key, zeroForOne, amountSpecified, ZERO_BYTES);

        // Verify swap delta
        assertEq(int256(swapDelta.amount0()), amountSpecified);

        // Get the pool data struct
        (,,,,,, uint256 insuranceFees0, uint256 insuranceFees1) = hook.poolDataMap(poolId);

        // Check insurance fees were collected (0.1% of 1e18 = 1e15)
        assertEq(insuranceFees0, 1e15);
        assertEq(insuranceFees1, 0);
    }

    function test_LiquidityProvision() public {
        // Initial liquidity was added in setup
        (
            , // Skip token0
            , // Skip token1
            , // Skip totalContributionsToken0
            , // Skip totalContributionsToken1
            uint256 totalLiquidityToken0,
            uint256 totalLiquidityToken1,
            , // Skip insuranceFees0
                // Skip insuranceFees1
        ) = hook.poolDataMap(poolId);

        assertGt(totalLiquidityToken0, 0);
        assertGt(totalLiquidityToken1, 0);

        // Store initial liquidity values
        uint256 initialLiquidityToken0 = totalLiquidityToken0;
        uint256 initialLiquidityToken1 = totalLiquidityToken1;

        // Remove some liquidity
        uint256 liquidityToRemove = 10e18;
        posm.decreaseLiquidity(
            tokenId,
            liquidityToRemove,
            0, // min amount 0
            0, // min amount 1
            address(this),
            block.timestamp,
            ZERO_BYTES
        );

        // Get updated pool data
        (
            , // Skip token0
            , // Skip token1
            , // Skip totalContributionsToken0
            , // Skip totalContributionsToken1
            uint256 newTotalLiquidityToken0,
            uint256 newTotalLiquidityToken1,
            , // Skip insuranceFees0
                // Skip insuranceFees1
        ) = hook.poolDataMap(poolId);

        // Verify total liquidity decreased
        assertLt(newTotalLiquidityToken0, initialLiquidityToken0);
        assertLt(newTotalLiquidityToken1, initialLiquidityToken1);
    }

    function test_RevertNoFeesToClaim() public {
        vm.expectRevert("No fees to claim");
        hook.claimInsuranceFees(key);
    }
}
