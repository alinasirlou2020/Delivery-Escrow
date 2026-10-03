# Delivery Module — Final Architecture Specification

## 1. Objective

Update the existing `DeliveryEscrow` smart contract by replacing the previous delivery/OTP architecture with the following final delivery architecture.

The existing contract already contains order, escrow, buyer, seller, payment, and possibly legacy lottery-related logic. Do not redesign unrelated parts of the contract.

The goal of this task is specifically to redesign and implement the **delivery lifecycle** as a production-oriented architecture that can handle normal delivery as well as delivery failures, damaged goods, lost shipments, wrong items, buyer rejection, returns, disputes, and refunds.

Do not create a separate simplified MVP architecture.

The architecture described below is the intended final architecture and should be implemented directly in the existing contract.

---

# 2. Core Design Principle

Every physical purchase is represented by an independent `Order`.

The contract must NOT manage delivery globally.

Use:

```solidity
mapping(uint256 => Order) public orders;
```

Each order has its own:

- buyer
- seller
- escrowed payment
- shipment ID
- delivery method
- delivery OTP hash
- delivery state
- delivery deadline
- delivery nonce
- delivery-related information

One buyer may have many orders, and every order must have its own independent delivery lifecycle.

Do NOT use a global OTP mapping such as:

```solidity
mapping(address => bytes32) userOtp;
```

Do NOT associate an OTP directly with a user.

The OTP belongs to the **order**, not to the user.

---

# 3. Final Order State Machine

Use the following main order states:

```solidity
enum State {
    Created,
    Funded,
    Shipped,
    OutForDelivery,
    Delivered,
    Disputed,
    Returning,
    Completed,
    Refunded,
    Cancelled
}
```

Do not create separate states such as:

- `DroneFailed`
- `CarCrashed`
- `PackageDamaged`
- `WrongPackage`
- `BuyerRejected`
- `CourierLost`

These are not primary order states.

Instead, they are represented as **delivery incidents** associated with an order.

The state machine must remain relatively small and stable.

---

# 4. Normal Delivery Flow

The normal successful lifecycle is:

```text
Created
   ↓
Funded
   ↓
Shipped
   ↓
OutForDelivery
   ↓
Delivered
   ↓
Completed
```

### Created

The order exists but has not been funded.

### Funded

The buyer has deposited the required payment into the escrow.

The seller's funds must remain controlled by the escrow contract.

### Shipped

The seller has handed the package to the delivery system and shipment information has been registered.

### OutForDelivery

The authorized delivery system reports that the package is actively being delivered.

### Delivered

The delivery system has submitted a valid delivery attestation.

The delivery attestation must verify the required delivery conditions, including the order/shipment identity and OTP verification.

### Completed

The delivery has been successfully accepted/finalized and the escrowed payment can be released to the seller.

---

# 5. Delivery Roles

Delivery responsibilities must be separated.

The architecture should distinguish at least:

### Buyer

The buyer can:

- view their order
- provide the delivery OTP through the off-chain delivery application
- raise a dispute
- request/accept a return where applicable

The buyer must NOT directly mark an order as delivered.

### Seller

The seller can:

- ship an order
- provide shipment information
- update information that is explicitly allowed by the contract

The seller must NOT directly mark an order as successfully delivered.

The seller must NOT control the OTP verification process.

The seller must NOT be able to release the escrow to themselves.

### Delivery Operator / Delivery Oracle

The delivery system is represented on-chain by an authorized delivery operator/oracle.

This role is responsible for submitting delivery-related attestations.

It may:

- mark an order as `OutForDelivery`
- submit a valid delivery attestation
- report delivery failures
- submit delivery-related incident information where appropriate

It must NOT arbitrarily release funds.

### Arbiter

The arbiter handles disputes.

The arbiter may resolve cases such as:

- damaged goods
- wrong item
- lost package
- disputed delivery
- buyer rejection
- return disputes
- other delivery conflicts

The arbiter must be separate from the delivery oracle.

The delivery oracle reports delivery information.

The arbiter resolves disputes.

---

# 6. Order Structure

The existing `Order` structure should be updated to contain the information required by the final delivery architecture.

Conceptually it should contain fields similar to:

```solidity
struct Order {
    address buyer;
    address seller;

    uint256 amount;

    string shipmentId;

    bytes32 deliveryOtpHash;

    DeliveryMethod deliveryMethod;

    State state;

    uint256 createdAt;

    uint256 deliveryDeadline;

    uint256 deliveryNonce;
}
```

The exact existing fields should be preserved where appropriate.

Do not blindly delete unrelated order information that is still required by the existing escrow/payment architecture.

