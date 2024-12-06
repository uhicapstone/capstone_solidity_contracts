// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IInsuranceCalculator} from "../../src/interfaces/IInsuranceCalculator.sol";

contract MockInsuranceCalculator is IInsuranceCalculator {
    function calculateInsuranceFee(bytes32, uint256 amount, uint256, uint256, uint256, uint256)
        external
        pure
        returns (uint256)
    {
        return amount / 100;
    }

    function calculateVolatility(bytes32, uint256, uint256) external pure returns (uint256) {
        // Return fixed volatility for testing
        return 100;
    }

    function calculateFlashLoanFee(uint256 amount, uint256, uint256, uint256) external pure returns (uint256) {
        // Return 0.1% fee for testing
        return amount / 1000;
    }
}
