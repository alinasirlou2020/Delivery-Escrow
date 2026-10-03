# DeliveryEscrow — Blockchain-Based Physical Delivery Escrow

## 1. Project Overview

This project is a blockchain-based **physical goods delivery escrow system** designed to connect on-chain payments with real-world product delivery.

The original prototype, `OnChainLotteryEscrow`, combines two separate concepts:

1. An on-chain lottery system using Chainlink VRF.
2. A physical-goods escrow and delivery settlement system.

The new project must **remove the entire lottery layer** and extract the delivery/payment functionality into a standalone smart contract called:

`DeliveryEscrow.sol`

The goal is to create a reusable escrow protocol where a buyer's payment is locked in a smart contract and released to the seller only when the delivery process is successfully completed.

The system should be designed to support multiple delivery methods, including:

- Human courier delivery
- Drone delivery
- Pickup-point delivery

The initial implementation should be an MVP suitable for testing and demonstration. It should not attempt to implement a complete production logistics infrastructure, GPS system, drone firmware, or a fully decentralized oracle network.

---

# 2. Main Concept

The core idea is:

**Physical delivery event → verified delivery information → cryptographic/on-chain confirmation → escrow settlement**

Instead of allowing the buyer to simply pay the seller before receiving the product, the buyer deposits the payment into the smart contract.

The smart contract temporarily holds the funds.

The seller ships the product.

A delivery system verifies that the package has reached the buyer.

The delivery system/oracle submits a delivery confirmation to the smart contract.

The smart contract then releases the funds to the seller.

If delivery fails, the seller does not ship, or a dispute occurs, the escrow remains locked until the appropriate timeout, refund, or arbitration process is executed.

---

# 3. Original Contract

The current prototype is:

`OnChainLotteryEscrow.sol`

It currently contains:

- ERC-20 payment handling
- Lottery ticket purchases
- Participant management
- Chainlink VRF v2.5
- Random winner selection
- Prize claiming
- OTP registration
- Physical item shipping
- Tracking information
- Delivery timelock
- OTP-based payment release
- Automatic payment release
- Dispute handling
- Arbiter resolution
- Lottery refunds

The new contract must preserve the useful escrow/delivery concepts while completely removing the lottery-specific architecture.

The existing factory contract is not part of the new design and does not need to be considered.

---

# 4. Architecture Transformation

The current architecture is effectively:

```text
Lottery
   ↓
Ticket Purchase
   ↓
Chainlink VRF
   ↓
Winner Selection
   ↓
Winner Claims Prize
   ↓
Seller Ships Item
   ↓
Delivery Verification
   ↓
Escrow Settlement
```

The new architecture must be:

```text
Buyer
   ↓
Create / Fund Order
   ↓
DeliveryEscrow
   ↓
Seller Ships Product
   ↓
Delivery System
   ↓
Delivery Verification
   ↓
Oracle / Attestation
   ↓
Smart Contract
   ↓
Release Payment
```

The lottery is no longer part of the system.

---

# 5. Features That Must Be Removed

The following functionality from `OnChainLotteryEscrow.sol` must be completely removed.

## Lottery configuration

Remove:

- `TICKET_PRICE`
- `MAX_TICKETS`
- `MIN_TICKETS`
- `LOTTERY_END_TIME`
- `prizeName`
- `participants`
- `winner`
- `userTicketCount`

## Chainlink VRF

Remove all Chainlink VRF dependencies and configuration:

- `VRFConsumerBaseV2Plus`
- `VRFV2PlusClient`
- `SUBSCRIPTION_ID`
- `KEY_HASH`
- `CALLBACK_GAS_LIMIT`
- `REQUEST_CONFIRMATIONS`
- `NUM_WORDS`
- `NATIVE_PAYMENT`
- `latestRequestId`
- VRF coordinator
- `fulfillRandomWords()`
- randomness request logic

## Lottery functions

Remove:

- `buyTickets()`
- `checkQuorumAndDraw()`
- `_requestRandomness()`
- `fulfillRandomWords()`
- `rerollWinnerOnTimeout()`
- `_removeFromPool()`

