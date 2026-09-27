// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {TicTacToeWager} from "../src/TicTacToeWager.sol";
import {ReenteringToken, Attacker} from "./mocks/ReenteringToken.sol";

/// @notice Reentrancy on `withdraw()` with a token that calls back during the payout.
contract TicTacToeWagerReentrancyTest is Test {
    uint256 internal constant STAKE = 5 ether;

    ReenteringToken internal token;
    TicTacToeWager internal wager;
    Attacker internal attacker;

    function setUp() public {
        token = new ReenteringToken();
        wager = new TicTacToeWager(address(token));
        attacker = new Attacker(wager);
        token.arm(wager, address(attacker));
        token.transfer(address(attacker), 100 ether);
    }

    function test_reentrantWithdrawIsRefusedAndPaysExactlyOnce() public {
        uint256 id = attacker.approveAndOpen(token, STAKE);
        attacker.cancel(id);
        assertEq(wager.withdrawable(address(attacker)), STAKE);
        uint256 before = token.balanceOf(address(attacker));

        attacker.withdraw();

        assertEq(token.reentryAttempts(), 1, "the hook fired");
        assertEq(token.reentrySuccesses(), 0, "the reentrant withdraw was refused");
        assertEq(token.balanceOf(address(attacker)), before + STAKE, "paid exactly once");
        assertEq(wager.withdrawable(address(attacker)), 0);
        assertEq(token.balanceOf(address(wager)), 0, "nothing extra left or taken");

        // The inner failure is the guard, not a balance check: the credit was already zeroed but
        // the guard fires first, and either defence alone would stop the double payment.
        bytes memory expected = abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(token.lastReentryError(), expected);
    }

    function test_reentrantWithdrawCannotDrainOtherPlayersCredit() public {
        // Another player also has credit sitting in the contract.
        address victim = makeAddr("victim");
        token.transfer(victim, 50 ether);
        vm.startPrank(victim);
        token.approve(address(wager), 20 ether);
        uint256 v = wager.open(20 ether);
        wager.cancel(v);
        vm.stopPrank();

        uint256 id = attacker.approveAndOpen(token, STAKE);
        attacker.cancel(id);
        uint256 before = token.balanceOf(address(attacker));

        attacker.withdraw();

        assertEq(token.balanceOf(address(attacker)), before + STAKE);
        assertEq(wager.withdrawable(victim), 20 ether, "victim credit untouched");
        assertEq(token.balanceOf(address(wager)), 20 ether, "victim funds still held");
    }
}
