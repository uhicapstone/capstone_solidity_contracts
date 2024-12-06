// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IInsuranceCalculator {
    function calculateInsuranceFee(
        bytes32 pool_id,
        uint256 amount,
        uint256 total_liquidity,
        uint256 total_volume,
        uint256 current_price,
        uint256 timestamp
    ) external returns (uint256);

    function calculateVolatility(bytes32 pool_id, uint256 current_price, uint256 timestamp)
        external
        returns (uint256);

    function calculateFlashLoanFee(
        uint256 amount,
        uint256 total_liquidity,
        uint256 utilization_rate,
        uint256 default_history
    ) external view returns (uint256);

    error CalculationError();

    error InvalidInput();
}
