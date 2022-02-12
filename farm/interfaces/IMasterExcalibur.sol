// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

import "./IMasterChef.sol";

interface IMasterExcalibur is IMasterChef {
  function getUserSlotLength(uint256 pid, address account) external view returns (uint256);

  function getUserLockSlotInfo(
    uint256 pid,
    address userAddress,
    uint256 slotId
  )
    external
    view
    returns (
      uint256 amount,
      uint256 rewardDebt,
      uint256 lockDurationBlock,
      uint256 depositBlock,
      uint256 multiplier,
      uint256 amountWithMultiplier,
      uint256 lockedBonusRewards
    );

  function pendingRewardsOnLockSlot(
    uint256 pid,
    address userAddress,
    uint256 slotId
  )
    external
    view
    returns (
      uint256 pending,
      uint256 lockedBonusRewards,
      bool canHarvestLockedBonusRewards
    );

  function harvestOnLockSlot(uint256 pid, uint256 slotId) external;

  function depositOnLockSlot(
    uint256 pid,
    uint256 amount,
    uint256 lockDurationBlock,
    bool fromRegularSlot
  ) external;

  function renewLockSlot(
    uint256 pid,
    uint256 slotId,
    uint256 lockDurationBlock
  ) external;

  function redepositOnLockSlot(
    uint256 pid,
    uint256 slotId,
    uint256 amountToAdd,
    bool fromRegularDeposit
  ) external;

  function withdrawOnLockSlot(uint256 pid, uint256 slotId) external;

  function emergencyWithdrawOnLockSlot(uint256 pid, uint256 slotId) external;
}
