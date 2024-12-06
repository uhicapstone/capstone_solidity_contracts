// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
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
    using FixedPointMathLib for uint256;
    using StateLibrary for IPoolManager;

    // Immutable state variables
    IInsuranceCalculator public insuranceCalculator;
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
        mapping(address => uint256) lpLiquidityToken0;
        mapping(address => uint256) lpLiquidityToken1;
        uint256 totalLiquidityToken0;
        uint256 totalLiquidityToken1;
        uint256 insuranceFees0;
        uint256 insuranceFees1;
    }

    struct TokenData {
        uint256 totalFunds;
        mapping(address => uint256) poolContributions;
    }

    // State variables
    mapping(PoolId => PoolData) public poolDataMap;
    mapping(address => TokenData) public tokenData;
    address[] public poolList;

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function setCalculator(address _calculator) external {
        if (_calculator == address(0)) revert Unauthorized();
        if (address(insuranceCalculator) != address(0)) revert Unauthorized();
        insuranceCalculator = IInsuranceCalculator(_calculator);
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
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24) external override returns (bytes4) {
        PoolId poolId = key.toId();
        poolList.push(address(uint160(bytes20(abi.encodePacked(poolId)))));

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

        PoolId poolId = key.toId();
        PoolData storage poolData = poolDataMap[poolId];

        uint256 amount = params.zeroForOne ? uint256(-params.amountSpecified) : uint256(-params.amountSpecified);
        uint256 totalVolume = poolData.totalContributionsToken0 + poolData.totalContributionsToken1;

        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint256 currentPrice = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18 >> (96 * 2);

        // Calculate insurance fee
        uint256 insuranceFee = insuranceCalculator.calculateInsuranceFee(
            PoolId.unwrap(poolId),
            amount,
            params.zeroForOne ? poolData.totalLiquidityToken0 : poolData.totalLiquidityToken1,
            totalVolume,
            currentPrice,
            block.timestamp
        );

        // Get input currency
        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;

        // Take tokens from user and mint claim tokens for the hook
        // The hook will receive claim tokens representing the insurance fee
        _mintClaimTokens(inputCurrency, insuranceFee);

        // Update insurance fee tracking
        _updateInsuranceFees(poolData, params.zeroForOne, amount, insuranceFee);

        emit InsuranceFeesCollected(
            params.zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1), amount, insuranceFee
        );

        // Return BeforeSwapDelta to charge the insurance fee
        return (
            BaseHook.beforeSwap.selector,
            toBeforeSwapDelta(int128(int256(insuranceFee)), 0),
            0 // No LP fee override
        );
    }

    function _updateInsuranceFees(PoolData storage poolData, bool zeroForOne, uint256 amount, uint256 fee) internal {
        if (zeroForOne) {
            poolData.totalContributionsToken0 += amount;
            poolData.insuranceFees0 += fee;
        } else {
            poolData.totalContributionsToken1 += amount;
            poolData.insuranceFees1 += fee;
        }
    }

    function claimInsuranceFees(PoolKey calldata key) external nonReentrant {
        PoolId poolId = key.toId();
        PoolData storage poolData = poolDataMap[poolId];

        (uint256 fees0, uint256 fees1) = _calculateClaimableFees(poolData, msg.sender);
        if (fees0 == 0 && fees1 == 0) revert NoFeesToClaim();

        _processFeeClaim(poolData, fees0, fees1);

        emit InsuranceFeeClaimed(msg.sender, poolData.token0, fees0);
        emit InsuranceFeeClaimed(msg.sender, poolData.token1, fees1);
    }

    function _calculateClaimableFees(PoolData storage poolData, address user)
        internal
        view
        returns (uint256 fees0, uint256 fees1)
    {
        if (poolData.totalLiquidityToken0 > 0) {
            fees0 = (poolData.insuranceFees0 * poolData.lpLiquidityToken0[user]) / poolData.totalLiquidityToken0;
        }
        if (poolData.totalLiquidityToken1 > 0) {
            fees1 = (poolData.insuranceFees1 * poolData.lpLiquidityToken1[user]) / poolData.totalLiquidityToken1;
        }
    }

    function _processFeeClaim(PoolData storage poolData, uint256 fees0, uint256 fees1) internal {
        if (fees0 > 0) {
            poolData.insuranceFees0 -= fees0;
            if (!IERC20(poolData.token0).transfer(msg.sender, fees0)) revert TransferFailed();
        }
        if (fees1 > 0) {
            poolData.insuranceFees1 -= fees1;
            if (!IERC20(poolData.token1).transfer(msg.sender, fees1)) revert TransferFailed();
        }
    }

    function _mintClaimTokens(Currency currency, uint256 amount) internal {
        // Mint claim tokens to the hook contract
        poolManager.mint(address(this), currency.toId(), amount);
    }

    function _burnClaimTokens(Currency currency, uint256 amount) internal {
        // Burn claim tokens from the hook contract
        poolManager.burn(address(this), currency.toId(), amount);
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        // Get positive deltas only
        uint256 amount0 = delta.amount0() > 0 ? uint256(uint128(delta.amount0())) : 0;
        uint256 amount1 = delta.amount1() > 0 ? uint256(uint128(delta.amount1())) : 0;

        PoolId poolId = key.toId();
        PoolData storage poolData = poolDataMap[poolId];

        // Update pool data - just track liquidity positions
        if (amount0 > 0) {
            poolData.lpLiquidityToken0[sender] += amount0;
            poolData.totalLiquidityToken0 += amount0;
        }
        if (amount1 > 0) {
            poolData.lpLiquidityToken1[sender] += amount1;
            poolData.totalLiquidityToken1 += amount1;
        }

        emit LiquidityUpdated(sender, Currency.unwrap(key.currency0), amount0, true);
        emit LiquidityUpdated(sender, Currency.unwrap(key.currency1), amount1, true);

        return (BaseHook.afterAddLiquidity.selector, BalanceDelta.wrap(0));
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata
    ) external override returns (bytes4, BalanceDelta) {
        // Get negative deltas only (convert to positive amounts)
        uint256 amount0 = delta.amount0() < 0 ? uint256(uint128(-delta.amount0())) : 0;
        uint256 amount1 = delta.amount1() < 0 ? uint256(uint128(-delta.amount1())) : 0;

        PoolId poolId = key.toId();
        PoolData storage poolData = poolDataMap[poolId];

        // Update pool data - just track liquidity positions
        if (amount0 > 0) {
            poolData.lpLiquidityToken0[sender] -= amount0;
            poolData.totalLiquidityToken0 -= amount0;
        }
        if (amount1 > 0) {
            poolData.lpLiquidityToken1[sender] -= amount1;
            poolData.totalLiquidityToken1 -= amount1;
        }

        emit LiquidityUpdated(sender, Currency.unwrap(key.currency0), amount0, false);
        emit LiquidityUpdated(sender, Currency.unwrap(key.currency1), amount1, false);

        return (BaseHook.afterRemoveLiquidity.selector, BalanceDelta.wrap(0));
    }

    function getVolatility(PoolId poolId) internal returns (uint256) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        uint256 currentPrice = uint256(sqrtPriceX96) * uint256(sqrtPriceX96) * 1e18 >> (96 * 2);

        return insuranceCalculator.calculateVolatility(PoolId.unwrap(poolId), currentPrice, block.timestamp);
    }

    function getClaimableInsuranceFees(PoolKey calldata key, address lp)
        external
        view
        returns (uint256 fees0, uint256 fees1)
    {
        PoolId poolId = key.toId();
        PoolData storage poolData = poolDataMap[poolId];

        if (poolData.totalLiquidityToken0 > 0) {
            fees0 = (poolData.insuranceFees0 * poolData.lpLiquidityToken0[lp]) / poolData.totalLiquidityToken0;
        }
        if (poolData.totalLiquidityToken1 > 0) {
            fees1 = (poolData.insuranceFees1 * poolData.lpLiquidityToken1[lp]) / poolData.totalLiquidityToken1;
        }

        return (fees0, fees1);
    }

    function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata data)
        external
        override
        nonReentrant
        returns (bool)
    {
        Currency currency = Currency.wrap(token);
        uint256 claimBalance = poolManager.balanceOf(address(this), currency.toId());

        if (claimBalance < amount) {
            revert InsufficientLiquidity(amount, claimBalance);
        }

        uint256 fee = this.flashFee(token, amount);
        uint256 repayment = amount + fee;

        // Burn claim tokens to allow withdrawal
        _burnClaimTokens(currency, amount);

        // Transfer tokens to receiver through PoolManager
        poolManager.take(currency, address(receiver), amount);

        // Callback to receiver
        if (receiver.onFlashLoan(msg.sender, token, amount, fee, data) != CALLBACK_SUCCESS) {
            revert CallbackFailed(address(receiver));
        }

        // Pull repayment with fee
        if (!IERC20(token).transferFrom(address(receiver), address(this), repayment)) {
            revert RepaymentFailed(token, address(receiver), repayment);
        }

        // Send repayment to PoolManager and mint new claim tokens
        IERC20(token).approve(address(poolManager), repayment);
        poolManager.mint(address(this), currency.toId(), repayment);

        emit FlashLoanExecuted(address(receiver), token, amount, fee);
        return true;
    }

    function flashFee(address token, uint256 amount) external view override returns (uint256) {
        TokenData storage tokenDataRef = tokenData[token];
        if (tokenDataRef.totalFunds == 0) revert UnsupportedToken(token);

        uint256 utilizationRate = tokenDataRef.totalFunds > 0 ? (amount * 1e18) / tokenDataRef.totalFunds : 0;

        return insuranceCalculator.calculateFlashLoanFee(amount, tokenDataRef.totalFunds, utilizationRate, 0);
    }

    function maxFlashLoan(address token) external view override returns (uint256) {
        Currency currency = Currency.wrap(token);
        return poolManager.balanceOf(address(this), currency.toId());
    }
}
