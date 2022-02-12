// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

interface IBondingFactory {
  function owner() external view returns (address);

  function activateBondingContract(
    uint256 startTime,
    uint256 endTime,
    uint256 maxGrailRewards
  ) external;

  function mintRewards(
    address to,
    uint256 rewardAmount
  ) external;

}
