pragma solidity =0.6.6;

import 'excalibur-core/contracts/interfaces/IExcaliburV2Pair.sol';
import 'excalibur-core/contracts/interfaces/IExcaliburV2Factory.sol';
import 'excalibur-core/contracts/interfaces/IERC20.sol';

import './libraries/SafeMath.sol';
import "./interfaces/IPriceConsumer.sol";
import "./interfaces/ISwapFeeRebate.sol";

contract SwapFeeRebate is ISwapFeeRebate{
  using SafeMath for uint;

  IExcaliburV2Factory public immutable factory;
  address immutable EXC;

  IPriceConsumer public priceConsumer;
  uint public feeRebateShare = 100; // 100%
  mapping(address => bool) public whitelistedPairs; // trustable pairs for transaction fee mining

  event FeeRebateShareUpdated(uint feeRebateShare, uint newFeeRebateShare);
  event SetPriceConsumer(address prevPriceConsumer, address priceConsumer);
  event SetWhitelistPair(address pair, bool whitelisted);

  constructor (IExcaliburV2Factory _factory, address excAddress, IPriceConsumer _priceConsumer) public {
    factory = _factory;
    EXC = excAddress;
    priceConsumer = _priceConsumer;
  }

  function owner() public view returns (address){
    return factory.owner();
  }

  function setPriceConsumer(IPriceConsumer _priceConsumer) external {
    require(msg.sender == owner(), "SwapFeeRebate: not allowed");
    emit SetPriceConsumer(address(priceConsumer), address(_priceConsumer));
    priceConsumer = _priceConsumer;
  }

  function setFeeRebateShare(uint newFeeRebateShare) external {
    require(msg.sender == owner(), "SwapFeeRebate: not allowed");
    require(newFeeRebateShare <= 100, "SwapFeeRebate: feeRebateShare mustn't exceed maximum");
    emit FeeRebateShareUpdated(feeRebateShare, newFeeRebateShare);
    feeRebateShare = newFeeRebateShare;
  }

  function setWhitelistPair(address token0, address token1, address pair, bool whitelisted) external {
    require(msg.sender == owner(), "SwapFeeRebate: not allowed");
    require(factory.getPair(token0, token1) == pair, "SwapFeeRebate: invalid pair address");
    whitelistedPairs[pair] = whitelisted;
    emit SetWhitelistPair(pair, whitelisted);
  }

  function isWhitelistedPair(address pair) external view returns (bool) {
    return whitelistedPairs[pair];
  }

  function updateEXCLastPrice() external override {
    priceConsumer.getEXCMaxPriceUSD();
  }

  function getEXCFees(address inputToken, address outputToken, uint outputTokenAmount) external view override returns (uint){
    if (feeRebateShare == 0) return 0;

    address pair = factory.getPair(inputToken, outputToken);
    if (!whitelistedPairs[pair]) return 0;
    uint feeAmount = IExcaliburV2Pair(pair).feeAmount();

    if(outputToken == EXC){
      return outputTokenAmount.mul(feeAmount).mul(feeRebateShare) / 100000 / 100;
    }

    uint excPrice = priceConsumer.lastEXCPrice();
    if(excPrice == 0) return 0;

    uint outputTokenPriceUSD = priceConsumer.getTokenMinPriceUSD(outputToken);
    if(outputTokenPriceUSD == 0) return 0;

    // check if token decimals is 18 like the EXC token and adjust it for conversion
    uint outputTokenDecimals = IERC20(outputToken).decimals();
    if (outputTokenDecimals < 18) {
      outputTokenAmount = outputTokenAmount.mul(10 ** (18 - outputTokenDecimals));
    }
    else if (outputTokenDecimals > 18){
      outputTokenAmount = outputTokenAmount / (10 ** (outputTokenDecimals - 18));
    }

    return outputTokenAmount.mul(outputTokenPriceUSD).mul(feeAmount).mul(feeRebateShare) / 100000 / 100 / excPrice;
  }
}