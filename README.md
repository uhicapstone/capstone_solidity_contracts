#  Dynamic LP Assurance Hook

## Table of Contents
1. [Introduction](#introduction)  
2. [Key Features](#key-features)  
3. [Technical Architecture](#technical-architecture)  
4. [Dynamic Fees Algorithm](#dynamic-fees-algorithm)  
5. [Set it up yourself](#Set-it-up-yourself)  

---

## Introduction

The **Dynamic LP Assurance Hook** is a Uniswap V4 hook designed to protect liquidity providers (LPs) by dynamically collecting insurance fees and enabling flash loan functionalities. It provides compensation for impermanent loss (IL) and utilizes dynamic algorithms to compute fair insurance and flash loan fees, ensuring optimal utilization of liquidity.

---

## Key Features

1. **Dynamic Insurance Fee**  
   - Fees are dynamically calculated based on multiple factors, including price volatility, trade size, and pool liquidity 
     using Stylus (https://github.com/uhicapstone/capstone_stylus_contracts) which implements computationally intensive 
     calculations, ensuring low-cost and efficient execution.
   - Provides liquidity providers with compensation for impermanent loss during liquidity withdrawal.  

2. **Flash Loan Functionality**  
   - Offers flash loans on idle liquidity by leveraging the clubbed liquidity across multiple pools.  
   - Dynamically calculates flash loan fees based on pool utilization, liquidity, and trade parameters. 

3. **Efficient Fee Distribution**  
   - Swap fees and flash loan fees are proportionally distributed among pools and liquidity providers using offchain computation through Brevis (https://github.com/uhicapstone/capstone_brevis_circuit).  

---

## Technical Architecture

1. **Swapping Process**  
   - The `beforeSwap` function calls `calculateInsuranceFee` which calculates insurance fees dynamically through stylus contract for each swap.  
   - Fees are taken using the ERC6909 token mechanism and added to the hook accounting in `poolDataMap` & `tokenDataMap` without transferring actual funds directly.

2. **Flash Loan Execution**  
   - The `flashLoan` function first calls `flashfee` which calculates flashloan fess through stylus contract. It then facilitates flash loans while ensuring repayment with fees.  
   - Fees collected are distributed among pools proportionally, leveraging the pooled liquidity.
     
3.  **Liquidity Withdraw**  
   - When LP withdraws liquidity it triggers `beforeRemoveLiquidity` which calls `_calculateClaimableFees` which calculates 
     the claimable insurance fees for LP based on their IL and share of liquidity in the pool.  
   - IL is calculated with the help of brevis.

---

## Dynamic Fees Algorithm

This is where the real magic happens, driving everything behind the scenes!<br/> 
The dynamic fees for insurance and flash loans are computed using a combination of metrics to ensure fair and adaptive pricing. These computations are offloaded to a Stylus contract for efficiency.

1. **Insurance Fee Calculation**  
   - **Inputs**:
     - Pool liquidity
     - Price volatility
     - Trade size
   - **Formula**:
     \[
     \text{InsuranceFee} = \text{TradeSize} \times \text{VolatilityFactor} \times \left(\frac{\text{CurrentPrice}}{\text{PreviousPrice}}\right)
     \]

2. **Flash Loan Fee Calculation**  
   - **Inputs**:
     - Available liquidity
     - Utilization rate
   - **Formula**:
     \[
     \text{FlashLoanFee} = \text{LoanAmount} \times \text{UtilizationRateFactor} \times \text{LiquidityFactor}
     \]

3. **Impermanent Loss Compensation**  
   - **Inputs**:
     - LP's share of liquidity
     - Price change
   - **Formula**:
     \[
     \text{Compensation} = \text{LPShare} \times \text{PoolContribution} \times \left(1 - \sqrt{\frac{\text{NewPrice}}{\text{OldPrice}}}\right)
     \]

---

## Set it up yourself


 1. **Prerequisites**

Ensure you have the following installed on your system:

- **[Foundry]**
- **Node.js & npm**

---

 2. **Installation**

1. Clone the GitHub repository
2. Run `make build-contracts` to install required dependencies and build the contracts
3. Run `cd operator` and `pnpm install` to install dependencies for the operator
4. Run `make deploy-to-anvil` from the root directory to set up a local anvil instance with EigenLayer and Uniswap v4 contracts deployed
5. Run `make start-anvil` from the root directory to start anvil on one terminal
6. Run `cd operator` and `pnpm dev` to start the operator in another terminal
7. Run `cd operator` and `pnpm create-task <number of tasks>` to create tasks.

Inspect the logs in the operator terminal to see the tasks being created and the balances being settled.



