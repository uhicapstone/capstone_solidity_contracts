// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC3156FlashBorrower} from "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {IERC3156FlashLender} from "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import {InsurancePoolHook} from "./InsurancePoolHook.sol";
import {IInsuranceCalculator} from "./interfaces/IInsuranceCalculator.sol";

/**
 * @title FlashLender
 * @notice Professional flash loan provider integrated with InsurancePoolHook
 * @dev Implements ERC-3156 Flash Loan standard
 */
contract FlashLender is IERC3156FlashLender {
    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    InsurancePoolHook public immutable insurancePool;
    IInsuranceCalculator public immutable calculator;

    error InvalidToken(address token);
    error InvalidCallback(address borrower);
    error RepaymentFailed(address token, uint256 amount);
    error InsufficientLiquidity(address token, uint256 requested, uint256 available);

    event FlashLoan(
        address indexed borrower, address indexed token, uint256 amount, uint256 fee, address indexed operator
    );

    constructor(address _insurancePool, address _calculator) {
        insurancePool = InsurancePoolHook(_insurancePool);
        calculator = IInsuranceCalculator(_calculator);
    }

    /**
     * @notice Execute a flash loan
     * @param receiver The contract receiving the tokens
     * @param token The loan currency
     * @param amount The amount of tokens lent
     * @param data Arbitrary data structure, intended to contain user-defined parameters
     */
    function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata data)
        external
        override
        returns (bool)
    {
        uint256 fee = flashFee(token, amount);
        uint256 availableLiquidity = maxFlashLoan(token);
        if (availableLiquidity < amount) {
            revert InsufficientLiquidity(token, amount, availableLiquidity);
        }

        // Transfer loan to receiver
        if (!IERC20(token).transfer(address(receiver), amount)) {
            revert InvalidToken(token);
        }

        // Get callback confirmation
        if (receiver.onFlashLoan(msg.sender, token, amount, fee, data) != CALLBACK_SUCCESS) {
            revert InvalidCallback(address(receiver));
        }

        // Transfer repayment
        if (!IERC20(token).transferFrom(address(receiver), address(insurancePool), amount + fee)) {
            revert RepaymentFailed(token, amount + fee);
        }

        emit FlashLoan(address(receiver), token, amount, fee, msg.sender);
        return true;
    }

    /**
     * @notice Calculate the fee for a flash loan
     * @param token The loan currency
     * @param amount The amount of tokens lent
     * @return The amount of `token` to be charged for the flash loan, on top of the returned principal
     */
    function flashFee(address token, uint256 amount) public view override returns (uint256) {
        return insurancePool.flashFee(token, amount);
    }

    /**
     * @notice Get the maximum flash loan amount for a token
     * @param token The loan currency
     * @return The maximum amount of `token` that can be flash-borrowed
     */
    function maxFlashLoan(address token) public view override returns (uint256) {
        return insurancePool.maxFlashLoan(token);
    }
}
