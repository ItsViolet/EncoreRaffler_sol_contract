import React, { useState } from 'react';
import { FileText, Shield, Users, Zap, RefreshCw, AlertTriangle } from 'lucide-react';

interface ContractSection {
  title: string;
  content: string;
  icon: React.ReactNode;
  color: string;
}

const ContractViewer: React.FC = () => {
  const [activeSection, setActiveSection] = useState<string>('overview');

  const sections: Record<string, ContractSection> = {
    overview: {
      title: 'Contract Overview',
      icon: <FileText className="w-5 h-5" />,
      color: 'bg-blue-500',
      content: `
        The EncoreRaffler is a sophisticated smart contract that enables trustless raffle management on Ethereum.
        
        Key Features:
        • Multiple raffle types (Donation, Profit, Incentive-based)
        • Atomic payment splitting for instant rewards
        • Secure signature verification system
        • Automatic refund mechanisms
        • Comprehensive event logging
        
        The contract uses USDC (or any ERC20) as the payment token and implements OpenZeppelin's security patterns.
      `
    },
    security: {
      title: 'Security Model',
      icon: <Shield className="w-5 h-5" />,
      color: 'bg-red-500',
      content: `
        Trust Assumptions:
        
        Contract Owner:
        • Can create raffles and update signers
        • Should use multisig wallet for enhanced security
        
        App Server Signer:
        • Authorizes incentive raffle entries
        • Must be secured in HSM (AWS KMS recommended)
        • Critical for preventing fund draining
        
        BitRefill Signer:
        • Authorizes final prize payouts
        • Also requires HSM security
        • Can end raffles and disburse prizes
        
        Protection Mechanisms:
        • ReentrancyGuard on all external calls
        • Signature scoping prevents replay attacks
        • Deadline-based refund system
        • On-chain validation of all critical parameters
      `
    },
    raffleTypes: {
      title: 'Raffle Types',
      icon: <Users className="w-5 h-5" />,
      color: 'bg-green-500',
      content: `
        Donation-Based Raffles:
        • Run until target entry count is reached
        • Prize pool is total collected amount
        • Automatically close when entry limit hit
        
        Profit-Based Raffles:
        • Run until manually stopped by organizer
        • Allow for organizer profit margin
        • Flexible entry management
        
        Incentive-Based Raffles:
        • Split each entry fee automatically
        • Instant reward (e.g., gift card) + raffle entry
        • Requires App Server signature authorization
        • Atomic payment processing
      `
    },
    functions: {
      title: 'Key Functions',
      icon: <Zap className="w-5 h-5" />,
      color: 'bg-purple-500',
      content: `
        Owner Functions:
        • createRaffle() - Anyone can create raffles with appServerSigner authorization
        • updateAppServerSigner() - Update trusted App Server address
        • updateBitRefillSigner() - Update trusted BitRefill address
        
        User Functions:
        • enterRaffle() - Enter standard raffles
        • joinIncentiveRaffle() - Enter incentive raffles with signature
        • refund() - Claim refunds after deadline passes
        
        Oracle Functions:
        • endRaffle() - End raffle and disburse prize (requires signature)
        
        View Functions:
        • getRaffleInfo() - Get complete raffle details
        • hasUserEntered() - Check user participation
        • getContractBalance() - Check contract token balance
      `
    },
    events: {
      title: 'Events & Errors',
      icon: <RefreshCw className="w-5 h-5" />,
      color: 'bg-orange-500',
      content: `
        Events:
        • RaffleCreated - New raffle initialization
        • Entry - Standard raffle entry
        • IncentiveEntry - Incentive raffle entry with split payment
        • RaffleEnded - Raffle completion and prize disbursement
        • Refunded - User refund processed
        • AppServerSignerUpdated - Signer address change
        • BitRefillSignerUpdated - Signer address change
        
        Custom Errors:
        • InvalidSigner - Invalid signer address
        • InvalidSignature - Signature verification failed
        • RaffleNotActive - Raffle not accepting entries
        • AlreadyEntered - User already participated
        • DeadlineNotPassed - Refund not yet available
        • TransferFailed - Token transfer unsuccessful
      `
    },
    architecture: {
      title: 'System Architecture',
      icon: <AlertTriangle className="w-5 h-5" />,
      color: 'bg-yellow-500',
      content: `
        Hybrid On-Chain/Off-Chain Design:
        
        On-Chain Components:
        • EncoreRaffler Contract (fund management & core logic)
        • ERC20 Payment Token (USDC)
        • Signature verification system
        
        Off-Chain Components:
        • Encore App Server (orchestration & metadata)
        • BitRefill API (gift card generation)
        • User Wallet (transaction signing)
        
        Raffle Creation Flow:
        1. User requests to create raffle via App Server
        2. App Server validates request and business logic
        3. App Server signs authorization message
        4. User calls createRaffle() with signature
        5. Contract verifies signature and creates raffle
        
        Flow for Incentive Raffles:
        1. User requests to join raffle
        2. App Server creates BitRefill invoice
        3. App Server signs authorization
        4. User calls joinIncentiveRaffle()
        5. Contract verifies signature
        6. Payment split atomically executed
        7. Prize pool updated, gift card delivered
        
        This design optimizes for user experience while maintaining security through trusted signers.
      `
    }
  };

  const sectionKeys = Object.keys(sections);

  return (
    <div className="min-h-screen bg-gray-50">
      <div className="container mx-auto px-4 py-8">
        <header className="text-center mb-12">
          <h1 className="text-4xl font-bold text-gray-900 mb-4">
            EncoreRaffler Smart Contract
          </h1>
          <p className="text-xl text-gray-600 max-w-3xl mx-auto">
            A comprehensive Solidity implementation for trustless raffle management with incentive mechanisms
          </p>
          <div className="mt-6 flex justify-center">
            <div className="bg-white rounded-lg shadow-md p-4 border border-gray-200">
              <div className="flex items-center space-x-4 text-sm text-gray-600">
                <span className="flex items-center">
                  <span className="w-2 h-2 bg-green-500 rounded-full mr-2"></span>
                  Solidity ^0.8.19
                </span>
                <span className="flex items-center">
                  <span className="w-2 h-2 bg-blue-500 rounded-full mr-2"></span>
                  OpenZeppelin Security
                </span>
                <span className="flex items-center">
                  <span className="w-2 h-2 bg-purple-500 rounded-full mr-2"></span>
                  ERC20 Compatible
                </span>
              </div>
            </div>
          </div>
        </header>

        <div className="flex flex-col lg:flex-row gap-8">
          {/* Navigation Sidebar */}
          <div className="lg:w-1/4">
            <div className="bg-white rounded-lg shadow-md p-6 sticky top-8">
              <h3 className="text-lg font-semibold text-gray-900 mb-4">Contract Sections</h3>
              <nav className="space-y-2">
                {sectionKeys.map((key) => {
                  const section = sections[key];
                  const isActive = activeSection === key;
                  return (
                    <button
                      key={key}
                      onClick={() => setActiveSection(key)}
                      className={`w-full flex items-center space-x-3 px-4 py-3 rounded-lg transition-all duration-200 ${
                        isActive
                          ? 'bg-blue-50 text-blue-700 border-l-4 border-blue-500'
                          : 'text-gray-600 hover:bg-gray-50 hover:text-gray-900'
                      }`}
                    >
                      <div className={`p-2 rounded-lg ${isActive ? section.color : 'bg-gray-100'}`}>
                        <div className={isActive ? 'text-white' : 'text-gray-600'}>
                          {section.icon}
                        </div>
                      </div>
                      <span className="text-sm font-medium">{section.title}</span>
                    </button>
                  );
                })}
              </nav>
            </div>
          </div>

          {/* Main Content */}
          <div className="lg:w-3/4">
            <div className="bg-white rounded-lg shadow-md p-8">
              <div className="flex items-center space-x-3 mb-6">
                <div className={`p-3 rounded-lg ${sections[activeSection].color}`}>
                  <div className="text-white">
                    {sections[activeSection].icon}
                  </div>
                </div>
                <h2 className="text-2xl font-bold text-gray-900">
                  {sections[activeSection].title}
                </h2>
              </div>
              
              <div className="prose prose-lg max-w-none">
                <div className="whitespace-pre-line text-gray-700 leading-relaxed">
                  {sections[activeSection].content}
                </div>
              </div>
            </div>
          </div>
        </div>

        {/* Footer */}
        <footer className="mt-16 text-center">
          <div className="bg-white rounded-lg shadow-md p-6">
            <h3 className="text-lg font-semibold text-gray-900 mb-4">Contract Files</h3>
            <div className="flex flex-col sm:flex-row gap-4 justify-center">
              <div className="bg-gray-50 rounded-lg p-4 border border-gray-200">
                <div className="flex items-center space-x-2 text-sm text-gray-600">
                  <FileText className="w-4 h-4" />
                  <span>contracts/EncoreRafflerV5.sol</span>
                </div>
                <p className="text-xs text-gray-500 mt-1">Complete implementation with VRF 2.5</p>
              </div>
              <div className="bg-gray-50 rounded-lg p-4 border border-gray-200">
                <div className="flex items-center space-x-2 text-sm text-gray-600">
                  <Shield className="w-4 h-4" />
                  <span>Chainlink VRF 2.5</span>
                </div>
                <p className="text-xs text-gray-500 mt-1">Provably fair randomness</p>
              </div>
              <div className="bg-gray-50 rounded-lg p-4 border border-gray-200">
                <div className="flex items-center space-x-2 text-sm text-gray-600">
                  <Users className="w-4 h-4" />
                  <span>EIP-712 Signatures</span>
                </div>
                <p className="text-xs text-gray-500 mt-1">Structured signature verification</p>
              </div>
            </div>
          </div>
        </footer>
      </div>
    </div>
  );
};

export default ContractViewer;