// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

// Add interface for Stylus contract
interface IInsuranceCalculator {
    function calculateInsuranceFee(
        bytes32 poolId,
        uint256 amount,
        uint256 totalLiquidity,
        uint256 totalVolume,
        uint256 currentPrice,
        uint256 timestamp
    ) external returns (uint256);

    function calculateIlCompensation(
        uint256 lpShare,
        uint256 insuranceFund,
        uint256 priceOld,
        uint256 priceNew,
        uint256 timeInPool,
        uint256 totalLiquidity
    ) external view returns (uint256);

    function calculateFlashLoanFee(
        uint256 loanAmount,
        uint256 totalLiquidity,
        uint256 utilizationRate,
        uint256 defaultHistory
    ) external view returns (uint256);

    function calculateVolatility(bytes32 poolId, uint256 currentPrice, uint256 timestamp) external returns (uint256);
}

contract InsurancePoolHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    address public flashLoanContract;

    // Add calculator reference
    IInsuranceCalculator public immutable insuranceCalculator;

    modifier onlyFlashLoanContract() {
        require(msg.sender == flashLoanContract, "Caller is not the flash loan contract");
        _;
    }

    // Pool data structure to track liquidity and fees
    struct PoolData {
        address token0;
        address token1;
        uint256 totalContributionsToken0; // Total fees collected for Token0
        uint256 totalContributionsToken1; // Total fees collected for Token1
        mapping(address => uint256) lpLiquidityToken0; // LP-specific liquidity in Token0
        mapping(address => uint256) lpLiquidityToken1; // LP-specific liquidity in Token1
        uint256 totalLiquidityToken0; // Total liquidity excluding fees
        uint256 totalLiquidityToken1; // Total liquidity excluding fees
        uint256 insuranceFees0;
        uint256 insuranceFees1;
    }

    // Token data structure for global accounting
    struct TokenData {
        uint256 totalFunds;
        mapping(address => uint256) poolContributions;
    }

    // Mappings
    mapping(PoolId => PoolData) public poolDataMap;
    mapping(address => TokenData) public tokenData;
    address[] public poolList;

    constructor(IPoolManager _poolManager, address _flashLoanContract, address _insuranceCalculator)
        BaseHook(_poolManager)
    {
        flashLoanContract = _flashLoanContract;
        insuranceCalculator = IInsuranceCalculator(_insuranceCalculator);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: true,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: true,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24) external override returns (bytes4) {
        PoolId poolId = key.toId();
        // Convert PoolId to bytes32 then address
        poolList.push(address(uint160(bytes20(abi.encodePacked(poolId)))));

        // Initialize pool data
        PoolData storage poolData = poolDataMap[poolId];
        poolData.token0 = Currency.unwrap(key.currency0);
        poolData.token1 = Currency.unwrap(key.currency1);

        return BaseHook.afterInitialize.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        PoolData storage poolData = poolDataMap[poolId];

        uint256 amount = params.zeroForOne ? uint256(-params.amountSpecified) : uint256(-params.amountSpecified);
        uint256 totalVolume = poolData.totalContributionsToken0 + poolData.totalContributionsToken1;

        // Calculate current price
        uint256 currentPrice = poolData.totalLiquidityToken1 > 0
            ? (poolData.totalLiquidityToken0 * 1e18) / poolData.totalLiquidityToken1
            : 0;

        // Get insurance fee from Stylus contract
        uint256 insuranceFee = insuranceCalculator.calculateInsuranceFee(
            PoolId.unwrap(poolId),
            amount,
            params.zeroForOne ? poolData.totalLiquidityToken0 : poolData.totalLiquidityToken1,
            totalVolume,
            currentPrice,
            block.timestamp
        );

        if (params.zeroForOne) {
            poolData.insuranceFees0 += insuranceFee;
            allocateFeesToPool(poolId, poolData.token0, insuranceFee);
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(int128(int256(insuranceFee)), 0), 0);
        } else {
            poolData.insuranceFees1 += insuranceFee;
            allocateFeesToPool(poolId, poolData.token1, insuranceFee);
            return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(0, int128(int256(insuranceFee))), 0);
        }
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta deltaIn,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        // Convert negative deltas to positive amounts
        uint256 amount0 = delta.amount0() >= 0 ? uint256(int256(delta.amount0())) : uint256(-int256(delta.amount0()));
        uint256 amount1 = delta.amount1() >= 0 ? uint256(int256(delta.amount1())) : uint256(-int256(delta.amount1()));

        // Use msg.sender as the LP address since it's the PositionManager
        updateLPLiquidity(key.toId(), sender, amount0, amount1, true);

        return (BaseHook.afterAddLiquidity.selector, deltaIn);
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta deltaIn,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        // Convert negative deltas to positive amounts for removal
        uint256 amount0 = delta.amount0() >= 0 ? uint256(int256(delta.amount0())) : uint256(-int256(delta.amount0()));
        uint256 amount1 = delta.amount1() >= 0 ? uint256(int256(delta.amount1())) : uint256(-int256(delta.amount1()));

        // Use msg.sender as the LP address since it's the PositionManager
        updateLPLiquidity(key.toId(), sender, amount0, amount1, false);

        return (BaseHook.afterRemoveLiquidity.selector, deltaIn);
    }

    // Helper functions from InsurancePoolManager
    function updateLPLiquidity(PoolId poolId, address lp, uint256 amountToken0, uint256 amountToken1, bool isAdding)
        internal
    {
        PoolData storage poolData = poolDataMap[poolId];

        if (isAdding) {
            poolData.lpLiquidityToken0[lp] += amountToken0;
            poolData.lpLiquidityToken1[lp] += amountToken1;
            poolData.totalLiquidityToken0 += amountToken0;
            poolData.totalLiquidityToken1 += amountToken1;
        } else {
            // Check if the LP has sufficient liquidity
            require(
                poolData.lpLiquidityToken0[lp] >= amountToken0 && poolData.lpLiquidityToken1[lp] >= amountToken1,
                "Insufficient LP liquidity"
            );
            poolData.lpLiquidityToken0[lp] -= amountToken0;
            poolData.lpLiquidityToken1[lp] -= amountToken1;
            poolData.totalLiquidityToken0 -= amountToken0;
            poolData.totalLiquidityToken1 -= amountToken1;
        }
    }

    function allocateFeesToPool(PoolId poolId, address feeToken, uint256 feeAmount) internal {
        PoolData storage poolData = poolDataMap[poolId];
        TokenData storage tokenDataRef = tokenData[feeToken];
        address poolAddress = address(uint160(bytes20(abi.encodePacked(poolId))));

        if (feeToken == poolData.token0) {
            poolData.totalContributionsToken0 += feeAmount;
        } else if (feeToken == poolData.token1) {
            poolData.totalContributionsToken1 += feeAmount;
        } else {
            revert("Invalid token");
        }

        tokenDataRef.totalFunds += feeAmount;
        tokenDataRef.poolContributions[poolAddress] += feeAmount;
    }

    function claimInsuranceFees(PoolKey calldata key) external {
        PoolId poolId = key.toId();
        PoolData storage poolData = poolDataMap[poolId];

        uint256 fees0 = poolData.insuranceFees0;
        uint256 fees1 = poolData.insuranceFees1;

        require(fees0 > 0 || fees1 > 0, "No fees to claim");

        poolData.insuranceFees0 = 0;
        poolData.insuranceFees1 = 0;

        TokenData storage token0Data = tokenData[poolData.token0];
        TokenData storage token1Data = tokenData[poolData.token1];

        if (fees0 > 0) {
            token0Data.totalFunds -= fees0;
            require(IERC20(poolData.token0).transfer(msg.sender, fees0), "Token0 transfer failed");
        }
        if (fees1 > 0) {
            token1Data.totalFunds -= fees1;
            require(IERC20(poolData.token1).transfer(msg.sender, fees1), "Token1 transfer failed");
        }
    }

    function calculateLPCompensation(PoolId poolId, address lp, address token, uint256 priceOld, uint256 priceNew)
        public
        view
        returns (uint256)
    {
        PoolData storage poolData = poolDataMap[poolId];

        uint256 lpLiquidity = token == poolData.token0 ? poolData.lpLiquidityToken0[lp] : poolData.lpLiquidityToken1[lp];
        uint256 totalLiquidity =
            token == poolData.token0 ? poolData.totalLiquidityToken0 : poolData.totalLiquidityToken1;

        uint256 lpShare = totalLiquidity > 0 ? (lpLiquidity * 1e18) / totalLiquidity : 0;

        uint256 insuranceFund = token == poolData.token0 ? poolData.insuranceFees0 : poolData.insuranceFees1;

        // Calculate time in pool (simplified - you might want to track entry time)
        uint256 timeInPool = 86400; // 1 day for example

        return insuranceCalculator.calculateIlCompensation(
            lpShare, insuranceFund, priceOld, priceNew, timeInPool, totalLiquidity
        );
    }

    // Flash loan related functions
    function transferFunds(address token, address to, uint256 amount) external onlyFlashLoanContract returns (bool) {
        TokenData storage tokenDataRef = tokenData[token];
        require(tokenDataRef.totalFunds >= amount, "Insufficient funds in the insurance pool");

        tokenDataRef.totalFunds -= amount;
        require(IERC20(token).transfer(to, amount), "Token transfer failed");
        return true;
    }

    function handleRepayment(address token, uint256 amount, uint256 loanFee) external onlyFlashLoanContract {
        TokenData storage tokenDataRef = tokenData[token];

        // Calculate utilization rate
        uint256 utilizationRate = tokenDataRef.totalFunds > 0 ? (amount * 1e18) / tokenDataRef.totalFunds : 0;

        // Calculate default history (simplified - you might want to track this)
        uint256 defaultHistory = 0;

        // Get flash loan fee from Stylus contract
        uint256 calculatedFee =
            insuranceCalculator.calculateFlashLoanFee(amount, tokenDataRef.totalFunds, utilizationRate, defaultHistory);

        require(loanFee >= calculatedFee, "Fee too low");

        tokenDataRef.totalFunds += amount;
        distributeFlashLoanFees(token, loanFee);
    }

    function distributeFlashLoanFees(address token, uint256 feeAmount) internal {
        TokenData storage tokenDataRef = tokenData[token];
        require(tokenDataRef.totalFunds > 0, "No token funds to distribute");

        for (uint256 i = 0; i < poolList.length; i++) {
            address pool = poolList[i];
            uint256 poolShare = tokenDataRef.poolContributions[pool];
            if (poolShare == 0) continue;

            uint256 distributedFee = (feeAmount * poolShare) / tokenDataRef.totalFunds;
            tokenDataRef.poolContributions[pool] += distributedFee;
        }
    }

    // View functions for flash loan contract
    function isTokenSupported(address token) external view returns (bool) {
        return tokenData[token].totalFunds > 0;
    }

    function getAvailableLiquidity(address token) external view returns (uint256) {
        return tokenData[token].totalFunds;
    }

    // Add helper function to get volatility if needed
    function getVolatility(PoolId poolId) internal returns (uint256) {
        PoolData storage poolData = poolDataMap[poolId];
        uint256 currentPrice = poolData.totalLiquidityToken1 > 0
            ? (poolData.totalLiquidityToken0 * 1e18) / poolData.totalLiquidityToken1
            : 0;

        return insuranceCalculator.calculateVolatility(PoolId.unwrap(poolId), currentPrice, block.timestamp);
    }
}
