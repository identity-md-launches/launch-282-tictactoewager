# Noughts (NGHT) and TicTacToeWager

Sepolia test game with no real value. Two players stake equal amounts of NGHT on a game of
tic-tac-toe; the winner collects both stakes, a draw returns each stake, and a player who lets the
one-hour move clock run out forfeits to the opponent.

This repository holds the contracts, tests and ABI exports for the contract stage of the launch.
The manifest (`launch.json`), the independent adversarial review, the factory deployment and the
website are separate assignments and are not part of this commit.

| Contract | File | Role |
| --- | --- | --- |
| `LaunchToken` | `src/LaunchToken.sol` | Noughts (NGHT), the fixed-supply launch token |
| `TicTacToeWager` | `src/TicTacToeWager.sol` | The game; the only application contract |

ABI exports: `docs/abi/LaunchToken.json`, `docs/abi/TicTacToeWager.json`.

## Toolchain

- Foundry with `solc = "0.8.26"`, `evm_version = "cancun"`, `bytecode_hash = "none"`, optimizer on
  (200 runs). `ffi` is off and `fs_permissions` is empty.
- Dependencies are vendored as ordinary files under `lib/` (no submodules):
  `forge-std` v1.11.0 and `openzeppelin-contracts` v5.4.0 (contracts directory only).
- Remappings live in `remappings.txt`.

```sh
forge build
forge test
forge fmt --check
```

The tests read no environment variables and hold no fixed ordering; they pass in parallel and in
isolation. The invariant suite runs 64 sequences of depth 48 by default.

## LaunchToken (NGHT)

- OpenZeppelin `ERC20` with name `Noughts`, symbol `NGHT`, 18 decimals.
- No constructor arguments. The constructor mints exactly 1,000,000,000 NGHT
  (`10^27` minor units) to `msg.sender`, which at launch is the ProjectFactory.
- No owner, mint, burn hook, pause, blocklist, fee or upgrade path. Runtime contains no
  `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`.
- The factory routes the whole supply to the liquidity pool and reward distributor. Players obtain
  NGHT by swapping Sepolia ETH in that pool; nothing in this repository sells or gives out NGHT.

## TicTacToeWager

### Deployment parameters

| Parameter | Value |
| --- | --- |
| Constructor | `constructor(address token_)` |
| `constructorArgs` in the manifest | `["$token"]` |
| Owner / admin | none; there is no privileged role and no `$owner` argument |
| Payable functions | none; no `receive`, no `fallback` |
| NGHT held at deploy | zero; the constructor only stores the token address |
| Constants | `MIN_STAKE = 1e18` (1 NGHT), `MOVE_TIMEOUT = 3600` seconds |

The constructor reverts on a zero token address. Everything else is runtime state.

For the manifest assignment: the launch is `kind: "evm_project"` with `LaunchToken` as the launch
token and a single contract entry named `TicTacToeWager` (identifier of your choosing, at most 32
ASCII characters, not `MerkleDistributor`) whose `constructorArgs` is `["$token"]`. No other
argument is needed and no reference other than `$token` is meaningful for this contract.

### Rules implemented

- `open(stake)`: pulls `stake` NGHT (`>= 1 NGHT`, `<= type(uint96).max`) with
  `SafeERC20.safeTransferFrom`; the caller is X. Returns the new id. Ids are sequential from 0;
  `gameCount()` is one past the last id.
- `join(id)`: a different address matches the stake and becomes O. X moves first. X's clock starts
  at join.
- `cancel(id)`: creator only, only while nobody has joined. Credits the stake to the creator's
  withdrawable balance.
- `move(id, cell)`: `cell` in `0..8` row-major, only the player to move, only an empty cell, only
  while `Active`. The board is packed into one word: two bits per cell, cell `i` at bits
  `2i..2i+1`, `1 = X`, `2 = O`. After each move the eight lines are checked against a bitmap of the
  mover's cells only, so mixed lines and neighbouring-cell bits can never register as a win.
  - Win: game `Finished`, mover credited `2 x stake`, `Won` emitted.
  - Full board with no win: game `Finished`, each player credited `stake`, `Drawn` emitted.
  - Otherwise the turn passes and the opponent's deadline becomes `now + 1 hour`.
- `claimTimeout(id)`: only the player who is **not** to move, only while `Active`, only when
  `block.timestamp >= moveDeadline(id)`. Credits `2 x stake` to the claimant and finishes the game.
- `withdraw()`: `nonReentrant`; zeroes the caller's credit, then transfers it with `safeTransfer`.
  Reverts when nothing is credited.
- A `Finished` or `Cancelled` game rejects `join`, `cancel`, `move` and `claimTimeout`, so no game
  can pay out twice.

Views: `token()`, `gameCount()`, `game(id)` (full struct), `board(id)` (`uint8[9]`), `turn(id)`
(address to move, zero when not active), `moveDeadline(id)` (zero when not active),
`withdrawable(address)`.

