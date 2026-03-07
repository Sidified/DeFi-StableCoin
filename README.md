
---

# Decentralized Stablecoin Protocol (DSC)

A **minimal over-collateralized decentralized stablecoin protocol** built in **Solidity** using the **Foundry** framework.

The protocol allows users to deposit crypto collateral (WETH/WBTC) and mint a USD-pegged stablecoin (`DSC`). The system enforces **strict collateralization rules, liquidation mechanics, and oracle safety checks** to maintain solvency.

This project demonstrates core concepts behind protocols like **MakerDAO (DAI)** and **Liquity**, including **collateralized debt positions, liquidation incentives, oracle integration, invariant testing, and protocol safety mechanisms**.

---

# Table of Contents

* Overview
* Protocol Architecture
* How the Protocol Works
* Collateralization Model
* Health Factor
* Liquidation System
* Oracle Integration
* Oracle Safety (OracleLib)
* Security Design
* Invariant Testing
* Project Structure
* Installation & Setup
* Running Tests
* Deployment
* Example User Flow
* Known Limitations
* Future Improvements
* Learning Goals
* Author

---

# Overview

The DSC protocol is designed to maintain a **stablecoin pegged to USD** using **over-collateralization**.

Users can:

1. Deposit collateral (WETH or WBTC)
2. Mint DSC stablecoins
3. Maintain a healthy collateral ratio
4. Repay DSC to unlock collateral
5. Be liquidated if the position becomes unsafe

The core invariant enforced by the system is:

```
Total Collateral Value ≥ Total DSC Supply
```

This ensures the stablecoin is always **fully backed by collateral**.

---

# Protocol Architecture

```
                +----------------------+
                |   Chainlink Oracles  |
                |   ETH/USD , BTC/USD  |
                +----------+-----------+
                           |
                           v
                +----------------------+
                |       DSCEngine      |
                |----------------------|
                | Deposit Collateral   |
                | Mint DSC             |
                | Burn DSC             |
                | Redeem Collateral    |
                | Liquidations         |
                +----------+-----------+
                           |
                           v
                +-------------------------+
                | DecentralizedStableCoin |
                |        (ERC20)          |
                +-------------------------+
```

The architecture separates responsibilities into two main contracts.

---

# Core Contracts

## DSCEngine

The **core protocol contract** responsible for system logic.

Responsibilities:

* Collateral deposits
* Minting stablecoins
* Burning stablecoins
* Liquidation mechanics
* Health factor calculations
* Oracle price integration

Important functions:

```
depositCollateral()
mintDsc()
burnDsc()
redeemCollateral()
liquidate()
```

---

## DecentralizedStableCoin

An **ERC20 stablecoin implementation**.

Features:

* ERC20 token with burn capability
* Minting restricted to DSCEngine
* Burn functionality for debt repayment

The DSCEngine becomes the **owner of the stablecoin contract**, ensuring only the protocol controls supply.

---

# Collateralization Model

The protocol enforces **200% collateralization**.

Example:

```
User deposits $2000 ETH
User can mint up to $1000 DSC
```

This creates a safety buffer to absorb market volatility.

Key parameters:

```
LIQUIDATION_THRESHOLD = 50%
LIQUIDATION_BONUS = 10%
MIN_HEALTH_FACTOR = 1
```

---

# Health Factor

The **health factor** determines the safety of a user's position.

Formula:

```
healthFactor = (collateralValue * liquidationThreshold)/totalDebt
```

Interpretation:

```
healthFactor > 1 → Safe
healthFactor = 1 → Liquidation edge
healthFactor < 1 → Liquidatable
```

Example:

```
Collateral = $2000
Debt = $1000

Adjusted collateral = 2000 * 50% = $1000

healthFactor = 1000 / 1000 = 1
```

---

# Liquidation System

When a user's **health factor drops below 1**, their position becomes liquidatable.

Liquidation steps:

1. A liquidator repays part or all of the user's debt.
2. The liquidator burns DSC.
3. The liquidator receives the user’s collateral.
4. A liquidation bonus incentivizes this action.

Example:

```
Debt repaid: $100
Liquidation bonus: 10%

Liquidator receives $110 worth of collateral.
```

This ensures the system remains solvent.

---

# Oracle Integration

The protocol uses **Chainlink price feeds** to determine collateral value.

Example feeds:

```
ETH/USD
BTC/USD
```

Price feeds return values with **8 decimals**, so the system converts them to **18-decimal precision** for compatibility with Solidity math.

Example conversion:

```
Price feed: 2000 * 10^8
Adjusted price: 2000 * 10^18
```

---

# Oracle Safety (OracleLib)

External data sources are dangerous in DeFi systems.

To protect against stale price feeds, the protocol uses **OracleLib**.

OracleLib verifies:

