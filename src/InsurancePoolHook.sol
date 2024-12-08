// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Slot0} from "@uniswap/v4-core/src/types/Slot0.sol";
import {IInsuranceCalculator} from "./interfaces/IInsuranceCalculator.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

contract InsurancePoolHook is BaseHook, IERC3156FlashLender, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using FixedPointMathLib for uint256;
    using StateLibrary for IPoolManager;

    IInsuranceCalculator public immutable insuranceCalculator;
    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    uint256 private constant Q96 = 1 << 96;

    // Custom errors
    error UnsupportedToken(address token);
    error CallbackFailed(address borrower);
    error InvalidAmount();
    error NoFeesToClaim();
    error InsufficientLiquidity();
    error NotImplemented();

    event InsuranceFeesCollected(address indexed token, uint256 swapAmount, uint256 fee);
    event InsuranceFeeClaimed(address indexed user, address indexed token, uint256 amount);
    event FlashLoanExecuted(address indexed borrower, address indexed token, uint256 amount, uint256 fee);

    struct PoolData {
        address token0;
        address token1;
        uint256 totalContributionsToken0;
        uint256 totalContributionsToken1;
        uint256 feeGrowthGlobal0;
        uint256 feeGrowthGlobal1;
    }

    struct TokenData {
        uint256 totalFunds;
        mapping(PoolId => uint256) poolContributions;
    }

    struct PositionData {
        uint256 feeGrowthInsideLast0;
        uint256 feeGrowthInsideLast1;
    }

    mapping(PoolId => PoolData) public poolDataMap;
    mapping(address => TokenData) public tokenDataMap;
    PoolId[] public poolList;
    mapping(bytes32 => PositionData) public positionDataMap;

    constructor(IPoolManager _poolManager, address _calculator) BaseHook(_poolManager) {
        require(_calculator != address(0), "Invalid calculator");
        insuranceCalculator = IInsuranceCalculator(_calculator);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24) external override returns (bytes4) {
        PoolId poolId = key.toId();
        poolList.push(poolId);
        PoolData storage poolData = poolDataMap[poolId];
        poolData.token0 = Currency.unwrap(key.currency0);
        poolData.token1 = Currency.unwrap(key.currency1);

        return BaseHook.afterInitialize.selector;
    }

    function beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4) {
        address user = abi.decode(hookData, (address));
        PoolId poolId = key.toId();
        PoolData storage pData = poolDataMap[poolId];

        if (params.liquidityDelta > 0) {
            bytes32 posKey = _positionKey(poolId, user, params);
            PositionData storage pos = positionDataMap[posKey];
            pos.feeGrowthInsideLast0 = pData.feeGrowthGlobal0;
            pos.feeGrowthInsideLast1 = pData.feeGrowthGlobal1;
        }
        return BaseHook.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override returns (bytes4) {
        address liquidityProvider = abi.decode(hookData, (address));
        if (params.liquidityDelta >= 0) return BaseHook.beforeRemoveLiquidity.selector;

        PoolId poolId = key.toId();
        PoolData storage poolData = poolDataMap[poolId];

        (uint128 userLiquidity,,) =
            poolManager.getPositionInfo(poolId, liquidityProvider, params.tickLower, params.tickUpper, params.salt);
        if (userLiquidity == 0) return BaseHook.beforeRemoveLiquidity.selector;

        uint128 liquidityToRemove = uint128(uint256(-params.liquidityDelta));
        if (liquidityToRemove > userLiquidity) {
            liquidityToRemove = userLiquidity;
        }

        bytes32 posKey = _positionKey(poolId, liquidityProvider, params);
        PositionData storage pos = positionDataMap[posKey];

        uint256 feeGrowthGlobal0 = poolData.feeGrowthGlobal0;
        uint256 feeGrowthGlobal1 = poolData.feeGrowthGlobal1;

        uint256 owed0 = ((feeGrowthGlobal0 - pos.feeGrowthInsideLast0) * liquidityToRemove) / Q96;
        uint256 owed1 = ((feeGrowthGlobal1 - pos.feeGrowthInsideLast1) * liquidityToRemove) / Q96;

        if (owed0 == 0 && owed1 == 0) {
            return BaseHook.beforeRemoveLiquidity.selector;
        }

        if (owed0 > 0) {
            TokenData storage tData0 = tokenDataMap[poolData.token0];
            if (tData0.totalFunds < owed0) revert InsufficientLiquidity();
            tData0.totalFunds -= owed0;
            poolData.totalContributionsToken0 =
                (poolData.totalContributionsToken0 > owed0) ? poolData.totalContributionsToken0 - owed0 : 0;

            Currency c0 = Currency.wrap(poolData.token0);
            c0.settle(poolManager, liquidityProvider, owed0, false);
            emit InsuranceFeeClaimed(liquidityProvider, poolData.token0, owed0);
        }

        if (owed1 > 0) {
            TokenData storage tData1 = tokenDataMap[poolData.token1];
            if (tData1.totalFunds < owed1) revert InsufficientLiquidity();
            tData1.totalFunds -= owed1;
            poolData.totalContributionsToken1 =
                (poolData.totalContributionsToken1 > owed1) ? poolData.totalContributionsToken1 - owed1 : 0;

            Currency c1 = Currency.wrap(poolData.token1);
            c1.settle(poolManager, liquidityProvider, owed1, false);
            emit InsuranceFeeClaimed(liquidityProvider, poolData.token1, owed1);
        }

        uint128 newLiquidity = userLiquidity - liquidityToRemove;
        if (newLiquidity > 0) {
            pos.feeGrowthInsideLast0 = feeGrowthGlobal0;
            pos.feeGrowthInsideLast1 = feeGrowthGlobal1;
        } else {
            delete positionDataMap[posKey];
        }

        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (params.amountSpecified == 0) revert InvalidAmount();

        PoolId poolId = key.toId();
        PoolData storage poolData = poolDataMap[poolId];

        uint256 amount = params.zeroForOne ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 totalLiquidity = poolManager.getLiquidity(poolId);
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint256 currentPrice = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18 >> (96 * 2);

        uint256 insuranceFee = insuranceCalculator.calculateInsuranceFee(
            PoolId.unwrap(poolId),
            amount,
            params.zeroForOne ? poolData.totalContributionsToken0 : poolData.totalContributionsToken1,
            totalLiquidity,
            currentPrice,
            block.timestamp
        );

        if (insuranceFee > 0) {
            Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
            inputCurrency.take(poolManager, address(this), insuranceFee, true);

            _updateInsuranceFees(poolData, params.zeroForOne, poolId, insuranceFee);

            if (totalLiquidity > 0) {
                if (params.zeroForOne) {
                    poolData.feeGrowthGlobal0 += (insuranceFee * Q96) / totalLiquidity;
                } else {
                    poolData.feeGrowthGlobal1 += (insuranceFee * Q96) / totalLiquidity;
                }
            }

            emit InsuranceFeesCollected(params.zeroForOne ? poolData.token0 : poolData.token1, amount, insuranceFee);
        }

        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(int128(int256(insuranceFee)), 0), 0);
    }

    function _updateInsuranceFees(PoolData storage poolData, bool zeroForOne, PoolId poolId, uint256 fee) internal {
        address token = zeroForOne ? poolData.token0 : poolData.token1;
        TokenData storage tData = tokenDataMap[token];

        if (zeroForOne) {
            poolData.totalContributionsToken0 += fee;
            tData.poolContributions[poolId] += fee;
        } else {
            poolData.totalContributionsToken1 += fee;
            tData.poolContributions[poolId] += fee;
        }
        tData.totalFunds += fee;
    }

    // Flash loan logic
    function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata data)
        external
        override
        nonReentrant
        returns (bool)
    {
        TokenData storage tokenDataRef = tokenDataMap[token];
        if (tokenDataRef.totalFunds < amount) revert InsufficientLiquidity();

        uint256 fee = flashFee(token, amount);

        FlashLoanCallback memory callback =
            FlashLoanCallback({receiver: receiver, token: token, amount: amount, fee: fee, data: data});

        tokenDataRef.totalFunds -= amount;
        poolManager.unlock(abi.encode(callback));
        // After loan is returned, totalFunds get updated in _unlockCallback when repayment happens

        return true;
    }

    struct FlashLoanCallback {
        IERC3156FlashBorrower receiver;
        address token;
        uint256 amount;
        uint256 fee;
        bytes data;
    }

    function _unlockCallback(bytes calldata data) internal override returns (bytes memory) {
        FlashLoanCallback memory callback = abi.decode(data, (FlashLoanCallback));
        Currency tokenCurrency = Currency.wrap(callback.token);

        tokenCurrency.settle(poolManager, address(this), callback.amount, true);
        tokenCurrency.take(poolManager, address(callback.receiver), callback.amount, false);

        bytes32 callbackResult =
            callback.receiver.onFlashLoan(msg.sender, callback.token, callback.amount, callback.fee, callback.data);
        if (callbackResult != CALLBACK_SUCCESS) revert CallbackFailed(address(callback.receiver));

        uint256 repayment = callback.amount + callback.fee;
        tokenCurrency.settle(poolManager, address(callback.receiver), repayment, false);
        tokenCurrency.take(poolManager, address(this), repayment, true);

        uint256 feeAmount = callback.fee;
        tokenDataMap[callback.token].totalFunds += repayment;
        distributeFlashLoanFees(callback.token, feeAmount);

        emit FlashLoanExecuted(address(callback.receiver), callback.token, callback.amount, callback.fee);
        return "";
    }

    function distributeFlashLoanFees(address token, uint256 feeAmount) internal {
        TokenData storage tokenData = tokenDataMap[token];

        for (uint256 i = 0; i < poolList.length; i++) {
            PoolId pid = poolList[i];
            uint256 poolContribution = tokenData.poolContributions[pid];
            if (poolContribution == 0) continue;

            uint256 distributedFee = (feeAmount * poolContribution) / tokenData.totalFunds;
            if (distributedFee == 0) continue;

            PoolData storage pData = poolDataMap[pid];

            if (token == pData.token0) {
                pData.totalContributionsToken0 += distributedFee;
            } else if (token == pData.token1) {
                pData.totalContributionsToken1 += distributedFee;
            }

            uint256 totalLiquidity = poolManager.getLiquidity(pid);
            if (totalLiquidity > 0) {
                if (token == pData.token0) {
                    pData.feeGrowthGlobal0 += (distributedFee * Q96) / totalLiquidity;
                } else {
                    pData.feeGrowthGlobal1 += (distributedFee * Q96) / totalLiquidity;
                }
            }
        }
    }

    function flashFee(address token, uint256 amount) public view override returns (uint256) {
        TokenData storage tokenDataRef = tokenDataMap[token];
        if (tokenDataRef.totalFunds == 0) revert UnsupportedToken(token);

        uint256 utilizationRate = (amount * 1e18) / tokenDataRef.totalFunds;
        return insuranceCalculator.calculateFlashLoanFee(amount, tokenDataRef.totalFunds, utilizationRate, 0);
    }

    function maxFlashLoan(address token) external view override returns (uint256) {
        return tokenDataMap[token].totalFunds;
    }

    function _positionKey(PoolId pid, address owner, IPoolManager.ModifyLiquidityParams calldata params)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(abi.encode(pid, owner, params.tickLower, params.tickUpper, params.salt));
    }
}
