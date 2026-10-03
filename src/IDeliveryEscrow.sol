// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IDeliveryEscrow
 * @notice External interface exposed to the delivery-oracle layer and to any
 * off-chain service that needs to construct or verify delivery attestations. Kept
 * separate from the implementation so the oracle side (a single trusted address
 * today, a signature-verifying relayer or a decentralized attestation network
 * tomorrow) can evolve without ever touching this ABI surface.
 */
interface IDeliveryEscrow {
    enum DeliveryMethod {
        HUMAN_COURIER,
        DRONE,
        PICKUP_POINT
    }

    /// @notice Final delivery state machine (Section 3 of the architecture spec).
    /// Intentionally small and stable — real-world failure modes are represented
    /// as `DeliveryIncident` records attached to an order, never as extra states.
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

    /// @notice Delivery incidents are attached to an order rather than modeled as
    /// dedicated states (Section 12). `Other` exists as an escape hatch for
    /// failure modes not enumerated here, so this enum never needs a breaking
    /// change for a new real-world edge case.
    enum IncidentType {
        DeliveryFailed,
        PackageDamaged,
        PackageLost,
        BuyerRejected,
        WrongPackage,
        Other
    }

    /// @notice How an arbiter may resolve a `Disputed` order (Section 25).
    /// `Reship` covers the "reship / retry delivery" outcome called out in
    /// Section 14 for cases like a drone failure where the goods themselves were
    /// never lost or damaged and a second delivery attempt is the appropriate fix
    /// — escrow stays fully locked and untouched, only the delivery sub-flow
    /// restarts.
    enum DisputeResolution {
        RefundBuyer,
        PaySeller,
        ApproveReturn,
        Reship
    }

    struct DeliveryIncident {
        IncidentType incidentType;
        address reportedBy;
        uint256 timestamp;
        string evidenceRef; // off-chain reference/hash only — never raw evidence
        bool resolved;
    }

    /// @notice EIP-712 typed payload the delivery platform signs off-chain and the
    /// delivery oracle submits on-chain. Binds delivery status + OTP verification
    /// result to one specific order, shipment, chain and contract, and carries a
    /// per-order nonce so a captured attestation can never be replayed once the
    /// order has moved on (Sections 10-11).
    struct DeliveryAttestation {
        uint256 orderId;
        bytes32 shipmentIdHash; // keccak256(bytes(order.shipmentId))
        bytes32 otpCommitment; // must equal order.deliveryOtpHash; bytes32(0) if unused
        bool delivered;
        uint256 nonce; // must equal order.deliveryNonce at submission time
        uint256 timestamp;
        uint256 chainId;
        address escrowContract;
    }

    function markOutForDelivery(uint256 orderId) external;

    function confirmDelivery(uint256 orderId, DeliveryAttestation calldata attestation, bytes calldata signature)
        external;

    function reportDeliveryIncident(uint256 orderId, IncidentType incidentType, string calldata evidenceRef) external;

    function confirmReturnReceived(uint256 orderId) external;

    function orderState(uint256 orderId) external view returns (State);
}
