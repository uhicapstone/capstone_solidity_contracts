// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "./InsurancePoolManager.sol";

contract InsurancePoolHook {
    InsurancePoolManager public insurancePoolManager;

    constructor(address insurancePoolManager_) {
        insurancePoolManager = InsurancePoolManager(insurancePoolManager_);
    }

    function afterInitialize(address poolid, address token0, address token1) external {
        // Initialize the pool data structure in the InsurancePool contract
        insurancePoolManager.initializePoolData(poolid, token0, token1);
    }

    // Hook called after liquidity is added
    function afterAddLiquidity(address poolid, address lp, uint256 amountAddedToken0, uint256 amountAddedToken1)
        external
    {
        // Update LP contributions directly (amounts are exact token contributions)
        insurancePoolManager.updateLPLiquidity(
            poolid,
            lp,
            amountAddedToken0,
            amountAddedToken1,
            true // Adding liquidity
        );
    }

    // Hook called after liquidity is removed
    function afterRemoveLiquidity(address poolid, address lp, uint256 amountRemovedToken0, uint256 amountRemovedToken1)
        external
    {
        // Update LP contributions directly (amounts are exact token removals)
        insurancePoolManager.updateLPLiquidity(
            poolid,
            lp,
            amountRemovedToken0,
            amountRemovedToken1,
            false // Removing liquidity
        );
    }

    // Hook called before a swap occurs
    function beforeSwap(address poolid, address feeToken, uint256 feeAmount) external {
        // Allocate swap fees to the insurance pool
        insurancePoolManager.allocateFeesToPool(poolid, feeToken, feeAmount);
    }
}
