// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

interface IDividends {
  function distributedTokensLength() external view returns (uint256);

  function distributedToken(uint256 index) external view returns (address);

  function isDistributedToken(address token) external view returns (bool);

  function updateUser(address userAddress, uint256 previousUserGrailBalance, uint256 previousTotalSupply) external;

  function addDividendsToPending(address token, uint256 amount) external;
}
