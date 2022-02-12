// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/EnumerableSet.sol";

import "./Bonding.sol";
import "./interfaces/tokens/IERC20Mintable.sol";

contract BondingFactory is Ownable {
  using SafeMath for uint256;
  using EnumerableSet for EnumerableSet.AddressSet;

  IERC20Mintable public immutable grailToken;

  address public immutable treasury;

  address[] public activeBondingContracts;
  EnumerableSet.AddressSet private _allBondingContracts;

  uint256 public constant MAX_MINTABLE_GRAIL_PERCENT = 10; // 10% of the total GRAIL circulating supply
  uint256 public constant MIN_VESTING_PERIOD = 3 days;
  uint256 public constant MIN_DEPOSIT_DURATION = 1 days;

  constructor(IERC20Mintable grailToken_, address treasury_) {
    grailToken = grailToken_;
    treasury = treasury_;
  }

  /********************************************/
  /****************** EVENTS ******************/
  /********************************************/

  event BondingCreated(
    address indexed bondingAddress,
    address bondToken,
    uint256 ratio,
    uint256 ratioDecimals,
    uint256 startTime,
    uint256 endTime,
    bool canHarvestBeforeEnd
  );
  event ActivateBondingContract(
    address indexed bondingContract,
    uint256 startTime,
    uint256 endTime
  );

  /**************************************************/
  /****************** PUBLIC VIEWS ******************/
  /**************************************************/

  function allBondingContractsLength() external view returns (uint256) {
    return _allBondingContracts.length();
  }

  function allBondingContracts(uint256 index) external view returns (address) {
    return _allBondingContracts.at(index);
  }

  function activeBondingContractsLength() external view returns (uint256) {
    return activeBondingContracts.length;
  }

  /****************************************************************/
  /****************** EXTERNAL OWNABLE FUNCTIONS  ******************/
  /****************************************************************/

  /*
   * @dev Creates the bonding contract
   */
  function createBonding(
    address bondToken,
    uint256 ratioDecimals,
    uint256 ratio,
    uint256 startTime,
    uint256 depositDuration,
    uint256 vestingPeriod,
    uint256 maxDepositAmount,
    bool canHarvestBeforeEnd
  ) external onlyOwner {
    require(ratio > 0, "createBonding: ratio should be greater than zero");
    require(startTime > _currentBlockTimestamp(), "createBonding: startTime should be greater than current time");
    require(
      depositDuration >= MIN_DEPOSIT_DURATION,
      "createBonding: depositDuration should be greater than minimum"
    );
    require(
      vestingPeriod >= MIN_VESTING_PERIOD,
      "createBonding: vestingPeriod should be greater than minimum"
    );
    require(maxDepositAmount > 0, "createBonding: maxDepositAmount should be greater than 0");

    uint256 endTime = startTime.add(depositDuration).add(vestingPeriod);

    bytes memory bytecode = _getBondingCreationCode();
    bytes32 salt = keccak256(abi.encodePacked(bondToken, startTime, endTime));
    address bondingAddress;

    assembly {
      bondingAddress := create2(0, add(bytecode, 32), mload(bytecode), salt)
    }

    Bonding(bondingAddress).initialize(
      bondToken,
      grailToken,
      treasury,
      ratioDecimals,
      ratio,
      startTime,
      depositDuration,
      vestingPeriod,
      maxDepositAmount,
      canHarvestBeforeEnd
    );

    _allBondingContracts.add(bondingAddress);
    emit BondingCreated(bondingAddress, bondToken, ratio, ratioDecimals, startTime, endTime, canHarvestBeforeEnd);
  }

  /**
  * @dev Activate a bonding contract
  *
  * Can only be called by a bonding contract
  */
  function activateBondingContract(uint256 startTime, uint256 endTime, uint256 maxGrailRewards) external {
    require(
      _allBondingContracts.contains(msg.sender),
      "activateBondingContract: caller is not a bonding contract"
    );
    require(_currentBlockTimestamp() < startTime, "activateBondingContract: invalid startTime");

    uint256 totalActiveGrailRewards = 0;
    uint256 _activeBondingContractsLength = activeBondingContracts.length;

    for (uint256 i = _activeBondingContractsLength; i > 0; i--) {
      uint256 index = i-1;
      Bonding curContract = Bonding(activeBondingContracts[index]);
      if (curContract.rewardsEndTime() > _currentBlockTimestamp()) {
        totalActiveGrailRewards = totalActiveGrailRewards.add(curContract.maxGRAILRewards());
      }
      else{
        activeBondingContracts[index] = activeBondingContracts[activeBondingContracts.length - 1];
        activeBondingContracts.pop();
      }
    }

    require(
      totalActiveGrailRewards.add(maxGrailRewards) <= grailToken.totalSupply().mul(MAX_MINTABLE_GRAIL_PERCENT).div(100),
      "createBonding: total active grail rewards should not exceed maximum"
    );
    activeBondingContracts.push(msg.sender);
    emit ActivateBondingContract(msg.sender, startTime, endTime);
  }

  /**
  * @dev Mints grail rewards for a bonding contract
  *
  * Can only be called by a bonding contract
  */
  function mintRewards(address to, uint256 rewardAmount) external {
    require(
      _allBondingContracts.contains(msg.sender),
      "mintRewards: caller is not a bonding contract"
    );
    grailToken.mint(to, rewardAmount);
  }

  /********************************************************/
  /****************** INTERNAL FUNCTION  ******************/
  /********************************************************/

  /**
   * @dev Retrieves child Bonding contract address
   */
  function _getBondingAddress(
    address bondToken,
    uint256 startTime,
    uint256 endTime
  ) internal view returns (address bondingAddress) {
    bondingAddress = address(
      uint256(
        keccak256(
          abi.encodePacked(
            hex"ff",
            address(this),
            keccak256(abi.encodePacked(bondToken, startTime, endTime)),
            keccak256(abi.encodePacked(_getBondingCreationCode()))
          )
        )
      )
    );
    return bondingAddress;
  }

  /**
   * @dev Utility function to get the current block timestamp
   */
  function _currentBlockTimestamp() internal view virtual returns (uint256) {
    return block.timestamp;
  }

  /**
   * @dev Utility function to get the Bonding contract creation code
   */
  function _getBondingCreationCode() internal pure virtual returns (bytes memory) {
    return type(Bonding).creationCode;
  }
}