## Lottery-specific states

Remove states related to:

- ticket sales
- winner selection
- VRF drawing
- winner claiming

The new state machine must be delivery/order based.

---

# 6. Features to Preserve and Redesign

The following concepts from the original contract should be preserved but redesigned for a standalone delivery protocol:

- ERC-20 payment
- Seller
- Buyer
- Arbiter
- OTP hash
- Shipping deadline
- Delivery deadline
- Shipment/tracking information
- Escrowed funds
- Delivery confirmation
- Automatic release
- Refund
- Dispute
- Arbitration
- Reentrancy protection
- Safe ERC-20 transfers

The existing implementation must not simply be copied.

The new contract should be designed around independent orders rather than one lottery round.

---

# 7. Multi-Order Architecture

The original contract represents one lottery and one associated prize.

The new contract must support multiple independent delivery orders inside the same contract.

For example:

```text
Order #1
Buyer A → Seller A → Human Courier

Order #2
Buyer B → Seller B → Drone

Order #3
Buyer C → Seller D → Pickup Point
```

Therefore, seller, buyer, amount, shipment information, OTP hash, deadlines, delivery method, and state should be stored per order.

The contract should use:

```solidity
mapping(uint256 => Order) public orders;
```

with:

```solidity
uint256 public nextOrderId;
```

---

# 8. Delivery Method

The contract should support multiple delivery methods.

Use an enum such as:

```solidity
enum DeliveryMethod {
    HUMAN_COURIER,
    DRONE,
    PICKUP_POINT
}
```

This allows the smart contract to remain independent from the actual logistics implementation.

The delivery infrastructure can change without requiring a completely different escrow contract.

---

# 9. Order Structure

The main order structure should contain information similar to:

```solidity
struct Order {
    address buyer;
    address seller;

    uint256 amount;

    string shipmentId;
    string trackingInfo;

    bytes32 otpHash;

    uint256 createdAt;
    uint256 shippingDeadline;
    uint256 deliveryDeadline;

    DeliveryMethod deliveryMethod;

    State state;
}
```

The exact implementation may be optimized later for gas efficiency.

Do not store sensitive information such as the plaintext OTP on-chain.

Only its cryptographic hash should be stored.

---

# 10. State Machine

The new contract should use a delivery-oriented state machine.

Recommended states:

```solidity
enum State {
    Created,
    Funded,
    Shipped,
    OutForDelivery,
    Delivered,
    Disputed,
    Completed,
    Refunded,
    Cancelled
}
```

## Created

The order exists but the buyer has not funded the escrow yet.

```text
Created
```

## Funded

The buyer has transferred the required ERC-20 amount to the escrow contract.

```text
Created → Funded
```

## Shipped

The seller has submitted the shipment/tracking information and confirmed that the product has been shipped.

```text
Funded → Shipped
```

## OutForDelivery

The delivery system has confirmed that the package is currently in the final delivery process.

For example:

```text
Warehouse
   ↓
Drone dispatched
   ↓
OutForDelivery
```

or:

```text
Courier receives package
   ↓
OutForDelivery
```

## Delivered

The delivery system has successfully verified delivery.

This should normally be triggered by an authorized delivery oracle or attestation mechanism.

```text
OutForDelivery → Delivered
```

## Completed

The escrow has been successfully settled and the seller has received the funds.

```text
Delivered → Completed
```

## Disputed

A dispute has been raised by the buyer or another authorized party.

```text
Shipped / OutForDelivery / Delivered
                ↓
             Disputed
```

## Refunded

The buyer has received a refund.

## Cancelled

The order has been cancelled before completion.

---

# 11. Payment Token

The contract should use an ERC-20 token for payment.

The existing contract uses:

```solidity
IERC20
```

and:

```solidity
SafeERC20
```

This approach should be preserved.

The contract should have a payment token such as:

```solidity
IERC20 public immutable PAYMENT_TOKEN;
```

For the initial DotOne prototype, the intended payment asset can be DOTO.

