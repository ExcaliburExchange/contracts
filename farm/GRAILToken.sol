// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/tokens/IERC20Mintable.sol";
import "./interfaces/tokens/IRegularToken.sol";
import "./interfaces/IDividends.sol";
import "./abstracts/ERC20/ERC20BurnSupply.sol";
import "./abstracts/ERC20/WrapERC20WithPenalty.sol";

contract GRAILToken is
  Ownable,
  ERC20("Excalibur dividend token", "GRAIL"),
  ERC20BurnSupply,
  WrapERC20WithPenalty,
  IERC20Mintable
{
  using SafeMath for uint256;

  address private _masterContractAddress;
  address private _bondingFactoryContractAddress;
  IDividends private _dividendsContract;

  uint256 public constant MAXIMUM_PENALTY_PERIOD = 14 days;
  uint256 public constant MINIMUM_PENALTY_PERIOD = 3 days;

  constructor(
    uint256 penaltyPeriod,
    uint256 penaltyMin,
    uint256 penaltyMax,
    IRegularToken regularTokenContract
  ) WrapERC20WithPenalty(penaltyPeriod, penaltyMin, penaltyMax, regularTokenContract) {}

  /********************************************/
  /****************** EVENTS ******************/
  /********************************************/

  event MasterContractAddressInitialized(address masterContractAddress);
  event BondingFactoryContractAddressInitialized(address BondingFactoryContractAddress);
  event DividendsContractAddressInitialized(address dividendsContractAddress);
  event UnwrapPenaltyPeriodUpdated(uint256 previousUnwrapPenaltyPeriod, uint256 newUnwrapPenaltyPeriod);

  /***********************************************/
  /****************** MODIFIERS ******************/
  /***********************************************/

  /*
   * @dev Throws if called by any account other than the master
   */
  modifier onlyMasterOrBondingFactory() {
    require(
      _isMaster() || _isBondingFactory(),
      "GRAILToken: caller is not the master or the exc converter factory"
    );
    _;
  }

  /**************************************************/
  /****************** PUBLIC VIEWS ******************/
  /**************************************************/

  function masterContractAddress() external view returns (address) {
    return _masterContractAddress;
  }

  function BondingFactoryContractAddress() external view returns (address) {
    return _bondingFactoryContractAddress;
  }

  function dividendsContractAddress() external view returns (address) {
    return address(_dividendsContract);
  }

  /****************************************************/
  /****************** INTERNAL VIEWS ******************/
  /****************************************************/

  /**
   * @dev Returns true if caller is the Master contract
   */
  function _isMaster() internal view returns (bool) {
    return msg.sender == _masterContractAddress;
  }

  /**
   * @dev Returns true if caller is the BondingFactory contract
   */
  function _isBondingFactory() internal view returns (bool) {
    return msg.sender == _bondingFactoryContractAddress;
  }

  /*****************************************************************/
  /****************** EXTERNAL OWNABLE FUNCTIONS  ******************/
  /*****************************************************************/

  /**
   * @dev Sets Master contract address
   *
   * Can only be initialize one time
   * Must only be called by the owner
   */
  function initializeMasterContractAddress(address master) external onlyOwner {
    require(_masterContractAddress == address(0), "GRAILToken: master already initialized");
    require(master != address(0), "GRAILToken: master initialized to zero address");
    _masterContractAddress = master;
    emit MasterContractAddressInitialized(master);
  }

  /**
   * @dev Sets EXC bonding factory contract address
   *
   * Can only be initialize one time
   * Must only be called by the owner
   */
  function initializeBondingFactoryContractAddress(address bondingFactoryContractAddress) external onlyOwner {
    require(_bondingFactoryContractAddress == address(0), "GRAILToken: BondingFactory already initialized");
    require(
      bondingFactoryContractAddress != address(0),
      "GRAILToken: BondingFactory initialized to zero address"
    );
    _bondingFactoryContractAddress = bondingFactoryContractAddress;
    emit BondingFactoryContractAddressInitialized(bondingFactoryContractAddress);
  }

  /**
   * @dev Sets Dividends contract address
   *
   * Can only be initialize one time
   * Must only be called by the owner
   */
  function initializeDividendsContract(IDividends dividendsContract) external onlyOwner {
    require(address(_dividendsContract) == address(0), "GRAILToken: dividends already initialized");
    require(address(dividendsContract) != address(0), "GRAILToken: dividends initialized to zero address");
    _dividendsContract = dividendsContract;
    emit DividendsContractAddressInitialized(address(dividendsContract));
  }

  /**
   * @dev Updates the unwrapPenaltyPeriod
   *
   * Must be a value between MINIMUM_PENALTY_PERIOD and MAXIMUM_PENALTY_PERIOD
   */
  function updateUnwrapPenaltyPeriod(uint256 penaltyPeriod) external onlyOwner {
    require(penaltyPeriod <= MAXIMUM_PENALTY_PERIOD, "GRAILToken: _unwrapPenaltyPeriod mustn't exceed maximum");
    require(penaltyPeriod >= MINIMUM_PENALTY_PERIOD, "GRAILToken: _unwrapPenaltyPeriod mustn't exceed minimum");
    uint256 prevPenalityPeriod = _unwrapPenaltyPeriod;
    _unwrapPenaltyPeriod = penaltyPeriod;
    emit UnwrapPenaltyPeriodUpdated(prevPenalityPeriod, _unwrapPenaltyPeriod);
  }

  /**
   * @dev Creates `amount` token to `account`
   *
   * Can only be called by the MasterChef or BondingFactory
   * See {ERC20-_mint}
   */
  function mint(address account, uint256 amount) external override onlyMasterOrBondingFactory returns (bool) {
    _mint(account, amount);
    return true;
  }

  /**
   * @dev Destroys `amount` tokens from the caller
   *
   * See {ERC20BurnSupply-_burn}
   */
  function burn(uint256 amount) external override {
    _burn(_msgSender(), amount);
  }

  /********************************************************/
  /****************** INTERNAL FUNCTIONS ******************/
  /********************************************************/

  /**
   * @dev Overrides _transfer function
   *
   * Updates dividendsContract user data if set
   */
  function _transfer(
    address sender,
    address recipient,
    uint256 amount
  ) internal override {
    uint256 senderPreviousBalance = balanceOf(sender);
    uint256 recipientPreviousBalance = balanceOf(recipient);
    super._transfer(sender, recipient, amount);
    if (address(_dividendsContract) != address(0)) {
      _dividendsContract.updateUser(sender, senderPreviousBalance, totalSupply());
      _dividendsContract.updateUser(recipient, recipientPreviousBalance, totalSupply());
    }
  }

  /**
   * @dev Overrides _burn function
   *
   * Updates dividendsContract user data if set
   */
  function _burn(address account, uint256 amount) internal override(ERC20, ERC20BurnSupply) {
    uint256 previousTotalSupply = totalSupply();
    uint256 accountPreviousBalance = balanceOf(account);
    ERC20BurnSupply._burn(account, amount);
    if (address(_dividendsContract) != address(0)) {
      _dividendsContract.updateUser(account, accountPreviousBalance, previousTotalSupply);
    }
  }

  /**
   * @dev Overrides _mint function
   *
   * Updates dividendsContract user data if set
   */
  function _mint(address account, uint256 amount) internal override {
    uint256 previousTotalSupply = totalSupply();
    uint256 accountPreviousBalance = balanceOf(account);
    super._mint(account, amount);
    if (address(_dividendsContract) != address(0)) {
      _dividendsContract.updateUser(account, accountPreviousBalance, previousTotalSupply);
    }
  }

  function _beforeTokenTransfer(
    address from,
    address to,
    uint256 amount
  ) internal override(ERC20, WrapERC20WithPenalty) {
    WrapERC20WithPenalty._beforeTokenTransfer(from, to, amount);
  }
}
