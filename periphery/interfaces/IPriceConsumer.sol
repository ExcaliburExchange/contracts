pragma solidity ^0.6.0;

interface IPriceConsumer {
  function USD() external pure returns (address);
  function WETH() external pure returns (address);
  function EXC() external pure returns (address);
  function lastEXCPrice() external view returns (uint);
  function getTokenFairPriceUSD(address token) external view returns (uint);
  function getTokenPriceUSDUsingPair(address token) external view returns (uint);
  function valueOfTokenUSD(address token) external view returns (uint);
  function getTokenMinPriceUSD(address token) external view returns (uint);
  function getEXCMaxPriceUSD() external returns (uint);
}
