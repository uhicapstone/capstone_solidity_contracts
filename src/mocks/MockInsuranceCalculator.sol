// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IInsuranceCalculator} from "../interfaces/IInsuranceCalculator.sol";

contract MockInsuranceCalculator is IInsuranceCalculator {
    // Mock implementation that returns 1% fee for insurance
    function calculateInsuranceFee(bytes32, uint256 amount, uint256, uint256, uint256, uint256)
        external
        returns (uint256)
    {
        // Simple 1% fee for testing
        return amount / 100;
    }

    // Mock implementation for volatility calculation
    function calculateVolatility(bytes32, uint256, uint256) external returns (uint256) {
        // Return a mock 5% volatility
        return 5e16; // 5% represented as 5 * 10^16 for 18 decimal precision
    }

    // Mock implementation for flash loan fees
    function calculateFlashLoanFee(uint256 amount, uint256, uint256, uint256) external pure returns (uint256) {
        // Simple 0.1% fee for testing
        return amount / 1000;
    }
}
