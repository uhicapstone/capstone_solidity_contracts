// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import "./InsurancePoolManager.sol";

contract FlashLender is IERC3156FlashLender {
    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    InsurancePoolManager public insurancePoolManager;

    uint256 public fee; // Fee percentage in basis points (bps)

    error TransferFailed(address token, address to, uint256 amount);
    error CallbackFailed(address receiver);
    error RepaymentFailed(address token, address from, uint256 amount);
    error UnsupportedToken(address token);

    /**
     * @param insurancePoolManager_ The address of the InsurancePoolManager contract.
     * @param fee_ The percentage of the loan `amount` that needs to be repaid, in addition to `amount`.
     */
    constructor(address insurancePoolManager_, uint256 fee_) {
        insurancePoolManager = InsurancePoolManager(insurancePoolManager_);
        fee = fee_;
    }

    /**
     * @dev Loan `amount` tokens to `receiver`, and takes it back plus a `flashFee` after the callback.
     * @param receiver The contract receiving the tokens, needs to implement the `onFlashLoan` interface.
     * @param token The loan currency.
     * @param amount The amount of tokens lent.
     * @param data A data parameter to be passed on to the `receiver` for any custom use.
     */
    function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata data)
        external
        override
        returns (bool)
    {
        uint256 loanFee = _flashFee(token, amount);

        // Transfer tokens from the InsurancePool
        if (!insurancePoolManager.transferFunds(token, address(receiver), amount)) {
            revert TransferFailed(token, address(receiver), amount);
        }

        // Callback to the receiver
        if (receiver.onFlashLoan(msg.sender, token, amount, loanFee, data) != CALLBACK_SUCCESS) {
            revert CallbackFailed(address(receiver));
        }

        // Pull repayment from the receiver
        uint256 totalRepayment = amount + loanFee;
        if (!IERC20(token).transferFrom(address(receiver), address(insurancePoolManager), totalRepayment)) {
            revert RepaymentFailed(token, address(receiver), totalRepayment);
        }

        insurancePoolManager.Repayment(token, amount, loanFee);

        return true;
    }

    /**
     * @dev The fee to be charged for a given loan.
     * @param token The loan currency.
     * @param amount The amount of tokens lent.
     * @return The amount of `token` to be charged for the loan, on top of the returned principal.
     */
    function flashFee(address token, uint256 amount) external view override returns (uint256) {
        return _flashFee(token, amount);
    }

    /**
     * @dev Internal function to calculate the fee for a given loan.
     * @param token The loan currency.
     * @param amount The amount of tokens lent.
     * @return The amount of `token` to be charged for the loan, on top of the returned principal.
     */
    function _flashFee(address token, uint256 amount) internal view returns (uint256) {
        if (!insurancePoolManager.isTokenSupported(token)) {
            revert UnsupportedToken(token);
        }
        return (amount * fee) / 10000;
    }

    /**
     * @dev The amount of currency available to be lent.
     * @param token The loan currency.
     * @return The amount of `token` that can be borrowed.
     */
    function maxFlashLoan(address token) external view override returns (uint256) {
        return insurancePoolManager.getAvailableLiquidity(token);
    }
}
