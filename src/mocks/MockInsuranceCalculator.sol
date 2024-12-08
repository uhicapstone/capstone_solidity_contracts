// SPDX-License-Identifier: MIT-OR-APACHE-2.0
pragma solidity ^0.8.23;

import {IInsuranceCalculator} from "../interfaces/IInsuranceCalculator.sol";

contract MockInsuranceCalculator is IInsuranceCalculator {
    function calculateInsuranceFee(
        bytes32 pool_id,
        uint256 amount,
        uint256 total_liquidity,
        uint256 total_volume,
        uint256 current_price,
        uint256 timestamp
    ) external pure returns (uint256) {
        // Silence unused parameter warnings
        pool_id;
        total_liquidity;
        total_volume;
        current_price;
        timestamp;

        // Simple 1% fee for testing
        return amount / 100;
    }

    function calculateFlashLoanFee(
        uint256 amount,
        uint256 total_liquidity,
        uint256 utilization_rate,
        uint256 default_history
    ) external pure returns (uint256) {
        // Silence unused parameter warnings
        total_liquidity;
        utilization_rate;
        default_history;

        // Simple 0.1% fee for testing
        return amount / 1000;
    }
}
