// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./interfaces/tokens/IERC20Mintable.sol";
import "./interfaces/tokens/IEXCToken.sol";
import "./interfaces/IMasterExcalibur.sol";
import "./MasterChef.sol";

/*
 * This contract is used to implement the Excalibur locking system to the Master contract
 *
 * It gives to each user lock slots on each pool, with which he's able to get bonus rewards proportionally to the
 * lock duration he decided on deposit
 *
 * The regular slot is the classic system used by every standard MasterChef contract
 * The lock slots are based on the regular, but with the addition of lock features
 *
 */
contract MasterExcalibur is Ownable, ReentrancyGuard, MasterChef, IMasterExcalibur {
  using SafeMath for uint256;

  using SafeERC20 for IERC20;
  using SafeERC20 for IERC20Mintable;

  // Info of each user on locked deposits
  struct UserLockSlotInfo {
    uint256 amount; // How many LP tokens the user has provided
    uint256 rewardDebt; // Reward debt
    uint256 lockDurationSeconds; // The lock duration in seconds
    uint256 depositTime; // The time at which the user made his deposit
    uint256 multiplier; // Active multiplier (times 1e4)
    uint256 amountWithMultiplier; // Amount + lock bonus faked amount (amount + amount*multiplier)
    uint256 bonusRewards; // Rewards earned from the lock bonus
  }

  // Used to directly set disableLockSlot without having to go through the timelock
  address public operator;

  mapping(uint256 => mapping(address => UserLockSlotInfo[])) public userLockSlotInfo;

  uint256 public constant MAX_USER_LOCK_SLOT = 2; // Locking slots allocation / user / pool
  uint256 public immutable MAX_LOCK_DURATION_SECONDS;
  uint256 public immutable MIN_LOCK_DURATION_SECONDS;
  uint256 public constant MAX_MULTIPLIER = 50; // 50%

  // Disables the lock slot feature for all pools:
  //  - Enables the emergencyWithdrawOnLockSlot and WithdrawOnLockSlot even if lockDuration has not ended
  //  - Disables the deposits
  bool public disableLockSlot = false;

  constructor(
    IEXCToken excToken_,
    IERC20Mintable grailToken_,
    uint256 startTime_,
    address devAddress_,
    address feeAddress_,
    uint256 maxLockDuration,
    uint256 minLockDuration
  ) MasterChef(excToken_, grailToken_, startTime_, devAddress_, feeAddress_) {
    operator = msg.sender;

    MAX_LOCK_DURATION_SECONDS = maxLockDuration;
    MIN_LOCK_DURATION_SECONDS = minLockDuration;
  }

  /********************************************/
  /****************** EVENTS ******************/
  /********************************************/

  event DepositOnLockSlot(
    address indexed user,
    uint256 indexed pid,
    uint256 slotId,
    uint256 amount,
    uint256 lockDurationSeconds
  );
  event RenewLockSlot(
    address indexed user,
    uint256 indexed pid,
    uint256 slotId,
    uint256 amount,
    uint256 lockDurationSeconds
  );
  event HarvestOnLockSlot(address indexed user, uint256 indexed pid, uint256 slotId, uint256 amount);
  event WithdrawOnLockSlot(address indexed user, uint256 indexed pid, uint256 slotId, uint256 amount);
  event EmergencyWithdrawOnLockSlot(address indexed user, uint256 indexed pid, uint256 slotId, uint256 amount);
  event DisableLockSlot(bool isDisable);

  event OperatorTransferred(address indexed previousOwner, address indexed newOwner);

  /***********************************************/
  /****************** MODIFIERS ******************/
  /***********************************************/

  /**
   * @dev Throws if called by any account other than the operator.
   */
  modifier onlyOperator() {
    require(operator == msg.sender, "onlyOperator: caller is not the operator");
    _;
  }

  /*
   * @dev Checks if a slot exists on the pool with given pid for userAddress
   */
  modifier validateSlot(
    uint256 pid,
    address userAddress,
    uint256 slotId
  ) {
    require(pid < poolInfo.length, "validateSlot: pool exists?");
    require(slotId < userLockSlotInfo[pid][userAddress].length, "validateSlot: slot exists?");
    _;
  }

  /**************************************************/
  /****************** PUBLIC VIEWS ******************/
  /**************************************************/

  /*
   * @dev Checks if pool is inactive
   */
  function isPoolClosed(uint256 pid) public view returns (bool) {
    return poolInfo[pid].accRewardsPerShare > 0 && poolInfo[pid].allocPoint == 0;
  }

  /**
   * @dev Returns the number of available pools
   */
  function getUserSlotLength(uint256 pid, address account) external view override returns (uint256) {
    return userLockSlotInfo[pid][account].length;
  }

  /**
   * @dev Returns user data of a given pool and slot
   */
  function getUserLockSlotInfo(
    uint256 pid,
    address userAddress,
    uint256 slotId
  )
    external
    view
    virtual
    override
    returns (
      uint256 amount,
      uint256 rewardDebt,
      uint256 lockDurationSeconds,
      uint256 depositTime,
      uint256 multiplier,
      uint256 amountWithMultiplier,
      uint256 bonusRewards
    )
  {
    UserLockSlotInfo storage userSlot = userLockSlotInfo[pid][userAddress][slotId];
    {
      return (
        userSlot.amount,
        userSlot.rewardDebt,
        userSlot.lockDurationSeconds,
        userSlot.depositTime,
        userSlot.multiplier,
        userSlot.amountWithMultiplier,
        userSlot.bonusRewards
      );
    }
  }

  /**
   * @dev Returns expected multiplier for a "lockDurationSeconds" duration lock on a slot (result is *1e8)
   */
  function getMultiplierByLockDurationSeconds(uint256 lockDurationSeconds) public view returns (uint256 multiplier) {
    // capped to MAX_LOCK_DURATION_SECONDS
    if (lockDurationSeconds > MAX_LOCK_DURATION_SECONDS) lockDurationSeconds = MAX_LOCK_DURATION_SECONDS;
    return MAX_MULTIPLIER.mul(lockDurationSeconds).mul(1e6).div(MAX_LOCK_DURATION_SECONDS);
  }

  /**
   * @dev Returns the (locked and unlocked) pending rewards for a user slot on a pool
   */
  function pendingRewardsOnLockSlot(
    uint256 pid,
    address userAddress,
    uint256 slotId
  )
    external
    view
    virtual
    override
    returns (
      uint256 pending,
      uint256 bonusRewards,
      bool canHarvestBonusRewards
    )
  {
    if(pid >= poolInfo.length || slotId >= userLockSlotInfo[pid][userAddress].length) return (0, 0, false);

    uint256 accRewardsPerShare = _getCurrentAccRewardsPerShare(pid);
    UserLockSlotInfo storage userSlot = userLockSlotInfo[pid][userAddress][slotId];

    if(userSlot.amountWithMultiplier == 0) return (0, 0, false);

    uint256 rewardsWithMultiplier = userSlot.amountWithMultiplier.mul(accRewardsPerShare).div(1e18).sub(
      userSlot.rewardDebt
    );

    pending = rewardsWithMultiplier.mul(userSlot.amount).div(userSlot.amountWithMultiplier);
    bonusRewards = rewardsWithMultiplier.add(userSlot.bonusRewards).sub(pending);
    canHarvestBonusRewards = _currentBlockTimestamp() >= userSlot.depositTime.add(userSlot.lockDurationSeconds);
    return (pending, bonusRewards, canHarvestBonusRewards);
  }

  /****************************************************************/
  /****************** EXTERNAL PUBLIC FUNCTIONS  ******************/
  /****************************************************************/

  /**
   * @dev Harvest user's pending rewards on a given pool and lock slot
   *
   *  If lockDuration is over :
   *    - harvest regular + bonus rewards
   *    - transfer user amount from lock slot to regular slot
   *  Else :
   *    - harvest regular rewards
   *    - bonus rewards remain locked
   */
  function harvestOnLockSlot(uint256 pid, uint256 slotId)
    external
    virtual
    override
    validateSlot(pid, msg.sender, slotId)
    nonReentrant
  {
    address userAddress = msg.sender;

    _updatePool(pid);
    _harvestOnLockSlot(pid, userAddress, slotId, false);

    UserLockSlotInfo storage userSlot = userLockSlotInfo[pid][userAddress][slotId];

    // check if lockDuration is over and so if the lockSlot is now unlocked
    if (_currentBlockTimestamp() >= userSlot.depositTime.add(userSlot.lockDurationSeconds)) {
      UserInfo storage user = userInfo[pid][userAddress];
      PoolInfo storage pool = poolInfo[pid];

      // transfer userLockSlotInfo.amount to userInfo.amount (to regular slot) and delete the now empty userLockSlot
      _harvest(pid, pool, user, userAddress);
      user.amount = user.amount.add(userSlot.amount);
      user.rewardDebt = user.amount.mul(pool.accRewardsPerShare).div(1e18);

      pool.lpSupplyWithMultiplier = pool.lpSupplyWithMultiplier.sub(userSlot.amountWithMultiplier).add(userSlot.amount);

      emit WithdrawOnLockSlot(userAddress, pid, slotId, userSlot.amount);
      emit Deposit(userAddress, pid, userSlot.amount);

      _removeUserLockSlot(pid, userAddress, slotId);
    }
  }

  /**
   * @dev Deposit tokens on a given pool for rewards allocation (lock slot)
   * - A lock slot must be available
   * - Tokens will be locked for "lockDurationSeconds"
   * - Bonus rewards amount will be proportional to the lock duration specified here
   *
   * if "fromRegularDeposit" is :
   * - set to true: the tokens will be transferred from the user's regular slot (userInfo), so no fees will be charged
   * - set to false: the tokens will be transferred from the user's wallet, so deposit fees will be charged
   */
  function depositOnLockSlot(
    uint256 pid,
    uint256 amount,
    uint256 lockDurationSeconds,
    bool fromRegularDeposit
  ) external virtual override validatePool(pid) nonReentrant {
    require(!disableLockSlot, "lock slot disabled");
    require(amount > 0, "amount zero");

    address userAddress = msg.sender;

    _updatePool(pid);
    PoolInfo storage pool = poolInfo[pid];

    // check whether the deposit should come from the regular slot of the pool or from the user's wallet
    if (fromRegularDeposit) {
      UserInfo storage user = userInfo[pid][userAddress];
      require(user.amount >= amount, "amount not available");

      _harvest(pid, pool, user, userAddress);

      // remove the amount to lock from the "regular" balances
      user.amount = user.amount.sub(amount);
      user.rewardDebt = user.amount.mul(pool.accRewardsPerShare).div(1e18);
      pool.lpSupply = pool.lpSupply.sub(amount);
      pool.lpSupplyWithMultiplier = pool.lpSupplyWithMultiplier.sub(amount);
      emit Withdraw(userAddress, pid, amount);
    } else {
      // handle tokens with transfer tax
      uint256 previousBalance = pool.lpToken.balanceOf(address(this));
      pool.lpToken.safeTransferFrom(userAddress, address(this), amount);
      amount = pool.lpToken.balanceOf(address(this)).sub(previousBalance);

      if (pool.depositFeeBP > 0) {
        // check if depositFee is enabled
        uint256 depositFee = amount.mul(pool.depositFeeBP).div(1e4);
        amount = amount.sub(depositFee);
        pool.lpToken.safeTransfer(feeAddress, depositFee);
      }
    }

    _lockAmount(pid, userAddress, amount, lockDurationSeconds);
  }

  /**
   * @dev Renew a lock slot
   *   - harvest regular + bonus rewards
   *   - reset the lock slot duration to lockDurationSeconds
   * If previous lockDurationSeconds has not ended :
   *   - requires lockDurationSeconds >= previousLockDuration
   */
  function renewLockSlot(
    uint256 pid,
    uint256 slotId,
    uint256 lockDurationSeconds
  ) external virtual override validateSlot(pid, msg.sender, slotId) nonReentrant {
    require(!disableLockSlot, "lock slot disabled");
    uint256 currentBlockTimestamp = _currentBlockTimestamp();

    address userAddress = msg.sender;
    UserLockSlotInfo storage userSlot = userLockSlotInfo[pid][userAddress][slotId];

    // if the slot is still locked, check if the new lockDurationSeconds is at least the same as the previous one
    if (currentBlockTimestamp < userSlot.depositTime.add(userSlot.lockDurationSeconds)) {
      require(userSlot.lockDurationSeconds <= lockDurationSeconds, "lockDurationSeconds too low");
    }

    _updatePool(pid);
    PoolInfo storage pool = poolInfo[pid];

    _harvestOnLockSlot(pid, userAddress, slotId, true);

    userSlot.depositTime = currentBlockTimestamp;

    // if the new lockDurationSeconds has changed, adjust the rewards multiplier
    if (userSlot.lockDurationSeconds != lockDurationSeconds) {
      userSlot.lockDurationSeconds = lockDurationSeconds;
      userSlot.multiplier = getMultiplierByLockDurationSeconds(lockDurationSeconds);
      uint256 amountWithMultiplier = userSlot.amount.mul(userSlot.multiplier.add(1e8)).div(1e8);
      pool.lpSupplyWithMultiplier = pool.lpSupplyWithMultiplier.sub(userSlot.amountWithMultiplier).add(
        amountWithMultiplier
      );
      userSlot.amountWithMultiplier = amountWithMultiplier;
    }
    userSlot.rewardDebt = userSlot.amountWithMultiplier.mul(pool.accRewardsPerShare).div(1e18);

    emit RenewLockSlot(userAddress, pid, slotId, userSlot.amount, userSlot.lockDurationSeconds);
  }

  /**
   * @dev Redeposit tokens on an already active given lock slot
   *  - Harvest all rewards (regular and bonus)
   *  - Reset the lock
   *
   * if "fromRegularDeposit" is :
   * - set to true: the tokens will be transferred from the user's regular slot (userInfo), so no fees will be charged
   * - set to false: the tokens will be transferred from the user's wallet, so deposit fees will be charged
   */
  function redepositOnLockSlot(
    uint256 pid,
    uint256 slotId,
    uint256 amountToAdd,
    bool fromRegularDeposit
  ) external virtual override validateSlot(pid, msg.sender, slotId) nonReentrant {
    require(!disableLockSlot, "lock slot disabled");
    require(amountToAdd > 0, "zero amount");

    address userAddress = msg.sender;

    _updatePool(pid);
    PoolInfo storage pool = poolInfo[pid];

    // check whether the deposit should come from the regular slot of the pool or from the user's wallet
    if (fromRegularDeposit) {
      UserInfo storage user = userInfo[pid][userAddress];
      require(user.amount >= amountToAdd, "amount not available");

      _harvest(pid, pool, user, userAddress);

      // remove the amount to lock from the "regular" balances
      user.amount = user.amount.sub(amountToAdd);
      user.rewardDebt = user.amount.mul(pool.accRewardsPerShare).div(1e18);
      pool.lpSupply = pool.lpSupply.sub(amountToAdd);
      pool.lpSupplyWithMultiplier = pool.lpSupplyWithMultiplier.sub(amountToAdd);

      emit Withdraw(userAddress, pid, amountToAdd);
    } else {
      // handle tokens with transfer tax
      uint256 previousBalance = pool.lpToken.balanceOf(address(this));
      pool.lpToken.safeTransferFrom(userAddress, address(this), amountToAdd);
      amountToAdd = pool.lpToken.balanceOf(address(this)).sub(previousBalance);

      if (pool.depositFeeBP > 0) {
        // check if depositFee is enabled
        uint256 depositFee = amountToAdd.mul(pool.depositFeeBP).div(1e4);
        amountToAdd = amountToAdd.sub(depositFee);
        pool.lpToken.safeTransfer(feeAddress, depositFee);
      }
    }

    _harvestOnLockSlot(pid, userAddress, slotId, true);

    // adjust balances with new deposit amount
    UserLockSlotInfo storage userSlot = userLockSlotInfo[pid][userAddress][slotId];
    uint256 amountToAddWithMultiplier = amountToAdd.mul(userSlot.multiplier.add(1e8)).div(1e8);

    userSlot.amount = userSlot.amount.add(amountToAdd);
    userSlot.amountWithMultiplier = userSlot.amountWithMultiplier.add(amountToAddWithMultiplier);
    userSlot.rewardDebt = userSlot.amountWithMultiplier.mul(pool.accRewardsPerShare).div(1e18);
    userSlot.depositTime = _currentBlockTimestamp();

    pool.lpSupply = pool.lpSupply.add(amountToAdd);
    pool.lpSupplyWithMultiplier = pool.lpSupplyWithMultiplier.add(amountToAddWithMultiplier);

    emit RenewLockSlot(userAddress, pid, slotId, userSlot.amount, userSlot.lockDurationSeconds);
  }

  /**
   * @dev Withdraw tokens from given pool and lock slot
   * - harvest if there is pending rewards
   * - withdraw the deposited amount to the user's wallet
   *
   * lockDurationSeconds must be over
   */
  function withdrawOnLockSlot(uint256 pid, uint256 slotId)
    external
    virtual
    override
    validateSlot(pid, msg.sender, slotId)
    nonReentrant
  {
    address userAddress = msg.sender;

    PoolInfo storage pool = poolInfo[pid];
    UserLockSlotInfo storage userSlot = userLockSlotInfo[pid][userAddress][slotId];

    require(
      userSlot.depositTime.add(userSlot.lockDurationSeconds) <= _currentBlockTimestamp() ||
        isPoolClosed(pid) ||
        disableLockSlot,
      "withdraw locked"
    );

    _updatePool(pid);
    // if lock slot feature has been disabled by the admin (disableLockSlot), we force the harvest of
    // all the user's bonus rewards
    _harvestOnLockSlot(pid, userAddress, slotId, true);

    uint256 withdrawAmount = userSlot.amount;

    pool.lpSupply = pool.lpSupply.sub(withdrawAmount);
    pool.lpSupplyWithMultiplier = pool.lpSupplyWithMultiplier.sub(userSlot.amountWithMultiplier);
    _removeUserLockSlot(pid, userAddress, slotId);

    emit WithdrawOnLockSlot(userAddress, pid, slotId, withdrawAmount);
    pool.lpToken.safeTransfer(userAddress, withdrawAmount);
  }

  /**
   * @dev Withdraw without caring about rewards, EMERGENCY ONLY
   *
   * Can't be called for locked deposits, except if disableLockSlot is set to true
   */
  function emergencyWithdrawOnLockSlot(uint256 pid, uint256 slotId)
    external
    virtual
    override
    validateSlot(pid, msg.sender, slotId)
    nonReentrant
  {
    address userAddress = msg.sender;
    PoolInfo storage pool = poolInfo[pid];
    UserLockSlotInfo storage userSlot = userLockSlotInfo[pid][userAddress][slotId];
    require(
      userSlot.depositTime.add(userSlot.lockDurationSeconds) <= _currentBlockTimestamp() ||
        isPoolClosed(pid) ||
        disableLockSlot,
      "withdraw locked"
    );
    uint256 amount = userSlot.amount;

    pool.lpSupply = pool.lpSupply.sub(userSlot.amount);
    pool.lpSupplyWithMultiplier = pool.lpSupplyWithMultiplier.sub(userSlot.amountWithMultiplier);

    _removeUserLockSlot(pid, userAddress, slotId);

    pool.lpToken.safeTransfer(userAddress, amount);
    emit EmergencyWithdrawOnLockSlot(userAddress, pid, slotId, amount);
  }

  /*****************************************************************/
  /****************** EXTERNAL OWNABLE FUNCTIONS  ******************/
  /*****************************************************************/

  /**
   * @dev Transfers the operator of the contract to a new account (`newOperator`).
   *
   * Must only be called by the current operator.
   */
  function transferOperator(address newOperator) external onlyOperator {
    require(newOperator != address(0), "transferOperator: new operator is the zero address");
    emit OperatorTransferred(operator, newOperator);
    operator = newOperator;
  }

  /**
   * @dev Unlock all locked deposits, forbid any new deposit on lock slots
   *
   * Must only be called by the operator.
   */
  function setDisableLockSlot(bool isDisable) external onlyOperator {
    disableLockSlot = isDisable;
    emit DisableLockSlot(isDisable);
  }

  /********************************************************/
  /****************** INTERNAL FUNCTIONS ******************/
  /********************************************************/

  /**
   * @dev Locks amount for a given pool during lockDurationSeconds into a free slot
   */
  function _lockAmount(
    uint256 pid,
    address userAddress,
    uint256 amount,
    uint256 lockDurationSeconds
  ) internal {
    require(userLockSlotInfo[pid][userAddress].length < MAX_USER_LOCK_SLOT, "no slot available");
    require(lockDurationSeconds >= MIN_LOCK_DURATION_SECONDS, "lockDuration mustn't exceed the minimum");
    require(lockDurationSeconds <= MAX_LOCK_DURATION_SECONDS, "lockDuration mustn't exceed the maximum");

    PoolInfo storage pool = poolInfo[pid];
    uint256 multiplier = getMultiplierByLockDurationSeconds(lockDurationSeconds);
    uint256 amountWithMultiplier = amount.mul(multiplier.add(1e8)).div(1e8);

    pool.lpSupply = pool.lpSupply.add(amount);
    pool.lpSupplyWithMultiplier = pool.lpSupplyWithMultiplier.add(amountWithMultiplier);

    // create new lock slot
    userLockSlotInfo[pid][userAddress].push(
      UserLockSlotInfo({
        amount: amount,
        rewardDebt: amountWithMultiplier.mul(pool.accRewardsPerShare).div(1e18),
        lockDurationSeconds: lockDurationSeconds,
        depositTime: _currentBlockTimestamp(),
        multiplier: multiplier,
        amountWithMultiplier: amountWithMultiplier,
        bonusRewards: 0
      })
    );
    emit DepositOnLockSlot(
      userAddress,
      pid,
      userLockSlotInfo[pid][userAddress].length.sub(1),
      amount,
      lockDurationSeconds
    );
  }

  /**
   * @dev Harvests the pending rewards for given pool and user on a lock slot
   */
  function _harvestOnLockSlot(
    uint256 pid,
    address userAddress,
    uint256 slotId,
    bool forceHarvestBonus
  ) internal {
    UserLockSlotInfo storage userSlot = userLockSlotInfo[pid][userAddress][slotId];

    uint256 rewardsWithMultiplier = userSlot.amountWithMultiplier.mul(poolInfo[pid].accRewardsPerShare).div(1e18).sub(
      userSlot.rewardDebt
    );
    uint256 pending = rewardsWithMultiplier.mul(userSlot.amount).div(userSlot.amountWithMultiplier);
    uint256 bonusRewards = rewardsWithMultiplier.sub(pending);

    // check if lockDurationSeconds is over
    if (_currentBlockTimestamp() >= userSlot.depositTime.add(userSlot.lockDurationSeconds) || forceHarvestBonus) {
      // bonus rewards are not locked anymore
      pending = pending.add(userSlot.bonusRewards).add(bonusRewards);
      userSlot.bonusRewards = 0;
    } else {
      userSlot.bonusRewards = userSlot.bonusRewards.add(bonusRewards);
    }

    userSlot.rewardDebt = userSlot.amountWithMultiplier.mul(poolInfo[pid].accRewardsPerShare).div(1e18);
    if (pending > 0) {
      if (poolInfo[pid].isGrailRewards) {
        _safeRewardsTransfer(userAddress, pending, _grailToken);
      } else {
        _safeRewardsTransfer(userAddress, pending, _excToken);
      }
      emit HarvestOnLockSlot(userAddress, pid, slotId, pending);
    }
  }

  /**
   * @dev Removes a slot from userLockSlotInfo by index
   */
  function _removeUserLockSlot(
    uint256 pid,
    address userAddress,
    uint256 slotId
  ) internal {
    UserLockSlotInfo[] storage userSlots = userLockSlotInfo[pid][userAddress];

    // in case of emergencyWithdraw : burn the remaining bonus rewards on the slot, so they won't be locked on the master forever
    uint256 remainingRewardsAmount = userSlots[slotId].bonusRewards;
    if (remainingRewardsAmount > 0) {
      poolInfo[pid].isGrailRewards ? _grailToken.burn(remainingRewardsAmount) : _excToken.burn(remainingRewardsAmount);
    }

    // slot removal
    userSlots[slotId] = userSlots[userSlots.length - 1];
    userSlots.pop();
  }
}
