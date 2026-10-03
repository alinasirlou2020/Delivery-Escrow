// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IDeliveryEscrow} from "./IDeliveryEscrow.sol";

/**
 * @title MockDeliveryOracle
 * @notice Stand-in for the real off-chain delivery-attestation bridge described in
 * the project README. In production, this contract's role is played by a service
 * that collects signed attestations from the delivery platform (drone telemetry,
 * courier app, pickup-point terminal, GPS/geofence checks, etc.) and forwards
 * them on-chain. For the MVP it simply forwards calls from a single trusted
 * `owner` (the "operator" running the delivery simulation), so the full order
 * lifecycle — including incidents and returns — can be demonstrated and tested
 * without any real logistics infrastructure. It never signs attestations itself;
 * that is the job of the separate `attestationSigner` key configured on
 * `DeliveryEscrow`.
 *
 * `DeliveryEscrow.deliveryOracle` must be set to the address of a deployed
 * instance of this contract (or any future, more sophisticated replacement that
 * implements the same forwarding pattern).
 *
 * @dev Each `Forwarded*` event is emitted *before* the corresponding call to
 * `ESCROW`, not after. The event itself only ever carries this call's own
 * static inputs (never anything read back from `ESCROW`), so there is nothing
 * for a reentrant call to reorder or fabricate, and if the forwarded call
 * reverts, the whole transaction — including the event — reverts with it.
 * Emitting first simply avoids flagging a false "event-after-external-call"
 * finding for a case with no actual log-integrity risk.
 */
contract MockDeliveryOracle is Ownable {
    IDeliveryEscrow public immutable ESCROW;

    event ForwardedOutForDelivery(uint256 indexed orderId);
    event ForwardedDeliveryConfirmation(uint256 indexed orderId);
    event ForwardedIncidentReport(uint256 indexed orderId, IDeliveryEscrow.IncidentType incidentType);
    event ForwardedReturnConfirmation(uint256 indexed orderId);

    constructor(address escrow, address initialOwner) Ownable(initialOwner) {
        ESCROW = IDeliveryEscrow(escrow);
    }

    /// @notice Simulates a drone dispatch / courier pickup event.
    function markOutForDelivery(uint256 orderId) external onlyOwner {
        emit ForwardedOutForDelivery(orderId);
        ESCROW.markOutForDelivery(orderId);
    }

    /// @notice Forwards a pre-signed delivery attestation to the escrow. The
    /// attestation and signature are produced off-chain by the delivery
    /// platform / attestation signer — this contract does not construct or sign
    /// them, it only relays the already-signed payload.
    function confirmDelivery(
        uint256 orderId,
        IDeliveryEscrow.DeliveryAttestation calldata attestation,
        bytes calldata signature
    ) external onlyOwner {
        emit ForwardedDeliveryConfirmation(orderId);
        ESCROW.confirmDelivery(orderId, attestation, signature);
    }

    /// @notice Simulates the delivery system reporting an operational failure it
    /// detected directly (drone failure, vehicle accident, lost package).
    function reportDeliveryIncident(
        uint256 orderId,
        IDeliveryEscrow.IncidentType incidentType,
        string calldata evidenceRef
    ) external onlyOwner {
        emit ForwardedIncidentReport(orderId, incidentType);
        ESCROW.reportDeliveryIncident(orderId, incidentType, evidenceRef);
    }

    /// @notice Simulates the delivery platform confirming a returned package has
    /// physically reached the seller.
    function confirmReturnReceived(uint256 orderId) external onlyOwner {
        emit ForwardedReturnConfirmation(orderId);
        ESCROW.confirmReturnReceived(orderId);
    }
}
