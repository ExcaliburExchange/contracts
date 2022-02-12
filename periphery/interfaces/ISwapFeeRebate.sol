pragma solidity ^0.6.0;

interface ISwapFeeRebate {
  function updateEXCLastPrice() external;
  function getEXCFees(address inputToken, address outputToken, uint outputTokenAmount) external view returns (uint);
}