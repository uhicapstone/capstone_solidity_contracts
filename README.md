# Dynamic LP Assurance Hook

## Table of Contents

1. [Introduction](#introduction)
2. [Key Features](#key-features)
3. [Technical Architecture](#technical-architecture)
4. [Dynamic Fees Algorithm](#dynamic-fees-algorithm)
5. [Local Development Setup](#local-development-setup)
6. [Running Tests](#running-tests)
7. [Set it up Yourself](#set-it-up-yourself)

---

## Introduction

The **Dynamic LP Assurance Hook** is an advanced Uniswap V4 hook designed to protect liquidity providers (LPs) by dynamically calculating and collecting insurance fees, while also enabling flash loan functionalities. It ensures LPs are compensated for impermanent loss (IL) and that fees for swaps and flash loans are optimally calculated based on current market and pool conditions.

---

## Key Features

1. **Dynamic Insurance Fee Calculation**

   - Adapts to trade size, pool liquidity, and other risk factors.
   - Compensates LPs for impermanent loss during liquidity withdrawal.
   - Offloads computationally intensive fee calculations to Stylus contracts for cost and execution efficiency.

2. **Flash Loan Functionality**

   - Facilitates flash loans on idle liquidity aggregated across multiple pools.
   - Dynamically adjusts flash loan fees based on utilization, liquidity, and trade size.
   - Offloads fee computation to Stylus contracts for performance gains.

3. **Efficient Fee Distribution**
   - Distributes insurance and flash loan fees proportionally among LPs based on pool contributions.
   - Leverages off-chain computation (e.g., Brevis circuits) for accurate and fair distributions.

---

## Technical Architecture

### Swapping Process

- On each swap (`beforeSwap`), calls `calculateInsuranceFee` (Stylus contract).
- Dynamically determines insurance fees based on pool conditions and trade parameters.
- Updates internal accounting (`poolDataMap`, `tokenDataMap`) without direct token transfers.

### Flash Loan Execution

- The `flashLoan` function executes loans using liquidity from multiple pools.
- Calls `flashFee` (Stylus contract) to compute fees based on utilization and liquidity.
- Ensures repayment plus fees, then distributes collected fees proportionally among LPs.

### Liquidity Withdrawals

- The `beforeRemoveLiquidity` function calculates IL compensation for the withdrawing LP.
- Utilizes Brevis circuits to determine LP's share and compensation accurately.

---

## Dynamic Fees Algorithm

### Insurance Fee Calculation

Formula:  
InsuranceFee = TradeSize × VolumeMultiplier × ILMultiplier × SizeMultiplier

- **TradeSize**: Size of the swap or liquidity movement.
- **VolumeMultiplier**: Increases or reduces fees based on total volume.  
  Example: 0.1 + (0.9 × TotalVolume) / (TotalVolume + 1)
- **ILMultiplier**: Adjusts fees based on historical impermanent loss.  
  Example: 1 + 3 × HistoricalIL
- **SizeMultiplier**: Higher fees for larger trades relative to liquidity.  
  Example: 1 + (TradeSize / TotalLiquidity)

### Flash Loan Fee Calculation

Formula:  
FlashLoanFee = LoanAmount × UtilizationMultiplier × LiquidityMultiplier × HistoricalMultiplier

- **UtilizationMultiplier**: Scales fee up as pool utilization increases.
- **LiquidityMultiplier**: Lowers fee when liquidity is high.
- **HistoricalMultiplier**: Adjusts fees based on past default or performance data.

---

## Local Development Setup

1. **Install Foundry (Forge)**  
   Follow instructions at:  
   https://book.getfoundry.sh/getting-started/installation

2. **Run a Local Dev Node** (e.g., Nitro Dev Node from Offchain Labs)  
   Clone and start the Arbitrum nitro dev node:

   ```bash
   git clone https://github.com/OffchainLabs/nitro-devnode.git
   cd nitro-devnode
   ./run-dev-node.sh
   ```

   This runs the node on http://localhost:8547.

3. **Check Dependencies**
   - Ensure you have `docker` and `docker-compose` for the Nitro Dev Node.
   - Ensure node.js and npm (or pnpm) are installed for the operator setup.

## Running Tests

1. **Build Contracts**

   ```bash
   forge build
   ```

2. **Run Tests Against the Nitro Dev Node**  
   With the Nitro dev node running on http://localhost:8547, run:

   ```bash
   forge test --match-path test/InsurancePoolHook.t.sol --rpc-url http://localhost:8547 -vvv --via-ir
   ```

   - `--match-path`: Specifies the test file.
   - `--rpc-url`: Points to your local dev node.
   - `-vvv`: Increases verbosity.
   - `--via-ir`: Uses Yul IR pipeline for optimization.

3. **View Logs and Results**  
   The test output will show which tests passed or failed. Adjust parameters as needed for debugging or verbosity.

## Set it up Yourself

### Prerequisites

- Foundry
- Node.js & npm

### Installation Steps

1. Clone the repository.
2. Run `make build-contracts` to install dependencies and build the contracts.
3. In `operator` directory, run `pnpm install` to install dependencies for the operator.
4. Run `make deploy-to-anvil` at the project root to set up a local environment with EigenLayer and Uniswap V4 contracts.
5. Run `make start-anvil` to start a local Anvil testchain.
6. In `operator`, run `pnpm dev` to start the operator.
7. In `operator`, run `pnpm create-task <number_of_tasks>` to create tasks and inspect operator logs.

By following these steps, you can develop, test, and iterate on the Dynamic LP Assurance Hook locally, verifying fee calculations, liquidity distributions, and IL compensations in a controlled and replicable environment.
