pragma solidity >=0.5.0;

interface IExcaliburV2Factory {
    event PairCreated(address indexed token0, address indexed token1, address pair, uint256);

    function owner() external view returns (address);
    function feeAmountOwner() external view returns (address);
    function feeTo() external view returns (address);

    function ownerFeeShare() external view returns (uint256);
    function referrersFeeShare(address) external view returns (uint256);

    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function allPairs(uint256) external view returns (address pair);
    function allPairsLength() external view returns (uint256);

    function createPair(address tokenA, address tokenB) external returns (address pair);

    function setFeeTo(address) external;
}