Events: `Opened(id, creator, stake)`, `Joined(id, joiner)`, `Moved(id, player, cell)`,
`Won(id, winner, amount)`, `Drawn(id, amountEach)`, `TimedOut(id, claimant, loser, amount)`,
`Cancelled(id, creator, amount)`, `Withdrawn(account, amount)`.

### Timeout semantics, stated precisely

- The deadline is `lastMoveTimestamp + 3600` (or `joinTimestamp + 3600` for X's first move).
- A claim at `block.timestamp == deadline` succeeds. One second earlier it reverts with
  `DeadlineNotReached`.
- The clock is a claimable right, not an automatic end. A late player may still move while the game
  is `Active` if the opponent has not yet claimed; the move restarts the clock for the other side.
  Whichever transaction is mined first decides the game. This avoids a stuck state and keeps a
  single source of truth (`status`), at the cost of a mempool race that the website should surface
  by showing the timer.
- Block timestamps on Sepolia can drift by a few seconds under a builder's control. A one-hour
  window makes that immaterial for a test game; do not reuse this design for high-value stakes
  without a longer window.

### Funds and accounting

- Invariant, tested by unit and invariant suites: NGHT held by the contract equals the stake of
  every `Open` game plus twice the stake of every `Active` game plus every withdrawable balance.
- The contract never holds ETH. All payouts are pull-based, so a recipient that cannot receive
  tokens blocks only itself.
- `stake` is stored as `uint96`. The whole NGHT supply (`10^27`) fits with room to spare; larger
  values revert with `StakeTooLarge`.
- `open` and `join` record state before pulling tokens. If the pull reverts the whole call reverts,
  so no game is left half-funded.

## Assumptions

- The token passed to the constructor is NGHT as deployed by the factory: a standard, non-hooked,
  non-rebasing, non-fee ERC-20 that returns `true`. The contract does not measure balances before
  and after transfers; a fee-on-transfer or rebasing token would break the accounting invariant.
- Players and the site treat NGHT as a valueless Sepolia test asset.
- The contract is deployed by the ProjectFactory with `msg.sender` equal to the factory. Nothing in
  the constructor depends on `msg.sender`, so this is safe by construction.
- No randomness is used anywhere; the game is deterministic.

## Operational responsibilities

- **Nobody can administer this contract.** There is no owner, pause, upgrade, fee switch or rescue
  function. A bug found after deployment can only be addressed by deploying a new contract and
  pointing the website at it.
- **Manifest assignment**: name `LaunchToken` as the token and `TicTacToeWager` with
  `constructorArgs ["$token"]` as the only application contract; no `$owner`.
- **Independent review** should attack, at minimum: win detection on the packed board, timeout
  claims by the wrong party or at the boundary, paying a game twice (win then timeout), and
  reentrancy on `withdraw`. Tests for each of those exist here, but passing tests are not an audit.
- **Website**: read `token()` for the NGHT address, show balance, allowance and `withdrawable`,
  require an `approve` before `open` and `join`, show `turn(id)` and `moveDeadline(id)`, offer
  `claimTimeout` when the deadline has passed and the connected wallet is the opponent, and a
  `withdraw` button. Lists come from `gameCount()`, `game(id)` and the events above.
- **Players** are responsible for watching their own clocks. There is no keeper; a timeout must be
  claimed by the opponent.

## Tests

| File | Covers |
| --- | --- |
| `test/LaunchToken.t.sol` | metadata, exact supply to deployer, transfer, no admin selectors, no forbidden opcodes |
| `test/TicTacToeWager.t.sol` | every win line for X and for O, a draw, win on the last cell, out-of-turn, stranger, occupied and out-of-range cells, self-join, cancel after join, cancel twice, timeout at exactly one hour (and one second early), timeout from a mid-game move, wrong-party timeouts, win-then-timeout, late-move race, moves and claims after the end, withdraw paths, held == escrow + credits, fuzzed stakes, callers and elapsed times |
| `test/TicTacToeWagerReentrancy.t.sol` | a hostile token re-enters `withdraw` during payout; the guard refuses it and exactly one payment is made; other players' credits are untouched |
| `test/TicTacToeWager.invariant.t.sol` | handler-driven invariants: held == escrow + credits, token conservation, well-formed records, no ETH |
| `test/Deploy.t.sol` | the local deploy helper wires the token into the game; a factory-style deploy keeps the supply with the deployer |

`test/mocks/ReenteringToken.sol` is a test double only; it is not part of the launch.

## Local deployment helper

`script/Deploy.s.sol` deploys both contracts wired together for a local chain. It takes no
environment configuration and is exercised by `test/Deploy.t.sol`. The production launch does not
use it: the factory deploys from the manifest. This repository authorises no transactions and holds
no keys.

## Not decided here

- The manifest's contract identifier string and pool parameters belong to the manifest assignment
  and policy.
- The website's handling of the timeout race (warn when the deadline is within a few seconds) is a
  frontend decision.
