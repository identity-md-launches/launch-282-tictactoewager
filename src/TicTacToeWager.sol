// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title TicTacToeWager
/// @notice Two-player tic-tac-toe with equal NGHT stakes. Many games run side by side, each
/// identified by a sequential id.
/// @dev Design summary:
/// - The only constructor argument is the NGHT token address. The contract holds no NGHT at
///   deployment; every stake is pulled with `approve` + `safeTransferFrom`.
/// - There is no payable function and no receive/fallback, so the contract never holds ETH.
/// - All payouts are pull-based. Wins, draws, timeouts and cancellations credit an internal
///   balance and the recipient calls `withdraw()` to collect. Nothing is pushed to a third party.
/// - `withdraw()` is nonReentrant and follows checks-effects-interactions.
/// - No owner, admin, pause or upgrade path exists.
/// - The board is packed into one storage word: two bits per cell, cell `i` at bits `2i..2i+1`,
///   value 0 = empty, 1 = X, 2 = O.
/// - The move clock is a claimable right, not an automatic end: while a game is `Active` the
///   player to move may still move at or after the deadline as long as the opponent has not yet
///   called `claimTimeout`. Whichever transaction lands first decides the game.
contract TicTacToeWager is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------------------------

    /// @notice Lifecycle of a game.
    /// @dev `None` is never stored; it is what an unused id reads as.
    enum Status {
        None,
        Open,
        Active,
        Finished,
        Cancelled
    }

    /// @notice Mark on a cell, also used to name the player to move.
    enum Mark {
        Empty,
        X,
        O
    }

    /// @notice Full game record. Fits in two storage slots.
    struct Game {
        address playerX; // creator; moves first
        uint96 stake; // per-player stake in NGHT minor units
        address playerO; // joiner; zero while Open
        uint40 moveDeadline; // unix time; while Active, the player to move may be timed out at or after it
        uint32 board; // 18 bits used, two per cell
        Status status;
        Mark turn; // player to move while Active; last mover's mark otherwise
    }

    // ---------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------

    /// @notice Smallest stake accepted by `open`: 1 NGHT.
    uint256 public constant MIN_STAKE = 1e18;

    /// @notice Time the player to move has before the opponent may claim the pot.
    uint256 public constant MOVE_TIMEOUT = 1 hours;

    /// @dev Nine occupied-cell bits.
    uint256 private constant FULL_BOARD = 0x1FF;

    /// @dev The eight winning lines as 9-bit cell bitmaps (bit i = cell i).
    uint256 private constant LINE_ROW_0 = 0x007; // 0 1 2
    uint256 private constant LINE_ROW_1 = 0x038; // 3 4 5
    uint256 private constant LINE_ROW_2 = 0x1C0; // 6 7 8
    uint256 private constant LINE_COL_0 = 0x049; // 0 3 6
    uint256 private constant LINE_COL_1 = 0x092; // 1 4 7
    uint256 private constant LINE_COL_2 = 0x124; // 2 5 8
    uint256 private constant LINE_DIAG_0 = 0x111; // 0 4 8
    uint256 private constant LINE_DIAG_1 = 0x054; // 2 4 6

    // ---------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------

    IERC20 private immutable _token;
    uint256 private _gameCount;
    mapping(uint256 id => Game) private _games;
    mapping(address account => uint256 amount) private _withdrawable;

    // ---------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------

    event Opened(uint256 indexed id, address indexed creator, uint256 stake);
    event Joined(uint256 indexed id, address indexed joiner);
    event Moved(uint256 indexed id, address indexed player, uint8 cell);
    event Won(uint256 indexed id, address indexed winner, uint256 amount);
    event Drawn(uint256 indexed id, uint256 amountEach);
    event TimedOut(uint256 indexed id, address indexed claimant, address indexed loser, uint256 amount);
    event Cancelled(uint256 indexed id, address indexed creator, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);

    // ---------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------

    error ZeroToken();
    error StakeTooLow(uint256 stake, uint256 minimum);
    error StakeTooLarge(uint256 stake);
    error GameNotFound(uint256 id);
    error GameNotOpen(uint256 id);
    error GameNotActive(uint256 id);
    error NotCreator(uint256 id, address caller);
    error SelfJoin(uint256 id);
    error NotYourTurn(uint256 id, address caller);
    error CellOutOfRange(uint8 cell);
    error CellOccupied(uint256 id, uint8 cell);
    error NotOpponent(uint256 id, address caller);
    error DeadlineNotReached(uint256 id, uint256 deadline, uint256 now_);
    error NothingToWithdraw(address account);

    // ---------------------------------------------------------------------------------------
    // Construction
    // ---------------------------------------------------------------------------------------

    /// @param token_ The NGHT launch token used for every stake and payout.
    constructor(address token_) {
        if (token_ == address(0)) revert ZeroToken();
        _token = IERC20(token_);
    }

    // ---------------------------------------------------------------------------------------
    // Player actions
    // ---------------------------------------------------------------------------------------

    /// @notice Open a new game and stake `stake` NGHT as player X.
    /// @dev Requires a prior `approve(this, stake)`. Effects are recorded before the pull so a
    /// failed transfer reverts the whole call.
    /// @return id The new game's id.
    function open(uint256 stake) external returns (uint256 id) {
        if (stake < MIN_STAKE) revert StakeTooLow(stake, MIN_STAKE);
        if (stake > type(uint96).max) revert StakeTooLarge(stake);

        id = _gameCount++;
        Game storage g = _games[id];
        g.playerX = msg.sender;
        g.stake = uint96(stake);
        g.status = Status.Open;

        emit Opened(id, msg.sender, stake);
        _token.safeTransferFrom(msg.sender, address(this), stake);
    }

    /// @notice Join an open game as player O by matching the creator's stake.
    /// @dev Requires a prior `approve(this, stake)`. X moves first; X's clock starts now.
    function join(uint256 id) external {
        Game storage g = _existing(id);
        if (g.status != Status.Open) revert GameNotOpen(id);
        if (msg.sender == g.playerX) revert SelfJoin(id);

        g.playerO = msg.sender;
        g.status = Status.Active;
        g.turn = Mark.X;
        g.moveDeadline = uint40(block.timestamp + MOVE_TIMEOUT);

        emit Joined(id, msg.sender);
        _token.safeTransferFrom(msg.sender, address(this), g.stake);
    }

    /// @notice Cancel a game nobody has joined and credit the stake back to the creator.
    /// @dev The refund lands in the creator's withdrawable balance; call `withdraw()` to collect.
    function cancel(uint256 id) external {
        Game storage g = _existing(id);
        if (g.status != Status.Open) revert GameNotOpen(id);
        if (msg.sender != g.playerX) revert NotCreator(id, msg.sender);

        g.status = Status.Cancelled;
        uint256 amount = g.stake;
        _withdrawable[msg.sender] += amount;

        emit Cancelled(id, msg.sender, amount);
    }

    /// @notice Place your mark on `cell` (0..8, row-major) in an active game.
    /// @dev After the move the eight lines are checked. A win credits the mover 2 x stake, a full
    /// board with no win credits each player their stake back. Otherwise the turn passes and the
    /// opponent's clock restarts.
    function move(uint256 id, uint8 cell) external {
        Game storage g = _existing(id);
        if (g.status != Status.Active) revert GameNotActive(id);
        if (cell > 8) revert CellOutOfRange(cell);

        Mark mark = g.turn;
        address mover = mark == Mark.X ? g.playerX : g.playerO;
        if (msg.sender != mover) revert NotYourTurn(id, msg.sender);

        uint32 board = g.board;
        uint256 shift = uint256(cell) * 2;
        if ((board >> shift) & 3 != 0) revert CellOccupied(id, cell);

        board |= uint32(uint256(mark) << shift);
        g.board = board;

        emit Moved(id, msg.sender, cell);

        uint256 mine = _bitmap(board, mark);
        if (_hasLine(mine)) {
            g.status = Status.Finished;
            g.moveDeadline = 0;
            uint256 pot = uint256(g.stake) * 2;
            _withdrawable[msg.sender] += pot;
            emit Won(id, msg.sender, pot);
            return;
        }

        uint256 theirs = _bitmap(board, mark == Mark.X ? Mark.O : Mark.X);
        if ((mine | theirs) == FULL_BOARD) {
            g.status = Status.Finished;
            g.moveDeadline = 0;
            uint256 stake = g.stake;
            _withdrawable[g.playerX] += stake;
            _withdrawable[g.playerO] += stake;
            emit Drawn(id, stake);
            return;
        }

        g.turn = mark == Mark.X ? Mark.O : Mark.X;
        g.moveDeadline = uint40(block.timestamp + MOVE_TIMEOUT);
    }

    /// @notice Claim the pot when the player to move has let the clock run out.
    /// @dev Only the player who is *not* to move may claim, and only once `block.timestamp` has
    /// reached `moveDeadline(id)`. A finished, cancelled or open game cannot be claimed.
    function claimTimeout(uint256 id) external {
        Game storage g = _existing(id);
        if (g.status != Status.Active) revert GameNotActive(id);

        uint256 deadline = g.moveDeadline;
        if (block.timestamp < deadline) revert DeadlineNotReached(id, deadline, block.timestamp);

        (address loser, address claimant) = g.turn == Mark.X ? (g.playerX, g.playerO) : (g.playerO, g.playerX);
        if (msg.sender != claimant) revert NotOpponent(id, msg.sender);

        g.status = Status.Finished;
        g.moveDeadline = 0;
        uint256 pot = uint256(g.stake) * 2;
        _withdrawable[msg.sender] += pot;

        emit TimedOut(id, msg.sender, loser, pot);
    }

    /// @notice Collect every NGHT credited to the caller.
    function withdraw() external nonReentrant {
        uint256 amount = _withdrawable[msg.sender];
        if (amount == 0) revert NothingToWithdraw(msg.sender);

        _withdrawable[msg.sender] = 0;
        emit Withdrawn(msg.sender, amount);
        _token.safeTransfer(msg.sender, amount);
    }

    // ---------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------

    /// @notice The NGHT token every stake is denominated in.
    function token() external view returns (address) {
        return address(_token);
    }

    /// @notice Number of games ever opened. Ids run from 0 to `gameCount() - 1`.
    function gameCount() external view returns (uint256) {
        return _gameCount;
    }

    /// @notice Full record of game `id`.
    function game(uint256 id) external view returns (Game memory) {
        return _existing(id);
    }

    /// @notice Board of game `id` as nine cells, row-major: 0 empty, 1 X, 2 O.
    function board(uint256 id) external view returns (uint8[9] memory cells) {
        uint32 packed = _existing(id).board;
        for (uint256 i; i < 9; ++i) {
            cells[i] = uint8((packed >> (i * 2)) & 3);
        }
    }

    /// @notice Address of the player to move, or zero when the game is not active.
    function turn(uint256 id) external view returns (address) {
        Game storage g = _existing(id);
        if (g.status != Status.Active) return address(0);
        return g.turn == Mark.X ? g.playerX : g.playerO;
    }

    /// @notice Timestamp at or after which the opponent may call `claimTimeout`, or zero when the
    /// game is not active.
    function moveDeadline(uint256 id) external view returns (uint256) {
        Game storage g = _existing(id);
        if (g.status != Status.Active) return 0;
        return g.moveDeadline;
    }

    /// @notice NGHT credited to `account` and collectable through `withdraw()`.
    function withdrawable(address account) external view returns (uint256) {
        return _withdrawable[account];
    }

    // ---------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------

    function _existing(uint256 id) private view returns (Game storage g) {
        if (id >= _gameCount) revert GameNotFound(id);
        g = _games[id];
    }

    /// @dev Nine-bit bitmap of the cells holding `mark`.
    function _bitmap(uint32 packed, Mark mark) private pure returns (uint256 bits) {
        uint256 m = uint256(mark);
        for (uint256 i; i < 9; ++i) {
            if ((packed >> (i * 2)) & 3 == m) bits |= 1 << i;
        }
    }

    /// @dev True when `bits` covers at least one of the eight lines.
    function _hasLine(uint256 bits) private pure returns (bool) {
        return (bits & LINE_ROW_0) == LINE_ROW_0 || (bits & LINE_ROW_1) == LINE_ROW_1
            || (bits & LINE_ROW_2) == LINE_ROW_2 || (bits & LINE_COL_0) == LINE_COL_0
            || (bits & LINE_COL_1) == LINE_COL_1 || (bits & LINE_COL_2) == LINE_COL_2
            || (bits & LINE_DIAG_0) == LINE_DIAG_0 || (bits & LINE_DIAG_1) == LINE_DIAG_1;
    }
}
