// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

import "./ERC20AvgReceiveTime.sol";
import "../../interfaces/tokens/IRegularToken.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * ERC20 implementation allowing to swap (unwrap) the current (=wrapped) token to regularToken (=unwrapped) with a
 * penalty based on average receive time
 *
 * Requires the authorization to mint the regularToken
 */
abstract contract WrapERC20WithPenalty is ERC20, ERC20AvgReceiveTime, ReentrancyGuard {
  using SafeMath for uint256;

  IRegularToken public immutable regularTokenAddress;

  /**
   * @dev Period in seconds during which the penalty to unwrap is decreasing, from _unwrapPenaltyMax to
   * _unwrapPenaltyMin
   */
  uint256 internal _unwrapPenaltyPeriod;

  /**
   * @dev Wrapped token to regular token unwrap max penalty
   * This penalty is intended to decrease over holding time
   * Example :
   *  - if _unwrapPenaltyMax = 30*1e10 (=30%). At maximum penalty : 1 unwrapped = 0.7 regular
   */
  uint256 internal _unwrapPenaltyMax;

  /**
   * @dev Wrapped token to regular token unwrap min penalty
   * A user's penalty to unwrap will be at this minimum once the _unwrapPenaltyPeriod is over
   * Example :
   *  - if _unwrapPenaltyMin = 10*1e10 (=10%). At minimum penalty : 1 unwrapped = 0.9 regular
   */
  uint256 internal _unwrapPenaltyMin;

  /**
   * @dev Initializes the contract of the token to unwrap to
   */
  constructor(
    uint256 penaltyPeriod,
    uint256 penaltyMin,
    uint256 penaltyMax,
    IRegularToken regularToken
  ) {
    require(penaltyMax >= _unwrapPenaltyMin && penaltyMax <= 100 && penaltyMax <= 100, "WrapERC20WithPenalty: invalid penalty min/max");
    _unwrapPenaltyPeriod = penaltyPeriod;
    _unwrapPenaltyMin = penaltyMin.mul(1e10);
    _unwrapPenaltyMax = penaltyMax.mul(1e10);
    regularTokenAddress = regularToken;
  }

  /********************************************/
  /****************** EVENTS ******************/
  /********************************************/

  event Unwrap(address account, uint256 wrapTokenAmount, uint256 unwrappedTokenAmount);

  /**************************************************/
  /****************** PUBLIC VIEWS ******************/
  /**************************************************/

  function unwrapPenaltyPeriod() external view returns (uint256) {
    return _unwrapPenaltyPeriod;
  }

  function unwrapPenaltyMin() external view returns (uint256) {
    return _unwrapPenaltyMin.div(1e10);
  }

  function unwrapPenaltyMax() external view returns (uint256) {
    return _unwrapPenaltyMax.div(1e10);
  }

  /**
   * @dev Calculates the current unwrapping penalty (* 1e10) for a given account
   * The penalty decreases over time (based on holding duration) from unwrapPenaltyMax% initially, to unwrapPenaltyMin%
   * when unwrapPenaltyPeriod is over
   */
  function getAccountPenalty(address account) public view returns (uint256) {
    uint256 avgHoldingDuration = getAvgHoldingDuration(account);

    // check if unwrapPenaltyPeriod has been exceeded
    if (avgHoldingDuration >= _unwrapPenaltyPeriod) {
      return _unwrapPenaltyMin;
    }

    if (avgHoldingDuration > 0) {
      return
        _unwrapPenaltyMax.sub(
          (_unwrapPenaltyMax.sub(_unwrapPenaltyMin)).mul(avgHoldingDuration).div(_unwrapPenaltyPeriod)
        );
    }

    return _unwrapPenaltyMax;
  }

  /**
   * @dev Returns the amount of regular token an account will get when unwrapping "amount" of wrapped token
   *
   * This function assumes that the amount is equal or lower than the current account's balance, else the result
   * won't be accurate
   */
  function getExpectedUnwrappedTokenAmount(address account, uint256 amount) public view returns (uint256) {
    uint256 currentPenalty = getAccountPenalty(account);
    if (currentPenalty > 0) {
      uint256 max = 1e12;
      return amount.mul(max.sub(currentPenalty)).div(1e12);
    }
    return amount;
  }

  /****************************************************************/
  /****************** EXTERNAL PUBLIC FUNCTIONS  ******************/
  /****************************************************************/

  /**
   * @dev Unwraps a given amount of wrapped token to regular token
   *
   * Wrapped token amount is burnt
   * Regular token is minted to the user account
   */
  function unwrap(uint256 amount) external nonReentrant {
    address account = msg.sender;

    require(balanceOf(account) >= amount, "WrapERC20WithPenalty: unwrap amount exceeds balance");
    require(amount > 0, "WrapERC20WithPenalty: unwrap amount 0");

    uint256 unwrappedTokenAmount = getExpectedUnwrappedTokenAmount(account, amount);

    emit Unwrap(account, amount, unwrappedTokenAmount);
    _burn(account, amount);
    regularTokenAddress.mint(account, unwrappedTokenAmount);
  }

  /********************************************************/
  /****************** INTERNAL FUNCTIONS ******************/
  /********************************************************/

  function _beforeTokenTransfer(
    address from,
    address to,
    uint256 amount
  ) internal virtual override(ERC20, ERC20AvgReceiveTime) {
    ERC20AvgReceiveTime._beforeTokenTransfer(from, to, amount);
  }
}
