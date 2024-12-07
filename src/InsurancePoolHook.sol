// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {CurrencySettler} from "v4-core/test/utils/CurrencySettler.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {FixedPointMathLib} from "lib/v4-core/lib/solmate/src/utils/FixedPointMathLib.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Slot0} from "v4-core/src/types/Slot0.sol";
import {IInsuranceCalculator} from "./interfaces/IInsuranceCalculator.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title InsurancePoolHook
 * @notice A Uniswap V4 hook that provides insurance and flash loan capabilities
 * @dev Implements insurance fee collection and flash loan functionality
 */
contract InsurancePoolHook is BaseHook, IERC3156FlashLender, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    using FixedPointMathLib for uint256;
    using StateLibrary for IPoolManager;

    // Immutable state variables
    IInsuranceCalculator public immutable insuranceCalculator;
    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");

    // Custom errors
    error UnsupportedToken(address token);
    error CallbackFailed(address borrower);
    error RepaymentFailed(address token, address from, uint256 amount);
    error InsufficientLiquidity(uint256 requested, uint256 available);
    error InvalidAmount();
    error NoFeesToClaim();
    error TransferFailed();
    error Unauthorized();

    // Events
    event InsuranceFeesCollected(address indexed token, uint256 amount, uint256 fee);
    event InsuranceFeeClaimed(address indexed user, address indexed token, uint256 amount);
    event FlashLoanExecuted(address indexed borrower, address indexed token, uint256 amount, uint256 fee);
    event LiquidityUpdated(address indexed user, address indexed token, uint256 amount, bool isAdd);

    struct PoolData {
        address token0;
        address token1;
        uint256 totalContributionsToken0;
        uint256 totalContributionsToken1;
    }

    struct TokenData {
        uint256 totalFunds;
        mapping(PoolId => uint256) poolContributions;
    }

    // State variables
    mapping(PoolId => PoolData) public poolDataMap;
    mapping(address => TokenData) public tokenDataMap;
    PoolId[] public poolList;

    constructor(IPoolManager _poolManager, address _calculator) BaseHook(_poolManager) {
        if (_calculator == address(0)) revert Unauthorized();
        insuranceCalculator = IInsuranceCalculator(_calculator);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
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
        if (params.amountSpecified == 0) revert InvalidAmount();

        // Get PoolId from PoolKey
        PoolId poolId = key.toId();
        PoolData storage poolData = poolDataMap[poolId];

        uint256 amount = params.zeroForOne ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);

        // Retrieve total liquidity using `getLiquidity` from PoolManager(statelibrary)
        uint256 totalLiquidity = poolManager.getLiquidity(poolId);

        // Fetch the current price from poolmanager
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint256 currentPrice = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18 >> (96 * 2);

        // Calculate insurance fee
        uint256 insuranceFee = insuranceCalculator.calculateInsuranceFee(
            PoolId.unwrap(poolId),
            amount,
            params.zeroForOne ? poolData.totalContributionsToken0 : poolData.totalContributionsToken1,
            totalLiquidity,
            currentPrice,
            block.timestamp
        );

        // Determine input currency
        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;

        // Take insurance fees from user and give claim tokens to hook
        inputCurrency.take(poolManager, address(this), insuranceFee, true);

        // Update insurance fees and pool data
        _updateInsuranceFees(poolData, params.zeroForOne, poolId, insuranceFee);

        // Emit insurance fee collection event
        emit InsuranceFeesCollected(
            params.zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1), amount, insuranceFee
        );

        // Return the required hook response
        return (BaseHook.beforeSwap.selector, toBeforeSwapDelta(int128(int256(insuranceFee)), 0), 0);
    }

    function _updateInsuranceFees(PoolData storage poolData, bool zeroForOne, PoolId poolId, uint256 fee) internal {
        // First update the pool-specific contributions
        if (zeroForOne) {
            poolData.totalContributionsToken0 += fee;
            tokenDataMap[poolData.token0].poolContributions[poolId] += fee;
            // Update total funds after pool contributions
            tokenDataMap[poolData.token0].totalFunds += fee;
        } else {
            poolData.totalContributionsToken1 += fee;
            tokenDataMap[poolData.token1].poolContributions[poolId] += fee;
            // Update total funds after pool contributions
            tokenDataMap[poolData.token1].totalFunds += fee;
        }
    }

    function beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external virtual override returns (bytes4) {
        // Get the liquidity provider address from hookData
        address liquidityProvider = abi.decode(hookData, (address));

        // Get the pool ID and data
        PoolId poolId = key.toId();
        PoolData storage poolData = poolDataMap[poolId];

        // Calculate claimable fees
        (uint256 fees0, uint256 fees1) = _calculateClaimableFees(poolData, poolId, params, liquidityProvider);
        if (fees0 == 0 && fees1 == 0) revert NoFeesToClaim();

        // Update accounting before transfers
        if (fees0 > 0) {
            poolData.totalContributionsToken0 -= fees0;
            tokenDataMap[poolData.token0].totalFunds -= fees0;
            tokenDataMap[poolData.token0].poolContributions[poolId] -= fees0;

            // Take tokens from hook and give to user
            key.currency0.settle(poolManager, liquidityProvider, fees0, true);
            emit InsuranceFeeClaimed(liquidityProvider, poolData.token0, fees0);
        }

        if (fees1 > 0) {
            poolData.totalContributionsToken1 -= fees1;
            tokenDataMap[poolData.token1].totalFunds -= fees1;
            tokenDataMap[poolData.token1].poolContributions[poolId] -= fees1;

            key.currency1.settle(poolManager, liquidityProvider, fees1, true);
            emit InsuranceFeeClaimed(liquidityProvider, poolData.token1, fees1);
        }

        return BaseHook.beforeRemoveLiquidity.selector;
    }

    function _calculateClaimableFees(
        PoolData storage poolData,
        PoolId poolId,
        IPoolManager.ModifyLiquidityParams calldata params,
        address liquiditiyProvider
    ) internal view returns (uint256 fees0, uint256 fees1) {
        // Fetch position info for the user
        (uint128 userLiquidity,,) =
            poolManager.getPositionInfo(poolId, liquiditiyProvider, params.tickLower, params.tickUpper, params.salt);

        // Fetch total liquidity from PoolManager
        uint128 totalLiquidity = poolManager.getLiquidity(poolId);

        if (totalLiquidity > 0) {
            // Calculate claimable fees proportionally to user's liquidity
            fees0 = (poolData.totalContributionsToken0 * userLiquidity) / totalLiquidity;
            fees1 = (poolData.totalContributionsToken1 * userLiquidity) / totalLiquidity;
        }
    }

    function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata data)
        external
        override
        nonReentrant
        returns (bool)
    {
        TokenData storage tokenDataRef = tokenDataMap[token];
        if (tokenDataRef.totalFunds < amount) revert InsufficientLiquidity(amount, tokenDataRef.totalFunds);

        uint256 fee = flashFee(token, amount);

        // Create a callback struct for the unlock
        FlashLoanCallback memory callback =
            FlashLoanCallback({receiver: receiver, token: token, amount: amount, fee: fee, data: data});

        // Unlock the pool manager and execute the flash loan
        poolManager.unlock(abi.encode(callback));

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

        TokenData storage tokenDataRef = tokenDataMap[callback.token];
        Currency tokenCurrency = Currency.wrap(callback.token);

        // Update accounting before transfer
        tokenDataRef.totalFunds -= callback.amount;

        // First create a debit for the borrower with the Pool Manager
        tokenCurrency.settle(
            poolManager,
            address(callback.receiver),
            callback.amount,
            false // false = transfer tokens, not burn claim tokens
        );

        // Then take claim tokens for the amount we just debited
        tokenCurrency.take(
            poolManager,
            address(callback.receiver),
            callback.amount,
            true // true = mint claim tokens
        );

        // Execute callback
        bytes32 callbackResult =
            callback.receiver.onFlashLoan(msg.sender, callback.token, callback.amount, callback.fee, callback.data);
        if (callbackResult != CALLBACK_SUCCESS) revert CallbackFailed(address(callback.receiver));

        // Take repayment with fee
        uint256 repayment = callback.amount + callback.fee;

        // Create a debit for us with the Pool Manager using the repayment from borrower
        tokenCurrency.settle(
            poolManager,
            address(this),
            repayment,
            false // false = transfer tokens, not burn claim tokens
        );

        // Take claim tokens for the repayment amount
        tokenCurrency.take(
            poolManager,
            address(this),
            repayment,
            true // true = mint claim tokens
        );

        // Update accounting and distribute fees
        tokenDataRef.totalFunds += repayment;
        distributeFlashLoanFees(callback.token, callback.fee);

        emit FlashLoanExecuted(address(callback.receiver), callback.token, callback.amount, callback.fee);

        return "";
    }

    function distributeFlashLoanFees(address token, uint256 feeAmount) internal {
        TokenData storage tokenData = tokenDataMap[token];
        require(tokenData.totalFunds > 0, "No token funds to distribute");

        uint256 totalDistributed = 0;
        // Distribute fees proportionally to each pool based on their contributions
        for (uint256 i = 0; i < poolList.length; i++) {
            PoolId poolId = poolList[i];
            uint256 poolContribution = tokenData.poolContributions[poolId];
            if (poolContribution == 0) continue;

            // Calculate this pool's share of the fee
            uint256 distributedFee = (feeAmount * poolContribution) / tokenData.totalFunds;
            if (distributedFee == 0) continue;

            totalDistributed += distributedFee;

            // Update pool-specific accounting
            PoolData storage poolData = poolDataMap[poolId];
            if (token == poolData.token0) {
                poolData.totalContributionsToken0 += distributedFee;
                tokenData.poolContributions[poolId] += distributedFee;
            } else if (token == poolData.token1) {
                poolData.totalContributionsToken1 += distributedFee;
                tokenData.poolContributions[poolId] += distributedFee;
            }
        }

        // Update total funds after all distributions
        tokenData.totalFunds += feeAmount;
    }

    function flashFee(address token, uint256 amount) public view override returns (uint256) {
        TokenData storage tokenDataRef = tokenDataMap[token];
        if (tokenDataRef.totalFunds == 0) revert UnsupportedToken(token);

        uint256 utilizationRate = tokenDataRef.totalFunds > 0 ? (amount * 1e18) / tokenDataRef.totalFunds : 0;

        return insuranceCalculator.calculateFlashLoanFee(amount, tokenDataRef.totalFunds, utilizationRate, 0);
    }

    function maxFlashLoan(address token) external view override returns (uint256) {
        return tokenDataMap[token].totalFunds;
    }
}
