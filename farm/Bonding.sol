// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/IBondingFactory.sol";

contract Bonding is ReentrancyGuard {
  using SafeMath for uint256;

  using SafeERC20 for IERC20;

  struct UserInfo {
    uint256 amount;
    uint256 lastRewardTime;
    uint256 rewardDebt;
    uint256 totalDueRewardsAmount; // Adjusted each time a new deposit is made
  }

  mapping(address => UserInfo) public userInfo;

  IERC20 public bondToken; // Address of the bond token contract
  IERC20 public grailToken; // Address of the GRAIL token contract
  address public treasury; // Address of the treasury to which deposits will be sent

  IBondingFactory public immutable factory; // Address of the bonding factory contract

  uint256 public ratioDecimals; // number of decimals in the ratio, allowing to manage multiple token decimals
  uint256 public ratio;
  uint256 public startTime;
  uint256 public depositDuration;
  uint256 public vestingPeriod;
  uint256 public maxDepositAmount;
  bool public canHarvestBeforeEnd;

  bool public activated;
  bool public isInitialized;
  uint256 public totalDepositAmount;

  constructor() {
    factory = IBondingFactory(msg.sender);
  }

  function initialize(
    address bondToken_,
    IERC20 grailToken_,
    address treasury_,
    uint256 ratioDecimals_,
    uint256 ratio_,
    uint256 startTime_,
    uint256 depositDuration_,
    uint256 vestingPeriod_,
    uint256 maxDepositAmount_,
    bool canHarvestBeforeEnd_
  ) external {
    require(!isInitialized, "initialize: already initialized");
    require(msg.sender == address(factory), "initialize: caller isn't factory");

    bondToken = IERC20(bondToken_);
    grailToken = grailToken_;
    treasury = treasury_;
    ratio = ratio_;
    ratioDecimals = ratioDecimals_;
    startTime = startTime_;
    depositDuration = depositDuration_;
    vestingPeriod = vestingPeriod_;
    maxDepositAmount = maxDepositAmount_;
    canHarvestBeforeEnd = canHarvestBeforeEnd_;

    isInitialized = true;
  }

  /********************************************/
  /****************** EVENTS ******************/
  /********************************************/

  event RatioUpdated(uint256 prevRatio, uint256 prevRatioDecimals, uint256 newRatio, uint256 newRatioDecimals);
  event Activate();
  event Deposit(address indexed user, uint256 amount);
  event Harvest(address indexed user, uint256 amount);

  /***********************************************/
  /****************** MODIFIERS ******************/
  /***********************************************/

  modifier onlyOwner() {
    require(msg.sender == owner(), "onlyOwner: caller is not the owner");
    _;
  }

  /**************************************************/
  /****************** PUBLIC VIEWS ******************/
  /**************************************************/

  function owner() public view returns (address) {
    // The owner of all the converters is the ConverterFactory contract owner
    return factory.owner();
  }
  
  function depositEndTime() public view returns (uint256) {
    return startTime.add(depositDuration);
  }

  function rewardsEndTime() public view returns (uint256) {
    return depositEndTime().add(vestingPeriod);
  }

  function isDepositActive() public view returns (bool) {
    uint256 currentBlockTimestamp = _currentBlockTimestamp();
    return activated && startTime < currentBlockTimestamp && currentBlockTimestamp <= depositEndTime() && totalDepositAmount < maxDepositAmount;
  }

  /**
   * @dev Calculate the total GRAIL rewards that should be distributed for a given bondToken amount
   */
  function calculateRewards(uint256 amount) public view returns (uint256) {
    return amount.mul(ratio).div(10 ** ratioDecimals);
  }

  /**
  * @dev Calculate the max GRAIL rewards for the bonding
  *
  * If deposits are still active, based on maxDepositAmount instead of totalDepositAmount
  */
  function maxGRAILRewards() public view returns (uint256){
    if (_currentBlockTimestamp() <= depositEndTime()) return calculateRewards(maxDepositAmount);
    return calculateRewards(totalDepositAmount);
  }

  /**
   * @dev Calculate harvestable GRAIL rewards for a given user
   */
  function pendingRewards(address userAddress) public view returns (uint256) {
    UserInfo storage user = userInfo[userAddress];
    uint256 currentBlockTimestamp = _currentBlockTimestamp();

    if (user.amount == 0 || currentBlockTimestamp <= user.lastRewardTime) {
      return 0;
    }

    uint256 pendingDuration = currentBlockTimestamp.sub(user.lastRewardTime);
    uint256 pending = user.totalDueRewardsAmount.mul(pendingDuration).div(vestingPeriod);

    if (pending > user.totalDueRewardsAmount.sub(user.rewardDebt)) {
      pending = user.totalDueRewardsAmount.sub(user.rewardDebt);
    }
    return pending;
  }

  /****************************************************************/
  /****************** EXTERNAL PUBLIC FUNCTIONS  ******************/
  /****************************************************************/

  /**
   * @dev Deposits bond tokens
   */
  function deposit(uint256 amount) external nonReentrant {
    require(isDepositActive(), "deposit: deposits not allowed");
    require(amount > 0, "deposit: amount must be greater than 0");
    require(totalDepositAmount.add(amount) <= maxDepositAmount, "deposit: max deposit amount reached");

    address userAddress = msg.sender;
    UserInfo storage user = userInfo[userAddress];

    if (user.amount > 0) {
      // harvest pending rewards if user has already made a deposit
      _harvest(user, userAddress);
    }
    else {
      // rewards start
      user.lastRewardTime = _currentBlockTimestamp();
    }

    // handle bond token transfer tax if needed
    uint256 previousBalance = bondToken.balanceOf(treasury);
    bondToken.safeTransferFrom(userAddress, treasury, amount);
    amount = bondToken.balanceOf(treasury).sub(previousBalance);

    user.amount = user.amount.add(amount);

    uint256 rewardsAmount = calculateRewards(amount);
    user.totalDueRewardsAmount = user.totalDueRewardsAmount.add(rewardsAmount).sub(user.rewardDebt);
    user.rewardDebt = 0;
    totalDepositAmount = totalDepositAmount.add(amount);

    emit Deposit(userAddress, amount);
  }

  /**
   * @dev Harvests the sender's GRAIL pending rewards
   */
  function harvest() external {
    address userAddress = msg.sender;
    UserInfo storage user = userInfo[userAddress];

    _harvest(user, userAddress);
  }

  /****************************************************************/
  /****************** EXTERNAL OWNABLE FUNCTIONS  ******************/
  /****************************************************************/

  /**
  * @dev Update rewards ratio for bondToken
  *
  * Can only be called by the owner
  */
  function updateRatio(uint256 decimals, uint256 ratio_) external onlyOwner {
    require(_currentBlockTimestamp() < startTime, "updateRatio: not allowed");
    require(ratio_ > 0, "updateRatio: ratio invalid zero value");

    emit RatioUpdated(ratio, ratioDecimals, ratio_, decimals);
    ratioDecimals = decimals;
    ratio = ratio_;
  }

  /**
  * @dev Activate a Bonding contract
  *
  * Can only be called by a child Bonding contract
  */
  function activate() external onlyOwner {
    require(_currentBlockTimestamp() < startTime && !activated, "activate: not allowed");
    activated = true;
    emit Activate();
    factory.activateBondingContract(startTime, rewardsEndTime(), maxGRAILRewards());
  }

  /********************************************************/
  /****************** INTERNAL FUNCTIONS ******************/
  /********************************************************/

  /**
   * @dev Harvests user's GRAIL pending rewards
   *
   * If called before the end and canHarvestBeforeEnd_ is set to false, does nothing
   */
  function _harvest(UserInfo storage user, address userAddress) internal {
    if(user.amount == 0) return;

    uint256 currentBlockTimestamp = _currentBlockTimestamp();
    if (!canHarvestBeforeEnd && currentBlockTimestamp <= rewardsEndTime()) return;

    uint256 pending = pendingRewards(userAddress);
    user.lastRewardTime = currentBlockTimestamp;

    // nothing to harvest
    if (pending == 0) return;

    user.rewardDebt = user.rewardDebt.add(pending);
    emit Harvest(userAddress, pending);
    factory.mintRewards(userAddress, pending);
  }

  /**
   * @dev Utility function to get the current block timestamp
   */
  function _currentBlockTimestamp() internal view virtual returns (uint256) {
    return block.timestamp;
  }
}
