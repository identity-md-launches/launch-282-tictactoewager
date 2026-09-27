// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {TicTacToeWager} from "../src/TicTacToeWager.sol";

contract TicTacToeWagerTest is Test {
    uint256 internal constant STAKE = 10 ether;
    uint256 internal constant HOUR = 1 hours;

    LaunchToken internal token;
    TicTacToeWager internal wager;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    /// @dev The eight lines as cell triples, in the same order the contract checks them.
    uint8[3][8] internal lines =
        [[0, 1, 2], [3, 4, 5], [6, 7, 8], [0, 3, 6], [1, 4, 7], [2, 5, 8], [0, 4, 8], [2, 4, 6]];

    // Events mirrored for expectEmit.
    event Opened(uint256 indexed id, address indexed creator, uint256 stake);
    event Joined(uint256 indexed id, address indexed joiner);
    event Moved(uint256 indexed id, address indexed player, uint8 cell);
    event Won(uint256 indexed id, address indexed winner, uint256 amount);
    event Drawn(uint256 indexed id, uint256 amountEach);
    event TimedOut(uint256 indexed id, address indexed claimant, address indexed loser, uint256 amount);
    event Cancelled(uint256 indexed id, address indexed creator, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);

    function setUp() public {
        token = new LaunchToken();
        wager = new TicTacToeWager(address(token));

        vm.warp(1_700_000_000);

        address[3] memory players = [alice, bob, carol];
        for (uint256 i; i < players.length; ++i) {
            token.transfer(players[i], 1_000 ether);
            vm.prank(players[i]);
            token.approve(address(wager), type(uint256).max);
        }
    }

    // ---------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------

    function _open(address who, uint256 stake) internal returns (uint256 id) {
        vm.prank(who);
        id = wager.open(stake);
    }

    function _openAndJoin() internal returns (uint256 id) {
        id = _open(alice, STAKE);
        vm.prank(bob);
        wager.join(id);
    }

    function _move(uint256 id, address who, uint8 cell) internal {
        vm.prank(who);
        wager.move(id, cell);
    }

    function _bitmapOf(uint8[3] memory cells) internal pure returns (uint256 bits) {
        for (uint256 i; i < 3; ++i) {
            bits |= 1 << cells[i];
        }
    }

    function _completesLine(uint256 bits) internal view returns (bool) {
        for (uint256 i; i < lines.length; ++i) {
            uint256 mask = _bitmapOf(lines[i]);
            if ((bits & mask) == mask) return true;
        }
        return false;
    }

    /// @dev Picks `count` cells outside `avoid` that never form a line among themselves.
    function _fillers(uint256 avoid, uint256 count) internal view returns (uint8[] memory picked) {
        picked = new uint8[](count);
        uint256 chosen;
        uint256 n;
        for (uint8 c; c < 9 && n < count; ++c) {
            if ((avoid >> c) & 1 == 1) continue;
            uint256 candidate = chosen | (1 << c);
            if (_completesLine(candidate)) continue;
            chosen = candidate;
            picked[n++] = c;
        }
        require(n == count, "not enough filler cells");
    }

    function _held() internal view returns (uint256) {
        return token.balanceOf(address(wager));
    }

    // ---------------------------------------------------------------------------------------
    // Construction and views
    // ---------------------------------------------------------------------------------------

    function test_constructorStoresToken() public view {
        assertEq(wager.token(), address(token));
        assertEq(wager.gameCount(), 0);
        assertEq(wager.MIN_STAKE(), 1 ether);
        assertEq(wager.MOVE_TIMEOUT(), 1 hours);
        assertEq(_held(), 0);
    }

    function test_constructorRejectsZeroToken() public {
        vm.expectRevert(TicTacToeWager.ZeroToken.selector);
        new TicTacToeWager(address(0));
    }

    function test_noPayableEntryPoints() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(wager).call{value: 1}("");
        assertFalse(ok, "receive/fallback accepted ETH");
        vm.prank(alice);
        (ok,) = address(wager).call{value: 1}(abi.encodeWithSelector(wager.withdraw.selector));
        assertFalse(ok, "withdraw accepted ETH");
        vm.prank(alice);
        (ok,) = address(wager).call(abi.encodeWithSignature("doesNotExist()"));
        assertFalse(ok, "fallback exists");
        assertEq(address(wager).balance, 0);
    }

    function test_viewsRevertForUnknownGame() public {
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.GameNotFound.selector, 0));
        wager.game(0);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.GameNotFound.selector, 7));
        wager.board(7);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.GameNotFound.selector, 0));
        wager.turn(0);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.GameNotFound.selector, 0));
        wager.moveDeadline(0);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.GameNotFound.selector, 0));
        wager.join(0);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.GameNotFound.selector, 0));
        wager.move(0, 0);
    }

    // ---------------------------------------------------------------------------------------
    // open
    // ---------------------------------------------------------------------------------------

    function test_openPullsStakeAndRecordsGame() public {
        uint256 before = token.balanceOf(alice);
        vm.expectEmit(address(wager));
        emit Opened(0, alice, STAKE);
        uint256 id = _open(alice, STAKE);

        assertEq(id, 0);
        assertEq(wager.gameCount(), 1);
        assertEq(token.balanceOf(alice), before - STAKE);
        assertEq(_held(), STAKE);

        TicTacToeWager.Game memory g = wager.game(id);
        assertEq(g.playerX, alice);
        assertEq(g.playerO, address(0));
        assertEq(g.stake, STAKE);
        assertEq(uint8(g.status), uint8(TicTacToeWager.Status.Open));
        assertEq(g.board, 0);
        assertEq(wager.turn(id), address(0));
        assertEq(wager.moveDeadline(id), 0);
    }

    function test_openAcceptsExactlyMinimumStake() public {
        uint256 id = _open(alice, 1 ether);
        assertEq(wager.game(id).stake, 1 ether);
    }

    function test_openRejectsStakeBelowMinimum() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.StakeTooLow.selector, 1 ether - 1, 1 ether));
        wager.open(1 ether - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.StakeTooLow.selector, 0, 1 ether));
        wager.open(0);
    }

    function test_openRejectsStakeAboveUint96() public {
        uint256 huge = uint256(type(uint96).max) + 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.StakeTooLarge.selector, huge));
        wager.open(huge);
    }

    function test_openRevertsWithoutAllowanceOrBalance() public {
        address dave = makeAddr("dave");
        vm.prank(dave);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(wager), 0, STAKE)
        );
        wager.open(STAKE);
        assertEq(wager.gameCount(), 0, "failed pull must not leave a game behind");

        vm.prank(dave);
        token.approve(address(wager), STAKE);
        vm.prank(dave);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, dave, 0, STAKE));
        wager.open(STAKE);
        assertEq(wager.gameCount(), 0);
    }

    function test_openManyGamesGetSequentialIds() public {
        assertEq(_open(alice, STAKE), 0);
        assertEq(_open(bob, 2 * STAKE), 1);
        assertEq(_open(alice, 3 * STAKE), 2);
        assertEq(wager.gameCount(), 3);
        assertEq(_held(), 6 * STAKE);
        assertEq(wager.game(1).playerX, bob);
        assertEq(wager.game(2).stake, 3 * STAKE);
    }

    // ---------------------------------------------------------------------------------------
    // join
    // ---------------------------------------------------------------------------------------

    function test_joinPullsMatchingStakeAndStartsClock() public {
        uint256 id = _open(alice, STAKE);
        uint256 before = token.balanceOf(bob);

        vm.expectEmit(address(wager));
        emit Joined(id, bob);
        vm.prank(bob);
        wager.join(id);

        assertEq(token.balanceOf(bob), before - STAKE);
        assertEq(_held(), 2 * STAKE);
        TicTacToeWager.Game memory g = wager.game(id);
        assertEq(g.playerO, bob);
        assertEq(uint8(g.status), uint8(TicTacToeWager.Status.Active));
        assertEq(uint8(g.turn), uint8(TicTacToeWager.Mark.X));
        assertEq(wager.turn(id), alice, "X moves first");
        assertEq(wager.moveDeadline(id), block.timestamp + HOUR);
    }

    function test_selfJoinRefused() public {
        uint256 id = _open(alice, STAKE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.SelfJoin.selector, id));
        wager.join(id);
    }

    function test_joinTwiceRefused() public {
        uint256 id = _openAndJoin();
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.GameNotOpen.selector, id));
        wager.join(id);
    }

    function test_joinWithoutFundsRevertsAndLeavesGameOpen() public {
        uint256 id = _open(alice, STAKE);
        address dave = makeAddr("dave");
        vm.prank(dave);
        vm.expectRevert();
        wager.join(id);
        assertEq(uint8(wager.game(id).status), uint8(TicTacToeWager.Status.Open));
        assertEq(wager.game(id).playerO, address(0));
    }

    // ---------------------------------------------------------------------------------------
    // cancel
    // ---------------------------------------------------------------------------------------

    function test_cancelCreditsCreatorAndWithdrawPays() public {
        uint256 id = _open(alice, STAKE);
        uint256 before = token.balanceOf(alice);

        vm.expectEmit(address(wager));
        emit Cancelled(id, alice, STAKE);
        vm.prank(alice);
        wager.cancel(id);

        assertEq(uint8(wager.game(id).status), uint8(TicTacToeWager.Status.Cancelled));
        assertEq(wager.withdrawable(alice), STAKE);
        assertEq(_held(), STAKE, "tokens stay until withdrawn");

        vm.expectEmit(address(wager));
        emit Withdrawn(alice, STAKE);
        vm.prank(alice);
        wager.withdraw();
        assertEq(token.balanceOf(alice), before + STAKE);
        assertEq(wager.withdrawable(alice), 0);
        assertEq(_held(), 0);
    }

    function test_cancelOnlyByCreator() public {
        uint256 id = _open(alice, STAKE);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.NotCreator.selector, id, bob));
        wager.cancel(id);
    }

    function test_cancelAfterJoinRefused() public {
        uint256 id = _openAndJoin();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.GameNotOpen.selector, id));
        wager.cancel(id);
    }

    function test_cancelTwiceRefused() public {
        uint256 id = _open(alice, STAKE);
        vm.prank(alice);
        wager.cancel(id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.GameNotOpen.selector, id));
        wager.cancel(id);
        assertEq(wager.withdrawable(alice), STAKE, "no double credit");
    }

    function test_cancelledGameCannotBeJoinedOrPlayed() public {
        uint256 id = _open(alice, STAKE);
        vm.prank(alice);
        wager.cancel(id);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.GameNotOpen.selector, id));
        wager.join(id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.GameNotActive.selector, id));
        wager.move(id, 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.GameNotActive.selector, id));
        wager.claimTimeout(id);
    }

    // ---------------------------------------------------------------------------------------
    // move: validation
    // ---------------------------------------------------------------------------------------

    function test_moveOutOfTurnRefused() public {
        uint256 id = _openAndJoin();
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.NotYourTurn.selector, id, bob));
        wager.move(id, 4);

        _move(id, alice, 4);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.NotYourTurn.selector, id, alice));
        wager.move(id, 0);
        assertEq(wager.turn(id), bob);
    }

    function test_moveByStrangerRefused() public {
        uint256 id = _openAndJoin();
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.NotYourTurn.selector, id, carol));
        wager.move(id, 4);
    }

    function test_moveBeforeJoinRefused() public {
        uint256 id = _open(alice, STAKE);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.GameNotActive.selector, id));
        wager.move(id, 4);
    }

    function test_moveOutOfRangeRefused() public {
        uint256 id = _openAndJoin();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.CellOutOfRange.selector, 9));
        wager.move(id, 9);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.CellOutOfRange.selector, 255));
        wager.move(id, 255);
    }

    function test_moveOnOccupiedCellRefused() public {
        uint256 id = _openAndJoin();
        _move(id, alice, 4);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.CellOccupied.selector, id, 4));
        wager.move(id, 4);

        _move(id, bob, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.CellOccupied.selector, id, 0));
        wager.move(id, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.CellOccupied.selector, id, 4));
        wager.move(id, 4);
    }

    function test_moveUpdatesBoardTurnAndDeadline() public {
        uint256 id = _openAndJoin();
        uint256 t0 = block.timestamp;

        vm.warp(t0 + 10 minutes);
        vm.expectEmit(address(wager));
        emit Moved(id, alice, 4);
        _move(id, alice, 4);

        uint8[9] memory b = wager.board(id);
        assertEq(b[4], 1, "X in centre");
        for (uint256 i; i < 9; ++i) {
            if (i != 4) assertEq(b[i], 0);
        }
        assertEq(wager.game(id).board, uint32(1) << 8, "packed X at cell 4");
        assertEq(wager.turn(id), bob);
        assertEq(wager.moveDeadline(id), t0 + 10 minutes + HOUR, "clock restarts for O");

        vm.warp(t0 + 25 minutes);
        _move(id, bob, 8);
        assertEq(wager.board(id)[8], 2, "O in corner");
        assertEq(wager.game(id).board, (uint32(1) << 8) | (uint32(2) << 16));
        assertEq(wager.turn(id), alice);
        assertEq(wager.moveDeadline(id), t0 + 25 minutes + HOUR);
    }

    function test_lateMoveStillAllowedUntilTimeoutClaimed() public {
        uint256 id = _openAndJoin();
        vm.warp(block.timestamp + 3 * HOUR);
        _move(id, alice, 0);
        assertEq(wager.turn(id), bob);
        assertEq(wager.moveDeadline(id), block.timestamp + HOUR);
        // Bob's own late move now lost him the right to claim Alice's earlier lateness.
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(
                TicTacToeWager.DeadlineNotReached.selector, id, block.timestamp + HOUR, block.timestamp
            )
        );
        wager.claimTimeout(id);
    }

    // ---------------------------------------------------------------------------------------
    // move: win detection, every line, both players
    // ---------------------------------------------------------------------------------------

    function test_everyLineWinsForX() public {
        for (uint256 l; l < lines.length; ++l) {
            _assertLineWin(lines[l], true);
        }
    }

    function test_everyLineWinsForO() public {
        for (uint256 l; l < lines.length; ++l) {
            _assertLineWin(lines[l], false);
        }
    }

    function _assertLineWin(uint8[3] memory line, bool xWins) internal {
        uint256 id = _openAndJoin();
        address winner = xWins ? alice : bob;
        address loser = xWins ? bob : alice;
        uint256 lineBits = _bitmapOf(line);
        // X wins on its third move after O has moved twice; O wins on its third after X's three.
        uint8[] memory fillers = _fillers(lineBits, xWins ? 2 : 3);

        uint256 heldBefore = _held();
        uint256 winnerCreditBefore = wager.withdrawable(winner);
        uint256 loserCreditBefore = wager.withdrawable(loser);

        if (xWins) {
            _move(id, alice, line[0]);
            _move(id, bob, fillers[0]);
            _move(id, alice, line[1]);
            _move(id, bob, fillers[1]);
            _assertActive(id);
            vm.expectEmit(address(wager));
            emit Moved(id, alice, line[2]);
            vm.expectEmit(address(wager));
            emit Won(id, alice, 2 * STAKE);
            _move(id, alice, line[2]);
        } else {
            _move(id, alice, fillers[0]);
            _move(id, bob, line[0]);
            _move(id, alice, fillers[1]);
            _move(id, bob, line[1]);
            _move(id, alice, fillers[2]);
            _assertActive(id);
            vm.expectEmit(address(wager));
            emit Moved(id, bob, line[2]);
            vm.expectEmit(address(wager));
            emit Won(id, bob, 2 * STAKE);
            _move(id, bob, line[2]);
        }

        TicTacToeWager.Game memory g = wager.game(id);
        assertEq(uint8(g.status), uint8(TicTacToeWager.Status.Finished), "finished");
        assertEq(wager.turn(id), address(0));
        assertEq(wager.moveDeadline(id), 0);
        assertEq(wager.withdrawable(winner), winnerCreditBefore + 2 * STAKE, "winner credited 2x");
        assertEq(wager.withdrawable(loser), loserCreditBefore, "loser credited nothing");
        assertEq(_held(), heldBefore, "no tokens leave until withdraw");

        uint8[9] memory b = wager.board(id);
        uint8 mark = xWins ? 1 : 2;
        for (uint256 i; i < 3; ++i) {
            assertEq(b[line[i]], mark, "winning cell mark");
        }
    }

    function _assertActive(uint256 id) internal view {
        assertEq(uint8(wager.game(id).status), uint8(TicTacToeWager.Status.Active), "game ended early");
    }

    function test_winnerCanWithdrawPot() public {
        uint256 id = _openAndJoin();
        uint256 before = token.balanceOf(alice);
        _move(id, alice, 0);
        _move(id, bob, 3);
        _move(id, alice, 1);
        _move(id, bob, 4);
        _move(id, alice, 2);

        vm.prank(alice);
        wager.withdraw();
        assertEq(token.balanceOf(alice), before + 2 * STAKE);
        assertEq(_held(), 0);
        assertEq(wager.withdrawable(alice), 0);
    }

    /// @dev A line on the packed board must be made of the *same* mark: a mixed X/O line, or bits
    /// borrowed from a neighbouring cell's 2-bit field, must never count as a win.
    function test_mixedLineIsNotAWin() public {
        uint256 id = _openAndJoin();
        // Row 0 ends up X O X, column 0 ends up X X O, diagonal 0 4 8 ends up X O -.
        _move(id, alice, 0);
        _move(id, bob, 1);
        _move(id, alice, 2);
        _move(id, bob, 4);
        _move(id, alice, 3);
        _move(id, bob, 6);
        _assertActive(id);
        assertEq(wager.withdrawable(alice), 0);
        assertEq(wager.withdrawable(bob), 0);
    }

    /// @dev Cell 4 holds O (binary 10 at bits 8..9). Cells 3 and 5 hold X (01 at bits 6..7 and
    /// 10..11). Read as raw bits the word is 0b10_10_01 around the middle row: a naive check of
    /// adjacent bits would see a pattern; the real decoder must see X O X and no win.
    function test_packedBitsAcrossCellBoundariesDoNotForgeAWin() public {
        uint256 id = _openAndJoin();
        _move(id, alice, 3);
        _move(id, bob, 4);
        _move(id, alice, 5);
        _move(id, bob, 0);
        _assertActive(id);
        uint8[9] memory b = wager.board(id);
        assertEq(b[3], 1);
        assertEq(b[4], 2);
        assertEq(b[5], 1);
        assertEq(b[0], 2);
    }

    // ---------------------------------------------------------------------------------------
    // draw
    // ---------------------------------------------------------------------------------------

    function test_fullBoardWithoutWinIsADraw() public {
        uint256 id = _openAndJoin();
        // Final board:
        //   X X O
        //   O O X
        //   X X O
        uint8[9] memory order = [0, 2, 1, 3, 5, 4, 6, 8, 7];
        for (uint256 i; i < 8; ++i) {
            _move(id, i % 2 == 0 ? alice : bob, order[i]);
        }
        _assertActive(id);

        vm.expectEmit(address(wager));
        emit Moved(id, alice, 7);
        vm.expectEmit(address(wager));
        emit Drawn(id, STAKE);
        _move(id, alice, 7);

        assertEq(uint8(wager.game(id).status), uint8(TicTacToeWager.Status.Finished));
        assertEq(wager.withdrawable(alice), STAKE);
        assertEq(wager.withdrawable(bob), STAKE);
        assertEq(wager.turn(id), address(0));
        assertEq(wager.moveDeadline(id), 0);
        assertEq(_held(), 2 * STAKE);

        vm.prank(alice);
        wager.withdraw();
        vm.prank(bob);
        wager.withdraw();
        assertEq(_held(), 0);
    }

    function test_winOnLastCellIsAWinNotADraw() public {
        uint256 id = _openAndJoin();
        // X: 0 1 5 6 8, O: 2 3 4 7 ; X completes 2 5 8? No: 2 is O. Use column 0 (0 3 6) for X.
        //   X O O
        //   X O X
        //   X O X  -> column 1 is O O O first. Build a board where X's ninth move wins:
        //   X O X
        //   X O O
        //   O X X  -> X wins on 8? row 2 is O X X, col 2 is X O X, diag 0-4-8 X O X: none.
        // Use:
        //   X X O
        //   O O X
        //   X O X  -> X's last move at 8 completes diagonal 2? (2 4 6) is O O X. Column 2 O X X.
        // Use instead:
        //   X O X
        //   O X O
        //   O X X  -> X's last move at cell 8 completes diagonal 0 4 8 (X X X).
        uint8[9] memory order = [0, 1, 2, 3, 4, 5, 7, 6, 8];
        for (uint256 i; i < 8; ++i) {
            _move(id, i % 2 == 0 ? alice : bob, order[i]);
        }
        _assertActive(id);
        vm.expectEmit(address(wager));
        emit Won(id, alice, 2 * STAKE);
        _move(id, alice, 8);
        assertEq(wager.withdrawable(alice), 2 * STAKE);
        assertEq(wager.withdrawable(bob), 0);
    }

    // ---------------------------------------------------------------------------------------
    // after the end
    // ---------------------------------------------------------------------------------------

    function test_noMovesOrClaimsAfterWin() public {
        uint256 id = _openAndJoin();
        _move(id, alice, 0);
        _move(id, bob, 3);
        _move(id, alice, 1);
        _move(id, bob, 4);
        _move(id, alice, 2);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.GameNotActive.selector, id));
        wager.move(id, 5);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.GameNotActive.selector, id));
        wager.move(id, 5);

        vm.warp(block.timestamp + 2 * HOUR);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.GameNotActive.selector, id));
        wager.claimTimeout(id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.GameNotActive.selector, id));
        wager.claimTimeout(id);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.GameNotOpen.selector, id));
        wager.cancel(id);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.GameNotOpen.selector, id));
        wager.join(id);

        assertEq(wager.withdrawable(alice), 2 * STAKE, "paid exactly once");
        assertEq(wager.withdrawable(bob), 0);
    }

    function test_noMovesAfterDraw() public {
        uint256 id = _openAndJoin();
        uint8[9] memory order = [0, 2, 1, 3, 5, 4, 6, 8, 7];
        for (uint256 i; i < 9; ++i) {
            _move(id, i % 2 == 0 ? alice : bob, order[i]);
        }
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.GameNotActive.selector, id));
        wager.move(id, 0);
        vm.warp(block.timestamp + 2 * HOUR);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.GameNotActive.selector, id));
        wager.claimTimeout(id);
    }

    // ---------------------------------------------------------------------------------------
    // timeouts
    // ---------------------------------------------------------------------------------------

    function test_timeoutOnFirstMoveExactlyOneHourAfterJoin() public {
        uint256 id = _openAndJoin();
        uint256 joinedAt = block.timestamp;
        uint256 deadline = wager.moveDeadline(id);
        assertEq(deadline, joinedAt + HOUR);

        // One second early: refused.
        vm.warp(deadline - 1);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.DeadlineNotReached.selector, id, deadline, deadline - 1));
        wager.claimTimeout(id);

        // Exactly one hour: allowed.
        vm.warp(deadline);
        vm.expectEmit(address(wager));
        emit TimedOut(id, bob, alice, 2 * STAKE);
        vm.prank(bob);
        wager.claimTimeout(id);

        assertEq(uint8(wager.game(id).status), uint8(TicTacToeWager.Status.Finished));
        assertEq(wager.withdrawable(bob), 2 * STAKE);
        assertEq(wager.withdrawable(alice), 0);
        assertEq(wager.turn(id), address(0));
        assertEq(wager.moveDeadline(id), 0);
    }

    function test_timeoutAfterAMoveMeasuredFromThatMove() public {
        uint256 id = _openAndJoin();
        vm.warp(block.timestamp + 30 minutes);
        _move(id, alice, 4);
        uint256 movedAt = block.timestamp;
        assertEq(wager.moveDeadline(id), movedAt + HOUR);

        vm.warp(movedAt + HOUR - 1);
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(TicTacToeWager.DeadlineNotReached.selector, id, movedAt + HOUR, movedAt + HOUR - 1)
        );
        wager.claimTimeout(id);

        vm.warp(movedAt + HOUR);
        vm.expectEmit(address(wager));
        emit TimedOut(id, alice, bob, 2 * STAKE);
        vm.prank(alice);
        wager.claimTimeout(id);
        assertEq(wager.withdrawable(alice), 2 * STAKE);
        assertEq(wager.withdrawable(bob), 0);
    }

    function test_timeoutCannotBeClaimedByThePlayerWhoIsLate() public {
        uint256 id = _openAndJoin();
        vm.warp(block.timestamp + 2 * HOUR);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.NotOpponent.selector, id, alice));
        wager.claimTimeout(id);
    }

    function test_timeoutCannotBeClaimedByAStranger() public {
        uint256 id = _openAndJoin();
        vm.warp(block.timestamp + 2 * HOUR);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.NotOpponent.selector, id, carol));
        wager.claimTimeout(id);
    }

    function test_timeoutCannotBeClaimedOnOpenGame() public {
        uint256 id = _open(alice, STAKE);
        vm.warp(block.timestamp + 2 * HOUR);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.GameNotActive.selector, id));
        wager.claimTimeout(id);
    }

    function test_timeoutCannotBeClaimedTwice() public {
        uint256 id = _openAndJoin();
        vm.warp(block.timestamp + HOUR);
        vm.prank(bob);
        wager.claimTimeout(id);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.GameNotActive.selector, id));
        wager.claimTimeout(id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.GameNotActive.selector, id));
        wager.move(id, 0);
        assertEq(wager.withdrawable(bob), 2 * STAKE, "paid once");
    }

    function test_winThenTimeoutDoesNotPayTwice() public {
        uint256 id = _openAndJoin();
        _move(id, alice, 0);
        _move(id, bob, 3);
        _move(id, alice, 1);
        _move(id, bob, 4);
        _move(id, alice, 2); // X wins; turn field still reads X.

        vm.warp(block.timestamp + 2 * HOUR);
        // Neither the "opponent of the last mover" nor the winner can time the game out.
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.GameNotActive.selector, id));
        wager.claimTimeout(id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.GameNotActive.selector, id));
        wager.claimTimeout(id);

        assertEq(wager.withdrawable(alice), 2 * STAKE);
        assertEq(wager.withdrawable(bob), 0);
        assertEq(_held(), 2 * STAKE);
    }

    function test_timeoutOnLateMoveRace() public {
        // Alice is late. Bob's claim lands first; Alice's subsequent move must fail.
        uint256 id = _openAndJoin();
        vm.warp(block.timestamp + HOUR);
        vm.prank(bob);
        wager.claimTimeout(id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.GameNotActive.selector, id));
        wager.move(id, 4);
    }

    // ---------------------------------------------------------------------------------------
    // withdraw
    // ---------------------------------------------------------------------------------------

    function test_withdrawWithNothingCreditedReverts() public {
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.NothingToWithdraw.selector, carol));
        wager.withdraw();
    }

    function test_withdrawTwiceRevertsSecondTime() public {
        uint256 id = _open(alice, STAKE);
        vm.prank(alice);
        wager.cancel(id);
        vm.prank(alice);
        wager.withdraw();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.NothingToWithdraw.selector, alice));
        wager.withdraw();
    }

    function test_withdrawAggregatesCreditsAcrossGames() public {
        uint256 a = _open(alice, STAKE);
        vm.prank(alice);
        wager.cancel(a);

        uint256 b = _openAndJoin();
        _move(b, alice, 0);
        _move(b, bob, 3);
        _move(b, alice, 1);
        _move(b, bob, 4);
        _move(b, alice, 2);

        assertEq(wager.withdrawable(alice), 3 * STAKE);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        wager.withdraw();
        assertEq(token.balanceOf(alice), before + 3 * STAKE);
        assertEq(_held(), 0);
    }

    function test_withdrawOnlyPaysCaller() public {
        uint256 id = _openAndJoin();
        vm.warp(block.timestamp + HOUR);
        vm.prank(bob);
        wager.claimTimeout(id);

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.NothingToWithdraw.selector, carol));
        wager.withdraw();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.NothingToWithdraw.selector, alice));
        wager.withdraw();
        assertEq(wager.withdrawable(bob), 2 * STAKE);
    }

    // ---------------------------------------------------------------------------------------
    // conservation across a mixed scenario
    // ---------------------------------------------------------------------------------------

    function test_heldEqualsEscrowPlusCredits() public {
        uint256 g0 = _open(alice, STAKE); // stays open
        uint256 g1 = _openAndJoin(); // will be won by X
        uint256 g2 = _open(bob, 3 * STAKE); // cancelled
        uint256 g3 = _open(carol, 2 * STAKE); // joined by alice, timed out
        vm.prank(alice);
        wager.join(g3);

        _move(g1, alice, 0);
        _move(g1, bob, 3);
        _move(g1, alice, 1);
        _move(g1, bob, 4);
        _move(g1, alice, 2);

        vm.prank(bob);
        wager.cancel(g2);

        vm.warp(block.timestamp + HOUR);
        vm.prank(alice); // carol (X) never moved in g3
        wager.claimTimeout(g3);

        uint256 escrow = STAKE; // g0 open
        uint256 credits = wager.withdrawable(alice) + wager.withdrawable(bob) + wager.withdrawable(carol);
        assertEq(wager.withdrawable(alice), 2 * STAKE + 4 * STAKE);
        assertEq(wager.withdrawable(bob), 3 * STAKE);
        assertEq(wager.withdrawable(carol), 0);
        assertEq(_held(), escrow + credits);

        vm.prank(alice);
        wager.withdraw();
        vm.prank(bob);
        wager.withdraw();
        assertEq(_held(), escrow);
        assertEq(uint8(wager.game(g0).status), uint8(TicTacToeWager.Status.Open));
    }

    // ---------------------------------------------------------------------------------------
    // fuzz
    // ---------------------------------------------------------------------------------------

    function testFuzz_openRoundTripsAnyValidStake(uint96 stake) public {
        stake = uint96(bound(stake, 1 ether, 1_000 ether));
        uint256 id = _open(alice, stake);
        assertEq(wager.game(id).stake, stake);
        assertEq(_held(), stake);
        vm.prank(alice);
        wager.cancel(id);
        vm.prank(alice);
        wager.withdraw();
        assertEq(_held(), 0);
        assertEq(token.balanceOf(alice), 1_000 ether);
    }

    function testFuzz_onlyPlayerToMoveMayMove(address caller, uint8 cell) public {
        uint256 id = _openAndJoin();
        vm.assume(caller != alice);
        cell = uint8(bound(cell, 0, 8));
        vm.prank(caller);
        vm.expectRevert(abi.encodeWithSelector(TicTacToeWager.NotYourTurn.selector, id, caller));
        wager.move(id, cell);
    }

    function testFuzz_timeoutBoundary(uint32 elapsed) public {
        uint256 id = _openAndJoin();
        uint256 deadline = wager.moveDeadline(id);
        vm.warp(block.timestamp + elapsed);
        vm.prank(bob);
        if (elapsed < HOUR) {
            vm.expectRevert(
                abi.encodeWithSelector(TicTacToeWager.DeadlineNotReached.selector, id, deadline, block.timestamp)
            );
            wager.claimTimeout(id);
        } else {
            wager.claimTimeout(id);
            assertEq(wager.withdrawable(bob), 2 * STAKE);
        }
    }
}
