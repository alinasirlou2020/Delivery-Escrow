// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {DeliveryEscrow} from "../src/DeliveryEscrow.sol";
import {MockDeliveryOracle} from "../src/MockDeliveryOracle.sol";

/**
 * @notice Deploys DeliveryEscrow and a MockDeliveryOracle wired to it, then points
 * the escrow at the oracle. Configure via environment variables:
 *
 *   PRIVATE_KEY           deployer key
 *   PAYMENT_TOKEN         ERC-20 address (e.g. DOTO on DotOne - verify before mainnet use)
 *   ARBITER               arbitration address (multisig recommended, must differ from oracle)
 *   ATTESTATION_SIGNER    key whose signature every DeliveryAttestation must carry
 *   ORACLE_OPERATOR       EOA/multisig allowed to drive the MockDeliveryOracle
 *   SHIPPING_WINDOW_SECS  default: 5 days
 *   DELIVERY_WINDOW_SECS  default: 7 days
 *   DISPUTE_WINDOW_SECS   default: 2 days
 *   RETURN_WINDOW_SECS    default: 10 days
 *
 * Example (local Anvil):
 *   forge script script/Deploy.s.sol:DeployDeliveryEscrow \
 *     --rpc-url http://127.0.0.1:8545 --broadcast
 */
contract DeployDeliveryEscrow is Script {
    function run() external returns (DeliveryEscrow escrow, MockDeliveryOracle oracle) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address paymentToken = vm.envAddress("PAYMENT_TOKEN");
        address arbiterAddr = vm.envAddress("ARBITER");
        address attestationSigner = vm.envAddress("ATTESTATION_SIGNER");
        address oracleOperator = vm.envOr("ORACLE_OPERATOR", vm.addr(deployerKey));

        uint256 shippingWindow = vm.envOr("SHIPPING_WINDOW_SECS", uint256(5 days));
        uint256 deliveryWindow = vm.envOr("DELIVERY_WINDOW_SECS", uint256(7 days));
        uint256 disputeWindow = vm.envOr("DISPUTE_WINDOW_SECS", uint256(2 days));
        uint256 returnWindow = vm.envOr("RETURN_WINDOW_SECS", uint256(10 days));

        address deployer = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // Deploy with the deployer as a temporary oracle so the constructor never
        // takes a zero address, then swap in the real MockDeliveryOracle contract.
        escrow = new DeliveryEscrow(
            paymentToken,
            deployer,
            attestationSigner,
            arbiterAddr,
            shippingWindow,
            deliveryWindow,
            disputeWindow,
            returnWindow
        );

        oracle = new MockDeliveryOracle(address(escrow), oracleOperator);
        escrow.setDeliveryOracle(address(oracle));

        vm.stopBroadcast();

        console.log("DeliveryEscrow deployed at:", address(escrow));
        console.log("MockDeliveryOracle deployed at:", address(oracle));
        console.log("Oracle operator:", oracleOperator);
        console.log("Attestation signer:", attestationSigner);
        console.log("Arbiter:", arbiterAddr);
    }
}
