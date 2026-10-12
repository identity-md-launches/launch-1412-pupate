// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Test-only token that calls back. A harvest auction asks a token for nothing but the vault's
/// balance, so any contract can be put up as a lot; this one always reports a balance of one token
/// and, whenever its `transfer` or `transferFrom` is called, makes the one call it was armed with.
/// The outcome of that call is recorded and never bubbles up: the transfer reports success either
/// way, and the test judges the books afterwards.
contract ReenteringToken {
    address public target;
    bytes public armed;
    uint256 public armedValue;

    bool public called;
    bool public succeeded;
    bytes public refusal;
    /// @dev The ETH balance of whoever called the transfer, at the moment it reached this token.
    uint256 public callerBalanceSeen;

    receive() external payable {}

    /// @dev `data` is sent to `target` with `value` wei from inside the next transfer. An empty
    /// target disarms.
    function arm(address target_, bytes calldata data, uint256 value) external {
        target = target_;
        armed = data;
        armedValue = value;
        called = false;
        succeeded = false;
        refusal = "";
    }

    function balanceOf(address) external pure returns (uint256) {
        return 1 ether;
    }

    function transfer(address, uint256) external returns (bool) {
        _callBack();
        return true;
    }

    function transferFrom(address, address, uint256) external returns (bool) {
        _callBack();
        return true;
    }

    function _callBack() private {
        callerBalanceSeen = msg.sender.balance;
        if (target == address(0)) return;
        called = true;
        (bool ok, bytes memory ret) = target.call{value: armedValue}(armed);
        succeeded = ok;
        if (!ok) refusal = ret;
    }
}
