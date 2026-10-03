// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {IDeliveryEscrow} from "./IDeliveryEscrow.sol";

/**
 * @title DeliveryEscrow
 * @notice Multi-order, ERC-20 payment escrow for physical-goods delivery,
 * implementing the final delivery architecture: normal delivery, delivery
 * incidents (failures, damage, loss, wrong item, buyer rejection), disputes,
 * returns and refunds — all built around one small, stable state machine plus a
 * per-order incident log, per the "Final Delivery Architecture Specification".
 *
 * @dev Genealogy: this is a direct descendant of `OnChainLotteryEscrow` (lottery /
 * VRF logic fully removed) that was first generalized into a multi-order MVP
 * escrow, and is now upgraded in place to the final delivery architecture
 * described in the spec. Order management, escrow/payment, delivery
 * verification, incidents, disputes, returns/refunds and access control are kept
 * as clearly separated concerns within this single contract (Section 31).
 *
 * The contract never observes the physical world directly (GPS, drone telemetry,
 * package condition, courier actions). All real-world delivery information
 * enters on-chain exclusively through the authorized `deliveryOracle` address,
 * and the terminal delivery confirmation additionally requires a valid EIP-712
 * signature from a separate `attestationSigner` key over a replay-protected,
 * order-bound `DeliveryAttestation` — decoupling "who may submit the
 * transaction" from "who cryptographically vouches for the delivery result".
 */
