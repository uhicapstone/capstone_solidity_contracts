// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/interfaces/IERC20.sol";

contract InsurancePoolManager {
    address public flashLoanContract;

    modifier onlyFlashLoanContract() {
        require(msg.sender == flashLoanContract, "Caller is not the flash loan contract");
        _;
    }

    struct PoolData {
        address token0; // Address of Token0
        address token1; // Address of Token1
        uint256 totalContributionsToken0; // Fees collected for Token0 (flashfee + swapfee)
        uint256 totalContributionsToken1; // Fees collected for Token1 (flashfee + swapfee)
        mapping(address => uint256) lpLiquidityToken0; // LP-specific liquidity provided in Token0
        mapping(address => uint256) lpLiquidityToken1; // LP-specific liquidity provided in Token1
        uint256 totalLiquidityToken0; // Total liquidity in Token0 excluding fees
        uint256 totalLiquidityToken1; // Total liquidity in Token1 excluding fees
    }

    struct TokenData {
        uint256 totalFunds; // Unified accounting of funds for each token
        mapping(address => uint256) poolContributions; // Contributions from each pool for this token
    }

    mapping(address => PoolData) public pools; // Tracks data for each pool
    mapping(address => TokenData) public tokens; // Tracks data for each token globally

    // Array to store pool addresses for efficient iteration (for distributing flashloanfees across pools)
    address[] public poolList;

    constructor(address _flashLoanContract) {
        flashLoanContract = _flashLoanContract;
    }

    // ** Update LP Liquidity **
    //Gets updated when lp adds or remove liquidity through hook's afterAddLiquidity and afterRemoveLiquidity function
    function updateLPLiquidity(address poolid, address lp, uint256 amountToken0, uint256 amountToken1, bool isAdding)
        external
    {
        PoolData storage poolData = pools[poolid];

        if (isAdding) {
            poolData.lpLiquidityToken0[lp] += amountToken0;
            poolData.lpLiquidityToken1[lp] += amountToken1;
            poolData.totalLiquidityToken0 += amountToken0;
            poolData.totalLiquidityToken1 += amountToken1;
        } else {
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

    // ** Allocate SwapFees to Pool and Tokens through beforeswap function from hook**
    function allocateFeesToPool(address poolid, address feeToken, uint256 feeAmount) external {
        PoolData storage poolData = pools[poolid];
        TokenData storage tokenData = tokens[feeToken];

        // Update pool-specific accounting
        if (feeToken == poolData.token0) {
            poolData.totalContributionsToken0 += feeAmount;
        } else if (feeToken == poolData.token1) {
            poolData.totalContributionsToken1 += feeAmount;
        } else {
            revert("Token does not match token0 or token1 for the pool");
        }

        // Update global token accounting
        tokenData.totalFunds += feeAmount;
        tokenData.poolContributions[poolid] += feeAmount;
    }

    // ** Calculate Compensation for LPs **
    function calculateLPCompensation(
        address poolid,
        address lp,
        address token,
        uint256 priceOld, // Old price ratio (Token0/Token1)
        uint256 priceNew // New price ratio (Token0/Token1)
    ) external view returns (uint256) {
        PoolData storage poolData = pools[poolid];
        uint256 poolTotal =
            (token == poolData.token0) ? poolData.totalContributionsToken0 : poolData.totalContributionsToken1;

        uint256 lpLiquidity =
            (token == poolData.token0) ? poolData.lpLiquidityToken0[lp] : poolData.lpLiquidityToken1[lp];
        uint256 totalLiquidity =
            (token == poolData.token0) ? poolData.totalLiquidityToken0 : poolData.totalLiquidityToken1;

        // Calculate LP's liquidity share
        uint256 liquidityShare = (lpLiquidity * 1e18) / totalLiquidity;

        // Calculate impermanent loss factor (ILF)
        uint256 priceRatioChange = (priceNew * 1e18) / priceOld;
        uint256 ILF = 1e18 - sqrt(priceRatioChange); // 1 - sqrt(new/old)

        // Ensure ILF is positive
        if (ILF > 1e18) ILF = 0;

        // Calculate compensation
        return (liquidityShare * poolTotal * ILF) / 1e36; // Normalize ILF scaling
    }

    // Helper function for square root (approximation)
    function sqrt(uint256 x) internal pure returns (uint256) {
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    // ** Flash Loan Fees Distribution to pools according to their share of liquidity(through swap fees) in insurance pool** after every flash loan repayment
    //significantly better if done offchain
    function distributeFlashLoanFees(address token, uint256 feeAmount) internal {
        TokenData storage tokenData = tokens[token];
        require(tokenData.totalFunds > 0, "No token funds to distribute");

        // Distribute fees proportionally to each pool
        for (uint256 i = 0; i < poolList.length; i++) {
            address pool = poolList[i];
            uint256 poolShare = tokenData.poolContributions[pool];
            uint256 distributedFee = (feeAmount * poolShare) / tokenData.totalFunds;

            // Check if the token corresponds to token0 or token1 for the pool
            PoolData storage poolData = pools[pool];
            if (token == poolData.token0) {
                poolData.totalContributionsToken0 += distributedFee;
            } else if (token == poolData.token1) {
                poolData.totalContributionsToken1 += distributedFee;
            } else {
                continue;
            }
        }
    }
    //transfering funds to borrower for flash loan

    function transferFunds(address token, address to, uint256 amount) external onlyFlashLoanContract returns (bool) {
        // Check if sufficient funds are available in the insurance pool
        TokenData storage tokenData = tokens[token];
        require(tokenData.totalFunds >= amount, "Insufficient funds in the insurance pool");

        // Deduct the amount from the token's total funds
        tokenData.totalFunds -= amount;

        // Transfer the tokens to the recipient
        if (!IERC20(token).transfer(to, amount)) {
            revert("Token transfer failed");
        }

        return true;
    }

    function Repayment(address token, uint256 amount, uint256 loanFee) external onlyFlashLoanContract {
        // Update total funds upon successful repayment
        tokens[token].totalFunds += amount;
        distributeFlashLoanFees(token, loanFee);
    }

    function initializePoolData(address poolid, address token0, address token1) external {
        poolList.push(poolid);
        PoolData storage poolData = pools[poolid];
        poolData.token0 = token0;
        poolData.token1 = token1;
    }

    // Add these missing functions that FlashLender.sol is trying to call
    function isTokenSupported(address token) public view returns (bool) {
        return tokens[token].totalFunds > 0;
    }

    function getAvailableLiquidity(address token) public view returns (uint256) {
        return tokens[token].totalFunds;
    }
}
