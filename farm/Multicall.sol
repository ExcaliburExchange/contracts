// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;
pragma abicoder v2;

import "@openzeppelin/contracts/utils/Address.sol";

/**
 * @dev Provides a function to batch together multiple calls in a single external call.
 */
contract Multicall {
  struct Call {
    address target;
    bytes callData;
  }

  function aggregate(bool successRequire, Call[] memory calls)
    external
    returns (uint256 blockNumber, bytes[] memory returnData)
  {
    blockNumber = block.number;
    returnData = new bytes[](calls.length);
    for (uint256 i = 0; i < calls.length; i++) {
      (bool success, bytes memory ret) = calls[i].target.call(calls[i].callData);
      if (successRequire) require(success);
      if (success) returnData[i] = ret;
    }
  }

  // Helper functions
  function getEthBalance(address addr) public view returns (uint256 balance) {
    balance = addr.balance;
  }

  function getBlockHash(uint256 blockNumber) public view returns (bytes32 blockHash) {
    blockHash = blockhash(blockNumber);
  }

  function getLastBlockHash() public view returns (bytes32 blockHash) {
    blockHash = blockhash(block.number - 1);
  }

  function getCurrentBlockTimestamp() public view returns (uint256 timestamp) {
    timestamp = block.timestamp;
  }

  function getCurrentBlockDifficulty() public view returns (uint256 difficulty) {
    difficulty = block.difficulty;
  }

  function getCurrentBlockGasLimit() public view returns (uint256 gaslimit) {
    gaslimit = block.gaslimit;
  }

  function getCurrentBlockCoinbase() public view returns (address coinbase) {
    coinbase = block.coinbase;
  }
}
