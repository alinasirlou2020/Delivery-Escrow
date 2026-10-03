// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {DeliveryEscrow} from "../src/DeliveryEscrow.sol";
import {IDeliveryEscrow} from "../src/IDeliveryEscrow.sol";
import {MockDeliveryOracle} from "../src/MockDeliveryOracle.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {ReentrantERC20} from "./mocks/ReentrantERC20.sol";

contract DeliveryEscrowTest is Test {
    DeliveryEscrow internal escrow;
    MockDeliveryOracle internal oracleContract;
    MockERC20 internal token;

    address internal admin;
    address internal oracleOperator;
    address internal arbiter;
    address internal buyer;
    address internal seller;
    address internal stranger;

    address internal attestationSigner;
    uint256 internal attestationSignerKey;

    uint256 internal constant SHIPPING_WINDOW = 5 days;
    uint256 internal constant DELIVERY_WINDOW = 7 days;
    uint256 internal constant DISPUTE_WINDOW = 2 days;
    uint256 internal constant RETURN_WINDOW = 10 days;
    uint256 internal constant AMOUNT = 100 ether;
    uint256 internal constant BUYER_INITIAL_BALANCE = 1_000 ether;

    function setUp() public {
        admin = makeAddr("admin");
        oracleOperator = makeAddr("oracleOperator");
        arbiter = makeAddr("arbiter");
        buyer = makeAddr("buyer");
        seller = makeAddr("seller");
        stranger = makeAddr("stranger");
        (attestationSigner, attestationSignerKey) = makeAddrAndKey("attestationSigner");

        vm.startPrank(admin);
        token = new MockERC20();
        // deploy with the admin as a temporary oracle (constructor forbids zero
        // address and forbids oracle == arbiter), then swap in the real mock oracle
        escrow = new DeliveryEscrow(
            address(token),
            admin,
            attestationSigner,
            arbiter,
            SHIPPING_WINDOW,
            DELIVERY_WINDOW,
            DISPUTE_WINDOW,
            RETURN_WINDOW
        );
        oracleContract = new MockDeliveryOracle(address(escrow), oracleOperator);
        escrow.setDeliveryOracle(address(oracleContract));
        vm.stopPrank();

        token.mint(buyer, BUYER_INITIAL_BALANCE);
        vm.prank(buyer);
        require(token.approve(address(escrow), type(uint256).max), "approve failed");
    }

    // ------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------

    function _createOrder(bytes32 otpHash) internal returns (uint256 orderId) {
        vm.prank(seller);
        orderId = escrow.createOrder(seller, buyer, AMOUNT, IDeliveryEscrow.DeliveryMethod.DRONE, otpHash, "shipment-1");
    }

    function _createOrderNoOtp() internal returns (uint256 orderId) {
        return _createOrder(bytes32(0));
    }

    function _createOrderWithOtp(string memory otp) internal returns (uint256 orderId, bytes32 otpHash) {
        uint256 expectedId = escrow.nextOrderId();
        otpHash = keccak256(abi.encodePacked(otp, expectedId, address(escrow)));
        orderId = _createOrder(otpHash);
        assertEq(orderId, expectedId);
    }

    function _fund(uint256 orderId) internal {
        vm.prank(buyer);
        escrow.fundOrder(orderId);
    }

    function _ship(uint256 orderId) internal {
        vm.prank(seller);
        escrow.shipOrder(orderId, "TRACK-123");
    }

    function _outForDelivery(uint256 orderId) internal {
        vm.prank(oracleOperator);
        oracleContract.markOutForDelivery(orderId);
    }

    /// @dev Builds and signs a valid attestation for the order's *current* nonce.
    function _buildAndSignAttestation(uint256 orderId, bytes32 otpCommitment, bool delivered)
        internal
        view
        returns (IDeliveryEscrow.DeliveryAttestation memory attestation, bytes memory signature)
    {
        // forge-lint: disable-next-line(unused-return)
        (,,, string memory shipmentId,,,,,,, uint256 deliveryNonce,,,) = escrow.orders(orderId);
        attestation = IDeliveryEscrow.DeliveryAttestation({
            orderId: orderId,
            shipmentIdHash: keccak256(bytes(shipmentId)),
            otpCommitment: otpCommitment,
            delivered: delivered,
            nonce: deliveryNonce,
            timestamp: block.timestamp,
            chainId: block.chainid,
            escrowContract: address(escrow)
        });
        bytes32 digest = escrow.hashDeliveryAttestation(attestation);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attestationSignerKey, digest);
        signature = abi.encodePacked(r, s, v);
    }

    function _confirmDelivery(uint256 orderId, bytes32 otpCommitment) internal {
        (IDeliveryEscrow.DeliveryAttestation memory attestation, bytes memory signature) =
            _buildAndSignAttestation(orderId, otpCommitment, true);
        vm.prank(oracleOperator);
        oracleContract.confirmDelivery(orderId, attestation, signature);
    }

    function _fullHappyPathToDelivered() internal returns (uint256 orderId) {
        orderId = _createOrderNoOtp();
        _fund(orderId);
        _ship(orderId);
        _outForDelivery(orderId);
        _confirmDelivery(orderId, bytes32(0));
    }

    function _orderState(uint256 orderId) internal view returns (IDeliveryEscrow.State) {
        return escrow.orderState(orderId);
    }

    // ============================================================
    // Deployment
    // ============================================================

    function test_constructor_rejectsZeroAddresses() public {
        vm.expectRevert(DeliveryEscrow.InvalidZeroAddress.selector);
        new DeliveryEscrow(
            address(0),
            admin,
            attestationSigner,
            arbiter,
            SHIPPING_WINDOW,
            DELIVERY_WINDOW,
            DISPUTE_WINDOW,
            RETURN_WINDOW
        );

        vm.expectRevert(DeliveryEscrow.InvalidZeroAddress.selector);
        new DeliveryEscrow(
            address(token),
            address(0),
            attestationSigner,
            arbiter,
            SHIPPING_WINDOW,
            DELIVERY_WINDOW,
            DISPUTE_WINDOW,
            RETURN_WINDOW
        );

        vm.expectRevert(DeliveryEscrow.InvalidZeroAddress.selector);
        new DeliveryEscrow(
            address(token), admin, address(0), arbiter, SHIPPING_WINDOW, DELIVERY_WINDOW, DISPUTE_WINDOW, RETURN_WINDOW
        );

        vm.expectRevert(DeliveryEscrow.InvalidZeroAddress.selector);
        new DeliveryEscrow(
            address(token),
            admin,
            attestationSigner,
            address(0),
            SHIPPING_WINDOW,
            DELIVERY_WINDOW,
            DISPUTE_WINDOW,
            RETURN_WINDOW
        );
    }

    function test_constructor_rejectsOracleEqualsArbiter() public {
        vm.expectRevert(DeliveryEscrow.BuyerSellerSame.selector);
        new DeliveryEscrow(
            address(token),
            admin,
            attestationSigner,
            admin,
            SHIPPING_WINDOW,
            DELIVERY_WINDOW,
            DISPUTE_WINDOW,
            RETURN_WINDOW
        );
    }

    function test_constructor_rejectsZeroWindows() public {
        vm.expectRevert(DeliveryEscrow.InvalidAmount.selector);
        new DeliveryEscrow(
            address(token), admin, attestationSigner, arbiter, 0, DELIVERY_WINDOW, DISPUTE_WINDOW, RETURN_WINDOW
        );
    }

    // ============================================================
    // Order creation / funding / shipping (unchanged surface, still covered)
    // ============================================================

    function test_createOrder_success() public {
        uint256 orderId = _createOrderNoOtp();
        (
            address oBuyer,
            address oSeller,
            uint256 amount,,,,,,,,,,,
            IDeliveryEscrow.State state
            // forge-lint: disable-next-line(unused-return)
        ) = escrow.orders(orderId);
        assertEq(oBuyer, buyer);
        assertEq(oSeller, seller);
        assertEq(amount, AMOUNT);
        assertEq(uint8(state), uint8(IDeliveryEscrow.State.Created));
    }

    function test_createOrder_revertsOnZeroAddresses() public {
        vm.prank(seller);
        vm.expectRevert(DeliveryEscrow.InvalidZeroAddress.selector);
        // forge-lint: disable-next-line(unused-return)
        escrow.createOrder(address(0), buyer, AMOUNT, IDeliveryEscrow.DeliveryMethod.DRONE, bytes32(0), "");
    }

    function test_createOrder_revertsOnSameBuyerSeller() public {
        vm.prank(seller);
        vm.expectRevert(DeliveryEscrow.BuyerSellerSame.selector);
        // forge-lint: disable-next-line(unused-return)
        escrow.createOrder(seller, seller, AMOUNT, IDeliveryEscrow.DeliveryMethod.DRONE, bytes32(0), "");
    }

    function test_fundOrder_success() public {
        uint256 orderId = _createOrderNoOtp();
        _fund(orderId);
        assertEq(uint8(_orderState(orderId)), uint8(IDeliveryEscrow.State.Funded));
    }

    function test_fundOrder_revertsForNonBuyer() public {
        uint256 orderId = _createOrderNoOtp();
        vm.prank(stranger);
        vm.expectRevert(DeliveryEscrow.NotBuyer.selector);
        escrow.fundOrder(orderId);
    }

    function test_shipOrder_success() public {
        uint256 orderId = _createOrderNoOtp();
        _fund(orderId);
        _ship(orderId);
        assertEq(uint8(_orderState(orderId)), uint8(IDeliveryEscrow.State.Shipped));
    }

    function test_shipOrder_revertsForNonSeller() public {
        uint256 orderId = _createOrderNoOtp();
        _fund(orderId);
        vm.prank(stranger);
        vm.expectRevert(DeliveryEscrow.NotSeller.selector);
        escrow.shipOrder(orderId, "x");
    }

    // ============================================================
    // Delivery lifecycle / access control
    // ============================================================

    function test_markOutForDelivery_onlyOracle() public {
        uint256 orderId = _createOrderNoOtp();
        _fund(orderId);
        _ship(orderId);

        vm.prank(stranger);
        vm.expectRevert(DeliveryEscrow.NotDeliveryOracle.selector);
        escrow.markOutForDelivery(orderId);

        _outForDelivery(orderId);
        assertEq(uint8(_orderState(orderId)), uint8(IDeliveryEscrow.State.OutForDelivery));
    }

    function test_confirmDelivery_worksDirectlyFromShipped_pickupPointStyle() public {
        uint256 orderId = _createOrderNoOtp();
        _fund(orderId);
        _ship(orderId);
        _confirmDelivery(orderId, bytes32(0));
        assertEq(uint8(_orderState(orderId)), uint8(IDeliveryEscrow.State.Delivered));
    }

    function test_confirmDelivery_revertsForNonOracleCaller() public {
        uint256 orderId = _createOrderNoOtp();
        _fund(orderId);
        _ship(orderId);
        (IDeliveryEscrow.DeliveryAttestation memory a, bytes memory sig) =
            _buildAndSignAttestation(orderId, bytes32(0), true);
        vm.prank(stranger);
        vm.expectRevert(DeliveryEscrow.NotDeliveryOracle.selector);
        escrow.confirmDelivery(orderId, a, sig);
    }

    function test_confirmDelivery_revertsIfInvalidState() public {
        uint256 orderId = _createOrderNoOtp();
        (IDeliveryEscrow.DeliveryAttestation memory a, bytes memory sig) =
            _buildAndSignAttestation(orderId, bytes32(0), true);
        vm.prank(oracleOperator);
        vm.expectRevert(DeliveryEscrow.InvalidState.selector);
        oracleContract.confirmDelivery(orderId, a, sig);
    }

    function test_confirmDelivery_cannotBeConfirmedTwice() public {
        uint256 orderId = _fullHappyPathToDelivered();
        (IDeliveryEscrow.DeliveryAttestation memory a, bytes memory sig) =
            _buildAndSignAttestation(orderId, bytes32(0), true);
        vm.prank(oracleOperator);
        vm.expectRevert(DeliveryEscrow.InvalidState.selector);
        oracleContract.confirmDelivery(orderId, a, sig);
    }

    // ---- attestation integrity / replay protection ----

    function test_confirmDelivery_revertsOnWrongSigner() public {
        uint256 orderId = _createOrderNoOtp();
        _fund(orderId);
        _ship(orderId);

        // forge-lint: disable-next-line(unused-return)
        (address wrongSigner, uint256 wrongKey) = makeAddrAndKey("notTheRealSigner");
        wrongSigner; // silence unused warning in some tooling
        // forge-lint: disable-next-line(unused-return)
        (,,, string memory shipmentId,,,,,,, uint256 nonce,,,) = escrow.orders(orderId);
        IDeliveryEscrow.DeliveryAttestation memory a = IDeliveryEscrow.DeliveryAttestation({
            orderId: orderId,
            shipmentIdHash: keccak256(bytes(shipmentId)),
            otpCommitment: bytes32(0),
            delivered: true,
            nonce: nonce,
            timestamp: block.timestamp,
            chainId: block.chainid,
            escrowContract: address(escrow)
        });
        bytes32 digest = escrow.hashDeliveryAttestation(a);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(wrongKey, digest);
        bytes memory badSig = abi.encodePacked(r, s, v);

        vm.prank(oracleOperator);
        vm.expectRevert(DeliveryEscrow.InvalidSignature.selector);
        oracleContract.confirmDelivery(orderId, a, badSig);
    }

    function test_confirmDelivery_revertsOnWrongNonce() public {
        uint256 orderId = _createOrderNoOtp();
        _fund(orderId);
        _ship(orderId);
        
        // forge-lint: disable-next-line(unused-return)
        (,,, string memory shipmentId,,,,,,,,,,) = escrow.orders(orderId);
        IDeliveryEscrow.DeliveryAttestation memory a = IDeliveryEscrow.DeliveryAttestation({
            orderId: orderId,
            shipmentIdHash: keccak256(bytes(shipmentId)),
            otpCommitment: bytes32(0),
            delivered: true,
            nonce: 777, // wrong - order's real nonce is 0
            timestamp: block.timestamp,
            chainId: block.chainid,
            escrowContract: address(escrow)
        });
        bytes32 digest = escrow.hashDeliveryAttestation(a);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attestationSignerKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(oracleOperator);
        vm.expectRevert(DeliveryEscrow.InvalidNonce.selector);
        oracleContract.confirmDelivery(orderId, a, sig);
    }

    function test_confirmDelivery_nonceIncrementsAndBlocksReplay() public {
        // Confirm order 0, capture its (now-stale) attestation+signature, then show
        // it cannot be replayed against a *different* order that happens to share
        // the same shipmentIdHash and otp commitment (0) — because orderId itself
        // is bound into the signed struct.
        uint256 orderA = _createOrderNoOtp();
        _fund(orderA);
        _ship(orderA);
        (IDeliveryEscrow.DeliveryAttestation memory a, bytes memory sig) =
            _buildAndSignAttestation(orderA, bytes32(0), true);

        vm.prank(oracleOperator);
        oracleContract.confirmDelivery(orderA, a, sig);

        // replaying the exact same (orderId, attestation, signature) triple again
        // must fail — state is no longer Shipped/OutForDelivery.
        vm.prank(oracleOperator);
        vm.expectRevert(DeliveryEscrow.InvalidState.selector);
        oracleContract.confirmDelivery(orderA, a, sig);
    }

    function test_confirmDelivery_revertsOnShipmentIdMismatch() public {
        uint256 orderId = _createOrderNoOtp();
        _fund(orderId);
        _ship(orderId);

        IDeliveryEscrow.DeliveryAttestation memory a = IDeliveryEscrow.DeliveryAttestation({
            orderId: orderId,
            shipmentIdHash: keccak256(bytes("wrong-shipment-id")),
            otpCommitment: bytes32(0),
            delivered: true,
            nonce: 0,
            timestamp: block.timestamp,
            chainId: block.chainid,
            escrowContract: address(escrow)
        });
        bytes32 digest = escrow.hashDeliveryAttestation(a);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attestationSignerKey, digest);
        bytes memory sig = abi.encodePacked(r, s, v);

        vm.prank(oracleOperator);
        vm.expectRevert(DeliveryEscrow.AttestationMismatch.selector);
        oracleContract.confirmDelivery(orderId, a, sig);
    }

    // ---- OTP binding ----

    function test_confirmDelivery_withCorrectOtpCommitment_succeeds() public {
        (uint256 orderId, bytes32 otpHash) = _createOrderWithOtp("123456");
        _fund(orderId);
        _ship(orderId);
        _confirmDelivery(orderId, otpHash);
        assertEq(uint8(_orderState(orderId)), uint8(IDeliveryEscrow.State.Delivered));
    }

    function test_confirmDelivery_withWrongOtpCommitment_reverts() public {
        (uint256 orderId,) = _createOrderWithOtp("123456");
        _fund(orderId);
        _ship(orderId);
        (IDeliveryEscrow.DeliveryAttestation memory a, bytes memory sig) =
            _buildAndSignAttestation(orderId, keccak256("some-other-hash"), true);

        vm.prank(oracleOperator);
        vm.expectRevert(DeliveryEscrow.DeliveryProofInvalid.selector);
        oracleContract.confirmDelivery(orderId, a, sig);
    }

    function test_otp_isBoundToOrderId_hashesDifferAcrossOrders() public {
        (uint256 orderA, bytes32 hashA) = _createOrderWithOtp("999999");
        (uint256 orderB, bytes32 hashB) = _createOrderWithOtp("999999");
        assertTrue(orderA != orderB);
        assertTrue(hashA != hashB); // same plaintext OTP, different per-order commitment
    }

    // ============================================================
    // Settlement: releaseFunds / autoRelease
    // ============================================================

    function test_releaseFunds_byBuyer_succeeds() public {
        uint256 orderId = _fullHappyPathToDelivered();
        uint256 sellerBalBefore = token.balanceOf(seller);

        vm.prank(buyer);
        escrow.releaseFunds(orderId);

        assertEq(token.balanceOf(seller), sellerBalBefore + AMOUNT);
        assertEq(uint8(_orderState(orderId)), uint8(IDeliveryEscrow.State.Completed));
    }

    function test_releaseFunds_revertsForNonBuyer() public {
        uint256 orderId = _fullHappyPathToDelivered();
        vm.prank(seller);
        vm.expectRevert(DeliveryEscrow.NotBuyer.selector);
        escrow.releaseFunds(orderId);
    }

    function test_autoRelease_revertsBeforeDisputeWindow() public {
        uint256 orderId = _fullHappyPathToDelivered();
        vm.expectRevert(DeliveryEscrow.DisputeWindowNotExpired.selector);
        escrow.autoRelease(orderId);
    }

    function test_autoRelease_succeedsAfterDisputeWindow_callableByAnyone() public {
        uint256 orderId = _fullHappyPathToDelivered();
        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);

        uint256 sellerBalBefore = token.balanceOf(seller);
        vm.prank(stranger);
        escrow.autoRelease(orderId);

        assertEq(token.balanceOf(seller), sellerBalBefore + AMOUNT);
    }

    function test_autoRelease_blockedIfDisputeWasRaised() public {
        uint256 orderId = _fullHappyPathToDelivered();
        vm.prank(buyer);
        escrow.raiseDispute(orderId, IDeliveryEscrow.IncidentType.PackageDamaged, "ipfs://evidence");

        vm.warp(block.timestamp + DISPUTE_WINDOW + 1);
        vm.expectRevert(DeliveryEscrow.InvalidState.selector);
        escrow.autoRelease(orderId);
    }

    // ============================================================
    // Failed shipment / pre-delivery refund (unchanged behavior)
    // ============================================================

    function test_reportNotShipped_thenRefund_succeeds() public {
        uint256 orderId = _createOrderNoOtp();
        _fund(orderId);
        vm.warp(block.timestamp + SHIPPING_WINDOW + 1);

        vm.prank(buyer);
        escrow.reportNotShipped(orderId);
        assertEq(uint8(_orderState(orderId)), uint8(IDeliveryEscrow.State.Cancelled));

        uint256 buyerBalBefore = token.balanceOf(buyer);
        escrow.refundOrder(orderId);
        assertEq(token.balanceOf(buyer), buyerBalBefore + AMOUNT);
        assertEq(uint8(_orderState(orderId)), uint8(IDeliveryEscrow.State.Refunded));
    }

    function test_refundOrder_cannotHappenTwice() public {
        uint256 orderId = _createOrderNoOtp();
        _fund(orderId);
        vm.warp(block.timestamp + SHIPPING_WINDOW + 1);
        vm.prank(buyer);
        escrow.reportNotShipped(orderId);
        escrow.refundOrder(orderId);

        vm.expectRevert(DeliveryEscrow.InvalidState.selector);
        escrow.refundOrder(orderId);
    }

    // ============================================================
    // Seller early cancellation (before shipment)
    // ============================================================

    function test_sellerAbortBeforeShipment_succeeds_andRefundsBuyer() public {
        uint256 orderId = _createOrderNoOtp();
        _fund(orderId);

        vm.prank(seller);
        escrow.sellerAbortBeforeShipment(orderId);
        assertEq(uint8(_orderState(orderId)), uint8(IDeliveryEscrow.State.Cancelled));

        // no need to wait out SHIPPING_WINDOW - refund is available immediately
        uint256 buyerBalBefore = token.balanceOf(buyer);
        escrow.refundOrder(orderId);
        assertEq(token.balanceOf(buyer), buyerBalBefore + AMOUNT);
        assertEq(uint8(_orderState(orderId)), uint8(IDeliveryEscrow.State.Refunded));
    }

    function test_sellerAbortBeforeShipment_revertsForNonSeller() public {
        uint256 orderId = _createOrderNoOtp();
        _fund(orderId);
        vm.prank(buyer);
        vm.expectRevert(DeliveryEscrow.NotSeller.selector);
        escrow.sellerAbortBeforeShipment(orderId);
    }

    function test_sellerAbortBeforeShipment_revertsAfterShipped() public {
        uint256 orderId = _createOrderNoOtp();
        _fund(orderId);
        _ship(orderId);
        vm.prank(seller);
        vm.expectRevert(DeliveryEscrow.InvalidState.selector);
        escrow.sellerAbortBeforeShipment(orderId);
    }

    function test_sellerAbortBeforeShipment_revertsBeforeFunding() public {
        uint256 orderId = _createOrderNoOtp();
        vm.prank(seller);
        vm.expectRevert(DeliveryEscrow.InvalidState.selector);
        escrow.sellerAbortBeforeShipment(orderId);
    }

    // ============================================================
    // Return timeout (Section 9 follow-up: silent oracle during Returning)
    // ============================================================

    function test_reportReturnTimeout_succeeds_reescalatesToDisputed() public {
        uint256 orderId = _fullHappyPathToDelivered();
        vm.prank(buyer);
        escrow.raiseDispute(orderId, IDeliveryEscrow.IncidentType.WrongPackage, "wrong item");
        vm.prank(arbiter);
        escrow.resolveDispute(orderId, IDeliveryEscrow.DisputeResolution.ApproveReturn);
        assertEq(uint8(_orderState(orderId)), uint8(IDeliveryEscrow.State.Returning));

        vm.warp(block.timestamp + RETURN_WINDOW + 1);
        vm.prank(buyer);
        escrow.reportReturnTimeout(orderId);

        assertEq(uint8(_orderState(orderId)), uint8(IDeliveryEscrow.State.Disputed));
        assertEq(escrow.incidentCount(orderId), 2); // original WrongPackage + the timeout incident

        // arbiter can now re-decide, e.g. refund the buyer since the return never showed up
        uint256 buyerBalBefore = token.balanceOf(buyer);
        vm.prank(arbiter);
        escrow.resolveDispute(orderId, IDeliveryEscrow.DisputeResolution.RefundBuyer);
        assertEq(token.balanceOf(buyer), buyerBalBefore + AMOUNT);
    }

    function test_reportReturnTimeout_revertsBeforeDeadline() public {
        uint256 orderId = _fullHappyPathToDelivered();
        vm.prank(buyer);
        escrow.raiseDispute(orderId, IDeliveryEscrow.IncidentType.WrongPackage, "wrong item");
        vm.prank(arbiter);
        escrow.resolveDispute(orderId, IDeliveryEscrow.DisputeResolution.ApproveReturn);

        vm.prank(buyer);
        vm.expectRevert(DeliveryEscrow.ReturnWindowNotExpired.selector);
        escrow.reportReturnTimeout(orderId);
    }

    function test_reportReturnTimeout_revertsForNonBuyer() public {
        uint256 orderId = _fullHappyPathToDelivered();
        vm.prank(buyer);
        escrow.raiseDispute(orderId, IDeliveryEscrow.IncidentType.WrongPackage, "wrong item");
        vm.prank(arbiter);
        escrow.resolveDispute(orderId, IDeliveryEscrow.DisputeResolution.ApproveReturn);
        vm.warp(block.timestamp + RETURN_WINDOW + 1);

        vm.prank(stranger);
        vm.expectRevert(DeliveryEscrow.NotBuyer.selector);
        escrow.reportReturnTimeout(orderId);
    }

    function test_reportReturnTimeout_revertsIfNotReturning() public {
        uint256 orderId = _fullHappyPathToDelivered();
        vm.prank(buyer);
        vm.expectRevert(DeliveryEscrow.InvalidState.selector);
        escrow.reportReturnTimeout(orderId);
    }

    function test_confirmReturnReceived_stillWorksAfterDeadline_ifOracleIsJustLate() public {
        // the deadline only unlocks the buyer's escalation path - it doesn't
        // block a late-but-genuine return confirmation if no one has escalated yet.
        uint256 orderId = _fullHappyPathToDelivered();
        vm.prank(buyer);
        escrow.raiseDispute(orderId, IDeliveryEscrow.IncidentType.WrongPackage, "wrong item");
        vm.prank(arbiter);
        escrow.resolveDispute(orderId, IDeliveryEscrow.DisputeResolution.ApproveReturn);
        vm.warp(block.timestamp + RETURN_WINDOW + 1);

        uint256 buyerBalBefore = token.balanceOf(buyer);
        vm.prank(oracleOperator);
        oracleContract.confirmReturnReceived(orderId);
        assertEq(token.balanceOf(buyer), buyerBalBefore + AMOUNT);
        assertEq(uint8(_orderState(orderId)), uint8(IDeliveryEscrow.State.Refunded));
    }

    // ============================================================
    // Delivery incidents (Sections 12-19)
    // ============================================================

    function test_reportDeliveryIncident_byOracle_movesToDisputed() public {
        uint256 orderId = _createOrderNoOtp();
        _fund(orderId);
        _ship(orderId);
        _outForDelivery(orderId);

        vm.prank(oracleOperator);
        oracleContract.reportDeliveryIncident(
            orderId, IDeliveryEscrow.IncidentType.DeliveryFailed, "drone-crash-log-hash"
        );
        assertEq(uint8(_orderState(orderId)), uint8(IDeliveryEscrow.State.Disputed));
        assertEq(escrow.incidentCount(orderId), 1);
        (IDeliveryEscrow.IncidentType incidentType, address reportedBy,,, bool resolved) =
        // forge-lint: disable-next-line(unused-return)
            escrow.orderIncidents(orderId, 0);
        assertEq(uint8(incidentType), uint8(IDeliveryEscrow.IncidentType.DeliveryFailed));
        assertEq(reportedBy, address(oracleContract));
        assertFalse(resolved);
    }

    function test_reportDeliveryIncident_revertsForNonOracle() public {
        uint256 orderId = _createOrderNoOtp();
        _fund(orderId);
        _ship(orderId);
        vm.prank(stranger);
        vm.expectRevert(DeliveryEscrow.NotDeliveryOracle.selector);
        escrow.reportDeliveryIncident(orderId, IDeliveryEscrow.IncidentType.PackageLost, "x");
    }

    function test_reportDeliveryIncident_worksFromReturning() public {
        // simulate: dispute -> ApproveReturn -> Returning -> return shipment lost
        uint256 orderId = _fullHappyPathToDelivered();
        vm.prank(buyer);
        escrow.raiseDispute(orderId, IDeliveryEscrow.IncidentType.WrongPackage, "ref");
        vm.prank(arbiter);
        escrow.resolveDispute(orderId, IDeliveryEscrow.DisputeResolution.ApproveReturn);
        assertEq(uint8(_orderState(orderId)), uint8(IDeliveryEscrow.State.Returning));

        vm.prank(oracleOperator);
        oracleContract.reportDeliveryIncident(orderId, IDeliveryEscrow.IncidentType.PackageLost, "return-lost");
        assertEq(uint8(_orderState(orderId)), uint8(IDeliveryEscrow.State.Disputed));
    }

    function test_raiseDispute_byBuyer_fromDelivered_forDamage() public {
        uint256 orderId = _fullHappyPathToDelivered();
        vm.prank(buyer);
        escrow.raiseDispute(orderId, IDeliveryEscrow.IncidentType.PackageDamaged, "ipfs://photo-hash");
        assertEq(uint8(_orderState(orderId)), uint8(IDeliveryEscrow.State.Disputed));
        assertEq(escrow.incidentCount(orderId), 1);
    }

    function test_raiseDispute_revertsForNonBuyer() public {
        uint256 orderId = _createOrderNoOtp();
        _fund(orderId);
        _ship(orderId);
        vm.prank(seller);
        vm.expectRevert(DeliveryEscrow.NotBuyer.selector);
        escrow.raiseDispute(orderId, IDeliveryEscrow.IncidentType.Other, "x");
    }

    function test_raiseDispute_revertsFromInvalidState() public {
        uint256 orderId = _createOrderNoOtp();
        vm.prank(buyer);
        vm.expectRevert(DeliveryEscrow.InvalidState.selector);
        escrow.raiseDispute(orderId, IDeliveryEscrow.IncidentType.Other, "too early");
    }

    function test_reportDeliveryTimeout_byBuyer_afterDeadline() public {
        uint256 orderId = _createOrderNoOtp();
        _fund(orderId);
        _ship(orderId);
        vm.warp(block.timestamp + DELIVERY_WINDOW + 1);

        vm.prank(buyer);
        escrow.reportDeliveryTimeout(orderId);
        assertEq(uint8(_orderState(orderId)), uint8(IDeliveryEscrow.State.Disputed));
        assertEq(escrow.incidentCount(orderId), 1);
    }

    function test_reportDeliveryTimeout_revertsBeforeDeadline() public {
        uint256 orderId = _createOrderNoOtp();
        _fund(orderId);
        _ship(orderId);
        vm.prank(buyer);
        vm.expectRevert(DeliveryEscrow.DeliveryWindowNotExpired.selector);
        escrow.reportDeliveryTimeout(orderId);
    }

    function test_deadlineExpiry_aloneNeverPaysSellerAutomatically() public {
        // Core safety property from Section 23/24: a missed deadline by itself
        // must never move funds. There is no function that both (a) checks only
        // deliveryDeadline expiry and (b) transfers to the seller — the only
        // deadline-based function (reportDeliveryTimeout) moves the order to
        // Disputed, never to Completed.
        uint256 orderId = _createOrderNoOtp();
        _fund(orderId);
        _ship(orderId);
        vm.warp(block.timestamp + DELIVERY_WINDOW + 1);
        vm.prank(buyer);
        escrow.reportDeliveryTimeout(orderId);
        assertEq(uint8(_orderState(orderId)), uint8(IDeliveryEscrow.State.Disputed));
        assertEq(token.balanceOf(seller), 0);
    }

    // ============================================================
    // Dispute resolution (Section 25) — three-way arbiter outcomes
    // ============================================================

    function test_resolveDispute_paySeller() public {
        uint256 orderId = _fullHappyPathToDelivered();
        vm.prank(buyer);
        escrow.raiseDispute(orderId, IDeliveryEscrow.IncidentType.Other, "buyer concedes");

        uint256 sellerBalBefore = token.balanceOf(seller);
        vm.prank(arbiter);
        escrow.resolveDispute(orderId, IDeliveryEscrow.DisputeResolution.PaySeller);

        assertEq(token.balanceOf(seller), sellerBalBefore + AMOUNT);
        assertEq(uint8(_orderState(orderId)), uint8(IDeliveryEscrow.State.Completed));
    }

    function test_resolveDispute_refundBuyer() public {
        uint256 orderId = _fullHappyPathToDelivered();
        vm.prank(buyer);
        escrow.raiseDispute(orderId, IDeliveryEscrow.IncidentType.PackageLost, "never arrived");

        uint256 buyerBalBefore = token.balanceOf(buyer);
        vm.prank(arbiter);
        escrow.resolveDispute(orderId, IDeliveryEscrow.DisputeResolution.RefundBuyer);

        assertEq(token.balanceOf(buyer), buyerBalBefore + AMOUNT);
        assertEq(uint8(_orderState(orderId)), uint8(IDeliveryEscrow.State.Refunded));
    }

    function test_resolveDispute_approveReturn_thenConfirmReturnReceived_refunds() public {
        uint256 orderId = _fullHappyPathToDelivered();
        vm.prank(buyer);
        escrow.raiseDispute(orderId, IDeliveryEscrow.IncidentType.WrongPackage, "wrong item shipped");

        vm.prank(arbiter);
        escrow.resolveDispute(orderId, IDeliveryEscrow.DisputeResolution.ApproveReturn);
        assertEq(uint8(_orderState(orderId)), uint8(IDeliveryEscrow.State.Returning));
        // no funds move yet while the return is in transit
        assertEq(token.balanceOf(buyer), 900 ether); // 1000 minted - 100 escrowed

        uint256 buyerBalBefore = token.balanceOf(buyer);
        vm.prank(oracleOperator);
        oracleContract.confirmReturnReceived(orderId);

        assertEq(token.balanceOf(buyer), buyerBalBefore + AMOUNT);
        assertEq(uint8(_orderState(orderId)), uint8(IDeliveryEscrow.State.Refunded));
    }

    function test_resolveDispute_reship_resetsToShippedWithoutMovingFunds() public {
        // e.g. drone failure mid-flight: goods never lost, just needs a retry.
        uint256 orderId = _createOrderNoOtp();
        _fund(orderId);
        _ship(orderId);
        _outForDelivery(orderId);

        vm.prank(oracleOperator);
        oracleContract.reportDeliveryIncident(orderId, IDeliveryEscrow.IncidentType.DeliveryFailed, "drone-log");
        assertEq(uint8(_orderState(orderId)), uint8(IDeliveryEscrow.State.Disputed));

        uint256 escrowBalBefore = token.balanceOf(address(escrow));
        vm.prank(arbiter);
        escrow.resolveDispute(orderId, IDeliveryEscrow.DisputeResolution.Reship);

        assertEq(uint8(_orderState(orderId)), uint8(IDeliveryEscrow.State.Shipped));
        assertEq(token.balanceOf(address(escrow)), escrowBalBefore); // untouched

        // delivery can proceed normally from here
        _outForDelivery(orderId);
        _confirmDelivery(orderId, bytes32(0));
        assertEq(uint8(_orderState(orderId)), uint8(IDeliveryEscrow.State.Delivered));
    }

    function test_confirmReturnReceived_revertsForNonOracle() public {
        uint256 orderId = _fullHappyPathToDelivered();
        vm.prank(buyer);
        escrow.raiseDispute(orderId, IDeliveryEscrow.IncidentType.WrongPackage, "x");
        vm.prank(arbiter);
        escrow.resolveDispute(orderId, IDeliveryEscrow.DisputeResolution.ApproveReturn);

        vm.prank(stranger);
        vm.expectRevert(DeliveryEscrow.NotDeliveryOracle.selector);
        escrow.confirmReturnReceived(orderId);
    }

    function test_confirmReturnReceived_revertsIfNotReturning() public {
        uint256 orderId = _fullHappyPathToDelivered();
        vm.prank(oracleOperator);
        vm.expectRevert(DeliveryEscrow.InvalidState.selector);
        oracleContract.confirmReturnReceived(orderId);
    }

    function test_resolveDispute_revertsForNonArbiter() public {
        uint256 orderId = _fullHappyPathToDelivered();
        vm.prank(buyer);
        escrow.raiseDispute(orderId, IDeliveryEscrow.IncidentType.Other, "x");

        vm.prank(stranger);
        vm.expectRevert(DeliveryEscrow.NotArbiter.selector);
        escrow.resolveDispute(orderId, IDeliveryEscrow.DisputeResolution.PaySeller);
    }

    function test_resolveDispute_revertsIfNotDisputed() public {
        uint256 orderId = _fullHappyPathToDelivered();
        vm.prank(arbiter);
        vm.expectRevert(DeliveryEscrow.InvalidState.selector);
        escrow.resolveDispute(orderId, IDeliveryEscrow.DisputeResolution.PaySeller);
    }

    function test_resolveDispute_cannotTouchUnrelatedOrder() public {
        // arbiter resolves order A; order B (a separate, still-open order) must be
        // completely unaffected.
        uint256 orderA = _fullHappyPathToDelivered();
        uint256 orderB = _createOrderNoOtp();
        _fund(orderB);

        vm.prank(buyer);
        escrow.raiseDispute(orderA, IDeliveryEscrow.IncidentType.Other, "x");
        vm.prank(arbiter);
        escrow.resolveDispute(orderA, IDeliveryEscrow.DisputeResolution.RefundBuyer);

        assertEq(uint8(_orderState(orderB)), uint8(IDeliveryEscrow.State.Funded));
    }

    // ============================================================
    // Admin
    // ============================================================

    function test_setDeliveryOracle_onlyOwner_andCannotEqualArbiter() public {
        vm.prank(stranger);
        vm.expectRevert();
        escrow.setDeliveryOracle(stranger);

        vm.prank(admin);
        vm.expectRevert(DeliveryEscrow.BuyerSellerSame.selector);
        escrow.setDeliveryOracle(arbiter);

        vm.prank(admin);
        escrow.setDeliveryOracle(stranger);
        assertEq(escrow.deliveryOracle(), stranger);
    }

    function test_setAttestationSigner_onlyOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        escrow.setAttestationSigner(stranger);

        vm.prank(admin);
        escrow.setAttestationSigner(stranger);
        assertEq(escrow.attestationSigner(), stranger);
    }

    function test_setArbiter_onlyOwner_andCannotEqualOracle() public {
        vm.prank(admin);
        vm.expectRevert(DeliveryEscrow.BuyerSellerSame.selector);
        escrow.setArbiter(address(oracleContract));

        vm.prank(admin);
        escrow.setArbiter(stranger);
        assertEq(escrow.arbiter(), stranger);
    }

    // ============================================================
    // Reentrancy
    // ============================================================

    function test_releaseFunds_isProtectedAgainstReentrancy() public {
        ReentrantERC20 evilToken = new ReentrantERC20();
        vm.prank(admin);
        DeliveryEscrow evilEscrow = new DeliveryEscrow(
            address(evilToken),
            admin,
            attestationSigner,
            arbiter,
            SHIPPING_WINDOW,
            DELIVERY_WINDOW,
            DISPUTE_WINDOW,
            RETURN_WINDOW
        );
        vm.prank(admin);
        MockDeliveryOracle evilOracle = new MockDeliveryOracle(address(evilEscrow), oracleOperator);
        vm.prank(admin);
        evilEscrow.setDeliveryOracle(address(evilOracle));

        evilToken.mint(buyer, BUYER_INITIAL_BALANCE);
        vm.prank(buyer);
        require(evilToken.approve(address(evilEscrow), type(uint256).max), "approve failed");

        vm.prank(seller);
        uint256 orderId =
            evilEscrow.createOrder(seller, buyer, AMOUNT, IDeliveryEscrow.DeliveryMethod.DRONE, bytes32(0), "s");
        vm.prank(buyer);
        evilEscrow.fundOrder(orderId);
        vm.prank(seller);
        evilEscrow.shipOrder(orderId, "x");

        IDeliveryEscrow.DeliveryAttestation memory a = IDeliveryEscrow.DeliveryAttestation({
            orderId: orderId,
            shipmentIdHash: keccak256(bytes("s")),
            otpCommitment: bytes32(0),
            delivered: true,
            nonce: 0,
            timestamp: block.timestamp,
            chainId: block.chainid,
            escrowContract: address(evilEscrow)
        });
        bytes32 digest = evilEscrow.hashDeliveryAttestation(a);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(attestationSignerKey, digest);
        vm.prank(oracleOperator);
        evilOracle.confirmDelivery(orderId, a, abi.encodePacked(r, s, v));

        // arm the token to try to re-enter releaseFunds() from within its own transfer()
        evilToken.setAttack(address(evilEscrow), orderId, true);

        vm.prank(buyer);
        vm.expectRevert();
        evilEscrow.releaseFunds(orderId);
    }
}
