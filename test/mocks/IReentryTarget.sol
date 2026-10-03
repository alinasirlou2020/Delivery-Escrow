// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal typed interface used only by `ReentrantERC20` to attempt a
/// reentrant call. Deliberately NOT related to `IDeliveryEscrow` — it just
/// happens to describe one function of it (`releaseFunds`) for test purposes.
interface IReentryTarget {
    function releaseFunds(uint256 orderId) external;
}
