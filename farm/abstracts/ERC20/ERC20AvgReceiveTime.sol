// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/**
 * ERC20 implementation handling the average timestamp at which an account received his tokens
 */
abstract contract ERC20AvgReceiveTime is ERC20 {
  using SafeMath for uint256;

  event AvgReceiveTimeUpdated(address account, uint256 divTokenAmount, bool isSender, uint256 result);

  // Average time at which each account has received tokens, updated into _beforeTokenTransfer hook
  mapping(address => uint256) private _accountsAvgReceiveTime;

  /**
   * @dev Returns the average time at which an account received his tokens
   */
  function avgReceiveTimeOf(address account) public view returns (uint256) {
    return _accountsAvgReceiveTime[account];
  }

  /**
   * @dev Returns the average duration in seconds during which an account has held his tokens
   */
  function getAvgHoldingDuration(address account) public view returns (uint256) {
    uint256 avgReceiveTime = _accountsAvgReceiveTime[account];
    if (avgReceiveTime > 0) {
      return _currentBlockTimestamp().sub(avgReceiveTime);
    }
    return 0;
  }

  /**
   * @dev Pre-calculates the average received time of account tokens
   */
  function _getAccountAvgReceiveTime(
    address account,
    uint256 divTokenAmount,
    bool isSender
  ) internal view returns (uint256) {
    uint256 currentBlockTimestamp = _currentBlockTimestamp();

    // balance before transfer is done (not including divTokenAmount)
    uint256 userBalance = balanceOf(account);
    uint256 accountAvgReceiveTime = avgReceiveTimeOf(account);

    if (userBalance == 0) {
      return currentBlockTimestamp;
    }

    // account is sending divTokenAmount tokens
    if (isSender) {
      // check if user is sending all of his tokens
      if (userBalance == divTokenAmount) {
        // reinitialize "account"s avgReceiveTime
        return 0;
      } else {
        return accountAvgReceiveTime;
      }
    }

    // account is receiving divTokenAmount tokens
    uint256 previousTimeWeight = accountAvgReceiveTime.mul(userBalance);
    uint256 currentTimeWeight = currentBlockTimestamp.mul(divTokenAmount);
    uint256 avgReceiveTime = (previousTimeWeight.add(currentTimeWeight)).div(userBalance.add(divTokenAmount));

    // should never happen
    if (avgReceiveTime > currentBlockTimestamp) {
      return currentBlockTimestamp;
    }

    return avgReceiveTime;
  }

  /**
   * @dev Updates accountsAvgReceiveTime for each affected account on every transfer
   */
  function _beforeTokenTransfer(
    address from,
    address to,
    uint256 amount
  ) internal virtual override {
    super._beforeTokenTransfer(from, to, amount);

    if (amount == 0 || from == to) {
      return;
    }

    if (from != address(0)) {
      // "from" is sending "amount" of tokens to "to"
      _accountsAvgReceiveTime[from] = _getAccountAvgReceiveTime(from, amount, true);
      emit AvgReceiveTimeUpdated(from, amount, true, _accountsAvgReceiveTime[from]);
    }

    if (to != address(0)) {
      // "to" is receiving "amount" of tokens from "from"
      _accountsAvgReceiveTime[to] = _getAccountAvgReceiveTime(to, amount, false);
      emit AvgReceiveTimeUpdated(to, amount, false, _accountsAvgReceiveTime[to]);
    }
  }

  /**
   * @dev Utility function to get the current block timestamp
   */
  function _currentBlockTimestamp() internal view virtual returns (uint256) {
    return block.timestamp;
  }
}
