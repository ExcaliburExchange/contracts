// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";

import "./interfaces/IDividends.sol";

/*
 * This contract is used to distribute dividends to GRAIL holders
 *
 * Dividends can be distributed in the form of one or more tokens
 * They are mainly managed to be received from the FeeManager contract, but other sources can be added (dev wallet for instance)
 *
 * The freshly received dividends are stored in a pending slot
 *
 * The content of this pending slot will be progressively transferred over time into a distribution slot
 * This distribution slot is the source of the dividends distribution to GRAIL holders during the current cycle
 *
 * This transfer from the pending slot to the distribution slot is based on cycleDividendsPercent and CYCLE_PERIOD_SECONDS
 *
 */
contract Dividends is Ownable, ReentrancyGuard, IDividends {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;
  using EnumerableSet for EnumerableSet.AddressSet;

  struct UserInfo {
    uint256 pendingDividends;
    uint256 lastGrailBalance;
    uint256 rewardDebt;
  }

  struct DividendsInfo {
    uint256 currentDistributionAmount; // total amount to distribute during the current cycle
    uint256 currentCycleDistributedAmount; // amount already distributed for the current cycle (times 1e2)
    uint256 pendingAmount; // total amount in the pending slot, not distributed yet
    uint256 distributedAmount; // total amount that has been distributed since initialization
    uint256 accDividendsPerShare; // accumulated dividends per share (times 1e18)
    uint256 lastUpdateTime; // last time the dividends distribution occurred
    uint256 cycleDividendsPercent; // fixed part of the pending dividends to assign to currentDistributionAmount on every cycle
    bool distributionDisabled; // deactivate a token distribution (for temporary dividends)
  }

  // actively distributed tokens
  EnumerableSet.AddressSet private _distributedTokens;
  uint256 public MAX_DISTRIBUTED_TOKENS = 10;

  // dividends info for every dividends token
  mapping(address => DividendsInfo) public dividendsInfo;
  mapping(address => mapping(address => UserInfo)) public users;
  // trustable addresses authorized to fund this contract's pendingAmount
  mapping(address => bool) public trustedDividendsSource;

  IERC20 public immutable grailToken;

  uint256 public constant MIN_CYCLE_DIVIDENDS_PERCENT = 5;
  uint256 public constant MAX_CYCLE_DIVIDENDS_PERCENT = 100;
  // dividends will be added to the currentDistributionAmount on each new cycle
  uint256 public cycleDurationSeconds = 1 days;
  uint256 public currentCycleStartTime;

  // Allow to exclude addresses from the dividends system
  // Intended to avoid dividends to be distributed to contracts where they might be lost forever (for instance LP tokens addresses)
  // Should at least include the Master and the Converters since they handle pending GRAIL rewards
  // Only contract addresses can be excluded (see excludeContract)
  mapping(address => bool) public excludedContracts;
  uint256 public excludedContractsTotalBalance;

  constructor(IERC20 grailToken_, uint256 startTime_) {
    grailToken = grailToken_;
    currentCycleStartTime = startTime_;
  }

  /********************************************/
  /****************** EVENTS ******************/
  /********************************************/

  event UserUpdated(address indexed user, uint256 previousBalance, uint256 newBalance);
  event DividendsCollected(address indexed user, address indexed token, uint256 amount);
  event CycleDividendsPercentUpdated(address indexed token, uint256 previousValue, uint256 newValue);
  event DividendsAddedToPending(address indexed token, uint256 amount);
  event DistributedTokenDisabled(address indexed token);
  event DistributedTokenRemoved(address indexed token);
  event DistributedTokenEnabled(address indexed token);
  event UpdateTrustedDividendsSource(address indexed sourceAddress, bool trustable);
  event ContractExcluded(address indexed account, bool isExcluded);

  /***********************************************/
  /****************** MODIFIERS ******************/
  /***********************************************/

  /*
   * @dev Checks if an index exists
   */
  modifier validateDistributedTokensIndex(uint256 index) {
    require(index < _distributedTokens.length(), "validateDistributedTokensIndex: index exists?");
    _;
  }

  modifier validateDistributedToken(address token){
    require(_distributedTokens.contains(token), "validateDistributedTokens: token does not exists");
    _;
  }

  /*
   * @dev Checks if caller is grailToken
   */
  modifier onlyGrailToken() {
    require(msg.sender == address(grailToken), "Dividends: caller is not GRAIL token");
    _;
  }

  /*******************************************/
  /****************** VIEWS ******************/
  /*******************************************/

  /**
   * @dev Returns the total supply of GRAIL accounting for the dividends distribution
   */
  function activeGrailSupply() public view returns (uint256) {
    return grailToken.totalSupply().sub(excludedContractsTotalBalance);
  }

  /**
   * @dev Returns the number of dividends tokens
   */
  function distributedTokensLength() external view override returns (uint256) {
    return _distributedTokens.length();
  }

  /**
   * @dev Returns dividends token address from given index
   */
  function distributedToken(uint256 index) external view override validateDistributedTokensIndex(index) returns (address){
    return address(_distributedTokens.at(index));
  }

  /**
   * @dev Returns true if given token is a dividends token
   */
  function isDistributedToken(address token) external view override returns (bool) {
    return _distributedTokens.contains(token);
  }

  /**
   * @dev Returns time at which the next cycle will start
   */
  function nextCycleStartTime() public view returns (uint256) {
    return currentCycleStartTime.add(cycleDurationSeconds);
  }

  /**
   * @dev Returns user's dividends pending amount for a given token
   */
  function pendingDividendsAmount(address token, address userAddress) external view returns (uint256) {
    if (activeGrailSupply() == 0) {
      return 0;
    }

    DividendsInfo storage dividendsInfo_ = dividendsInfo[token];

    uint256 accDividendsPerShare = dividendsInfo_.accDividendsPerShare;
    uint256 lastUpdateTime = dividendsInfo_.lastUpdateTime;
    uint256 dividendAmountPerSecond_ = _dividendsAmountPerSecond(token);

    // check if the current cycle has changed since last update
    if (_currentBlockTimestamp() > nextCycleStartTime()) {
      // get remaining rewards from last cycle
      accDividendsPerShare = accDividendsPerShare.add(
        (nextCycleStartTime().sub(lastUpdateTime)).mul(dividendAmountPerSecond_).mul(1e16).div(activeGrailSupply())
      );
      lastUpdateTime = nextCycleStartTime();
      dividendAmountPerSecond_ = dividendsInfo_.pendingAmount.mul(dividendsInfo_.cycleDividendsPercent).div(
        cycleDurationSeconds
      ); // .mul(1e2).div(100)
    }

    // get pending rewards from current cycle
    accDividendsPerShare = accDividendsPerShare.add(
      (_currentBlockTimestamp().sub(lastUpdateTime)).mul(dividendAmountPerSecond_).mul(1e16).div(activeGrailSupply())
    );
    return
      grailToken
        .balanceOf(userAddress)
        .mul(accDividendsPerShare)
        .div(1e18)
        .sub(users[token][userAddress].rewardDebt)
        .add(users[token][userAddress].pendingDividends);
  }

  /**************************************************/
  /****************** PUBLIC FUNCTIONS **************/
  /**************************************************/

  /**
   * @dev Updates the current cycle start time if previous cycle has ended
   */
  function updateCurrentCycleStartTime() public {
    uint256 nextCycleStartTime_ = nextCycleStartTime();

    if (_currentBlockTimestamp() >= nextCycleStartTime_) {
      currentCycleStartTime = nextCycleStartTime_;
    }
  }

  /**
   * @dev Updates dividends info for a given token
   */
  function updateDividendsInfo(address token) external validateDistributedToken(token) {
    _updateDividendsInfo(token, activeGrailSupply());
  }

  /****************************************************************/
  /****************** EXTERNAL PUBLIC FUNCTIONS  ******************/
  /****************************************************************/

  /**
   * @dev Updates all dividendsInfo
   */
  function massUpdateDividendsInfo() external {
    uint256 length = _distributedTokens.length();
    for (uint256 index = 0; index < length; ++index) {
      _updateDividendsInfo(_distributedTokens.at(index), activeGrailSupply());
    }
  }

  /**
   * @dev Harvests caller's pending dividends of a given token
   */
  function harvestDividends(address token) external nonReentrant {
    require(!excludedContracts[msg.sender], "harvestDividends: Caller is excluded");
    if (!_distributedTokens.contains(token)) {
      require(dividendsInfo[token].distributedAmount > 0, 'harvestDividends: invalid token');
    }

    _harvestDividends(msg.sender, token);
  }

  /**
   * @dev Harvests all caller's pending dividends
   */
  function harvestAllDividends() external nonReentrant {
    require(!excludedContracts[msg.sender], "harvestDividends: Caller is excluded");

    for (uint256 index = 0; index < _distributedTokens.length(); ++index) {
      _harvestDividends(msg.sender, _distributedTokens.at(index));
    }
  }

  /**
   * @dev Transfers the given amount of token from caller to pendingAmount
   *
   * Must only be called by a trustable address
   */
  function addDividendsToPending(address token, uint256 amount) external override nonReentrant {
    require(trustedDividendsSource[msg.sender], "addDividendsToPending: Non trusted source");

    uint256 prevTokenBalance = IERC20(token).balanceOf(address(this));
    DividendsInfo storage dividendsInfo_ = dividendsInfo[token];

    IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

    // handle tokens with transfer tax
    uint256 receivedAmount = IERC20(token).balanceOf(address(this)).sub(prevTokenBalance);
    dividendsInfo_.pendingAmount = dividendsInfo_.pendingAmount.add(receivedAmount);

    emit DividendsAddedToPending(token, receivedAmount);
  }

  /*****************************************************************/
  /****************** OWNABLE FUNCTIONS  ******************/
  /*****************************************************************/

  /**
   * @dev Updates a given user info when his GRAIL balance changed
   *
   * Must only be called by a trusted source (GRAIL token contract)
   */
  function updateUser(address userAddress, uint256 previousUserGrailBalance, uint256 previousTotalSupply) external override nonReentrant onlyGrailToken {
    _updateUser(userAddress, previousUserGrailBalance, previousTotalSupply);
  }

  /**
   * @dev Enables a given token to be distributed as dividends
   *
   * Effective from the next cycle
   */
  function enableDistributedToken(address token) external onlyOwner {
    DividendsInfo storage dividendsInfo_ = dividendsInfo[token];
    require(
      dividendsInfo_.lastUpdateTime == 0 || dividendsInfo_.distributionDisabled,
      "enableDistributedToken: Already enabled dividends token"
    );
    require(_distributedTokens.length() < MAX_DISTRIBUTED_TOKENS, "enableDistributedToken: too many distributedTokens");
    // initialize lastUpdateTime if never set before
    if (dividendsInfo_.lastUpdateTime == 0) {
      dividendsInfo_.lastUpdateTime = _currentBlockTimestamp();
    }
    // initialize cycleDividendsPercent to the minimum if never set before
    if (dividendsInfo_.cycleDividendsPercent == 0) {
      dividendsInfo_.cycleDividendsPercent = MIN_CYCLE_DIVIDENDS_PERCENT;
    }
    dividendsInfo_.distributionDisabled = false;
    _distributedTokens.add(token);
    emit DistributedTokenEnabled(token);
  }

  /**
   * @dev Disables distribution of a given token as dividends
   *
   * Effective from the next cycle
   */
  function disableDistributedToken(address token) external onlyOwner {
    DividendsInfo storage dividendsInfo_ = dividendsInfo[token];
    require(
      dividendsInfo_.lastUpdateTime > 0 && !dividendsInfo_.distributionDisabled,
      "disableDistributedToken: Already disabled dividends token"
    );
    dividendsInfo_.distributionDisabled = true;
    emit DistributedTokenDisabled(token);
  }

  /**
   * @dev Handles contract exclusions from the dividends distribution
   */
  function excludeContract(address account, bool excluded) external onlyOwner {
    require(excludedContracts[account] != excluded, "excludeContract: already excluded or included");
    require(_isContract(account), "excludeContract: Cannot exclude non contract address");
    uint256 accountGrailBalance = grailToken.balanceOf(account);
    if (excluded) {
      excludedContractsTotalBalance = excludedContractsTotalBalance.add(accountGrailBalance);
    } else {
      excludedContractsTotalBalance = excludedContractsTotalBalance.sub(accountGrailBalance);
    }
    _updateUser(account, accountGrailBalance, grailToken.totalSupply());
    excludedContracts[account] = excluded;
    emit ContractExcluded(account, excluded);
  }

  /**
   * @dev Updates the percentage of pending dividends that will be distributed during the next cycle
   *
   * Must be a value between MIN_CYCLE_DIVIDENDS_PERCENT and MAX_CYCLE_DIVIDENDS_PERCENT
   */
  function updateCycleDividendsPercent(address token, uint256 percent) external onlyOwner {
    require(percent <= MAX_CYCLE_DIVIDENDS_PERCENT, "updateCycleDividendsPercent: percent mustn't exceed maximum");
    require(percent >= MIN_CYCLE_DIVIDENDS_PERCENT, "updateCycleDividendsPercent: percent mustn't exceed minimum");
    DividendsInfo storage dividendsInfo_ = dividendsInfo[token];
    uint256 previousPercent = dividendsInfo_.cycleDividendsPercent;
    dividendsInfo_.cycleDividendsPercent = percent;
    emit CycleDividendsPercentUpdated(token, previousPercent, dividendsInfo_.cycleDividendsPercent);
  }

  /**
   * @dev Updates whether given sourceAddress should be handled as a dividends source
   *
   * Must only be called by the owner
   */
  function updateTrustedDividendsSource(address sourceAddress, bool trustable) external onlyOwner {
    trustedDividendsSource[sourceAddress] = trustable;
    emit UpdateTrustedDividendsSource(sourceAddress, trustable);
  }

  /**
  * @dev remove an address from _distributedTokens
  *
  * Can only be valid for a disabled dividends token and if the distribution has ended
  */
  function removeTokenFromDistributedTokens(address tokenToRemove) external onlyOwner {
    DividendsInfo storage _dividendsInfo = dividendsInfo[tokenToRemove];
    require(_dividendsInfo.distributionDisabled && _dividendsInfo.currentDistributionAmount == 0, "removeTokenFromDistributedTokens: cannot be removed");
    _distributedTokens.remove(tokenToRemove);
    emit DistributedTokenRemoved(tokenToRemove);
  }

  /********************************************************/
  /****************** INTERNAL FUNCTIONS ******************/
  /********************************************************/

  /**
   * @dev Returns the amount of dividends token distributed every second (times 1e2)
   */
  function _dividendsAmountPerSecond(address token) internal view returns (uint256) {
    if (!_distributedTokens.contains(token)) return 0;
    return dividendsInfo[token].currentDistributionAmount.mul(1e2).div(cycleDurationSeconds);
  }

  function _updateDividendsInfo(address token, uint256 activeGrailSupply_) internal {
    uint256 currentBlockTimestamp = _currentBlockTimestamp();
    DividendsInfo storage dividendsInfo_ = dividendsInfo[token];

    updateCurrentCycleStartTime();

    uint256 lastUpdateTime = dividendsInfo_.lastUpdateTime;
    uint256 accDividendsPerShare = dividendsInfo_.accDividendsPerShare;
    if (currentBlockTimestamp <= lastUpdateTime) {
      return;
    }

    // if no GRAIL is active or initial distribution has not started yet
    if (activeGrailSupply_ == 0 || currentBlockTimestamp < currentCycleStartTime) {
      dividendsInfo_.lastUpdateTime = currentBlockTimestamp;
      return;
    }

    // check if the current cycle has changed since last update
    if (lastUpdateTime < currentCycleStartTime) {
      // update accDividendPerShare for the end of the previous cycle
      accDividendsPerShare = accDividendsPerShare.add(
        (dividendsInfo_.currentDistributionAmount.mul(1e2).sub(dividendsInfo_.currentCycleDistributedAmount))
          .mul(1e16)
          .div(activeGrailSupply_)
      );

      // check if distribution is enabled
      if (!dividendsInfo_.distributionDisabled) {
        // transfer the token's cycleDividendsPercent part from the pending slot to the distribution slot
        uint256 currentDistributionAmount = dividendsInfo_.pendingAmount.mul(dividendsInfo_.cycleDividendsPercent).div(
          100
        );
        dividendsInfo_.distributedAmount = dividendsInfo_.distributedAmount.add(
          dividendsInfo_.currentDistributionAmount
        );
        dividendsInfo_.currentDistributionAmount = currentDistributionAmount;
        dividendsInfo_.pendingAmount = dividendsInfo_.pendingAmount.sub(currentDistributionAmount);
      } else {
        // stop the token's distribution on next cycle
        dividendsInfo_.distributedAmount = dividendsInfo_.distributedAmount.add(
          dividendsInfo_.currentDistributionAmount
        );
        dividendsInfo_.currentDistributionAmount = 0;
      }

      dividendsInfo_.currentCycleDistributedAmount = 0;
      lastUpdateTime = currentCycleStartTime;
    }

    uint256 toDistribute = (currentBlockTimestamp.sub(lastUpdateTime)).mul(_dividendsAmountPerSecond(token));
    // ensure that we can't distribute more than currentDistributionAmount (for instance w/ a > 24h service interruption)
    if (
      dividendsInfo_.currentCycleDistributedAmount.add(toDistribute) > dividendsInfo_.currentDistributionAmount.mul(1e2)
    ) {
      toDistribute = dividendsInfo_.currentDistributionAmount.mul(1e2).sub(dividendsInfo_.currentCycleDistributedAmount);
    }

    dividendsInfo_.currentCycleDistributedAmount = dividendsInfo_.currentCycleDistributedAmount.add(toDistribute);
    dividendsInfo_.accDividendsPerShare = accDividendsPerShare.add(toDistribute.mul(1e16).div(activeGrailSupply_));
    dividendsInfo_.lastUpdateTime = currentBlockTimestamp;
  }

  /**
   * @dev Updates user info : pendingDividends, rewardDebt
   *
   * Updates excludedContractsTotalBalance if needed
   */
  function _updateUser(address userAddress, uint256 previousUserGrailBalance, uint256 previousTotalSupply) internal {
    uint256 userGrailBalance = grailToken.balanceOf(userAddress);

    // for each distributedToken
    for (uint256 index = 0; index < _distributedTokens.length(); ++index) {
      address token = _distributedTokens.at(index);
      _updateDividendsInfo(token, previousTotalSupply.sub(excludedContractsTotalBalance));

      DividendsInfo storage dividendsInfo_ = dividendsInfo[token];
      UserInfo storage user = users[token][userAddress];

      // check if userAddress isn't excluded from the dividends
      if (!excludedContracts[userAddress]) {
        uint256 pending = previousUserGrailBalance.mul(dividendsInfo_.accDividendsPerShare).div(1e18).sub(
          user.rewardDebt
        );
        user.pendingDividends = user.pendingDividends.add(pending);
      } else if (user.pendingDividends > 0) {
        // get back the dividends already attributed to a newly excluded userAddress
        // send address's pendingDividends to dividendsInfo's pendingAmount
        dividendsInfo_.pendingAmount = dividendsInfo_.pendingAmount.add(user.pendingDividends);
        user.pendingDividends = 0;
      }
      user.rewardDebt = userGrailBalance.mul(dividendsInfo_.accDividendsPerShare).div(1e18);
    }

    if (excludedContracts[userAddress]) {
      excludedContractsTotalBalance = excludedContractsTotalBalance.add(userGrailBalance).sub(previousUserGrailBalance);
    }

    emit UserUpdated(userAddress, previousUserGrailBalance, userGrailBalance);
  }

  /**
   * @dev Harvests user's pending dividends of a given token
   */
  function _harvestDividends(address userAddress, address token) internal {
    _updateDividendsInfo(token, activeGrailSupply());

    DividendsInfo storage dividendsInfo_ = dividendsInfo[token];
    UserInfo storage user = users[token][userAddress];

    uint256 userGrailBalance = grailToken.balanceOf(msg.sender);
    uint256 pending = user.pendingDividends.add(
      userGrailBalance.mul(dividendsInfo_.accDividendsPerShare).div(1e18).sub(user.rewardDebt)
    );

    user.pendingDividends = 0;
    user.rewardDebt = userGrailBalance.mul(dividendsInfo_.accDividendsPerShare).div(1e18);

    _safeTokenTransfer(IERC20(token), userAddress, pending);
    emit DividendsCollected(userAddress, token, pending);
  }

  /**
   * @dev Safe token transfer function, in case rounding error causes pool to not have enough tokens
   */
  function _safeTokenTransfer(
    IERC20 token,
    address to,
    uint256 amount
  ) internal {
    if (amount > 0) {
      uint256 tokenBal = token.balanceOf(address(this));
      if (amount > tokenBal) {
        token.safeTransfer(to, tokenBal);
      } else {
        token.safeTransfer(to, amount);
      }
    }
  }

  /**
   * @dev Checks whether the account address is a contract (used in excludeContract function)
   *
   * Relies on extcodesize, which returns 0 for contracts in construction, since the code is only stored at the end of
   * the constructor execution
   */
  function _isContract(address account) internal view returns (bool) {
    uint256 size;
    assembly {
      size := extcodesize(account)
    }
    return size > 0;
  }

  /**
   * @dev Utility function to get the current block timestamp
   */
  function _currentBlockTimestamp() internal view virtual returns (uint256) {
    return block.timestamp;
  }
}
