// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/tokens/IERC20Mintable.sol";
import "./interfaces/tokens/IEXCToken.sol";
import "./interfaces/IMasterExcalibur.sol";
import "./interfaces/IMasterChef.sol";

contract MasterChef is Ownable, ReentrancyGuard, IMasterChef {
  using SafeMath for uint256;

  using SafeERC20 for IERC20;
  using SafeERC20 for IERC20Mintable;
  using SafeERC20 for IEXCToken;

  // Info of each user.
  struct UserInfo {
    uint256 amount; // How many LP tokens the user has provided
    uint256 rewardDebt; // Reward debt. See explanation below
    /**
     * We do some fancy math here. Basically, any point in time, the amount of EXCs
     * entitled to a user but is pending to be distributed is:
     *
     * pending reward = (user.amount * pool.accRewardsPerShare) - user.rewardDebt
     *
     * Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
     *   1. The pool's `accRrewardsPerShare` (and `lastRewardTime`) gets updated
     *   2. User receives the pending reward sent to his/her address
     *   3. User's `amount` gets updated
     *   4. User's `rewardDebt` gets updated
     */
  }

  // Info of each pool.
  struct PoolInfo {
    IERC20 lpToken; // Address of LP token contract
    uint256 lpSupply; // Sum of LP staked on this pool
    uint256 lpSupplyWithMultiplier; // Sum of LP staked on this pool including the user's multiplier
    uint256 allocPoint; // How many allocation points assigned to this pool. EXC or GRAIL to distribute per second
    uint256 lastRewardTime; // Last time that EXC or GRAIL distribution occurs
    uint256 accRewardsPerShare; // Accumulated Rewards (EXC or GRAIL token) per share, times 1e18. See below
    uint256 depositFeeBP; // Deposit Fee
    bool isGrailRewards; // Are the rewards GRAIL token (if not, rewards are EXC)
  }

  IEXCToken internal immutable _excToken; // Address of the EXC token contract
  IERC20Mintable internal immutable _grailToken; // Address of the GRAIL token contract

  address public devAddress; // Dev address
  address public feeAddress; // Deposit Fee address

  mapping(uint256 => mapping(address => UserInfo)) public userInfo; // Info of each user that stakes LP tokens
  PoolInfo[] public poolInfo; // Info of each pool
  uint256 public totalAllocPoint = 0; // Total allocation points. Must be the sum of all allocation points in all pools
  uint256 public immutable startTime; // The time at which mining starts

  uint256 public constant MAX_DEPOSIT_FEE_BP = 400; // 4%

  uint256 public constant INITIAL_EMISSION_RATE = 1 ether; // Initial emission rate : EXC+GRAIL per second
  uint256 public constant MINIMUM_EMISSION_RATE = 0.1 ether;
  uint256 public rewardsPerSecond; // Token rewards created per second

  constructor(
    IEXCToken excToken_,
    IERC20Mintable grailToken_,
    uint256 startTime_,
    address devAddress_,
    address feeAddress_
  ) {
    require(devAddress_ != address(0), "constructor: devAddress init with zero address");
    require(feeAddress_ != address(0), "constructor: feeAddress init with zero address");

    _excToken = excToken_;
    _grailToken = grailToken_;
    startTime = startTime_;
    rewardsPerSecond = INITIAL_EMISSION_RATE;
    devAddress = devAddress_;
    feeAddress = feeAddress_;

    // staking pool
    poolInfo.push(
      PoolInfo({
        lpToken: excToken_,
        lpSupply: 0,
        lpSupplyWithMultiplier: 0,
        allocPoint: 800,
        lastRewardTime: startTime_,
        accRewardsPerShare: 0,
        depositFeeBP: 0,
        isGrailRewards: false
      })
    );
    totalAllocPoint = 800;
  }

  /********************************************/
  /****************** EVENTS ******************/
  /********************************************/

  event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
  event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
  event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
  event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);

  event EmissionRateUpdated(uint256 previousEmissionRate, uint256 newEmissionRate);
  event PoolAdded(uint256 indexed pid, uint256 allocPoint, address lpToken, uint256 depositFeeBP, bool isGrailRewards);
  event PoolConfigUpdated(uint256 indexed pid, uint256 allocPoint, address lpToken, uint256 depositFeeBP);
  event PoolUpdated(uint256 indexed pid, uint256 lastRewardTime, uint256 accRewardsPerShare);

  event FeeAddressUpdated(address previousAddress, address newAddress);
  event DevAddressUpdated(address previousAddress, address newAddress);

  /***********************************************/
  /****************** MODIFIERS ******************/
  /***********************************************/

  /*
   * @dev Check if a pid exists
   */
  modifier validatePool(uint256 pid) {
    require(pid < poolInfo.length, "validatePool: pool exists?");
    _;
  }

  /**************************************************/
  /****************** PUBLIC VIEWS ******************/
  /**************************************************/

  function excToken() external view override returns (address) {
    return address(_excToken);
  }

  function grailToken() external view override returns (address) {
    return address(_grailToken);
  }

  /**
   * @dev Returns the number of available pools
   */
  function poolLength() external view returns (uint256) {
    return poolInfo.length;
  }

  /**
   * @dev Returns user data for a given pool
   */
  function getUserInfo(uint256 pid, address userAddress)
    external
    view
    override
    returns (uint256 amount, uint256 rewardDebt)
  {
    UserInfo storage user = userInfo[pid][userAddress];
    return (user.amount, user.rewardDebt);
  }

  /**
   * @dev Returns data of a given pool
   */
  function getPoolInfo(uint256 pid)
    external
    view
    override
    returns (
      address lpToken,
      uint256 allocPoint,
      uint256 lastRewardTime,
      uint256 accRewardsPerShare,
      uint256 depositFeeBP,
      bool isGrailRewards,
      uint256 lpSupply,
      uint256 lpSupplyWithMultiplier
    )
  {
    PoolInfo storage pool = poolInfo[pid];
    return (
      address(pool.lpToken),
      pool.allocPoint,
      pool.lastRewardTime,
      pool.accRewardsPerShare,
      pool.depositFeeBP,
      pool.isGrailRewards,
      pool.lpSupply,
      pool.lpSupplyWithMultiplier
    );
  }

  /**
   * @dev Returns a given user pending rewards for a given pool
   */
  function pendingRewards(uint256 pid, address userAddress) external view returns (uint256 pending) {
    uint256 accRewardsPerShare = _getCurrentAccRewardsPerShare(pid);
    UserInfo storage user = userInfo[pid][userAddress];
    pending = user.amount.mul(accRewardsPerShare).div(1e18).sub(user.rewardDebt);
    return pending;
  }

  /****************************************************************/
  /****************** EXTERNAL PUBLIC FUNCTIONS  ******************/
  /****************************************************************/

  /**
   * @dev Updates rewards states of the given pool to be up-to-date
   */
  function updatePool(uint256 pid) external nonReentrant validatePool(pid) {
    _updatePool(pid);
  }

  /**
   * @dev Updates rewards states for all pools
   *
   * Be careful of gas spending
   */
  function massUpdatePools() external nonReentrant {
    _massUpdatePools();
  }

  /**
   * @dev Harvests user's pending rewards on a given pool
   */
  function harvest(uint256 pid) external override nonReentrant validatePool(pid) {
    address userAddress = msg.sender;
    PoolInfo storage pool = poolInfo[pid];
    UserInfo storage user = userInfo[pid][userAddress];

    _updatePool(pid);
    _harvest(pid, pool, user, userAddress);

    user.rewardDebt = user.amount.mul(pool.accRewardsPerShare).div(1e18);
  }

  /**
   * @dev Deposits LP tokens on a given pool for rewards allocation
   */
  function deposit(uint256 pid, uint256 amount) external override nonReentrant validatePool(pid) {
    address userAddress = msg.sender;
    PoolInfo storage pool = poolInfo[pid];
    UserInfo storage user = userInfo[pid][userAddress];

    _updatePool(pid);
    _harvest(pid, pool, user, userAddress);

    if (amount > 0) {
      // handle tokens with auto burn
      uint256 previousBalance = pool.lpToken.balanceOf(address(this));
      pool.lpToken.safeTransferFrom(userAddress, address(this), amount);
      amount = pool.lpToken.balanceOf(address(this)).sub(previousBalance);

      // check if depositFee is enabled
      if (pool.depositFeeBP > 0) {
        uint256 depositFee = amount.mul(pool.depositFeeBP).div(10000);
        amount = amount.sub(depositFee);
        pool.lpToken.safeTransfer(feeAddress, depositFee);
      }

      user.amount = user.amount.add(amount);

      pool.lpSupply = pool.lpSupply.add(amount);
      pool.lpSupplyWithMultiplier = pool.lpSupplyWithMultiplier.add(amount);
    }
    user.rewardDebt = user.amount.mul(pool.accRewardsPerShare).div(1e18);
    emit Deposit(userAddress, pid, amount);
  }

  /**
   * @dev Withdraw LP tokens from a given pool
   */
  function withdraw(uint256 pid, uint256 amount) external override nonReentrant validatePool(pid) {
    address userAddress = msg.sender;
    PoolInfo storage pool = poolInfo[pid];
    UserInfo storage user = userInfo[pid][userAddress];

    require(user.amount >= amount, "withdraw: invalid amount");

    _updatePool(pid);
    _harvest(pid, pool, user, userAddress);

    if (amount > 0) {
      user.amount = user.amount.sub(amount);

      pool.lpSupply = pool.lpSupply.sub(amount);
      pool.lpSupplyWithMultiplier = pool.lpSupplyWithMultiplier.sub(amount);
      pool.lpToken.safeTransfer(userAddress, amount);
    }
    user.rewardDebt = user.amount.mul(pool.accRewardsPerShare).div(1e18);
    emit Withdraw(userAddress, pid, amount);
  }

  /**
   * @dev Withdraw without caring about rewards, EMERGENCY ONLY
   */
  function emergencyWithdraw(uint256 pid) external validatePool(pid) {
    PoolInfo storage pool = poolInfo[pid];
    UserInfo storage user = userInfo[pid][msg.sender];
    uint256 amount = user.amount;

    pool.lpSupply = pool.lpSupply.sub(user.amount);
    pool.lpSupplyWithMultiplier = pool.lpSupplyWithMultiplier.sub(user.amount);
    user.amount = 0;
    user.rewardDebt = 0;

    emit EmergencyWithdraw(msg.sender, pid, amount);
    pool.lpToken.safeTransfer(msg.sender, amount);
  }

  /*****************************************************************/
  /****************** EXTERNAL OWNABLE FUNCTIONS  ******************/
  /*****************************************************************/

  /**
   * @dev Updates dev address
   *
   * Must only be called by devAddress
   */
  function setDevAddress(address newDevAddress) external {
    require(msg.sender == devAddress, "caller is not devAddress");
    require(newDevAddress != address(0), "zero address");
    emit DevAddressUpdated(devAddress, newDevAddress);
    devAddress = newDevAddress;
  }

  /**
   * @dev Updates fee address
   *
   * Must only be called by the owner
   */
  function setFeeAddress(address newFeeAddress) external onlyOwner {
    require(newFeeAddress != address(0), "zero address");
    emit FeeAddressUpdated(feeAddress, newFeeAddress);
    feeAddress = newFeeAddress;
  }

  /**
   * @dev Updates the emission rate
   * param withUpdate should be set to true every time it's possible
   *
   * Must only be called by the owner
   */
  function updateEmissionRate(uint256 newEmissionRate, bool withUpdate) external onlyOwner {
    require(newEmissionRate >= MINIMUM_EMISSION_RATE, "rewardsPerSecond mustn't exceed the minimum");
    require(newEmissionRate <= INITIAL_EMISSION_RATE, "rewardsPerSecond mustn't exceed the maximum");
    if(withUpdate) _massUpdatePools();
    emit EmissionRateUpdated(rewardsPerSecond, newEmissionRate);
    rewardsPerSecond = newEmissionRate;
  }

  /**
   * @dev Adds a new pool
   * param withUpdate should be set to true every time it's possible
   *
   * Must only be called by the owner
   */
  function add(
    uint256 allocPoint,
    IERC20 lpToken,
    uint256 depositFeeBP,
    bool isGrailRewards,
    bool withUpdate
  ) external onlyOwner {
    require(depositFeeBP <= MAX_DEPOSIT_FEE_BP, "add: invalid deposit fee basis points");
    uint256 currentBlockTimestamp = _currentBlockTimestamp();

    if (withUpdate && allocPoint > 0) {
      // Updates all pools if new pool allocPoint > 0
      _massUpdatePools();
    }

    uint256 lastRewardTime = currentBlockTimestamp > startTime ? currentBlockTimestamp : startTime;
    totalAllocPoint = totalAllocPoint.add(allocPoint);
    poolInfo.push(
      PoolInfo({
        lpToken: lpToken,
        lpSupply: 0,
        lpSupplyWithMultiplier: 0,
        allocPoint: allocPoint,
        lastRewardTime: lastRewardTime,
        accRewardsPerShare: 0,
        depositFeeBP: depositFeeBP,
        isGrailRewards: isGrailRewards
      })
    );

    emit PoolAdded(poolInfo.length.sub(1), allocPoint, address(lpToken), depositFeeBP, isGrailRewards);
  }

  /**
   * @dev Updates configuration on existing pool
   * param withUpdate should be set to true every time it's possible
   *
   * Must only be called by the owner
   */
  function set(
    uint256 pid,
    uint256 allocPoint,
    uint256 depositFeeBP,
    bool withUpdate
  ) external onlyOwner {
    require(depositFeeBP <= MAX_DEPOSIT_FEE_BP, "set: invalid deposit fee basis points");
    PoolInfo storage pool = poolInfo[pid];
    uint256 prevAllocPoint = pool.allocPoint;

    if (withUpdate && allocPoint != prevAllocPoint) {
      // Updates each existent pool if new allocPoints differ from the previously ones
      _massUpdatePools();
    }

    pool.allocPoint = allocPoint;
    pool.depositFeeBP = depositFeeBP;
    if (prevAllocPoint != allocPoint) {
      totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(allocPoint);
    }

    emit PoolConfigUpdated(pid, allocPoint, address(pool.lpToken), depositFeeBP);
  }

  /********************************************************/
  /****************** INTERNAL FUNCTIONS ******************/
  /********************************************************/

  /**
   * @dev Returns the accRewardsPerShare adjusted for current block of a given pool
   */
  function _getCurrentAccRewardsPerShare(uint256 pid) internal view returns (uint256) {
    uint256 currentBlockTimestamp = _currentBlockTimestamp();
    PoolInfo storage pool = poolInfo[pid];
    uint256 accRewardsPerShare = pool.accRewardsPerShare;

    // check if pool is active and not already up-to-date
    if (currentBlockTimestamp > pool.lastRewardTime && pool.lpSupplyWithMultiplier > 0) {
      uint256 nbSeconds = currentBlockTimestamp.sub(pool.lastRewardTime);
      uint256 tokensReward = nbSeconds.mul(rewardsPerSecond).mul(pool.allocPoint).mul(1e18).div(totalAllocPoint);
      return accRewardsPerShare.add(tokensReward.div(pool.lpSupplyWithMultiplier));
    }

    return accRewardsPerShare;
  }

  /**
   * @dev Harvests the pending rewards for a given pool and user
   * Does not update user.rewardDebt !
   * Functions calling this must update rewardDebt themselves
   */
  function _harvest(
    uint256 pid,
    PoolInfo storage pool,
    UserInfo storage user,
    address userAddress
  ) internal {
    if (user.amount > 0) {
      uint256 pending = user.amount.mul(pool.accRewardsPerShare).div(1e18).sub(user.rewardDebt);
      if (pending > 0) {
        if (pool.isGrailRewards) {
          _safeRewardsTransfer(userAddress, pending, _grailToken);
        } else {
          _safeRewardsTransfer(userAddress, pending, _excToken);
        }
        emit Harvest(userAddress, pid, pending);
      }
    }
  }

  /**
   * @dev Safe token transfer function, in case rounding error causes pool to not have enough tokens
   */
  function _safeRewardsTransfer(
    address to,
    uint256 amount,
    IERC20Mintable tokenReward
  ) internal {
    uint256 tokenRewardBalance = tokenReward.balanceOf(address(this));
    bool transferSuccess = false;
    if (amount > tokenRewardBalance) {
      transferSuccess = tokenReward.transfer(to, tokenRewardBalance);
    } else {
      transferSuccess = tokenReward.transfer(to, amount);
    }
    require(transferSuccess, "safeRewardTransfer: Transfer failed");
  }

  /**
   * @dev Updates rewards states of the given pool to be up-to-date
   */
  function _updatePool(uint256 pid) internal {
    uint256 currentBlockTimestamp = _currentBlockTimestamp();
    PoolInfo storage pool = poolInfo[pid];

    if (currentBlockTimestamp <= pool.lastRewardTime) {
      return;
    }

    if (pool.lpSupplyWithMultiplier == 0) {
      pool.lastRewardTime = currentBlockTimestamp;
      return;
    }

    uint256 nbSeconds = currentBlockTimestamp.sub(pool.lastRewardTime);
    uint256 tokensReward = nbSeconds.mul(rewardsPerSecond).mul(pool.allocPoint).div(totalAllocPoint);
    pool.accRewardsPerShare = pool.accRewardsPerShare.add(tokensReward.mul(1e18).div(pool.lpSupplyWithMultiplier));
    pool.lastRewardTime = currentBlockTimestamp;

    _excToken.mint(devAddress, tokensReward.div(10));
    if (pool.isGrailRewards) {
      _grailToken.mint(address(this), tokensReward);
    } else {
      _excToken.mint(address(this), tokensReward);
    }

    emit PoolUpdated(pid, pool.lastRewardTime, pool.accRewardsPerShare);
  }

  /**
   * @dev Updates rewards states for all pools
   *
   * Be careful of gas spending
   */
  function _massUpdatePools() internal {
    uint256 length = poolInfo.length;
    for (uint256 pid = 0; pid < length; ++pid) {
      _updatePool(pid);
    }
  }

  /**
   * @dev Utility function to get the current block timestamp
   */
  function _currentBlockTimestamp() internal view virtual returns (uint256) {
    return block.timestamp;
  }
}
