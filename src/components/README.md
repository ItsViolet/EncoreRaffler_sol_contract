# EncoreRafflerV5 Smart Contract

This directory contains the complete implementation of the EncoreRafflerV5 smart contract with Chainlink VRF 2.5 integration.

## Contract Overview

The EncoreRafflerV5 is a sophisticated smart contract that enables trustless raffle management on Ethereum with the following key features:

- **Dual Raffle Modes**: Pool raffles (flexible) and Traditional raffles (committed)
- **Chainlink VRF 2.5**: Provably fair randomness for winner selection
- **Multiple Raffle Types**: Donation-based, Profit-based, and Incentive-based
- **Atomic Payment Splitting**: Instant rewards combined with raffle entries
- **EIP-712 Signatures**: Structured signature verification system
- **Flexible Refunds**: Pool raffles allow anytime refunds, traditional raffles have deadline-based refunds
- **Early Ending**: Pool raffles can end early when target amount is reached
- **Comprehensive Events**: Complete audit trail of all actions

## Key Components

### 1. Raffle Modes
- **Pool Raffles (isPool = true)**: Flexible participation, direct payout, early ending capability
- **Traditional Raffles (isPool = false)**: Committed participation, VRF winner selection, deadline-based refunds

### 2. Raffle Types
- **DonationBased**: Runs until target entries reached
- **ProfitBased**: Runs until manually stopped
- **IncentiveBased**: Splits payment for instant reward + raffle entry

### 3. Chainlink VRF 2.5 Integration
- **Secure Randomness**: Cryptographically secure random number generation
- **Subscription Model**: Gas-efficient VRF requests
- **Automatic Fulfillment**: Winner selection and prize disbursement

### 4. Security Model
- **Contract Owner**: Creates raffles, updates signers
- **App Server Signer**: Authorizes raffle creation and incentive entries
- **EIP-712 Signatures**: Structured signature verification prevents replay attacks
- **ReentrancyGuard**: Prevents reentrancy attacks
- **VRF Integration**: Eliminates need for trusted randomness oracle

### 5. Core Functions
- `createRaffle()`: Create new raffles with App Server signature
- `enterRaffle()`: Enter standard raffles
- `joinIncentiveRaffle()`: Enter incentive raffles with signature
- `endRaffle()`: End raffle and initiate winner selection
- `refund()`: Claim refunds (flexible for pools, deadline-based for traditional)
- `fulfillRandomWords()`: Chainlink VRF callback for winner selection

## Security Features

1. **EIP-712 Signatures**: Structured signature verification with replay protection
2. **Chainlink VRF 2.5**: Provably fair randomness eliminates manipulation
3. **Dual Refund System**: Pool raffles allow flexible exits, traditional raffles have deadline protection
4. **Input Validation**: Comprehensive validation of all parameters
5. **Event Logging**: Complete audit trail of all contract interactions
6. **Emergency Controls**: Pause/unpause functionality for critical situations

## Usage

The contract is designed to work with:
- ERC20 payment tokens (USDC recommended)
- Chainlink VRF 2.5 Coordinator
- OpenZeppelin security libraries
- Ethereum mainnet or compatible networks

## Files

- `contracts/EncoreRafflerV5.sol`: Complete Solidity implementation with VRF 2.5
- `src/components/ContractViewer.tsx`: React interface for documentation
- Dependencies: OpenZeppelin contracts, Chainlink VRF 2.5

## Deployment

To deploy this contract:

1. Install dependencies: `npm install @openzeppelin/contracts @chainlink/contracts`
2. Configure your deployment environment
3. Set up Chainlink VRF 2.5 subscription
3. Deploy with constructor parameters:
   - `_paymentToken`: ERC20 token address (e.g., USDC)
   - `_appServerSigner`: Trusted App Server signer address
   - `_vrfCoordinator`: Chainlink VRF Coordinator address
   - `_subscriptionId`: VRF subscription ID
   - `_keyHash`: VRF key hash for gas lane

## Testing

Before deployment, ensure comprehensive testing of:
- Both pool and traditional raffle modes
- EIP-712 signature verification for all protected functions
- Dual refund system (pool vs traditional)
- Chainlink VRF integration and winner selection
- Early ending for pool raffles when target reached
- Event emission and error handling
- Integration with external systems (BitRefill API)

## License

MIT License - See contract header for details.