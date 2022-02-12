// SPDX-License-Identifier: MIT
pragma solidity =0.7.6;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./interfaces/IDividends.sol";
import "./interfaces/tokens/IERC20Mintable.sol";
import "./interfaces/IExcaliburV2Pair.sol";
import "./interfaces/IExcaliburRouter.sol";

/**
 * This contract receive fees from various sources including swap fees and master deposit fees
 * Those fees will be converted to caller-defined token(s) before being distributed over four predefined destinations
 * Those destinations are: Dividends contract, dev address, SAFU funds address and buy back & burn address
 *
 * Collected EXCToken will be automatically burnt upon distribution
 */
contract FeeManager is Ownable, ReentrancyGuard {
  using SafeMath for uint256;
  using SafeERC20 for IERC20;

  uint256 public dividendsShare = 70; // = 70%
  uint256 public buybackAndBurnShare = 5; // = 5%
  uint256 public safundsShare = 5; // = 5%
  uint256 public devShare = 20; // = 20%

  uint256 public constant MIN_DIVIDENDS_SHARE = 50; // 50%
  uint256 public constant MIN_BUYBACK_AND_BURN_SHARE = 5; // 5%
  uint256 public constant MAX_BUYBACK_AND_BURN_SHARE = 25; // 25%
  uint256 public constant MIN_SAFUNDS_SHARE = 2; // 2%
  uint256 public constant MAX_SAFUNDS_SHARE = 10; // 10%
  uint256 public constant MAX_DEV_SHARE = 20; // = 20%

  IDividends public immutable dividendsContract;
  IERC20Mintable public immutable excToken;
  address public devAddress;
  address public immutable safundsAddress;
  address public immutable buybackAndBurnAddress;

  IExcaliburRouter public routerContract;

  constructor(
    IERC20Mintable excToken_,
    IDividends dividendsContract_,
    address devAddress_,
    address safundsAddress_,
    address buybackAndBurnAddress_
  ) {
    excToken = excToken_;
    dividendsContract = dividendsContract_;
    devAddress = devAddress_;
    safundsAddress = safundsAddress_;
    buybackAndBurnAddress = buybackAndBurnAddress_;
  }

  /********************************************/
  /****************** EVENTS ******************/
  /********************************************/

  event DevAddressUpdated(address indexed prevDevAddress, address indexed newDevAddress);
  event SharesUpdated(uint256 dividendsShare, uint256 buybackAndBurnShare, uint256 safundsShare, uint256 devShare);
  event RouterInitialized(address routerAddress);

  /****************************************************************/
  /****************** EXTERNAL PUBLIC FUNCTIONS  ******************/
  /****************************************************************/

  /**
   * @dev Distributes all fees to the predefined destinations
   */
  function distributeFees() external nonReentrant {
    uint256 length = dividendsContract.distributedTokensLength();
    for (uint256 index = 0; index < length; ++index) {
      IERC20 token = IERC20(dividendsContract.distributedToken(index));
      _distributeToken(token);
    }
    if (excToken.balanceOf(address(this)) > 0) {
      // Burn excToken
      excToken.burn(excToken.balanceOf(address(this)));
    }
  }

  /**
   * @dev Distributes fees to the predefined destinations for only one token
   */
  function distributeFeesByToken(IERC20 token) external nonReentrant {
    require(dividendsContract.isDistributedToken(address(token)), "distributeFeesByToken: not registered as dividends token");
    _distributeToken(token);
    if (excToken.balanceOf(address(this)) > 0) {
      // Burn excToken
      excToken.burn(excToken.balanceOf(address(this)));
    }
  }

  /*****************************************************************/
  /****************** EXTERNAL OWNABLE FUNCTIONS  ******************/
  /*****************************************************************/

  /**
   * @dev Updates shares for each predefined destinations
   *
   * Total shares should always be 100% and respect the min/max settings for each of them
   */
  function updateShares(
    uint256 dividendsShare_,
    uint256 buybackAndBurnShare_,
    uint256 safundsShare_,
    uint256 devShare_
  ) external onlyOwner {
    require(dividendsShare_ >= MIN_DIVIDENDS_SHARE, "FeeManager: dividendsShare mustn't exceed minimum");
    require(
      buybackAndBurnShare_ >= MIN_BUYBACK_AND_BURN_SHARE,
      "FeeManager: buybackAndBurnShare mustn't exceed minimum"
    );
    require(
      buybackAndBurnShare_ <= MAX_BUYBACK_AND_BURN_SHARE,
      "FeeManager: buybackAndBurnShare mustn't exceed maximum"
    );
    require(safundsShare_ >= MIN_SAFUNDS_SHARE, "FeeManager: safundsShare mustn't exceed minimum");
    require(safundsShare_ <= MAX_SAFUNDS_SHARE, "FeeManager: safundsShare mustn't exceed maximum");
    require(devShare_ <= MAX_DEV_SHARE, "FeeManager: devShare mustn't exceed maximum");

    require(
      dividendsShare_.add(buybackAndBurnShare_).add(safundsShare_).add(devShare_) == 100,
      "FeeManager: invalid shares"
    );

    dividendsShare = dividendsShare_;
    buybackAndBurnShare = buybackAndBurnShare_;
    safundsShare = safundsShare_;
    devShare = devShare_;
    emit SharesUpdated(dividendsShare, buybackAndBurnShare, safundsShare, devShare);
  }

  /**
   * @dev Setup Router contract address
   *
   * Can only be initialized one time
   * Must only be called by the owner
   */
  function initializeRouter(IExcaliburRouter router) external onlyOwner {
    require(address(routerContract) == address(0), "FeeManager: routerAddress already initialized");
    routerContract = router;
    emit RouterInitialized(address(routerContract));
  }

  /**
   * @dev Unbind given LP token
   */
  function removeLiquidityToToken(address tokenAddress) external onlyOwner {
    _removeLiquidityToToken(tokenAddress);
  }

  /**
   * @dev Unbind list of LP tokens
   */
  function removeAllLiquidityToToken(address[] calldata tokenAddresses) external onlyOwner {
    for (uint256 i = 0; i < tokenAddresses.length; i++) {
      _removeLiquidityToToken(tokenAddresses[i]);
    }
  }

  /**
   * @dev Swap token0 balance to token1 through routerContract
   */
  function swapBalanceToToken(address token0, address token1, uint256 minAmountToReceived) external onlyOwner {
    _swapAmountToToken(token0, token1, IERC20(token0).balanceOf(address(this)), minAmountToReceived);
  }

  /**
   * @dev Swap token0 amount to token1 through routerContract
   */
  function swapAmountToToken(address token0, address token1, uint256 token0Amount, uint256 minAmountToReceived) external onlyOwner {
    _swapAmountToToken(token0, token1, token0Amount, minAmountToReceived);
  }

  function _swapAmountToToken(address token0, address token1, uint256 token0Amount, uint256 minAmountToReceived) internal onlyOwner {
    require(token0 != address(excToken), "FeeManager: cannot swap excToken");
    IERC20 token0Contract = IERC20(token0);

    // check for allowance
    if (token0Contract.allowance(address(this), address(routerContract)) < token0Amount) {
      token0Contract.safeApprove(address(routerContract), 0);
      token0Contract.safeApprove(address(routerContract), uint256(-1));
    }

    address[] memory path = new address[](2);
    path[0] = token0;
    path[1] = token1;
    // call router swap function
    routerContract.swapExactTokensForTokensSupportingFeeOnTransferTokens(
      token0Amount,
      minAmountToReceived,
      path,
      address(this),
      address(0),
      block.timestamp
    );
  }

  /**
   * @dev Updates dev address
   *
   * Must only be called by the current dev address
   */
  function setDevAddr(address newDevAddress) external {
    require(msg.sender == devAddress, "setDevAddr: caller is not devAddr");
    require(newDevAddress != address(0), "setDevAddr: zero address");
    address prevDevAddress = devAddress;
    devAddress = newDevAddress;
    emit DevAddressUpdated(prevDevAddress, devAddress);
  }

  /********************************************************/
  /****************** INTERNAL FUNCTIONS ******************/
  /********************************************************/

  /**
   * @dev Sends a given dividends token to each predefined destinations
   */
  function _distributeToken(IERC20 token) internal {
    uint256 tokenBalance = token.balanceOf(address(this));

    // calculate repartition between predefined destinations
    uint256 dividendsAmount = tokenBalance.mul(dividendsShare).div(100);
    uint256 safundsAmount = tokenBalance.mul(safundsShare).div(100);
    uint256 buybackAndBurnAmount = tokenBalance.mul(buybackAndBurnShare).div(100);
    uint256 devAmount = tokenBalance.sub(dividendsAmount).sub(safundsAmount).sub(buybackAndBurnAmount);

    // check for allowance
    if (token.allowance(address(this), address(dividendsContract)) < dividendsAmount) {
      token.safeApprove(address(dividendsContract), 0);
      token.safeApprove(address(dividendsContract), uint256(-1));
    }

    // distribution
    dividendsContract.addDividendsToPending(address(token), dividendsAmount);
    token.safeTransfer(safundsAddress, safundsAmount);
    token.safeTransfer(buybackAndBurnAddress, buybackAndBurnAmount);
    token.safeTransfer(devAddress, devAmount);
  }

  /**
   * @dev Unbind tokenAddress pair LP tokens
   */
  function _removeLiquidityToToken(address tokenAddress) internal {
    IExcaliburV2Pair pair = IExcaliburV2Pair(tokenAddress);
    uint256 amount = pair.balanceOf(address(this));
    address token0 = pair.token0();
    address token1 = pair.token1();

    // check for allowance
    if (pair.allowance(address(this), address(routerContract)) < amount) {
      pair.approve(address(routerContract), 0);
      pair.approve(address(routerContract), uint256(-1));
    }

    routerContract.removeLiquidity(token0, token1, amount, 1, 1, address(this), block.timestamp);
  }
}
