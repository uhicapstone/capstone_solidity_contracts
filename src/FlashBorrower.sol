// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/interfaces/IERC3156FlashBorrower.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC3156FlashLender.sol";

/**
 * @title FlashBorrower
 * @dev Example implementation of the ERC-3156 Flash Borrower interface.
 */
contract FlashBorrower is IERC3156FlashBorrower {
    enum Action {
        NORMAL,
        OTHER
    }

    IERC3156FlashLender public lender;

    error UntrustedLender(address lender);
    error UntrustedInitiator(address initiator);

    /**
     * @dev Set the lender during deployment.
     * @param lender_ The address of the flash lender.
     */
    constructor(IERC3156FlashLender lender_) {
        lender = lender_;
    }

    /**
     * @dev ERC-3156 Flash loan callback.
     * @param initiator The initiator of the loan.
     * @param token The loan currency.
     * @param amount The amount of tokens lent.
     * @param fee The additional amount of tokens to repay.
     * @param data Arbitrary data structure, intended to contain user-defined parameters.
     * @return The keccak256 hash of "ERC3156FlashBorrower.onFlashLoan".
     */
    function onFlashLoan(address initiator, address token, uint256 amount, uint256 fee, bytes calldata data)
        external
        override
        returns (bytes32)
    {
        // Verify the lender
        if (msg.sender != address(lender)) {
            revert UntrustedLender(msg.sender);
        }

        // Verify the loan initiator
        if (initiator != address(this)) {
            revert UntrustedInitiator(initiator);
        }

        // Decode the action from the data
        (Action action) = abi.decode(data, (Action));

        // Handle the action
        if (action == Action.NORMAL) {
            // Perform a normal operation
        } else if (action == Action.OTHER) {
            // Perform another operation
        }

        // Return the success callback
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }

    /**
     * @dev Initiate a flash loan.
     * @param token The loan currency.
     * @param amount The amount of tokens to borrow.
     */
    function flashBorrow(address token, uint256 amount) public {
        // Encode the action for the flash loan callback
        bytes memory data = abi.encode(Action.NORMAL);

        // Calculate the repayment amount
        uint256 _fee = lender.flashFee(token, amount);
        uint256 _repayment = amount + _fee;

        // Approve the lender to withdraw the repayment
        IERC20(token).approve(address(lender), _repayment);

        // Initiate the flash loan
        lender.flashLoan(this, token, amount, data);
    }
}