However, the contract should not hard-code a token address into the source code.

The token address should be provided during deployment.

The actual production DOTO token address must be verified separately before deployment.

---

# 12. Escrow Flow

The basic payment lifecycle should be:

```text
Buyer
  │
  │ ERC-20 transfer
  ▼
DeliveryEscrow
  │
  │ funds locked
  ▼
Seller ships product
  │
  ▼
Delivery verification
  │
  ▼
DeliveryEscrow
  │
  │ release
  ▼
Seller
```

The buyer should not directly transfer the payment to the seller.

The smart contract must hold the funds until the settlement conditions are satisfied.

---

# 13. Order Creation

A function such as:

```solidity
createOrder(...)
```

should create an order.

The order should contain:

- Buyer
- Seller
- Amount
- Shipment ID if available
- OTP hash if used
- Delivery method
- Relevant deadlines
- Initial state

The implementation may choose whether the seller or another authorized system creates the order.

The buyer must ultimately be the party funding the escrow.

---

# 14. Funding

A function such as:

```solidity
fundOrder(uint256 orderId)
```

should allow the buyer to fund the order.

The function should:

1. Verify that the caller is the buyer.
2. Verify that the order is in the correct state.
3. Transfer ERC-20 tokens from the buyer to the contract.
4. Update the state to `Funded`.
5. Emit `OrderFunded`.

Use:

```solidity
SafeERC20.safeTransferFrom()
```

rather than manually handling ERC-20 transfers.

---

# 15. Shipping

The seller should have a function such as:

```solidity
shipOrder(
    uint256 orderId,
    string calldata trackingInfo
)
```

This replaces the original:

```solidity
shipItem()
```

The function should:

1. Verify that the caller is the seller associated with the order.
2. Verify that the order is funded.
3. Store the shipment/tracking information.
4. Set the delivery deadline.
5. Change the state from `Funded` to `Shipped`.
6. Emit `OrderShipped`.

---

# 16. Shipping Deadline

The buyer's funds must not remain locked forever if the seller never ships.

Each order should therefore have a shipping deadline.

For example:

```text
Buyer funds order
       ↓
Seller has N days to ship
       ↓
Seller fails to ship
       ↓
Buyer can request refund / escalation
```

The exact duration should be configurable or defined as an MVP constant.

The current prototype uses a five-day shipping window, but the new implementation may define this as a configurable parameter.

---

# 17. Out-for-Delivery

The new contract should have a delivery-system controlled function such as:

```solidity
markOutForDelivery(uint256 orderId)
```

This should be restricted to an authorized delivery oracle/system.

Example:

```text
Shipped
   ↓
Package loaded onto drone
   ↓
Drone dispatched
   ↓
OutForDelivery
```

For human delivery:

```text
Shipped
   ↓
Courier receives package
   ↓
OutForDelivery
```

The smart contract itself cannot directly read GPS, drone sensors, camera data, or logistics databases.

Those systems exist outside the blockchain.

---

# 18. Delivery Oracle / Attestation Layer

The project requires an off-chain bridge between physical delivery and the blockchain.

The architecture should be:

```text
Drone / Courier
       ↓
GPS / Sensors / Delivery App
       ↓
Delivery Platform
       ↓
Verification
       ↓
Oracle / Attestation
       ↓
DeliveryEscrow
```

The smart contract cannot directly access:

- GPS
- drone telemetry
- physical sensors
- cameras
- delivery databases
- mobile applications

Therefore, an authorized off-chain delivery system must submit the verified result to the blockchain.

For the MVP, this system can be represented by a simple mock oracle address.

Example:

```solidity
address public deliveryOracle;
```

with:

```solidity
modifier onlyDeliveryOracle()
```

---

# 19. Delivery Confirmation

A function such as:

```solidity
confirmDelivery(
    uint256 orderId,
    bytes calldata proof
)
```

should allow the authorized delivery oracle to confirm delivery.

For the MVP, the proof may initially be simplified.

For example:

