// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IReentryTarget {
    function releaseFunds(uint256 orderId) external;
}

/**
 * @notice ERC-20 whose `transfer` callback tries to re-enter `releaseFunds` on a
 * configured target. Used only to prove `nonReentrant` blocks the re-entrant call;
 * it is never part of the production system.
 */
contract ReentrantERC20 is ERC20 {
    address public target;
    uint256 public reentryOrderId;
    bool public attack;

    constructor() ERC20("Reentrant Token", "REENT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setAttack(address _target, uint256 _orderId, bool _attack) external {
        target = _target;
        reentryOrderId = _orderId;
        attack = _attack;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        if (attack) {
            attack = false; // avoid infinite loop, single re-entry attempt is enough to prove the guard
            IReentryTarget(target).releaseFunds(reentryOrderId);
        }
        return ok;
    }
}
