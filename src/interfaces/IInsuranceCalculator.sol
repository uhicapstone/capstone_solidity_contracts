// SPDX-License-Identifier: MIT-OR-APACHE-2.0
pragma solidity ^0.8.23;

interface IInsuranceCalculator {
    function calculateInsuranceFee(
        bytes32 pool_id,
        uint256 amount,
        uint256 total_liquidity,
        uint256 total_volume,
        uint256 current_price,
        uint256 timestamp
    ) external view returns (uint256);

    function calculateFlashLoanFee(
        uint256 amount,
        uint256 total_liquidity,
        uint256 utilization_rate,
        uint256 default_history
    ) external view returns (uint256);

    error CalculationError();

    error InvalidInput();
}
