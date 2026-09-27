// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {TicTacToeWager} from "../src/TicTacToeWager.sol";

/// @dev Drives the game from a fixed cast of actors with bounded, mostly-valid inputs so the
/// invariant test spends its budget on real state transitions rather than reverts.
contract WagerHandler is Test {
    LaunchToken public token;
    TicTacToeWager public wager;
    address[] public actors;

    uint256 public totalWithdrawn;
    uint256 public totalStaked;

    constructor(LaunchToken token_, TicTacToeWager wager_, address[] memory actors_) {
        token = token_;
        wager = wager_;
        actors = actors_;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _gameId(uint256 seed) internal view returns (uint256 id, bool exists) {
        uint256 count = wager.gameCount();
        if (count == 0) return (0, false);
        return (seed % count, true);
    }

    function open(uint256 actorSeed, uint256 stake) external {
        address who = _actor(actorSeed);
        stake = bound(stake, 1 ether, 50 ether);
        if (token.balanceOf(who) < stake) return;
        vm.prank(who);
        wager.open(stake);
        totalStaked += stake;
    }

    function join(uint256 actorSeed, uint256 gameSeed) external {
        (uint256 id, bool exists) = _gameId(gameSeed);
        if (!exists) return;
        TicTacToeWager.Game memory g = wager.game(id);
        if (g.status != TicTacToeWager.Status.Open) return;
        address who = _actor(actorSeed);
        if (who == g.playerX) who = _actor(actorSeed + 1);
        if (token.balanceOf(who) < g.stake) return;
        vm.prank(who);
        wager.join(id);
        totalStaked += g.stake;
    }

    function cancel(uint256 gameSeed) external {
        (uint256 id, bool exists) = _gameId(gameSeed);
        if (!exists) return;
        TicTacToeWager.Game memory g = wager.game(id);
        if (g.status != TicTacToeWager.Status.Open) return;
        vm.prank(g.playerX);
        wager.cancel(id);
    }

    function move(uint256 gameSeed, uint8 cell) external {
        (uint256 id, bool exists) = _gameId(gameSeed);
        if (!exists) return;
        address mover = wager.turn(id);
        if (mover == address(0)) return;
        uint8[9] memory b = wager.board(id);
        cell = uint8(bound(cell, 0, 8));
        // Find the first empty cell at or after the seed.
        for (uint256 i; i < 9; ++i) {
            uint8 c = uint8((cell + i) % 9);
            if (b[c] == 0) {
                vm.prank(mover);
                wager.move(id, c);
                return;
            }
        }
    }

    function claimTimeout(uint256 gameSeed) external {
        (uint256 id, bool exists) = _gameId(gameSeed);
        if (!exists) return;
        TicTacToeWager.Game memory g = wager.game(id);
        if (g.status != TicTacToeWager.Status.Active) return;
        if (block.timestamp < g.moveDeadline) return;
        address claimant = g.turn == TicTacToeWager.Mark.X ? g.playerO : g.playerX;
        vm.prank(claimant);
        wager.claimTimeout(id);
    }

    function withdraw(uint256 actorSeed) external {
        address who = _actor(actorSeed);
        uint256 amount = wager.withdrawable(who);
        if (amount == 0) return;
        vm.prank(who);
        wager.withdraw();
        totalWithdrawn += amount;
    }

    function warp(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, 2 hours);
        vm.warp(block.timestamp + seconds_);
    }

    // Adversarial calls that must always revert and never change accounting.

    function strangerClaimsTimeout(uint256 actorSeed, uint256 gameSeed) external {
        (uint256 id, bool exists) = _gameId(gameSeed);
        if (!exists) return;
        TicTacToeWager.Game memory g = wager.game(id);
        address who = _actor(actorSeed);
        if (who == g.playerX || who == g.playerO) return;
        vm.prank(who);
        vm.expectRevert();
        wager.claimTimeout(id);
    }

    function latePlayerClaimsTimeout(uint256 gameSeed) external {
        (uint256 id, bool exists) = _gameId(gameSeed);
        if (!exists) return;
        address late = wager.turn(id);
        if (late == address(0)) return;
        vm.prank(late);
        vm.expectRevert();
        wager.claimTimeout(id);
    }
}

contract TicTacToeWagerInvariantTest is Test {
    LaunchToken internal token;
    TicTacToeWager internal wager;
    WagerHandler internal handler;
    address[] internal actors;

    uint256 internal constant PER_ACTOR = 500 ether;

    function setUp() public {
        vm.warp(1_700_000_000);
        token = new LaunchToken();
        wager = new TicTacToeWager(address(token));

        for (uint256 i; i < 4; ++i) {
            address a = makeAddr(string(abi.encodePacked("actor", vm.toString(i))));
            actors.push(a);
            token.transfer(a, PER_ACTOR);
            vm.prank(a);
            token.approve(address(wager), type(uint256).max);
        }

        handler = new WagerHandler(token, wager, actors);
        targetContract(address(handler));
    }

    /// @notice NGHT held == stakes of open games + both stakes of active games + all credits.
    function invariant_heldEqualsEscrowPlusCredits() public view {
        uint256 escrow;
        uint256 count = wager.gameCount();
        for (uint256 id; id < count; ++id) {
            TicTacToeWager.Game memory g = wager.game(id);
            if (g.status == TicTacToeWager.Status.Open) escrow += g.stake;
            else if (g.status == TicTacToeWager.Status.Active) escrow += 2 * uint256(g.stake);
        }
        uint256 credits;
        for (uint256 i; i < actors.length; ++i) {
            credits += wager.withdrawable(actors[i]);
        }
        assertEq(token.balanceOf(address(wager)), escrow + credits, "held != escrow + credits");
    }

    /// @notice Tokens are never created or destroyed: actors + contract == what was handed out.
    function invariant_tokenConservation() public view {
        uint256 sum = token.balanceOf(address(wager));
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, PER_ACTOR * actors.length);
        assertEq(handler.totalStaked(), handler.totalWithdrawn() + token.balanceOf(address(wager)));
    }

    /// @notice A finished or cancelled game never has a live clock, and every game's players and
    /// stake are well formed.
    function invariant_gameRecordsWellFormed() public view {
        uint256 count = wager.gameCount();
        for (uint256 id; id < count; ++id) {
            TicTacToeWager.Game memory g = wager.game(id);
            assertTrue(g.playerX != address(0), "creator set");
            assertGe(g.stake, 1 ether, "stake floor");
            if (g.status == TicTacToeWager.Status.Open || g.status == TicTacToeWager.Status.Cancelled) {
                assertEq(g.playerO, address(0), "no joiner");
                assertEq(g.board, 0, "no moves");
            } else {
                assertTrue(g.playerO != address(0) && g.playerO != g.playerX, "joiner set");
            }
            if (g.status != TicTacToeWager.Status.Active) {
                assertEq(wager.moveDeadline(id), 0);
                assertEq(wager.turn(id), address(0));
            } else {
                assertTrue(wager.turn(id) == g.playerX || wager.turn(id) == g.playerO);
            }
            assertEq(g.board >> 18, 0, "only 18 board bits used");
        }
    }

    /// @notice The contract never holds ETH.
    function invariant_noEther() public view {
        assertEq(address(wager).balance, 0);
    }
}