```text
Mock Delivery Oracle
        ↓
confirmDelivery(orderId)
        ↓
Delivered
```

A more advanced implementation can later introduce signed delivery attestations.

Potential future verification inputs include:

- OTP
- GPS location
- Geofence validation
- Timestamp
- Shipment ID
- Drone delivery status
- Courier identity
- Device signature
- Delivery platform signature

The MVP should not attempt to implement all of these.

---

# 20. OTP Design

The original contract stores:

```solidity
bytes32 otpHash;
```

This concept should be preserved.

The plaintext OTP must never be stored on-chain.

Instead:

```text
OTP
 ↓
keccak256(...)
 ↓
otpHash
 ↓
stored on-chain
```

However, the new architecture should avoid the original model where:

```text
Buyer → gives OTP to Seller → Seller calls releaseWithOtp()
```

because the seller should not be the sole party proving delivery.

The preferred architecture is:

```text
Buyer
   ↓
OTP
   ↓
Delivery App / Drone Interface
   ↓
Verification
   ↓
Delivery Oracle
   ↓
Smart Contract
```

The seller should not be able to release the escrow simply because they know the OTP.

---

# 21. OTP Security

The OTP hash should preferably be bound to the order.

For example, conceptually:

```solidity
keccak256(
    abi.encodePacked(
        otp,
        orderId,
        secret
    )
)
```

The exact construction can be decided during implementation.

The important requirements are:

- Do not store plaintext OTP.
- Prevent OTP reuse across orders.
- Prevent replay between orders.
- Do not allow the seller to arbitrarily release the escrow using only the OTP.
- Avoid exposing sensitive delivery secrets through events.

---

# 22. Escrow Release

Once delivery has been successfully confirmed, the funds can be released.

Possible flow:

```text
OutForDelivery
      ↓
Delivery Confirmed
      ↓
Delivered
      ↓
Release Funds
      ↓
Completed
```

The release function must:

1. Verify the order state.
2. Verify that the order has been successfully delivered.
3. Prevent double release.
4. Transfer the escrowed ERC-20 amount to the seller.
5. Update the state.
6. Emit `EscrowReleased`.

Use:

```solidity
SafeERC20.safeTransfer()
```

and:

```solidity
nonReentrant
```

for payment settlement.

---

# 23. Automatic Release

The system should also support a timeout-based release mechanism.

For example:

```solidity
autoRelease(uint256 orderId)
```

If the delivery process has reached the appropriate stage and the configured timeout expires without a dispute, the seller can receive the escrowed funds.

The exact timing should be defined by the implementation.

Example:

```text
Delivered
   ↓
Dispute Window
   ↓
No dispute
   ↓
Auto Release
   ↓
Completed
```

The existing contract currently uses a seven-day delivery timelock, but the new architecture should separate:

- shipping deadline
- delivery deadline
- optional dispute window

rather than treating them as the same concept.

---

# 24. Failed Shipment

If the seller does not ship within the shipping deadline:

```text
Funded
   ↓
Shipping deadline expired
   ↓
Seller failed to ship
   ↓
Refund / Dispute
```

A function such as:

```solidity
reportNotShipped(uint256 orderId)
```

can allow the buyer to escalate the order.

The funds must not remain permanently locked.

---

# 25. Dispute System

The system needs an arbitration mechanism for exceptional cases.

A buyer should be able to call:

```solidity
raiseDispute(
    uint256 orderId,
    string calldata reason
)
```

The order then enters:

```text
Disputed
```

The escrow funds remain locked.

An authorized arbiter can then resolve the dispute.

---

# 26. Dispute Resolution

The arbiter can decide between:

```text
Seller receives payment
```

or:

```text
Buyer receives refund
```

A basic MVP function can be:

```solidity
resolveDispute(
    uint256 orderId,
    bool payToSeller
)
```

The arbiter must be restricted using an access-control mechanism.

The arbiter must not be able to arbitrarily withdraw unrelated orders.

---

# 27. Important Security Requirements

The contract must preserve the security practices used by the original prototype.

## Reentrancy protection

Use:

