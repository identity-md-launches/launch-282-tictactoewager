// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {TicTacToeWager} from "../src/TicTacToeWager.sol";

contract DeployTest is Test {
    function test_deployWiresTokenIntoWager() public {
        Deploy script = new Deploy();
        (LaunchToken token, TicTacToeWager wager) = script.deploy();

        assertEq(wager.token(), address(token));
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.balanceOf(address(script)), token.totalSupply(), "supply goes to the deployer");
        assertEq(token.balanceOf(address(wager)), 0, "application holds nothing at deploy");
        assertEq(wager.gameCount(), 0);
    }

    /// @dev Mirrors the launch: the factory (any address) deploys the token, then the application
    /// with the token address as its only constructor argument.
    function test_factoryStyleDeploymentLeavesSupplyWithDeployer() public {
        address factory = makeAddr("factory");
        vm.startPrank(factory);
        LaunchToken token = new LaunchToken();
        TicTacToeWager wager = new TicTacToeWager(address(token));
        vm.stopPrank();

        assertEq(token.balanceOf(factory), 1_000_000_000 ether);
        assertEq(wager.token(), address(token));
    }
}
