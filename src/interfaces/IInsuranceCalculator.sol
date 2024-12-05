// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IInsuranceCalculator {
    function calculateInsuranceFee(
        bytes32 poolId,
        uint256 amount,
        uint256 totalLiquidity,
        uint256 totalVolume,
        uint256 currentPrice,
        uint256 timestamp
    ) external returns (uint256);

    function calculateVolatility(bytes32 poolId, uint256 currentPrice, uint256 timestamp) external returns (uint256);

    function calculateFlashLoanFee(
        uint256 amount,
        uint256 totalLiquidity,
        uint256 utilizationRate,
        uint256 defaultHistory
    ) external pure returns (uint256);

    error CalculationError();

    error InvalidInput();
}
