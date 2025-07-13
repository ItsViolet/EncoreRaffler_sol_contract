// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/VRFConsumerBaseV2_5.sol";
import "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

/**
 * @title EncoreRafflerV5
 * @dev Smart contract for managing various types of raffles with VRF 2.5 support
 * @author Encore Team
 * @notice This contract facilitates trustless raffles with Chainlink VRF 2.5 for randomness
 */
contract EncoreRafflerV5 is ReentrancyGuard, EIP712, VRFConsumerBaseV2_5 {
    using ECDSA for bytes32;

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
        Inactive,       // Not created or does not exist
        Active,         // Open and accepting entries
        Closed,         // Ended, awaiting winner selection
        AwaitingVRF,    // Waiting for Chainlink VRF response
        Finalized       // Winner selected and prize paid out
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
        uint256 targetAmount;       // For pool raffles: target amount to reach
        bool isPool;                // If true, allows flexible refunds and early ending
        uint256 vrfRequestId;       // Chainlink VRF request ID
        uint256 winnerIndex;        // Index of the winner (1-based)
        address payoutAddress;      // Address to receive the prize
        mapping(address => bool) hasEntered; // Tracks entrants to prevent double-entry
    }

    /// @notice VRF request tracking
    struct VRFRequest {
        uint256 raffleId;
        bool fulfilled;
    }

    // =============================================================================
    // STATE VARIABLES
    // =============================================================================

    /// @notice The ERC20 token used for all payments (e.g., USDC)
    IERC20 public immutable paymentToken;

    /// @notice The privileged contract owner
    address public owner;

    /// @notice The trusted address for the App Server to authorize operations
    address public appServerSigner;

    /// @notice Mapping from raffle ID to the Raffle struct
    mapping(uint256 => Raffle) public raffles;

    /// @notice Mapping from VRF request ID to VRF request info
    mapping(uint256 => VRFRequest) public vrfRequests;

    /// @notice Counter for generating unique raffle IDs
    uint256 private nextRaffleId = 1;

    /// @notice Emergency pause mechanism
    bool public paused = false;

    /// @notice Grace period after deadline for refunds (1 hour)
    uint256 public constant REFUND_GRACE_PERIOD = 3600;

    // =============================================================================
    // VRF 2.5 CONFIGURATION
    // =============================================================================

    /// @notice Chainlink VRF Coordinator
    address public immutable vrfCoordinator;

    /// @notice VRF subscription ID
    uint256 public immutable subscriptionId;

    /// @notice Key hash for VRF requests
    bytes32 public immutable keyHash;

    /// @notice Callback gas limit for VRF
    uint32 public constant CALLBACK_GAS_LIMIT = 100000;

    /// @notice Number of confirmations for VRF
    uint16 public constant REQUEST_CONFIRMATIONS = 3;

    /// @notice Number of random words to request
    uint32 public constant NUM_WORDS = 1;

    /// @notice Whether to enable native payment for VRF
    bool public constant ENABLE_NATIVE_PAYMENT = false;

    // =============================================================================
    // EIP-712 CONSTANTS
    // =============================================================================

    bytes32 private constant CREATE_RAFFLE_TYPEHASH = keccak256(
        "CreateRaffle(address organizer,uint8 raffleType,uint256 entryCost,uint256 incentiveAmount,uint256 entryLimit,uint256 deadline,uint256 targetAmount,bool isPool,address payoutAddress,uint256 nonce)"
    );

    bytes32 private constant INCENTIVE_ENTRY_TYPEHASH = keccak256(
        "IncentiveEntry(uint256 raffleId,address user,address paymentAddress,uint256 nonce)"
    );

    bytes32 private constant END_RAFFLE_TYPEHASH = keccak256(
        "EndRaffle(uint256 raffleId,address caller,uint256 nonce)"
    );

    /// @notice Nonces for signature replay protection
    mapping(address => uint256) public nonces;

    // =============================================================================
    // EVENTS
    // =============================================================================

    event RaffleCreated(uint256 indexed raffleId, address indexed organizer, RaffleType raffleType, uint256 entryCost, bool isPool);
    event Entry(uint256 indexed raffleId, address indexed user, uint256 amount);
    event IncentiveEntry(uint256 indexed raffleId, address indexed user, uint256 raffleAmount, uint256 incentiveAmount, address incentiveDestination);
    event RaffleClosed(uint256 indexed raffleId);
    event VRFRequested(uint256 indexed raffleId, uint256 indexed requestId);
    event WinnerSelected(uint256 indexed raffleId, uint256 winnerIndex, address payoutAddress, uint256 prizeAmount);
    event PoolRaffleFinalized(uint256 indexed raffleId, address payoutAddress, uint256 prizeAmount);
    event Refunded(uint256 indexed raffleId, address indexed user, uint256 refundAmount);
    event AppServerSignerUpdated(address indexed oldSigner, address indexed newSigner);
    event ContractPaused(address indexed by);
    event ContractUnpaused(address indexed by);

    // =============================================================================
    // CUSTOM ERRORS
    // =============================================================================

    error InvalidSigner();
    error InvalidSignature();
    error RaffleNotActive();
    error DeadlineNotPassed();
    error GracePeriodNotPassed();
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
    error VRFRequestNotFound();
    error RaffleNotAwaitingVRF();
    error CannotEndPoolEarly();
    error InvalidRefundConditions();

    // =============================================================================
    // MODIFIERS
    // =============================================================================

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier validAddress(address _addr) {
        if (_addr == address(0)) revert ZeroAddress();
        _;
    }

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

    /// @notice Initializes the contract with payment token, signers, and VRF configuration
    /// @param _paymentToken The ERC20 token address for payments
    /// @param _appServerSigner The trusted App Server signer address
    /// @param _vrfCoordinator Chainlink VRF Coordinator address
    /// @param _subscriptionId VRF subscription ID
    /// @param _keyHash VRF key hash
    constructor(
        address _paymentToken,
        address _appServerSigner,
        address _vrfCoordinator,
        uint256 _subscriptionId,
        bytes32 _keyHash
    ) 
        EIP712("EncoreRafflerV5", "1")
        VRFConsumerBaseV2_5(_vrfCoordinator)
    {
        if (_paymentToken == address(0)) revert ZeroAddress();
        if (_appServerSigner == address(0)) revert ZeroAddress();
        if (_vrfCoordinator == address(0)) revert ZeroAddress();

        paymentToken = IERC20(_paymentToken);
        owner = msg.sender;
        appServerSigner = _appServerSigner;
        vrfCoordinator = _vrfCoordinator;
        subscriptionId = _subscriptionId;
        keyHash = _keyHash;
    }

    // =============================================================================
    // OWNER FUNCTIONS
    // =============================================================================

    /// @notice Updates the trusted App Server signer address
    /// @param _newSigner The address of the new signer
    function updateAppServerSigner(address _newSigner) external onlyOwner nonReentrant validAddress(_newSigner) {
        address oldSigner = appServerSigner;
        appServerSigner = _newSigner;
        emit AppServerSignerUpdated(oldSigner, _newSigner);
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
    // RAFFLE CREATION
    // =============================================================================

    /// @notice Creates a new raffle with App Server authorization
    /// @param _raffleType The type of the raffle
    /// @param _entryCost The cost in paymentToken for one entry
    /// @param _incentiveAmount The portion for instant incentive (IncentiveBased only)
    /// @param _entryLimit The number of entries for DonationBased raffles
    /// @param _deadline Timestamp after which users can claim refunds
    /// @param _targetAmount Target amount for pool raffles
    /// @param _isPool Whether this is a pool raffle
    /// @param _payoutAddress Address to receive the prize
    /// @param _signature The signature from appServerSigner
    function createRaffle(
        RaffleType _raffleType,
        uint256 _entryCost,
        uint256 _incentiveAmount,
        uint256 _entryLimit,
        uint256 _deadline,
        uint256 _targetAmount,
        bool _isPool,
        address _payoutAddress,
        bytes calldata _signature
    ) external nonReentrant whenNotPaused validAddress(_payoutAddress) {
        if (_entryCost == 0) revert InvalidAmount();
        if (_deadline <= block.timestamp) revert InvalidAmount();
        
        if (_raffleType == RaffleType.IncentiveBased) {
            if (_incentiveAmount == 0 || _incentiveAmount >= _entryCost) revert InvalidAmount();
        }

        if (_raffleType == RaffleType.DonationBased && _entryLimit == 0) {
            revert InvalidAmount();
        }

        if (_isPool && _targetAmount == 0) {
            revert InvalidAmount();
        }

        // Verify App Server signature
        bytes32 structHash = keccak256(abi.encode(
            CREATE_RAFFLE_TYPEHASH,
            msg.sender,
            uint8(_raffleType),
            _entryCost,
            _incentiveAmount,
            _entryLimit,
            _deadline,
            _targetAmount,
            _isPool,
            _payoutAddress,
            nonces[msg.sender]++
        ));
        
        bytes32 hash = _hashTypedDataV4(structHash);
        if (hash.recover(_signature) != appServerSigner) {
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
        raffle.targetAmount = _targetAmount;
        raffle.isPool = _isPool;
        raffle.payoutAddress = _payoutAddress;

        emit RaffleCreated(raffleId, msg.sender, _raffleType, _entryCost, _isPool);
    }

    // =============================================================================
    // USER FUNCTIONS
    // =============================================================================

    /// @notice Enters a user into a standard (non-incentive) raffle
    /// @param _raffleId The ID of the raffle to enter
    function enterRaffle(uint256 _raffleId) external nonReentrant whenNotPaused validRaffleId(_raffleId) {
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

        // Transfer entry fee to contract
        if (!paymentToken.transferFrom(msg.sender, address(this), raffle.entryCost)) {
            revert TransferFailed();
        }

        // Check if raffle should close
        bool shouldClose = false;
        
        if (raffle.raffleType == RaffleType.DonationBased && raffle.entryCount >= raffle.entryLimit) {
            shouldClose = true;
        } else if (raffle.isPool && raffle.totalCollected >= raffle.targetAmount) {
            shouldClose = true;
        }

        if (shouldClose) {
            raffle.status = RaffleStatus.Closed;
            emit RaffleClosed(_raffleId);
        }

        emit Entry(_raffleId, msg.sender, raffle.entryCost);
    }

    /// @notice Enters a user into an incentive-based raffle with payment splitting
    /// @param _raffleId The ID of the raffle to join
    /// @param _paymentAddress The destination address for the incentive portion
    /// @param _signature The signature from the App Server
    function joinIncentiveRaffle(
        uint256 _raffleId,
        address _paymentAddress,
        bytes calldata _signature
    ) external nonReentrant whenNotPaused validRaffleId(_raffleId) validAddress(_paymentAddress) {
        Raffle storage raffle = raffles[_raffleId];
        
        if (raffle.status != RaffleStatus.Active) revert RaffleNotActive();
        if (raffle.hasEntered[msg.sender]) revert AlreadyEntered();
        if (raffle.raffleType != RaffleType.IncentiveBased) revert InvalidRaffleType();

        // Verify App Server signature
        bytes32 structHash = keccak256(abi.encode(
            INCENTIVE_ENTRY_TYPEHASH,
            _raffleId,
            msg.sender,
            _paymentAddress,
            nonces[msg.sender]++
        ));
        
        bytes32 hash = _hashTypedDataV4(structHash);
        if (hash.recover(_signature) != appServerSigner) {
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

        // Transfer total amount from user to contract
        if (!paymentToken.transferFrom(msg.sender, address(this), raffle.entryCost)) {
            revert TransferFailed();
        }

        // Transfer incentive portion to payment address
        if (!paymentToken.transfer(_paymentAddress, raffle.incentiveAmount)) {
            revert TransferFailed();
        }

        // Check if pool raffle should close
        if (raffle.isPool && raffle.totalCollected >= raffle.targetAmount) {
            raffle.status = RaffleStatus.Closed;
            emit RaffleClosed(_raffleId);
        }

        emit IncentiveEntry(_raffleId, msg.sender, raffleAmount, raffle.incentiveAmount, _paymentAddress);
    }

    /// @notice Allows users to claim refunds under specific conditions
    /// @param _raffleId The ID of the raffle to get a refund from
    function refund(uint256 _raffleId) external nonReentrant whenNotPaused validRaffleId(_raffleId) {
        Raffle storage raffle = raffles[_raffleId];
        
        if (!raffle.hasEntered[msg.sender]) revert AlreadyEntered();

        // Check refund conditions
        if (raffle.isPool) {
            // Pool raffles: can refund anytime if still active
            if (raffle.status != RaffleStatus.Active) revert InvalidRefundConditions();
        } else {
            // Traditional raffles: can only refund after deadline + grace period
            if (raffle.status != RaffleStatus.Active) revert RaffleNotActive();
            if (block.timestamp <= raffle.deadline + REFUND_GRACE_PERIOD) revert GracePeriodNotPassed();
        }

        // Calculate refund amount
        uint256 refundAmount;
        if (raffle.raffleType == RaffleType.IncentiveBased) {
            refundAmount = raffle.entryCost - raffle.incentiveAmount;
        } else {
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
    // RAFFLE ENDING FUNCTIONS
    // =============================================================================

    /// @notice Ends a raffle and initiates winner selection
    /// @param _raffleId The ID of the raffle to end
    /// @param _signature Optional signature from appServerSigner (required for organizer)
    function endRaffle(uint256 _raffleId, bytes calldata _signature) external nonReentrant whenNotPaused validRaffleId(_raffleId) {
        Raffle storage raffle = raffles[_raffleId];
        
        if (raffle.status != RaffleStatus.Active && raffle.status != RaffleStatus.Closed) {
            revert RaffleNotActive();
        }

        bool isAppServer = msg.sender == appServerSigner;
        bool isOrganizer = msg.sender == raffle.organizer;
        
        if (!isAppServer && !isOrganizer) {
            revert InvalidSigner();
        }

        // Check timing conditions
        if (!isAppServer) {
            if (raffle.isPool) {
                // Pool raffles: organizer can end early only if target reached
                if (raffle.totalCollected < raffle.targetAmount && block.timestamp < raffle.deadline) {
                    revert CannotEndPoolEarly();
                }
            } else {
                // Traditional raffles: organizer needs to wait for deadline
                if (block.timestamp < raffle.deadline) {
                    revert DeadlineNotPassed();
                }
            }
        }

        // Verify signature if organizer is calling
        if (isOrganizer) {
            bytes32 structHash = keccak256(abi.encode(
                END_RAFFLE_TYPEHASH,
                _raffleId,
                msg.sender,
                nonces[msg.sender]++
            ));
            
            bytes32 hash = _hashTypedDataV4(structHash);
            if (hash.recover(_signature) != appServerSigner) {
                revert InvalidSignature();
            }
        }

        // Handle pool raffles directly
        if (raffle.isPool) {
            _finalizePoolRaffle(_raffleId);
        } else {
            // Request VRF for traditional raffles
            _requestVRF(_raffleId);
        }
    }

    /// @notice Internal function to finalize pool raffles without VRF
    /// @param _raffleId The ID of the pool raffle to finalize
    function _finalizePoolRaffle(uint256 _raffleId) internal {
        Raffle storage raffle = raffles[_raffleId];
        
        uint256 prizeAmount = raffle.totalCollected;
        raffle.status = RaffleStatus.Finalized;
        raffle.totalCollected = 0;
        
        // Transfer prize to payout address
        if (prizeAmount > 0) {
            if (!paymentToken.transfer(raffle.payoutAddress, prizeAmount)) {
                revert TransferFailed();
            }
        }

        emit PoolRaffleFinalized(_raffleId, raffle.payoutAddress, prizeAmount);
    }

    /// @notice Internal function to request VRF for winner selection
    /// @param _raffleId The ID of the raffle
    function _requestVRF(uint256 _raffleId) internal {
        Raffle storage raffle = raffles[_raffleId];
        
        if (raffle.entryCount == 0) {
            // No entries, finalize with no winner
            raffle.status = RaffleStatus.Finalized;
            emit WinnerSelected(_raffleId, 0, raffle.payoutAddress, 0);
            return;
        }

        // Request randomness from Chainlink VRF 2.5
        uint256 requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: keyHash,
                subId: subscriptionId,
                requestConfirmations: REQUEST_CONFIRMATIONS,
                callbackGasLimit: CALLBACK_GAS_LIMIT,
                numWords: NUM_WORDS,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({
                        nativePayment: ENABLE_NATIVE_PAYMENT
                    })
                )
            })
        );

        raffle.vrfRequestId = requestId;
        raffle.status = RaffleStatus.AwaitingVRF;
        
        vrfRequests[requestId] = VRFRequest({
            raffleId: _raffleId,
            fulfilled: false
        });

        emit VRFRequested(_raffleId, requestId);
    }

    /// @notice Callback function for Chainlink VRF 2.5
    /// @param _requestId The VRF request ID
    /// @param _randomWords Array of random words from VRF
    function fulfillRandomWords(uint256 _requestId, uint256[] calldata _randomWords) internal override {
        VRFRequest storage request = vrfRequests[_requestId];
        
        if (request.raffleId == 0) revert VRFRequestNotFound();
        if (request.fulfilled) return; // Already fulfilled
        
        request.fulfilled = true;
        
        Raffle storage raffle = raffles[request.raffleId];
        if (raffle.status != RaffleStatus.AwaitingVRF) revert RaffleNotAwaitingVRF();

        // Calculate winner index (1-based)
        uint256 winnerIndex = (_randomWords[0] % raffle.entryCount) + 1;
        raffle.winnerIndex = winnerIndex;
        
        // Finalize raffle
        uint256 prizeAmount = raffle.totalCollected;
        raffle.status = RaffleStatus.Finalized;
        raffle.totalCollected = 0;
        
        // Transfer prize to payout address
        if (prizeAmount > 0) {
            if (!paymentToken.transfer(raffle.payoutAddress, prizeAmount)) {
                revert TransferFailed();
            }
        }

        emit WinnerSelected(request.raffleId, winnerIndex, raffle.payoutAddress, prizeAmount);
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

    /// @notice Returns complete raffle information
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
        uint256 deadline,
        uint256 targetAmount,
        bool isPool,
        uint256 winnerIndex,
        address payoutAddress
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
            raffle.deadline,
            raffle.targetAmount,
            raffle.isPool,
            raffle.winnerIndex,
            raffle.payoutAddress
        );
    }

    /// @notice Checks if a pool raffle can end early
    /// @param _raffleId The ID of the raffle
    function canEndPoolEarly(uint256 _raffleId) external view validRaffleId(_raffleId) returns (bool) {
        Raffle storage raffle = raffles[_raffleId];
        return raffle.isPool && 
               raffle.status == RaffleStatus.Active && 
               raffle.totalCollected >= raffle.targetAmount;
    }

    /// @notice Returns the contract balance of payment tokens
    function getContractBalance() external view returns (uint256) {
        return paymentToken.balanceOf(address(this));
    }

    /// @notice Returns VRF request information
    /// @param _requestId The VRF request ID
    function getVRFRequest(uint256 _requestId) external view returns (uint256 raffleId, bool fulfilled) {
        VRFRequest storage request = vrfRequests[_requestId];
        return (request.raffleId, request.fulfilled);
    }
}