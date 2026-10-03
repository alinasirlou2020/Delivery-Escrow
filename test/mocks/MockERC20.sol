// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Minimal mintable ERC-20 used in tests to stand in for the DOTO token.
contract MockERC20 is ERC20 {
    constructor() ERC20("Mock DOTO", "mDOTO") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