The important requirement is that delivery-specific information is stored per order.

---

# 7. Delivery Methods

The system must support multiple physical delivery methods.

Use:

```solidity
enum DeliveryMethod {
    HUMAN_COURIER,
    DRONE,
    PICKUP_POINT
}
```

The delivery method belongs to the order.

For example:

```text
Order #1001 → DRONE
Order #1002 → HUMAN_COURIER
Order #1003 → PICKUP_POINT
```

The delivery method itself does not change the escrow logic.

The same delivery verification and dispute architecture must be reusable across all delivery methods.

---

# 8. OTP Architecture

OTP must be associated with an individual order.

The contract should store only a hash:

```solidity
bytes32 deliveryOtpHash;
```

Never store the plaintext OTP on-chain.

The OTP hash should be bound to the order to prevent reuse across different orders.

For example, conceptually:

```solidity
keccak256(
    abi.encodePacked(
        otp,
        orderId
    )
);
```

The exact hashing implementation may be improved if necessary, but the important requirements are:

1. plaintext OTP must never be stored on-chain
2. an OTP must be associated with one specific order
3. an OTP from one order must not be reusable for another order
4. the delivery verification must be bound to the correct order

---

# 9. Important OTP Design Change

Do NOT use the previous architecture where the seller provides the OTP to the contract to release payment.

The seller must never control the delivery confirmation.

The intended flow is:

```text
Buyer receives package
        ↓
Buyer provides OTP to delivery application
        ↓
Delivery system verifies OTP
        ↓
Delivery system verifies shipment/order information
        ↓
Delivery system creates a delivery attestation
        ↓
Authorized Delivery Oracle submits the attestation
        ↓
Smart contract verifies the attestation
        ↓
Order becomes Delivered
        ↓
Escrow can eventually be released
```

The buyer does not need to submit a raw OTP transaction directly to the smart contract.

The delivery system acts as the interface between the physical world and the blockchain.

---

# 10. Delivery Attestation

The smart contract cannot directly observe:

- GPS
- drone location
- vehicle accidents
- package condition
- camera footage
- courier actions
- physical package contents
- real-world delivery databases

Therefore, physical delivery information must enter the blockchain through an authorized delivery oracle.

The final architecture should use a signed delivery attestation.

Conceptually, an attestation should bind information such as:

```text
Order ID
Shipment ID
Delivery status
OTP verification result
Timestamp
Nonce
Chain ID
Contract address
```

Additional delivery information may be included where appropriate.

The attestation must be cryptographically bound to the specific order.

Use a replay-resistant design.

If EIP-712 typed structured data is used, include appropriate domain separation and order-specific values.

The delivery nonce must prevent a valid old attestation from being reused.

---

# 11. Replay Protection

Delivery attestations must not be reusable.

A delivery attestation for:

```text
Order #1001
Nonce 0
```

must not be usable again after the order has already advanced.

The contract should maintain:

```solidity
uint256 deliveryNonce;
```

or an equivalent replay-protection mechanism.

The signed data should include the relevant nonce.

After successful processing, the nonce must be invalidated or incremented.

The attestation should also be bound to:

- the specific order
- the specific contract
- the specific chain

This prevents cross-order and cross-chain replay attacks.

---

# 12. Delivery Incidents

Do not create a new primary order state for every possible delivery problem.

Instead, define a delivery incident system.

Use something conceptually similar to:

```solidity
enum IncidentType {
    DeliveryFailed,
    PackageDamaged,
    PackageLost,
    BuyerRejected,
    WrongPackage,
    Other
}
```

And:

```solidity
struct DeliveryIncident {
    IncidentType incidentType;

    address reportedBy;

    uint256 timestamp;

    string evidenceRef;

    bool resolved;
}
```

The exact structure can be adapted to the existing contract.

The important architectural principle is:

```text
Order State
+
Delivery Incident
```

For example:

```text
Order State:
Disputed

Incident:
PackageDamaged
```

or:

```text
Order State:
Disputed

Incident:
DeliveryFailed
```

Do not create:

```text
State.PackageDamaged
State.DroneFailed
State.CarCrashed
State.WrongPackage
```

---

# 13. Scenario: Successful Delivery

Flow:

```text
Funded
   ↓
Shipped
   ↓
OutForDelivery
   ↓
Delivery Attestation
   ↓
Delivered
   ↓
Completed
```

The delivery attestation must be submitted by an authorized delivery operator/oracle.

After successful completion, the escrowed funds are released according to the existing payment architecture.

The seller cannot bypass this process.

---

# 14. Scenario: Drone Failure

Example:

The drone leaves the warehouse but fails during the journey.

The drone system reports:

```text
Delivery failed
```

