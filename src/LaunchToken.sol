// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title Noughts (NGHT) launch token
/// @notice Fixed-supply ERC-20 used as the working currency of TicTacToeWager.
/// @dev The whole supply of 1,000,000,000 NGHT (10^27 minor units) is minted once to the
/// deployer, which in the project launch is the ProjectFactory. The factory routes that supply
/// to the liquidity pool and the reward distributor. There is no owner, no mint, no burn hook,
/// no pause, no blocklist, no fee and no upgrade path: the bytecode deployed is the bytecode
/// that runs forever.
contract LaunchToken is ERC20 {
    /// @notice Total supply in minor units: 1,000,000,000 tokens with 18 decimals.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18;

    constructor() ERC20("Noughts", "NGHT") {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
