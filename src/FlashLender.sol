// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";
import "./InsurancePoolHook.sol";

contract FlashLender is IERC3156FlashLender {
    bytes32 public constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    InsurancePoolHook public insurancePoolHook;

    uint256 public fee; // Fee percentage in basis points (bps)

    error TransferFailed(address token, address to, uint256 amount);
    error CallbackFailed(address receiver);
    error RepaymentFailed(address token, address from, uint256 amount);
    error UnsupportedToken(address token);

    /**
     * @param insurancePoolHook_ The address of the InsurancePoolHook contract.
     * @param fee_ The percentage of the loan `amount` that needs to be repaid, in addition to `amount`.
     */
    constructor(address insurancePoolHook_, uint256 fee_) {
        insurancePoolHook = InsurancePoolHook(insurancePoolHook_);
        fee = fee_;
    }

    /**
     * @dev Loan `amount` tokens to `receiver`, and takes it back plus a `flashFee` after the callback.
     */
    function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata data)
        external
        override
        returns (bool)
    {
        uint256 loanFee = _flashFee(token, amount);

        // Transfer tokens from the InsurancePool
        if (!insurancePoolHook.transferFunds(token, address(receiver), amount)) {
            revert TransferFailed(token, address(receiver), amount);
        }

        // Callback to the receiver
        if (receiver.onFlashLoan(msg.sender, token, amount, loanFee, data) != CALLBACK_SUCCESS) {
            revert CallbackFailed(address(receiver));
        }

        // Pull repayment from the receiver
        uint256 totalRepayment = amount + loanFee;
        if (!IERC20(token).transferFrom(address(receiver), address(insurancePoolHook), totalRepayment)) {
            revert RepaymentFailed(token, address(receiver), totalRepayment);
        }

        insurancePoolHook.handleRepayment(token, amount, loanFee);

        return true;
    }

    /**
     * @dev The fee to be charged for a given loan.
     */
    function flashFee(address token, uint256 amount) external view override returns (uint256) {
        return _flashFee(token, amount);
    }

    /**
     * @dev Internal function to calculate the fee for a given loan.
     */
    function _flashFee(address token, uint256 amount) internal view returns (uint256) {
        if (!insurancePoolHook.isTokenSupported(token)) {
            revert UnsupportedToken(token);
        }
        return (amount * fee) / 10000;
    }

    /**
     * @dev The amount of currency available to be lent.
     */
    function maxFlashLoan(address token) external view override returns (uint256) {
        return insurancePoolHook.getAvailableLiquidity(token);
    }
}