contract DeliveryEscrow is ReentrancyGuard, Ownable, EIP712, IDeliveryEscrow {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;

    // ============================================================
    // Custom errors
    // ============================================================
    error InvalidZeroAddress();
    error InvalidAmount();
    error BuyerSellerSame();
    error OrderDoesNotExist();
    error InvalidState();
    error NotBuyer();
    error NotSeller();
    error NotDeliveryOracle();
    error NotArbiter();
    error NotBuyerOrSeller();
    error ShippingWindowNotExpired();
    error DeliveryWindowNotExpired();
    error DisputeWindowNotExpired();
    error ReturnWindowNotExpired();
    error DeliveryProofInvalid();
    error AttestationMismatch();
    error InvalidNonce();
    error InvalidSignature();

    // ============================================================
    // EIP-712 typed data
    // ============================================================

    bytes32 private constant DELIVERY_ATTESTATION_TYPEHASH = keccak256(
        "DeliveryAttestation(uint256 orderId,bytes32 shipmentIdHash,bytes32 otpCommitment,bool delivered,uint256 nonce,uint256 timestamp,uint256 chainId,address escrowContract)"
    );

    // ============================================================
    // Immutable configuration
    // ============================================================

    /// @notice ERC-20 token used for every order's payment (e.g. DOTO on DotOne).
    IERC20 public immutable PAYMENT_TOKEN;

    /// @notice How long the seller has to ship after the buyer funds the order.
    uint256 public immutable SHIPPING_WINDOW;

    /// @notice Default delivery-attempt window used to set each order's
    /// `deliveryDeadline` when it ships. A missed deadline never releases funds
    /// by itself (Section 23) — it only unlocks `reportDeliveryTimeout`, which the
    /// buyer can use to escalate to a dispute.
    uint256 public immutable DELIVERY_WINDOW;

    /// @notice Cooling-off period after delivery is confirmed during which the
    /// buyer may still raise a dispute before anyone can trigger `autoRelease`.
    uint256 public immutable DISPUTE_WINDOW;

    /// @notice Maximum time a `Returning` order is allowed to wait for
    /// `confirmReturnReceived` before the buyer may re-escalate it back to
    /// `Disputed` via `reportReturnTimeout` (Section 9 follow-up: without this,
    /// a silent oracle could leave an order stuck in `Returning` forever).
    uint256 public immutable RETURN_WINDOW;

    // ============================================================
    // Mutable admin-controlled roles
    // ============================================================

    /// @notice Address authorized to submit delivery-lifecycle transactions
    /// (`markOutForDelivery`, `confirmDelivery`, `reportDeliveryIncident`,
    /// `confirmReturnReceived`). In production this is expected to be a contract
    /// operated by the delivery platform's backend / relayer infrastructure.
    address public deliveryOracle;

    /// @notice Key whose signature must appear over every `DeliveryAttestation`.
    /// Kept independent from `deliveryOracle` so the address merely allowed to
    /// *submit* transactions is not, by itself, able to fabricate a delivery
    /// result — the attestation content must additionally be signed by this key.
    address public attestationSigner;

    /// @notice Address authorized to resolve disputes. Intended to be a multisig
    /// or a dedicated arbitration contract in production. Always distinct from
    /// `deliveryOracle` (Section 5: "The arbiter must be separate from the
    /// delivery oracle").
    address public arbiter;

    // ============================================================
    // Order storage
    // ============================================================

    struct Order {
        address buyer;
        address seller;
        uint256 amount;
        string shipmentId;
        string trackingInfo;
        bytes32 deliveryOtpHash; // keccak256(otp, orderId, address(this)); zero if OTP unused
        uint256 createdAt;
        uint256 shippingDeadline; // set once funded
        uint256 deliveryDeadline; // set once shipped
        uint256 deliveredAt; // set once delivery is confirmed
        uint256 deliveryNonce; // replay-protection counter for delivery attestations
        uint256 returnDeadline; // set when a dispute resolves into Returning
        DeliveryMethod deliveryMethod;
        State state;
    }

    mapping(uint256 => Order) public orders;
    uint256 public nextOrderId;

    /// @notice Append-only incident log per order (Section 12). Real-world
    /// failure modes — drone failure, vehicle accident, lost package, damaged
    /// goods, wrong item, buyer rejection — are recorded here rather than as
    /// dedicated order states.
    mapping(uint256 => DeliveryIncident[]) public orderIncidents;

    // ============================================================
    // Events
    // ============================================================

    event OrderCreated(
        uint256 indexed orderId,
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        DeliveryMethod deliveryMethod
    );
    event OrderFunded(uint256 indexed orderId, address indexed buyer, uint256 amount);
    event OrderShipped(uint256 indexed orderId, string trackingInfo, uint256 deliveryDeadline);
    event OutForDelivery(uint256 indexed orderId, DeliveryMethod deliveryMethod);
    event DeliveryConfirmed(uint256 indexed orderId, uint256 deliveredAt);
    event DeliveryIncidentReported(
        uint256 indexed orderId, IncidentType incidentType, address indexed reportedBy, string evidenceRef
    );
    event DisputeRaised(
        uint256 indexed orderId, address indexed raisedBy, IncidentType incidentType, string evidenceRef
    );
    event ReturnStarted(uint256 indexed orderId, address indexed approvedBy);
    event OrderReturned(uint256 indexed orderId);
    event DisputeResolved(uint256 indexed orderId, DisputeResolution resolution, address indexed arbiter);
    event EscrowReleased(uint256 indexed orderId, address indexed seller, uint256 amount, bool auto_);
    event Refunded(uint256 indexed orderId, address indexed buyer, uint256 amount);
    event OrderCancelled(uint256 indexed orderId, string reason);
    event DeliveryOracleUpdated(address indexed oldOracle, address indexed newOracle);
    event AttestationSignerUpdated(address indexed oldSigner, address indexed newSigner);
    event ArbiterUpdated(address indexed oldArbiter, address indexed newArbiter);

    // ============================================================
    // Modifiers
    // ============================================================

    modifier orderExists(uint256 orderId) {
        _checkOrderExists(orderId);
        _;
    }

    modifier onlyState(uint256 orderId, State expected) {
        _checkOnlyState(orderId, expected);
        _;
    }

    modifier onlyDeliveryOracle() {
        _checkOnlyDeliveryOracle();
        _;
    }

    // Note: no `onlyArbiter` modifier — it would only ever be used once (on
    // `resolveDispute`), so the access check is inlined there directly instead
    // (see the forge-lint `modifier-used-only-once` rule).

    function _checkOrderExists(uint256 orderId) internal view {
        if (orderId >= nextOrderId) revert OrderDoesNotExist();
    }

    function _checkOnlyState(uint256 orderId, State expected) internal view {
        if (orders[orderId].state != expected) revert InvalidState();
    }

    function _checkOnlyDeliveryOracle() internal view {
        if (msg.sender != deliveryOracle) revert NotDeliveryOracle();
    }

    // ============================================================
    // Constructor
    // ============================================================

    constructor(
        address paymentToken,
        address initialDeliveryOracle,
        address initialAttestationSigner,
        address initialArbiter,
        uint256 shippingWindow,
        uint256 deliveryWindow,
        uint256 disputeWindow,
        uint256 returnWindow
    ) Ownable(msg.sender) EIP712("DeliveryEscrow", "1") {
        if (
            paymentToken == address(0) || initialDeliveryOracle == address(0) || initialAttestationSigner == address(0)
                || initialArbiter == address(0)
        ) {
            revert InvalidZeroAddress();
        }
        if (initialArbiter == initialDeliveryOracle) revert BuyerSellerSame(); // roles must stay separate
        if (shippingWindow == 0 || deliveryWindow == 0) revert InvalidAmount();

        PAYMENT_TOKEN = IERC20(paymentToken);
        deliveryOracle = initialDeliveryOracle;
        attestationSigner = initialAttestationSigner;
        arbiter = initialArbiter;
        SHIPPING_WINDOW = shippingWindow;
        DELIVERY_WINDOW = deliveryWindow;
        DISPUTE_WINDOW = disputeWindow;
        RETURN_WINDOW = returnWindow;
    }

    // ============================================================
    // Admin
    // ============================================================

    function setDeliveryOracle(address newOracle) external onlyOwner {
        if (newOracle == address(0)) revert InvalidZeroAddress();
        if (newOracle == arbiter) revert BuyerSellerSame();
        address oldOracle = deliveryOracle;
        deliveryOracle = newOracle;
        emit DeliveryOracleUpdated(oldOracle, newOracle);
    }

    function setAttestationSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert InvalidZeroAddress();
        address oldSigner = attestationSigner;
        attestationSigner = newSigner;
        emit AttestationSignerUpdated(oldSigner, newSigner);
    }

    function setArbiter(address newArbiter) external onlyOwner {
        if (newArbiter == address(0)) revert InvalidZeroAddress();
        if (newArbiter == deliveryOracle) revert BuyerSellerSame();
        address oldArbiter = arbiter;
        arbiter = newArbiter;
        emit ArbiterUpdated(oldArbiter, newArbiter);
    }

    // ============================================================
    // 1. Order creation
    // ============================================================

    /**
     * @notice Creates a new, independent order. One buyer may have many orders,
     * each with its own delivery lifecycle, OTP commitment and nonce — never a
     * global per-user OTP mapping.
     * @param seller Address that will receive payment once delivery is confirmed
     * (or a dispute resolves in its favor).
     * @param buyer Address that must fund the order and is the only party who can
     * raise a dispute or provide the delivery OTP through the off-chain app.
     * @param amount ERC-20 amount (in PAYMENT_TOKEN units) to be escrowed.
     * @param deliveryMethod HUMAN_COURIER, DRONE or PICKUP_POINT — informational
     * for the off-chain delivery system; the escrow/dispute logic below is
     * identical across all three (Section 7).
     * @param deliveryOtpHash keccak256(otp, orderId, address(this)) computed
     * off-chain, or bytes32(0) if this order relies purely on oracle attestation
     * (e.g. drone geofence + sensor) rather than an OTP. `orderId` here is
     * `nextOrderId`, which is public and known before calling this function. The
     * plaintext OTP itself never touches this contract, at creation or later.
     * @param shipmentId External reference (marketplace order id, carrier label
     * id, etc.) used to bind delivery attestations to the correct shipment.
     */
    function createOrder(
        address seller,
        address buyer,
        uint256 amount,
        DeliveryMethod deliveryMethod,
        bytes32 deliveryOtpHash,
        string calldata shipmentId
    ) external returns (uint256 orderId) {
        if (buyer == address(0) || seller == address(0)) revert InvalidZeroAddress();
        if (buyer == seller) revert BuyerSellerSame();
        if (amount == 0) revert InvalidAmount();
        if (msg.sender != buyer && msg.sender != seller) revert NotBuyerOrSeller();

        orderId = nextOrderId++;
        Order storage o = orders[orderId];
        o.buyer = buyer;
        o.seller = seller;
        o.amount = amount;
        o.shipmentId = shipmentId;
        o.deliveryOtpHash = deliveryOtpHash;
        o.createdAt = block.timestamp;
        o.deliveryMethod = deliveryMethod;
        o.state = State.Created;

        emit OrderCreated(orderId, buyer, seller, amount, deliveryMethod);
    }

    // ============================================================
    // 2. Funding
    // ============================================================

    function fundOrder(uint256 orderId) external nonReentrant orderExists(orderId) onlyState(orderId, State.Created) {
        Order storage o = orders[orderId];
        if (msg.sender != o.buyer) revert NotBuyer();

        o.state = State.Funded;
        o.shippingDeadline = block.timestamp + SHIPPING_WINDOW;

        PAYMENT_TOKEN.safeTransferFrom(msg.sender, address(this), o.amount);

        emit OrderFunded(orderId, msg.sender, o.amount);
    }

    // ============================================================
    // 3. Shipping
    // ============================================================

    function shipOrder(uint256 orderId, string calldata trackingInfo)
        external
        orderExists(orderId)
        onlyState(orderId, State.Funded)
    {
        Order storage o = orders[orderId];
        if (msg.sender != o.seller) revert NotSeller();

        o.trackingInfo = trackingInfo;
        o.deliveryDeadline = block.timestamp + DELIVERY_WINDOW;
        o.state = State.Shipped;

        emit OrderShipped(orderId, trackingInfo, o.deliveryDeadline);
    }

    // ============================================================
    // 4. Delivery lifecycle (oracle-controlled)
    // ============================================================

    /// @notice Marks the order as out for delivery (package handed to courier /
    /// drone dispatched). Optional step — `confirmDelivery` also accepts orders
    /// still in `Shipped` state, since e.g. pickup-point orders may not have a
    /// meaningful "out for delivery" phase.
    function markOutForDelivery(uint256 orderId)
        external
        override
        orderExists(orderId)
        onlyState(orderId, State.Shipped)
        onlyDeliveryOracle
    {
        Order storage o = orders[orderId];
        o.state = State.OutForDelivery;
        emit OutForDelivery(orderId, o.deliveryMethod);
    }

    /**
     * @notice Submits a signed delivery attestation produced off-chain by the
     * delivery platform (Sections 9-11). The buyer never submits a raw OTP
     * transaction; the app collects the OTP, the delivery system verifies it and
     * the shipment identity, then signs an attestation carrying only the OTP's
     * commitment hash — never the plaintext — together with a per-order nonce,
     * the chain id and this contract's address, so the attestation can never be
     * replayed across orders, chains or contracts.
     * @param orderId Order to confirm delivery for.
     * @param attestation The signed payload; see {IDeliveryEscrow-DeliveryAttestation}.
     * @param signature EIP-712 signature over `attestation`, produced by the key
     * currently set as `attestationSigner`.
     */
    function confirmDelivery(uint256 orderId, DeliveryAttestation calldata attestation, bytes calldata signature)
        external
        override
        orderExists(orderId)
        onlyDeliveryOracle
    {
        Order storage o = orders[orderId];
        if (o.state != State.Shipped && o.state != State.OutForDelivery) revert InvalidState();

        if (attestation.orderId != orderId) revert AttestationMismatch();
        if (attestation.escrowContract != address(this)) revert AttestationMismatch();
        if (attestation.chainId != block.chainid) revert AttestationMismatch();
        if (attestation.shipmentIdHash != keccak256(bytes(o.shipmentId))) revert AttestationMismatch();
        if (attestation.nonce != o.deliveryNonce) revert InvalidNonce();
        if (attestation.otpCommitment != o.deliveryOtpHash) revert DeliveryProofInvalid();
        if (!attestation.delivered) revert DeliveryProofInvalid();

        bytes32 digest = _hashTypedDataV4(_hashAttestation(attestation));
        address signer = ECDSA.recover(digest, signature);
        if (signer != attestationSigner) revert InvalidSignature();

        o.deliveryNonce += 1; // burn this nonce so the same attestation can never be replayed
        o.deliveredAt = block.timestamp;
        o.state = State.Delivered;

        emit DeliveryConfirmed(orderId, block.timestamp);
    }

    /// @notice Computes the EIP-712 digest a `DeliveryAttestation` must be signed
    /// over. Exposed so off-chain tooling/tests can reproduce the exact digest
    /// the contract will check.
    function hashDeliveryAttestation(DeliveryAttestation calldata attestation) external view returns (bytes32) {
        return _hashTypedDataV4(_hashAttestation(attestation));
    }

    function _hashAttestation(DeliveryAttestation calldata a) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                DELIVERY_ATTESTATION_TYPEHASH,
                a.orderId,
                a.shipmentIdHash,
                a.otpCommitment,
                a.delivered,
                a.nonce,
                a.timestamp,
                a.chainId,
                a.escrowContract
            )
        );
    }

    // ============================================================
    // 5. Delivery incidents (Sections 12-19)
    // ============================================================

    /// @notice Lets the delivery oracle report an operational failure it detected
    /// directly (drone failure, vehicle accident, package lost in transit) while
    /// an order is in transit, or while a return shipment is in transit back to
    /// the seller. Moves the order straight to `Disputed` — the contract never
    /// assumes fault, it only locks funds pending arbiter resolution.
    function reportDeliveryIncident(uint256 orderId, IncidentType incidentType, string calldata evidenceRef)
        external
        override
        orderExists(orderId)
        onlyDeliveryOracle
    {
        Order storage o = orders[orderId];
        if (o.state != State.Shipped && o.state != State.OutForDelivery && o.state != State.Returning) {
            revert InvalidState();
        }
        _recordIncident(orderId, incidentType, msg.sender, evidenceRef);
        o.state = State.Disputed;
    }

    /// @notice Lets the buyer escalate an order to arbitration: package never
    /// arrived, arrived damaged, wrong item, or any other valid rejection reason
    /// (Sections 17-19). The buyer can never mark an order as delivered and can
    /// never release escrow directly — raising a dispute only locks the order for
    /// the arbiter.
    function raiseDispute(uint256 orderId, IncidentType incidentType, string calldata evidenceRef)
        external
        orderExists(orderId)
    {
        Order storage o = orders[orderId];
        if (msg.sender != o.buyer) revert NotBuyer();
        if (o.state != State.Shipped && o.state != State.OutForDelivery && o.state != State.Delivered) {
            revert InvalidState();
        }
        _recordIncident(orderId, incidentType, msg.sender, evidenceRef);
        o.state = State.Disputed;
        emit DisputeRaised(orderId, msg.sender, incidentType, evidenceRef);
    }

    /// @notice Lets the buyer escalate a shipment that has silently blown past its
    /// delivery deadline without any oracle report (Section 22). A missed
    /// deadline alone never pays the seller; it only unlocks this escalation
    /// path, which — like every other incident — resolves through the arbiter.
    function reportDeliveryTimeout(uint256 orderId) external orderExists(orderId) {
        Order storage o = orders[orderId];
        if (msg.sender != o.buyer) revert NotBuyer();
        if (o.state != State.Shipped && o.state != State.OutForDelivery) revert InvalidState();
        if (block.timestamp <= o.deliveryDeadline) revert DeliveryWindowNotExpired();

        _recordIncident(orderId, IncidentType.DeliveryFailed, msg.sender, "delivery-deadline-expired");
        o.state = State.Disputed;
    }

    function _recordIncident(uint256 orderId, IncidentType incidentType, address reportedBy, string memory evidenceRef)
        internal
    {
        orderIncidents[orderId].push(
            DeliveryIncident({
                incidentType: incidentType,
                reportedBy: reportedBy,
                timestamp: block.timestamp,
                evidenceRef: evidenceRef,
                resolved: false
            })
        );
        emit DeliveryIncidentReported(orderId, incidentType, reportedBy, evidenceRef);
    }

    function incidentCount(uint256 orderId) external view returns (uint256) {
        return orderIncidents[orderId].length;
    }

    // ============================================================
    // 6. Settlement — normal path
    // ============================================================

    /// @notice Buyer-confirmed early release: the buyer is satisfied with the
    /// delivered goods and voluntarily releases funds before the dispute window
    /// elapses.
    function releaseFunds(uint256 orderId)
        external
        nonReentrant
        orderExists(orderId)
        onlyState(orderId, State.Delivered)
    {
        Order storage o = orders[orderId];
        if (msg.sender != o.buyer) revert NotBuyer();

        _settleToSeller(orderId, o, false);
    }

    /// @notice Permissionless fallback release once the dispute window has
    /// elapsed with no dispute raised. Anyone may call this — funds only ever
    /// move to the order's fixed seller address, so there is no incentive to
    /// grief. Unreachable once a dispute has moved the order out of `Delivered`.
    function autoRelease(uint256 orderId)
        external
        nonReentrant
        orderExists(orderId)
        onlyState(orderId, State.Delivered)
    {
        Order storage o = orders[orderId];
        if (block.timestamp < o.deliveredAt + DISPUTE_WINDOW) revert DisputeWindowNotExpired();

        _settleToSeller(orderId, o, true);
    }

    function _settleToSeller(uint256 orderId, Order storage o, bool isAuto) internal {
        o.state = State.Completed;
        uint256 amount = o.amount;
        PAYMENT_TOKEN.safeTransfer(o.seller, amount);
        emit EscrowReleased(orderId, o.seller, amount, isAuto);
    }

    // ============================================================
    // 7. Failed shipment / pre-delivery refund
    // ============================================================

    /// @notice Lets the buyer flag that the seller never shipped within the
    /// shipping deadline. Moves the order to `Cancelled`, unlocking `refundOrder`.
    function reportNotShipped(uint256 orderId) external orderExists(orderId) onlyState(orderId, State.Funded) {
        Order storage o = orders[orderId];
        if (msg.sender != o.buyer) revert NotBuyer();
        if (block.timestamp <= o.shippingDeadline) revert ShippingWindowNotExpired();

        o.state = State.Cancelled;
        emit OrderCancelled(orderId, "Seller failed to ship before deadline");
    }

    /// @notice Lets the seller voluntarily cancel an order it has been paid for
    /// but has not shipped yet (e.g. out of stock) — no need to wait for the
    /// buyer to wait out the full `SHIPPING_WINDOW` and call `reportNotShipped`.
    /// Moves straight to `Cancelled`, unlocking `refundOrder` immediately. The
    /// buyer retains the symmetric, deadline-gated path via `reportNotShipped`;
    /// this function only ever lets the seller give up its own claim early, it
    /// can never be used to deny or delay a refund the buyer is owed.
    function sellerAbortBeforeShipment(uint256 orderId) external orderExists(orderId) onlyState(orderId, State.Funded) {
        Order storage o = orders[orderId];
        if (msg.sender != o.seller) revert NotSeller();

        o.state = State.Cancelled;
        emit OrderCancelled(orderId, "Seller cancelled before shipment");
    }

    /// @notice Pulls the refund for a cancelled (never-shipped) order. Callable by
    /// anyone — funds only ever move to the order's fixed buyer address.
    function refundOrder(uint256 orderId)
        external
        nonReentrant
        orderExists(orderId)
        onlyState(orderId, State.Cancelled)
    {
        Order storage o = orders[orderId];
        o.state = State.Refunded;
        uint256 amount = o.amount;
        PAYMENT_TOKEN.safeTransfer(o.buyer, amount);
        emit Refunded(orderId, o.buyer, amount);
    }

    /// @notice Lets the buyer or seller cancel an order that was created but never
    /// funded — no funds have moved yet, so this is a pure bookkeeping step.
    function cancelUnfundedOrder(uint256 orderId) external orderExists(orderId) onlyState(orderId, State.Created) {
        Order storage o = orders[orderId];
        if (msg.sender != o.buyer && msg.sender != o.seller) revert NotBuyerOrSeller();

        o.state = State.Cancelled;
        emit OrderCancelled(orderId, "Cancelled before funding");
    }

    // ============================================================
    // 8. Dispute resolution (Section 25)
    // ============================================================

    /**
     * @notice Resolves a disputed order. Only the arbiter may call this, and it
     * can only ever act on the single order passed in — there is no batch or
     * unrestricted-withdrawal path, so a compromised or malicious arbiter call
     * can never touch an unrelated order's escrowed funds.
     * @param resolution RefundBuyer pays the buyer and closes the order;
     * PaySeller pays the seller and closes the order; ApproveReturn moves the
     * order to `Returning` and starts a `RETURN_WINDOW` countdown (see
     * `reportReturnTimeout`) without moving any funds yet, pending physical
     * return of the goods (Section 20); Reship moves the order back to `Shipped` with a
     * fresh delivery deadline, without moving any funds, for cases like a drone
     * failure where a second delivery attempt is the appropriate fix (Section 14).
     */
    function resolveDispute(uint256 orderId, DisputeResolution resolution)
        external
        nonReentrant
        orderExists(orderId)
        onlyState(orderId, State.Disputed)
    {
        if (msg.sender != arbiter) revert NotArbiter();

        Order storage o = orders[orderId];
        _markLatestIncidentResolved(orderId);

        if (resolution == DisputeResolution.RefundBuyer) {
            o.state = State.Refunded;
            uint256 amount = o.amount;
            PAYMENT_TOKEN.safeTransfer(o.buyer, amount);
            emit Refunded(orderId, o.buyer, amount);
        } else if (resolution == DisputeResolution.PaySeller) {
            o.state = State.Completed;
            uint256 amount = o.amount;
            PAYMENT_TOKEN.safeTransfer(o.seller, amount);
            emit EscrowReleased(orderId, o.seller, amount, false);
        } else if (resolution == DisputeResolution.ApproveReturn) {
            o.state = State.Returning;
            o.returnDeadline = block.timestamp + RETURN_WINDOW;
            emit ReturnStarted(orderId, msg.sender);
        } else {
            // Reship: the goods themselves are not lost/damaged (e.g. a drone
            // failure mid-flight); escrow stays fully locked, only the delivery
            // sub-flow restarts with a fresh deadline and attestation nonce.
            o.state = State.Shipped;
            o.deliveryDeadline = block.timestamp + DELIVERY_WINDOW;
            emit OrderShipped(orderId, o.trackingInfo, o.deliveryDeadline);
        }

        emit DisputeResolved(orderId, resolution, msg.sender);
    }

    function _markLatestIncidentResolved(uint256 orderId) internal {
        DeliveryIncident[] storage incidents = orderIncidents[orderId];
        if (incidents.length == 0) return;
        DeliveryIncident storage last = incidents[incidents.length - 1];
        if (!last.resolved) last.resolved = true;
    }

    // ============================================================
    // 9. Returns (Sections 20-21)
    // ============================================================

    /**
     * @notice Called by the delivery oracle once the delivery platform confirms
     * the returned package has physically reached the seller. The escrow stays
     * locked for the entire `Returning` phase (Section 20) — no funds move until
     * this explicit confirmation. On success the order goes directly to
     * `Refunded`: the intermediate "package physically received" fact is what
     * this call attests to, and there is no further on-chain action needed once
     * it has, so a distinct terminal "Returned" state would only duplicate
     * `Refunded` without adding enforceable meaning — the state machine stays as
     * small and stable as Section 3 requires.
     */
    function confirmReturnReceived(uint256 orderId)
        external
        override
        nonReentrant
        orderExists(orderId)
        onlyState(orderId, State.Returning)
        onlyDeliveryOracle
    {
        Order storage o = orders[orderId];
        o.state = State.Refunded;
        uint256 amount = o.amount;
        PAYMENT_TOKEN.safeTransfer(o.buyer, amount);
        emit OrderReturned(orderId);
        emit Refunded(orderId, o.buyer, amount);
    }

    /// @notice Lets the buyer re-escalate a `Returning` order whose return
    /// shipment the delivery platform never confirmed as received within
    /// `RETURN_WINDOW` of the arbiter's `ApproveReturn` decision. Moves back to
    /// `Disputed` (recorded as a `PackageLost` incident) so the arbiter can
    /// re-decide — typically `RefundBuyer` at that point — rather than leaving
    /// the order locked in `Returning` indefinitely.
    function reportReturnTimeout(uint256 orderId) external orderExists(orderId) onlyState(orderId, State.Returning) {
        Order storage o = orders[orderId];
        if (msg.sender != o.buyer) revert NotBuyer();
        if (block.timestamp <= o.returnDeadline) revert ReturnWindowNotExpired();

        _recordIncident(orderId, IncidentType.PackageLost, msg.sender, "return-deadline-expired");
        o.state = State.Disputed;
    }

    // ============================================================
    // Views
    // ============================================================

    function orderState(uint256 orderId) external view override orderExists(orderId) returns (State) {
        return orders[orderId].state;
    }
}