```
block.timestamp - lastUpdate <= TIMEOUT
```

Where:

```
TIMEOUT = 3 hours
```

If price data is stale:

```
OracleLib__PriceIsStale()
```

The protocol intentionally **halts operations** rather than using unreliable prices.

This design prioritizes **safety over availability**.

---

# Security Design

The protocol incorporates multiple defensive mechanisms.

## Over-Collateralization

Every minted DSC must be backed by collateral.

---

## Reentrancy Protection

All sensitive functions use:

```
ReentrancyGuard
```

---

## CEI Pattern

Functions follow:

```
Checks → Effects → Interactions
```

to minimize reentrancy risks.

---

## Oracle Freshness Checks

Prevents stale or outdated price data.

---

## Liquidation Incentives

Ensures unhealthy positions are quickly resolved.

---

## Health Factor Enforcement

Critical operations verify:

```
_revertIfHealthFactorIsBroken()
```

---

# Invariant Testing

The protocol includes **fuzz-based invariant testing**.

Invariant tests ensure:

```
Total collateral value ≥ total DSC supply
```

Testing configuration:

```
runs = 128
depth = 128
```

Total interactions executed:

```
≈ 16,000 random operations
```

This simulates chaotic user behavior.

Invariant testing uses a **Handler contract** to generate randomized interactions such as:

```
depositCollateral
mintDsc
redeemCollateral
```

The goal is to verify that **no sequence of actions can break protocol solvency**.

---

# Project Structure

```
src/
 ├── DSCEngine.sol
 ├── DecentralizedStableCoin.sol
 └── Libraries/
      └── OracleLib.sol

script/
 ├── DeployDSC.s.sol
 └── HelperConfig.s.sol

test/
 ├── unit/
 │    └── DSCEngineTest.t.sol
 └── fuzz/
      ├── Handler.t.sol
      └── Invariants.t.sol
```

---

# Installation & Setup

Install Foundry:

```
curl -L https://foundry.paradigm.xyz | bash
foundryup
```

Clone the repository:

```
git clone https://github.com/Sidified/DeFi-StableCoin.git
cd DeFi-StableCoin
```

Install dependencies: This project uses OpenZeppelin and Chainlink libraries.

```
forge install
```

---

# Running Tests

Run all tests:

```
forge test
```

Run with detailed logs:

```
forge test -vvvv
```

Run only invariant tests:

```
forge test --match-path test/fuzz
```

---

# Deployment

Deployment scripts are located in:

```
script/DeployDSC.s.sol
```

Example deployment command:

```
forge script script/DeployDSC.s.sol --broadcast
```

---

# Example User Flow

Example interaction with the protocol:

1. User deposits ETH as collateral.

```
depositCollateral(ETH, 10)
```

2. User mints DSC.

```
mintDsc(1000)
```

3. User spends DSC externally.

4. User later repays the loan.

```
burnDsc(1000)
```

5. User withdraws collateral.

```
redeemCollateral(ETH, 10)
```

---

# Known Limitations

This implementation is simplified for educational purposes.

Potential issues in production systems include:

* Extreme market crashes causing bad debt
* Oracle manipulation attacks
* Liquidity shortages for liquidators

Real-world protocols implement additional mechanisms to mitigate these risks.

---

# Future Improvements

Potential production upgrades include:

* Stability fees
* Governance-controlled risk parameters
* Multi-collateral risk models
* Insurance funds
* Flash loan attack mitigation
* Liquidation auctions
* Cross-chain collateral support

---

# Learning Goals

This project demonstrates:

* DeFi lending protocol architecture
* Over-collateralized stablecoin systems
* Liquidation incentive design
* Oracle integrations
* Smart contract security patterns
* Fuzz testing
* Invariant testing
* Solidity protocol development using Foundry

---

# Author

Siddharth Choudhary -
Blockchain Developer

Focused on **DeFi protocol development, smart contract security, and blockchain infrastructure**.

---

## 🤝 Connect & Collaborate

I'm actively seeking opportunities to contribute to Web3 projects and collaborate with other developers. Whether you're:
- 👨‍💼 A company looking for smart contract developers
- 🎓 A learner wanting to discuss these concepts
- 🛠️ A developer interested in collaboration
- 🔍 A recruiter evaluating technical skills

**Let's connect!**

- 💼 **LinkedIn:** [Siddharth Choudhary](https://www.linkedin.com/in/siddharth-choudhary-797391215/)
- 🐦 **Twitter:** [Sid_Hary_](https://x.com/Sid_Hary_)
- 📧 **Email:** sidforwork46@gmail.com


## 📄 License

Distributed under the MIT License. See `LICENSE` for more information.

## 🤝 Acknowledgements

* **Patrick Collins & Cyfrin Updraft** for the foundational knowledge.
---

**Made with ❤️ using Foundry and Chainlink**