```solidity
ReentrancyGuard
```

for functions that transfer funds.

Particularly:

- `fundOrder`
- `releaseFunds`
- `autoRelease`
- `refundOrder`
- `resolveDispute`

where appropriate.

## Safe ERC-20 transfers

Use OpenZeppelin:

```solidity
SafeERC20
```

instead of raw token transfers.

## State validation

Every state-changing function must verify that the order is currently in a valid state.

For example:

```text
Funded → shipOrder()
```

must be valid.

But:

```text
Completed → shipOrder()
```

must revert.

## Access control

Different operations should have different permissions:

```text
Buyer
Seller
Delivery Oracle
Arbiter
```

must not be interchangeable.

## Replay protection

Future delivery attestations must include sufficient information to prevent replay.

A delivery proof should eventually be bound to:

- Order ID
- Contract address
- Chain ID
- Nonce or unique delivery identifier
- Delivery result
- Timestamp/deadline where appropriate

---

# 28. Events

The contract should emit events for all important lifecycle changes.

Recommended events:

```solidity
event OrderCreated(
    uint256 indexed orderId,
    address indexed buyer,
    address indexed seller,
    uint256 amount
);

event OrderFunded(
    uint256 indexed orderId,
    address indexed buyer,
    uint256 amount
);

event OrderShipped(
    uint256 indexed orderId,
    string shipmentId
);

event OutForDelivery(
    uint256 indexed orderId,
    DeliveryMethod deliveryMethod
);

event DeliveryConfirmed(
    uint256 indexed orderId
);

event EscrowReleased(
    uint256 indexed orderId,
    address indexed seller,
    uint256 amount
);

event DisputeRaised(
    uint256 indexed orderId,
    address indexed buyer,
    string reason
);

event DisputeResolved(
    uint256 indexed orderId,
    bool paidToSeller
);

event Refunded(
    uint256 indexed orderId,
    address indexed buyer,
    uint256 amount
);
```

Event parameters should be adjusted during implementation to balance usability and gas cost.

Sensitive information such as plaintext OTPs must never be emitted.

---

# 29. Recommended Contract Interfaces

The initial contract should contain functions conceptually similar to:

```solidity
createOrder(...)

fundOrder(uint256 orderId)

shipOrder(
    uint256 orderId,
    string calldata trackingInfo
)

markOutForDelivery(uint256 orderId)

confirmDelivery(
    uint256 orderId,
    bytes calldata proof
)

releaseFunds(uint256 orderId)

autoRelease(uint256 orderId)

raiseDispute(
    uint256 orderId,
    string calldata reason
)

resolveDispute(
    uint256 orderId,
    bool payToSeller
)

reportNotShipped(uint256 orderId)

refundOrder(uint256 orderId)
```

The final function signatures should be decided during implementation.

---

# 30. MVP Oracle

For the first prototype, do not build a real decentralized oracle network.

Use a simple authorized address:

```solidity
address public deliveryOracle;
```

and:

```solidity
modifier onlyDeliveryOracle()
```

The test environment can use:

```text
MockDeliveryOracle
```

This allows the complete delivery flow to be demonstrated without requiring a real drone infrastructure.

---

# 31. MVP Demonstration

The first working demo should simulate:

### Step 1 — Create Order

```text
Seller creates an order
Buyer is assigned
Amount = 100 DOTO
Delivery method = DRONE
```

### Step 2 — Fund

```text
Buyer
 ↓
100 DOTO
 ↓
DeliveryEscrow
```

### Step 3 — Ship

```text
Seller
 ↓
shipOrder()
 ↓
Shipped
```

### Step 4 — Drone Dispatch

```text
Mock Delivery Oracle
 ↓
markOutForDelivery()
 ↓
OutForDelivery
```

### Step 5 — Delivery

Simulate OTP/delivery verification.

```text
Buyer provides OTP
       ↓
Mock Delivery System
       ↓
Delivery Oracle
       ↓
confirmDelivery()
```

### Step 6 — Settlement

