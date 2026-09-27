// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {TicTacToeWager} from "../src/TicTacToeWager.sol";

/// @title Local deployment helper
/// @notice Deploys Noughts (NGHT) and TicTacToeWager wired together, for local forks and anvil.
/// @dev The production launch does NOT use this script: the ProjectFactory deploys both contracts
/// from launch.json (LaunchToken first, then TicTacToeWager with constructorArgs ["$token"]).
/// This script exists so the wiring can be exercised in tests and on a local chain. It takes no
/// configuration from the environment; `deploy()` is the unit under test.
contract Deploy is Script {
    /// @notice Deploy the token and the game contract pointing at it.
    /// @return token The NGHT token, whole supply minted to the caller of this function.
    /// @return wager The game contract configured with `token`.
    function deploy() public returns (LaunchToken token, TicTacToeWager wager) {
        token = new LaunchToken();
        wager = new TicTacToeWager(address(token));
    }

    /// @notice Broadcast `deploy()` with the sender forge is given on the command line.
    function run() external returns (LaunchToken token, TicTacToeWager wager) {
        vm.startBroadcast();
        (token, wager) = deploy();
        vm.stopBroadcast();
    }
}