Do not create:

```text
DroneFailed
```

Instead:

```text
OutForDelivery
      ↓
Delivery Incident
      ↓
Disputed
```

The incident type is:

```solidity
DeliveryFailed
```

The escrow remains locked.

The system can then resolve the case through the appropriate process.

Possible outcomes:

```text
Refund buyer
```

or:

```text
Reship / retry delivery
```

or another resolution defined by the business rules.

The smart contract must not automatically assume that a drone failure means the seller is at fault.

---

# 15. Scenario: Vehicle Accident

If a courier vehicle crashes:

```text
OutForDelivery
      ↓
DeliveryFailed Incident
      ↓
Disputed
```

The delivery system may submit evidence/reference information.

The funds remain in escrow.

The arbiter or predefined dispute logic determines the final financial outcome.

Do not automatically pay the seller merely because the seller successfully shipped the package.

---

# 16. Scenario: Package Lost

If the package is lost:

```text
OutForDelivery
      ↓
DeliveryFailed / PackageLost Incident
      ↓
Disputed
```

The order must not become `Completed`.

The funds remain protected.

The dispute can eventually resolve to:

```text
Refunded
```

or another approved resolution such as a reshipment.

---

# 17. Scenario: Package Damaged

If the package reaches the buyer but is physically damaged:

```text
Delivered
      ↓
Buyer detects damage
      ↓
Disputed
```

The escrow must remain protected.

The buyer can raise a dispute.

The dispute should contain an incident such as:

```solidity
PackageDamaged
```

Evidence should remain off-chain.

For example:

- photos
- videos
- courier records
- inspection reports
- delivery logs

Do not store large media files directly on-chain.

Store only a reference/hash where appropriate.

---

# 18. Scenario: Wrong Product

If the seller shipped the wrong item:

```text
Delivered
      ↓
Buyer disputes
      ↓
Disputed
```

Incident:

```solidity
WrongPackage
```

The arbiter resolves the dispute.

Possible resolution:

```text
Return item
   ↓
Returned
   ↓
Refunded
```

The smart contract itself cannot determine whether the physical product is actually correct, so this must be handled by the dispute mechanism.

---

# 19. Scenario: Buyer Rejects Delivery

If the buyer refuses the package, do not automatically treat the refusal as fraud or as a seller failure.

The system should distinguish between:

### Valid rejection

Examples:

- visibly damaged package
- wrong product
- order mismatch
- other valid business rule

→ `Disputed`

### Unjustified refusal

If the delivery system confirms that the correct package was delivered and the buyer simply refused it, the platform's return/refusal policy determines the result.

The smart contract should support the resulting state transition without hardcoding assumptions about physical responsibility.

---

# 20. Scenario: Return to Seller

If a return is approved:

```text
Disputed
    ↓
Returning
    ↓
Returned
```

The escrow must remain locked while the return is in progress.

Once the return is confirmed:

```text
Returned
    ↓
Refunded
```

The buyer receives the refund according to the existing escrow/payment architecture.

---

# 21. Scenario: Return Shipment Is Lost

If the package is lost during the return:

```text
Returning
    ↓
Delivery Incident
    ↓
Disputed
```

The contract must not automatically refund or pay the seller without a valid resolution.

The arbiter resolves the dispute according to the platform's rules and available evidence.

---

# 22. Scenario: Delivery Delayed

A delivery may be delayed without being permanently lost.

Do not create a permanent state such as:

```text
Delayed
```

unless the existing business requirements specifically require it.

A delay should normally remain:

```text
Shipped
```

or:

```text
OutForDelivery
```

while the delivery deadline is monitored.

If the deadline expires and the delivery has not been completed, the appropriate failure/dispute process should be triggered.

---

# 23. Delivery Deadline

Every order should have a delivery deadline:

```solidity
uint256 deliveryDeadline;
```

The contract must be able to determine whether delivery has exceeded the allowed time.

After expiration, the system should prevent inappropriate automatic release of the escrow.

The exact timeout behavior should be implemented according to the existing escrow rules, but the key security requirement is:

> A seller must never receive the escrow merely because a delivery deadline expired if the delivery itself has not been successfully verified.

---

# 24. Automatic Release

Automatic release must only happen under clearly defined conditions.

A simple timeout must not automatically mean:

```text
Seller gets paid
```

The safest logic is:

```text
Valid delivery confirmation
        ↓
Delivered
        ↓
Completion conditions satisfied
        ↓
Release
```

If the delivery fails or a dispute exists:

```text
Do NOT release seller funds automatically.
```

---

# 25. Arbiter Resolution

The arbiter must be able to resolve disputes without breaking the escrow accounting.