```text
Delivery confirmed
       ↓
Escrow released
       ↓
Seller receives DOTO
       ↓
Completed
```

### Step 7 — Failure Scenario

Also test:

```text
Buyer funds
   ↓
Seller never ships
   ↓
Deadline expires
   ↓
Buyer refund
```

### Step 8 — Dispute Scenario

Also test:

```text
Delivery
   ↓
Buyer raises dispute
   ↓
Arbiter reviews
   ↓
Seller paid OR Buyer refunded
```

---

# 32. Testing Requirements

The project should be implemented with Foundry tests.

At minimum, test:

### Order creation

- Valid order
- Zero address rejection
- Invalid amount
- Invalid parameters

### Funding

- Buyer can fund
- Non-buyer cannot fund
- Correct token amount transferred
- Cannot fund twice
- Incorrect state rejected

### Shipping

- Seller can ship
- Non-seller cannot ship
- Cannot ship before funding
- Cannot ship twice
- Tracking information stored
- Delivery deadline created

### Delivery

- Only authorized oracle can mark out-for-delivery
- Only authorized oracle can confirm delivery
- Invalid state rejected
- Delivery cannot be confirmed twice

### OTP

- Correct OTP/proof works
- Invalid OTP fails
- OTP is never stored as plaintext
- Replay attempts fail

### Settlement

- Seller receives the correct amount
- Buyer cannot withdraw seller funds
- Seller cannot withdraw early
- Funds cannot be released twice

### Timeout

- Auto-release works after deadline
- Auto-release fails before deadline
- Seller cannot exploit the timeout

### Refund

- Buyer can receive a valid refund
- Seller cannot claim the buyer's refund
- Refund cannot happen twice

### Dispute

- Buyer can raise a valid dispute
- Invalid users cannot raise disputes
- Arbiter can resolve
- Non-arbiter cannot resolve
- Seller payment path works
- Buyer refund path works

### Security

Test:

- Reentrancy
- Unauthorized access
- Invalid state transitions
- Double settlement
- Replay attacks
- Incorrect order IDs
- Zero addresses
- Zero amounts

---

# 33. Future Architecture

The MVP should be intentionally simple, but the architecture should allow future expansion.

The long-term architecture could become:

```text
                    ┌───────────────────┐
                    │     Buyer App     │
                    └─────────┬─────────┘
                              │
                              ▼
                    ┌───────────────────┐
                    │ DeliveryEscrow    │
                    │ Smart Contract    │
                    └─────────┬─────────┘
                              │
                    ┌─────────┴─────────┐
                    │                   │
                    ▼                   ▼
                 Seller             Oracle
                                      │
                         ┌────────────┼────────────┐
                         │            │            │
                         ▼            ▼            ▼
                       Drone       Courier      Pickup
                         │            │            │
                         └────────────┼────────────┘
                                      ▼
                              Delivery Platform
                                      │
                         GPS / OTP / Sensors /
                         Location / Timestamp
                                      │
                                      ▼
                                Attestation
                                      │
                                      ▼
                              DeliveryEscrow
                                      │
                                      ▼
                                  Settlement
```

---

# 34. Drone Delivery

Drone delivery is one of the primary future use cases.

However, the smart contract should not attempt to communicate directly with a drone.

The drone is an external physical system.

The correct architecture is:

```text
Drone
 ↓
Telemetry
 ↓
Delivery Platform
 ↓
Verification
 ↓
Signed Attestation
 ↓
Blockchain
 ↓
DeliveryEscrow
```

For example, the system could eventually verify:

- Correct shipment ID
- Correct destination
- Drone reached the delivery geofence
- Delivery timestamp
- OTP confirmation
- Drone successfully completed the drop-off
- No active delivery failure
- Authorized delivery device signature

Only the final verified result should be submitted to the smart contract.

---

# 35. Human Courier

The exact same escrow architecture should support human delivery.

Example:

```text
Seller
 ↓
Courier receives package
 ↓
Courier delivers package
 ↓
Buyer provides OTP
 ↓
Delivery application verifies
 ↓
Oracle submits attestation
 ↓
Escrow releases
```

