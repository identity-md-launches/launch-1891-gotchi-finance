// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Gotchi Finance
/// @notice Fixed-supply ERC-20: one billion GOTCHI, with 18 decimals.
/// @dev The immediate deployer receives the entire supply. At launch that is the factory.
/// There are no administrative roles or external mint, burn, or upgrade functions.
contract GotchiToken is ERC20 {
    /// @notice The entire supply in the token's smallest units (10^27).
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("Gotchi Finance", "GOTCHI") {
        _mint(msg.sender, INITIAL_SUPPLY);
    }
}