Conceptually, the arbiter may resolve a dispute by:

### Refund Buyer

```text
Disputed
   ↓
Refunded
```

### Approve Seller Payment

```text
Disputed
   ↓
Completed
```

### Approve Return

```text
Disputed
   ↓
Returning
```

The exact functions and parameters should enforce strict state validation.

The arbiter must not be able to withdraw arbitrary funds from unrelated orders.

---

# 26. Return and Refund Safety

A refund must only be possible once.

A seller payment must only be possible once.

The contract must prevent:

- double refund
- refund after seller payment
- seller payment after refund
- duplicate delivery confirmation
- duplicate dispute resolution
- replayed delivery attestations

Use strict state checks and the existing `ReentrancyGuard` / `SafeERC20` architecture where applicable.

---

# 27. Events

The delivery system should emit clear events for off-chain systems.

At minimum, support events conceptually similar to:

```solidity
OrderShipped
OutForDelivery
DeliveryConfirmed
DeliveryIncidentReported
DisputeRaised
ReturnStarted
OrderReturned
DisputeResolved
EscrowReleased
Refunded
```

Events should contain the relevant `orderId`.

Where useful, include:

- shipment ID
- actor
- timestamp
- incident type
- resolution type

Do not put sensitive personal information in events.

---

# 28. Evidence

Physical evidence must remain off-chain.

Do NOT store:

- photos
- videos
- GPS history
- customer address
- phone number
- national ID
- private customer information

directly on the blockchain.

Instead, use an off-chain storage system and optionally store:

```text
evidence reference
```

or:

```text
content hash
```

on-chain.

The smart contract should only store the minimum information necessary for verification, accountability, and dispute resolution.

---

# 29. Security Requirements

The delivery implementation must enforce:

1. Strict state transitions.
2. Role-based access control.
3. Authorized delivery oracle only.
4. Separate arbiter role.
5. No seller-controlled delivery confirmation.
6. No plaintext OTP on-chain.
7. Order-bound OTP verification.
8. Replay protection for delivery attestations.
9. Protection against duplicate refunds.
10. Protection against duplicate seller payouts.
11. Reentrancy protection.
12. Safe ERC20 transfers.
13. No automatic seller payout when delivery failed.
14. No automatic seller payout while an order is disputed.
15. No modification of unrelated orders.
16. No arbitrary arbiter withdrawal.
17. No reuse of a delivery attestation.
18. No cross-order OTP reuse.

---

# 30. Final Architecture Summary

The final delivery architecture should follow this model:

```text
                    BUYER
                      │
                      │ OTP
                      ↓
              DELIVERY PLATFORM
                      │
       ┌──────────────┼──────────────┐
       │              │              │
      Drone         Courier      Pickup Point
       │              │              │
       └──────────────┼──────────────┘
                      ↓
              Delivery Verification
                      │
          OTP + Shipment + Delivery Data
                      ↓
              Delivery Attestation
                      ↓
             DELIVERY ORACLE
                      │
                      ↓
              DeliveryEscrow
                      │
        ┌─────────────┴─────────────┐
        │                           │
    Successful                    Failure
        │                           │
        ↓                           ↓
   Delivered                    Incident
        │                           │
        ↓                           ↓
   Completed                    Disputed
        │                    ┌──────┼──────┐
        ↓                    │      │      │
   Seller Paid             Refund  Return  Seller Paid
                                  │
                                  ↓
                              Returning
                                  │
                                  ↓
                               Returned
                                  │
                                  ↓
                               Refunded
```

---

# 31. Implementation Instruction

You are modifying an existing Solidity contract.

Do NOT create a completely separate unrelated contract unless necessary.

First inspect the existing contract and identify:

- current `Order` structure
- current state enum
- current delivery functions
- current OTP logic
- current shipment logic
- current escrow release logic
- current dispute logic
- current access control
- current payment transfer logic

Then refactor the existing delivery architecture to match this specification.

Preserve compatible existing functionality where it does not conflict with this architecture.

Remove or replace legacy delivery logic that conflicts with this specification.

Do not introduce a new architectural model.

Do not create multiple competing implementations.

Do not simplify the architecture into an MVP-only solution.

The resulting code must be structured so it can be compiled, tested, fuzz-tested, and audited after implementation.

Before changing unrelated parts of the contract, clearly identify whether the change is required by the delivery architecture.

The final implementation must preserve the separation between:

```text
Order Management
Escrow / Payment
Delivery Verification
Delivery Incidents
Disputes
Returns
Refunds
Access Control
```

The delivery module must be deterministic on-chain while relying on an authorized delivery oracle/attestation layer for real-world delivery information.