This means the blockchain layer does not need to care whether the delivery agent is:

```text
Human
```

or:

```text
Drone
```

The difference exists primarily in the off-chain delivery infrastructure.

---

# 36. DotOne Integration

The project is intended as a potential use case for the DotOne ecosystem.

The initial concept is to use the DotOne blockchain and DOTO token as the settlement layer for physical commerce.

Conceptually:

```text
Buyer
  ↓
DOTO
  ↓
DotOne Smart Chain
  ↓
DeliveryEscrow
  ↓
DotOne/Postex Delivery Infrastructure
  ↓
Human Courier / Drone
  ↓
Delivery Verification
  ↓
Smart Contract
  ↓
Seller receives DOTO
```

The MVP should therefore be compatible with an EVM-compatible network and ERC-20 token architecture.

The exact DOTO token address and production network configuration must be verified before deployment.

---

# 37. Important Product Principle

The project should not be presented as merely:

> "A smart contract that releases payment when an OTP is entered."

The stronger concept is:

> **A blockchain escrow layer that connects physical delivery verification to automatic financial settlement.**

OTP is only one possible verification mechanism.

The architecture should eventually allow multiple delivery proofs to contribute to the final delivery attestation.

---

# 38. Current Scope

The immediate implementation should focus on:

1. `DeliveryEscrow.sol`
2. ERC-20 escrow
3. Multi-order architecture
4. Buyer/Seller roles
5. Delivery method abstraction
6. Shipping lifecycle
7. Mock delivery oracle
8. OTP hash support
9. Delivery confirmation
10. Automatic settlement
11. Refunds
12. Disputes
13. Arbiter
14. Events
15. Foundry unit tests
16. Security checks

Do NOT implement yet:

- Real drone firmware
- Real GPS integration
- Real logistics API
- Decentralized oracle network
- DAO governance
- Complex reputation system
- Cross-chain functionality
- Fiat payment rails
- Stablecoin conversion
- Full production identity/KYC system
- Complex zero-knowledge proofs

Those can be future modules.

---

# 39. Desired Development Approach

The implementation should be incremental.

### Phase 1

Create:

```text
DeliveryEscrow.sol
```

with:

- imports
- enums
- structs
- state variables
- custom errors
- modifiers
- events
- constructor

### Phase 2

Implement:

```text
createOrder()
fundOrder()
shipOrder()
```

### Phase 3

Implement:

```text
markOutForDelivery()
confirmDelivery()
releaseFunds()
```

using a mock delivery oracle.

### Phase 4

Implement:

```text
autoRelease()
reportNotShipped()
refundOrder()
```

### Phase 5

Implement:

```text
raiseDispute()
resolveDispute()
```

### Phase 6

Add:

- OTP verification
- replay protection
- delivery attestation structure
- stronger access control

### Phase 7

Write comprehensive Foundry tests.

### Phase 8

Deploy to a local Anvil environment.

### Phase 9

Deploy to the intended DotOne test environment only after the actual network configuration and token contract have been verified.

---

# 40. Final Goal

The final MVP should demonstrate the following complete lifecycle:

```text
             CREATE ORDER
                   │
                   ▼
                FUNDED
                   │
                   ▼
                SHIPPED
                   │
                   ▼
           OUT FOR DELIVERY
                   │
                   ▼
           DELIVERY VERIFIED
                   │
                   ▼
               DELIVERED
                   │
                   ▼
           ESCROW RELEASED
                   │
                   ▼
              COMPLETED
```

With alternative failure paths:

```text
Seller fails to ship
        ↓
      Refund
```

and:

```text
Delivery problem
        ↓
     Dispute
        ↓
     Arbiter
      ↙   ↘
 Refund   Seller Paid
```

The system should ultimately demonstrate how an EVM-compatible blockchain can act as a neutral escrow and settlement layer between a buyer, seller, and physical delivery infrastructure.

The first implementation should remain small, modular, testable, and easy to extend toward real courier and drone delivery infrastructure later.