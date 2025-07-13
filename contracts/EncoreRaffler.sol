// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title EncoreRaffler
 * @dev Smart contract for managing various types of raffles with incentive mechanisms
 * @author Encore Team
 * @notice This contract facilitates trustless raffles with immediate incentive payouts
 */
contract EncoreRaffler is ReentrancyGuard {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // =============================================================================
    // ENUMS
    // =============================================================================

    /// @notice Defines the behavior and rules of a raffle
    enum RaffleType {
        DonationBased,  // Runs until target entries, prize is total collected
        ProfitBased,    // Runs until manually stopped, allows organizer profit
        IncentiveBased  // Each entry splits payment for instant reward and raffle ticket
    }

    /// @notice Tracks the current state of a raffle
    enum RaffleStatus {
        Inactive,   // Not created or does not exist
        Active,     // Open and accepting entries
        Closed,     // Ended, awaiting prize disbursement
        Finalized   // Prize has been paid out
    }

    // =============================================================================
    // STRUCTS
    // =============================================================================

    /// @notice Core data structure representing a single raffle
    struct Raffle {
        uint256 id;
        address organizer;
        RaffleStatus status;
        RaffleType raffleType;
        uint256 entryCost;          // Cost for a single raffle entry
        uint256 incentiveAmount;    // For IncentiveBased: amount paid for instant reward
        uint256 totalCollected;     // Total funds collected for the main prize pool
        uint256 entryLimit;         // For DonationBased: number of entries to close raffle
        uint256 entryCount;         // Current number of entries
        uint256 deadline;           // Timestamp after which users can claim refunds
        mapping(address => bool) hasEntered; // Tracks entrants to prevent double-entry
    }

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    /// @notice The ERC20 token used for all payments (e.g., USDC)
    IERC20 public immutable paymentToken;

    /// @notice The privileged contract owner
    address public owner;

    /// @notice The trusted address for the App Server to authorize incentive joins
    address public appServerSigner;

    /// @notice The trusted address for authorizing final prize payouts
    address public bitrefillSigner;

    /// @notice Mapping from raffle ID to the Raffle struct
    mapping(uint256 => Raffle) public raffles;

    /// @notice Nonce to prevent replay attacks for bitrefillSigner signatures
    mapping(address => uint256) public nonces;

    /// @notice Counter for generating unique raffle IDs
    uint256 private nextRaffleId = 1;

    // =============================================================================
    // EVENTS
    // =============================================================================

    event RaffleCreated(uint256 indexed raffleId, address indexed organizer, RaffleType raffleType, uint256 entryCost);
    event Entry(uint256 indexed raffleId, address indexed user, uint256 amount);
    event IncentiveEntry(uint256 indexed raffleId, address indexed user, uint256 raffleAmount, uint256 incentiveAmount, address incentiveDestination);
    event RaffleEnded(uint256 indexed raffleId, address indexed prizeDestination, uint256 prizeAmount);
    event Refunded(uint256 indexed raffleId, address indexed user, uint256 refundAmount);
    event AppServerSignerUpdated(address indexed oldSigner, address indexed newSigner);
    event BitRefillSignerUpdated(address indexed oldSigner, address indexed newSigner);

    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================

    error InvalidSigner();
    error InvalidSignature();
    error RaffleNotActive();
    error DeadlineNotPassed();
    error AlreadyEntered();
    error RaffleClosed();
    error InvalidRaffleType();
    error TransferFailed();
    error OnlyOwner();
    error InvalidRaffleId();
    error InsufficientAllowance();
    error InvalidAmount();
    error RaffleNotClosed();
    error ZeroAddress();
    error ContractPaused();

    // =============================================================================
    // ADDITIONAL STATE VARIABLES
    // =============================================================================

    /// @notice Emergency pause mechanism
    bool public paused = false;

    // =============================================================================
    // ADDITIONAL EVENTS
    // =============================================================================

    event ContractPaused(address indexed by);
    event ContractUnpaused(address indexed by);

    // =============================================================================
    // ADDITIONAL MODIFIERS
    // =============================================================================

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier validAddress(address _addr) {
        if (_addr == address(0)) revert ZeroAddress();
        _;
    }

    // =============================================================================
    // MODIFIERS
    // =============================================================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    modifier validRaffleId(uint256 _raffleId) {
        if (_raffleId == 0 || _raffleId >= nextRaffleId) revert InvalidRaffleId();
        _;
    }

    // =============================================================================
    // CONSTRUCTOR
    // =============================================================================

    /// @notice Initializes the contract with the payment token and signers
    /// @param _paymentToken The ERC20 token address for payments
    /// @param _appServerSigner The trusted App Server signer address
    /// @param _bitrefillSigner The trusted BitRefill signer address
    constructor(
        address _paymentToken,
        address _appServerSigner,
        address _bitrefillSigner
    ) {
        if (_paymentToken == address(0)) revert ZeroAddress();
        if (_appServerSigner == address(0)) revert ZeroAddress();
        if (_bitrefillSigner == address(0)) revert ZeroAddress();

        paymentToken = IERC20(_paymentToken);
        owner = msg.sender;
        appServerSigner = _appServerSigner;
        bitrefillSigner = _bitrefillSigner;
    }

    // =============================================================================
    // OWNER FUNCTIONS
    // =============================================================================

    /// @notice Creates a new raffle
    /// @dev Anyone can create a raffle with valid appServerSigner authorization
    /// @param _raffleType The type of the raffle (Donation, Profit, Incentive)
    /// @param _entryCost The cost in paymentToken for one entry
    /// @param _incentiveAmount The portion of the cost for the instant incentive (for IncentiveBased only)
    /// @param _entryLimit The number of entries at which a DonationBased raffle closes
    /// @param _deadline Timestamp after which users can claim refunds
    /// @param _signature The signature from appServerSigner authorizing this raffle creation
    function createRaffle(
        RaffleType _raffleType,
        uint256 _entryCost,
        uint256 _incentiveAmount,
        uint256 _entryLimit,
        uint256 _deadline,
        bytes calldata _signature
    ) external nonReentrant {
        if (_entryCost == 0) revert InvalidAmount();
        if (_deadline <= block.timestamp) revert InvalidAmount();
        
        if (_raffleType == RaffleType.IncentiveBased) {
            if (_incentiveAmount == 0 || _incentiveAmount >= _entryCost) revert InvalidAmount();
        }

        if (_raffleType == RaffleType.DonationBased && _entryLimit == 0) {
            revert InvalidAmount();
        }

        // Verify App Server signature for raffle creation authorization
        bytes32 messageHash = keccak256(abi.encodePacked(
            msg.sender,
            uint256(_raffleType),
            _entryCost,
            _incentiveAmount,
            _entryLimit,
            _deadline,
            nonces[appServerSigner]++
        ));
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        
        if (ethSignedMessageHash.recover(_signature) != appServerSigner) {
            revert InvalidSignature();
        }

        uint256 raffleId = nextRaffleId++;
        Raffle storage raffle = raffles[raffleId];
        
        raffle.id = raffleId;
        raffle.organizer = msg.sender;
        raffle.status = RaffleStatus.Active;
        raffle.raffleType = _raffleType;
        raffle.entryCost = _entryCost;
        raffle.incentiveAmount = _incentiveAmount;
        raffle.entryLimit = _entryLimit;
        raffle.deadline = _deadline;

        emit RaffleCreated(raffleId, msg.sender, _raffleType, _entryCost);
    }

    /// @notice Updates the trusted App Server signer address
    /// @param _newSigner The address of the new signer
    function updateAppServerSigner(address _newSigner) external onlyOwner nonReentrant validAddress(_newSigner) {
        address oldSigner = appServerSigner;
        appServerSigner = _newSigner;
        emit AppServerSignerUpdated(oldSigner, _newSigner);
    }

    /// @notice Updates the trusted BitRefill signer address
    /// @param _newSigner The address of the new signer
    function updateBitRefillSigner(address _newSigner) external onlyOwner nonReentrant validAddress(_newSigner) {
        address oldSigner = bitrefillSigner;
        bitrefillSigner = _newSigner;
        emit BitRefillSignerUpdated(oldSigner, _newSigner);
    }

    /// @notice Emergency pause function
    function pause() external onlyOwner {
        paused = true;
        emit ContractPaused(msg.sender);
    }

    /// @notice Emergency unpause function
    function unpause() external onlyOwner {
        paused = false;
        emit ContractUnpaused(msg.sender);
    }

    // =============================================================================
    // USER FUNCTIONS
    // =============================================================================

    /// @notice Enters a user into a standard (non-incentive) raffle
    /// @dev User must have approved the contract to spend `entryCost` of paymentToken
    /// @param _raffleId The ID of the raffle to enter
    function enterRaffle(uint256 _raffleId) external nonReentrant validRaffleId(_raffleId) {
        Raffle storage raffle = raffles[_raffleId];
        
        if (raffle.status != RaffleStatus.Active) revert RaffleNotActive();
        if (raffle.hasEntered[msg.sender]) revert AlreadyEntered();
        if (raffle.raffleType == RaffleType.IncentiveBased) revert InvalidRaffleType();

        // Check allowance
        if (paymentToken.allowance(msg.sender, address(this)) < raffle.entryCost) {
            revert InsufficientAllowance();
        }

        // Update raffle state
        raffle.hasEntered[msg.sender] = true;
        raffle.entryCount++;
        raffle.totalCollected += raffle.entryCost;

        // Transfer entry fee to contract (after state updates)
        if (!paymentToken.transferFrom(msg.sender, address(this), raffle.entryCost)) {
            revert TransferFailed();
        }

        // Check if DonationBased raffle should close
        if (raffle.raffleType == RaffleType.DonationBased && raffle.entryCount >= raffle.entryLimit) {
            raffle.status = RaffleStatus.Closed;
        }

        emit Entry(_raffleId, msg.sender, raffle.entryCost);
    }

    /// @notice Enters a user into an incentive-based raffle, atomically splitting the payment
    /// @dev User must approve the contract for `entryCost` (total amount)
    /// @param _raffleId The ID of the raffle to join
    /// @param _paymentAddress The destination address for the incentive portion
    /// @param _signature The signature from the App Server authorizing this action
    function joinIncentiveRaffle(
        uint256 _raffleId,
        address _paymentAddress,
        bytes calldata _signature
    ) external nonReentrant validRaffleId(_raffleId) {
        Raffle storage raffle = raffles[_raffleId];
        
        if (raffle.status != RaffleStatus.Active) revert RaffleNotActive();
        if (raffle.hasEntered[msg.sender]) revert AlreadyEntered();
        if (raffle.raffleType != RaffleType.IncentiveBased) revert InvalidRaffleType();

        // Verify App Server signature
        bytes32 messageHash = keccak256(abi.encodePacked(_raffleId, _paymentAddress, msg.sender));
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        
        if (ethSignedMessageHash.recover(_signature) != appServerSigner) {
            revert InvalidSignature();
        }

        // Check allowance for total amount
        if (paymentToken.allowance(msg.sender, address(this)) < raffle.entryCost) {
            revert InsufficientAllowance();
        }

        // Update raffle state
        raffle.hasEntered[msg.sender] = true;
        raffle.entryCount++;
        
        // Calculate amounts
        uint256 raffleAmount = raffle.entryCost - raffle.incentiveAmount;
        raffle.totalCollected += raffleAmount;

        // Transfer total amount from user to contract (after state updates)
        if (!paymentToken.transferFrom(msg.sender, address(this), raffle.entryCost)) {
            revert TransferFailed();
        }

        // Split payment: incentive portion to payment address
        if (!paymentToken.transfer(_paymentAddress, raffle.incentiveAmount)) {
            revert TransferFailed();
        }

        emit IncentiveEntry(_raffleId, msg.sender, raffleAmount, raffle.incentiveAmount, _paymentAddress);
    }

    /// @notice Allows a user to claim a refund if the raffle deadline has passed
    /// @param _raffleId The ID of the raffle to get a refund from
    function refund(uint256 _raffleId) external nonReentrant validRaffleId(_raffleId) {
        Raffle storage raffle = raffles[_raffleId];
        
        if (raffle.status != RaffleStatus.Active) revert RaffleNotActive();
        if (block.timestamp <= raffle.deadline) revert DeadlineNotPassed();
        if (!raffle.hasEntered[msg.sender]) revert AlreadyEntered();

        // Calculate refund amount first
        uint256 refundAmount;
        if (raffle.raffleType == RaffleType.IncentiveBased) {
            // For incentive raffles, only refund the raffle portion
            refundAmount = raffle.entryCost - raffle.incentiveAmount;
        } else {
            // For other raffles, refund the full entry cost
            refundAmount = raffle.entryCost;
        }

        // Update state before external call
        raffle.hasEntered[msg.sender] = false;
        raffle.entryCount--;
        raffle.totalCollected -= refundAmount;

        // Transfer refund to user
        if (!paymentToken.transfer(msg.sender, refundAmount)) {
            revert TransferFailed();
        }

        emit Refunded(_raffleId, msg.sender, refundAmount);
    }

    // =============================================================================
    // ORACLE/SERVER FUNCTIONS
    // =============================================================================

    /// @notice Ends a raffle and disburses the prize pool to a specified address
    /// @dev Must be called with a valid signature from the `bitrefillSigner`
    /// @param _raffleId The ID of the raffle to end
    /// @param _destination The address to send the prize pool to
    /// @param _signature The signature authorizing the payout
    function endRaffle(
        uint256 _raffleId,
        address _destination,
        bytes calldata _signature
    ) external nonReentrant validRaffleId(_raffleId) {
        Raffle storage raffle = raffles[_raffleId];
        
        if (raffle.status != RaffleStatus.Active && raffle.status != RaffleStatus.Closed) {
            revert RaffleNotActive();
        }

        // Verify BitRefill signature
        bytes32 messageHash = keccak256(abi.encodePacked(_raffleId, _destination, nonces[bitrefillSigner]++));
        bytes32 ethSignedMessageHash = messageHash.toEthSignedMessageHash();
        
        if (ethSignedMessageHash.recover(_signature) != bitrefillSigner) {
            revert InvalidSignature();
        }

        // Cache prize amount and update state before external call
        uint256 prizeAmount = raffle.totalCollected;
        raffle.status = RaffleStatus.Finalized;
        raffle.totalCollected = 0; // Clear the prize pool to prevent double spending
        
        // Transfer prize to destination
        if (prizeAmount > 0) {
            if (!paymentToken.transfer(_destination, prizeAmount)) {
                revert TransferFailed();
            }
        }

        emit RaffleEnded(_raffleId, _destination, prizeAmount);
    }

    // =============================================================================
    // VIEW FUNCTIONS
    // =============================================================================

    /// @notice Returns the current raffle count
    function getRaffleCount() external view returns (uint256) {
        return nextRaffleId - 1;
    }

    /// @notice Checks if a user has entered a specific raffle
    /// @param _raffleId The ID of the raffle
    /// @param _user The address of the user
    function hasUserEntered(uint256 _raffleId, address _user) external view returns (bool) {
        return raffles[_raffleId].hasEntered[_user];
    }

    /// @notice Returns basic raffle information (excluding mapping data)
    /// @param _raffleId The ID of the raffle
    function getRaffleInfo(uint256 _raffleId) external view validRaffleId(_raffleId) returns (
        uint256 id,
        address organizer,
        RaffleStatus status,
        RaffleType raffleType,
        uint256 entryCost,
        uint256 incentiveAmount,
        uint256 totalCollected,
        uint256 entryLimit,
        uint256 entryCount,
        uint256 deadline
    ) {
        Raffle storage raffle = raffles[_raffleId];
        return (
            raffle.id,
            raffle.organizer,
            raffle.status,
            raffle.raffleType,
            raffle.entryCost,
            raffle.incentiveAmount,
            raffle.totalCollected,
            raffle.entryLimit,
            raffle.entryCount,
            raffle.deadline
        );
    }

    /// @notice Returns the contract balance of payment tokens
    function getContractBalance() external view returns (uint256) {
        return paymentToken.balanceOf(address(this));
    }
}