// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {TicTacToeWager} from "../../src/TicTacToeWager.sol";

/// @dev A hostile stand-in for NGHT. On every transfer *out of* the wager contract it calls back
/// into `withdraw()` and records whether that reentrant call succeeded. The real NGHT has no
/// hooks; this mock exists only to show the guard and the CEI ordering hold even if it did.
contract ReenteringToken is ERC20 {
    TicTacToeWager public wager;
    address public attacker;
    uint256 public reentryAttempts;
    uint256 public reentrySuccesses;
    bytes public lastReentryError;

    constructor() ERC20("Hostile", "HST") {
        _mint(msg.sender, 1_000_000 ether);
    }

    function arm(TicTacToeWager wager_, address attacker_) external {
        wager = wager_;
        attacker = attacker_;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from == address(wager) && to == attacker && address(wager) != address(0)) {
            ++reentryAttempts;
            // The reentrant call runs with this contract as msg.sender, which is not the attacker,
            // so we impersonate through the attacker contract instead.
            (bool ok, bytes memory err) = attacker.call(abi.encodeWithSignature("reenter()"));
            if (ok) {
                ++reentrySuccesses;
            } else {
                lastReentryError = err;
            }
        }
    }
}

/// @dev The attacker holds the credit and forwards the reentrant `withdraw()`.
contract Attacker {
    TicTacToeWager public immutable wager;

    constructor(TicTacToeWager wager_) {
        wager = wager_;
    }

    function approveAndOpen(ERC20 token, uint256 stake) external returns (uint256 id) {
        token.approve(address(wager), stake);
        id = wager.open(stake);
    }

    function cancel(uint256 id) external {
        wager.cancel(id);
    }

    function withdraw() external {
        wager.withdraw();
    }

    function reenter() external {
        wager.withdraw();
    }
}
