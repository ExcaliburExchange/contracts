// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

interface IMasterChef {
  function excToken() external view returns (address);

  function grailToken() external view returns (address);

  function getUserInfo(uint256 pid, address account) external view returns (uint256 amount, uint256 rewardDebt);

  function getPoolInfo(uint256 pid)
    external
    view
    returns (
      address lpToken,
      uint256 allocPoint,
      uint256 lastRewardTime,
      uint256 accRewardsPerShare,
      uint256 depositFeeBP,
      bool isGrailRewards,
      uint256 lpSupply,
      uint256 lpSupplyWithMultiplier
    );

  function harvest(uint256 pid) external;

  function deposit(uint256 pid, uint256 amount) external;

  function withdraw(uint256 pid, uint256 amount) external;
}
