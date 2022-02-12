pragma solidity =0.6.6;

import '@uniswap/lib/contracts/libraries/TransferHelper.sol';

import 'excalibur-core/contracts/interfaces/IExcaliburV2Factory.sol';
import 'excalibur-core/contracts/interfaces/IExcaliburV2Pair.sol';
import 'excalibur-core/contracts/interfaces/IERC20.sol';

import './interfaces/IExcaliburRouter.sol';
import './libraries/UniswapV2Library.sol';
import './libraries/SafeMath.sol';
import './interfaces/IWETH.sol';
import "./interfaces/ISwapFeeRebate.sol";

contract ExcaliburRouter is IExcaliburRouter {
  using SafeMath for uint;

  ISwapFeeRebate public immutable swapFeeRebate;

  address public immutable EXC;
  address public immutable override factory;
  address public immutable override WETH;

  address public operator;

  bool public feeRebateDisabled;

  mapping(address => uint) public accountAccEXCFromFees;
  uint public curDayTotalAllocatedEXC;
  uint public curDayStartTime;
  uint public maxDailyEXCAllocation = 1000 ether; // daily cap for EXC allocation from rebate

  bytes4 private constant EXC_MINT_SELECTOR = bytes4(keccak256(bytes('mint(address,uint256)')));

  uint private unlocked = 1;
  modifier lock() {
    require(unlocked == 1, 'ExcaliburRouter: LOCKED');
    unlocked = 0;
    _;
    unlocked = 1;
  }

  modifier ensure(uint deadline) {
    require(deadline >= block.timestamp, 'ExcaliburRouter: EXPIRED');
    _;
  }

  constructor(address _factory, address _WETH, address _EXC, ISwapFeeRebate _SwapFeeRebate) public {
    operator = msg.sender;

    factory = _factory;
    WETH = _WETH;

    swapFeeRebate = _SwapFeeRebate;
    EXC = _EXC;
    curDayStartTime = block.timestamp;
  }

  event WithdrawEXCFromFees(address indexed account, uint excAmount);
  event SetFeeRebateDisabled(bool prevFeeRebateDisabled, bool feeRebateDisabled);
  event SetMaxDailyEXCAllocation(uint prevMaxDailyEXCAllocation, uint newMaxDailyEXCAllocation);
  event AllocatedEXCFromFees(address indexed swapToken, address indexed toToken, uint swapTokenAmount, uint EXCAmount);
  event AllocatedEXCFromFeesCapped(address indexed swapToken, address indexed toToken, uint swapTokenAmount, uint EXCAmount, uint cappedAmount);
  event OperatorTransferred(address indexed previousOwner, address indexed newOwner);

  receive() external payable {
  }

  function setFeeRebateDisabled(bool feeRebateDisabled_) external {
    require(msg.sender == operator, "ExcaliburRouter: not allowed");
    emit SetFeeRebateDisabled(feeRebateDisabled, feeRebateDisabled_);
    feeRebateDisabled = feeRebateDisabled_;
  }

  function setMaxDailyEXCAllocation(uint _maxDailyEXCAllocation) external {
    require(msg.sender == IExcaliburV2Factory(factory).owner(), "ExcaliburRouter: not allowed");
    emit SetMaxDailyEXCAllocation(maxDailyEXCAllocation, _maxDailyEXCAllocation);
    maxDailyEXCAllocation = _maxDailyEXCAllocation;
  }


  /**
   * @dev Transfers the operator of the contract to a new account (`newOperator`).
   *
   * Must only be called by the current operator.
   */
  function transferOperator(address newOperator) external {
    require(msg.sender == operator, "ExcaliburRouter: not allowed");
    require(newOperator != address(0), "transferOperator: new operator is the zero address");
    emit OperatorTransferred(operator, newOperator);
    operator = newOperator;
  }

  function getPair(address token1, address token2) external view returns (address){
    return UniswapV2Library.pairFor(factory, token1, token2);
  }

  function isContract(address account) public view returns (bool){
    uint size;
    assembly {
      size := extcodesize(account)
    }
    return size > 0;
  }

  // **** ADD LIQUIDITY ****
  function _addLiquidity(
    address tokenA,
    address tokenB,
    uint amountADesired,
    uint amountBDesired,
    uint amountAMin,
    uint amountBMin
  ) internal returns (uint amountA, uint amountB) {
    // create the pair if it doesn't exist yet
    if (IExcaliburV2Factory(factory).getPair(tokenA, tokenB) == address(0)) {
      IExcaliburV2Factory(factory).createPair(tokenA, tokenB);
    }
    (uint reserveA, uint reserveB) = UniswapV2Library.getReserves(factory, tokenA, tokenB);
    if (reserveA == 0 && reserveB == 0) {
      (amountA, amountB) = (amountADesired, amountBDesired);
    } else {
      uint amountBOptimal = UniswapV2Library.quote(amountADesired, reserveA, reserveB);
      if (amountBOptimal <= amountBDesired) {
        require(amountBOptimal >= amountBMin, 'ExcaliburRouter: INSUFFICIENT_B_AMOUNT');
        (amountA, amountB) = (amountADesired, amountBOptimal);
      } else {
        uint amountAOptimal = UniswapV2Library.quote(amountBDesired, reserveB, reserveA);
        assert(amountAOptimal <= amountADesired);
        require(amountAOptimal >= amountAMin, 'ExcaliburRouter: INSUFFICIENT_A_AMOUNT');
        (amountA, amountB) = (amountAOptimal, amountBDesired);
      }
    }
  }

  function addLiquidity(
    address tokenA,
    address tokenB,
    uint amountADesired,
    uint amountBDesired,
    uint amountAMin,
    uint amountBMin,
    address to,
    uint deadline
  ) external override ensure(deadline) returns (uint amountA, uint amountB, uint liquidity) {
    (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
    address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
    TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
    TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
    liquidity = IExcaliburV2Pair(pair).mint(to);
  }

  function addLiquidityETH(
    address token,
    uint amountTokenDesired,
    uint amountTokenMin,
    uint amountETHMin,
    address to,
    uint deadline
  ) external override payable ensure(deadline) returns (uint amountToken, uint amountETH, uint liquidity) {
    (amountToken, amountETH) = _addLiquidity(
      token,
      WETH,
      amountTokenDesired,
      msg.value,
      amountTokenMin,
      amountETHMin
    );
    address pair = UniswapV2Library.pairFor(factory, token, WETH);
    TransferHelper.safeTransferFrom(token, msg.sender, pair, amountToken);
    IWETH(WETH).deposit{value : amountETH}();
    assert(IWETH(WETH).transfer(pair, amountETH));
    liquidity = IExcaliburV2Pair(pair).mint(to);
    // refund dust eth, if any
    if (msg.value > amountETH) TransferHelper.safeTransferETH(msg.sender, msg.value - amountETH);
  }

  // **** REMOVE LIQUIDITY ****
  function removeLiquidity(
    address tokenA,
    address tokenB,
    uint liquidity,
    uint amountAMin,
    uint amountBMin,
    address to,
    uint deadline
  ) public override ensure(deadline) returns (uint amountA, uint amountB) {
    address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
    IExcaliburV2Pair(pair).transferFrom(msg.sender, pair, liquidity);
    // send liquidity to pair
    (uint amount0, uint amount1) = IExcaliburV2Pair(pair).burn(to);
    (address token0,) = UniswapV2Library.sortTokens(tokenA, tokenB);
    (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
    require(amountA >= amountAMin, 'ExcaliburRouter: INSUFFICIENT_A_AMOUNT');
    require(amountB >= amountBMin, 'ExcaliburRouter: INSUFFICIENT_B_AMOUNT');
  }

  function removeLiquidityETH(
    address token,
    uint liquidity,
    uint amountTokenMin,
    uint amountETHMin,
    address to,
    uint deadline
  ) public override ensure(deadline) returns (uint amountToken, uint amountETH) {
    (amountToken, amountETH) = removeLiquidity(
      token,
      WETH,
      liquidity,
      amountTokenMin,
      amountETHMin,
      address(this),
      deadline
    );
    TransferHelper.safeTransfer(token, to, amountToken);
    IWETH(WETH).withdraw(amountETH);
    TransferHelper.safeTransferETH(to, amountETH);
  }

  function removeLiquidityWithPermit(
    address tokenA,
    address tokenB,
    uint liquidity,
    uint amountAMin,
    uint amountBMin,
    address to,
    uint deadline,
    bool approveMax, uint8 v, bytes32 r, bytes32 s
  ) external override returns (uint amountA, uint amountB) {
    address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
    uint value = approveMax ? uint(- 1) : liquidity;
    IExcaliburV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
    (amountA, amountB) = removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, to, deadline);
  }

  function removeLiquidityETHWithPermit(
    address token,
    uint liquidity,
    uint amountTokenMin,
    uint amountETHMin,
    address to,
    uint deadline,
    bool approveMax, uint8 v, bytes32 r, bytes32 s
  ) external override returns (uint amountToken, uint amountETH) {
    address pair = UniswapV2Library.pairFor(factory, token, WETH);
    uint value = approveMax ? uint(- 1) : liquidity;
    IExcaliburV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
    (amountToken, amountETH) = removeLiquidityETH(token, liquidity, amountTokenMin, amountETHMin, to, deadline);
  }

  // **** REMOVE LIQUIDITY (supporting fee-on-transfer tokens) ****
  function removeLiquidityETHSupportingFeeOnTransferTokens(
    address token,
    uint liquidity,
    uint amountTokenMin,
    uint amountETHMin,
    address to,
    uint deadline
  ) public override ensure(deadline) returns (uint amountETH) {
    (, amountETH) = removeLiquidity(
      token,
      WETH,
      liquidity,
      amountTokenMin,
      amountETHMin,
      address(this),
      deadline
    );
    TransferHelper.safeTransfer(token, to, IERC20(token).balanceOf(address(this)));
    IWETH(WETH).withdraw(amountETH);
    TransferHelper.safeTransferETH(to, amountETH);
  }

  function removeLiquidityETHWithPermitSupportingFeeOnTransferTokens(
    address token,
    uint liquidity,
    uint amountTokenMin,
    uint amountETHMin,
    address to,
    uint deadline,
    bool approveMax, uint8 v, bytes32 r, bytes32 s
  ) external override returns (uint amountETH) {
    address pair = UniswapV2Library.pairFor(factory, token, WETH);
    uint value = approveMax ? uint(- 1) : liquidity;
    IExcaliburV2Pair(pair).permit(msg.sender, address(this), value, deadline, v, r, s);
    amountETH = removeLiquidityETHSupportingFeeOnTransferTokens(
      token, liquidity, amountTokenMin, amountETHMin, to, deadline
    );
  }

  // **** SWAP ****

  /**
   * @dev Updates harvestable EXC balance for caller
   */
  function _updateAccountAccEXCFromFees(address swapToken, address toToken, uint swapTokenAmount) internal {
    if(feeRebateDisabled || msg.sender != tx.origin || isContract(msg.sender)) return;
    uint EXCAmount = swapFeeRebate.getEXCFees(swapToken, toToken, swapTokenAmount);
    if(EXCAmount > 0){
      if(block.timestamp > curDayStartTime.add(1 days)){
        curDayStartTime = block.timestamp;
        curDayTotalAllocatedEXC = 0;
      }

      if(curDayTotalAllocatedEXC.add(EXCAmount) > maxDailyEXCAllocation) {
        uint cappedAmount = maxDailyEXCAllocation.sub(curDayTotalAllocatedEXC);
        emit AllocatedEXCFromFeesCapped(swapToken, toToken, swapTokenAmount, EXCAmount, cappedAmount);
        if(cappedAmount == 0) return;
        EXCAmount = cappedAmount;
      }

      accountAccEXCFromFees[msg.sender] += EXCAmount;
      curDayTotalAllocatedEXC += EXCAmount;
      emit AllocatedEXCFromFees(swapToken, toToken, swapTokenAmount, EXCAmount);
    }
  }

  /**
   * @dev EXC minting for transaction fee mining
   */
  function _safeMintExc(address to, uint value) private {
    (bool success, bytes memory data) = EXC.call(abi.encodeWithSelector(EXC_MINT_SELECTOR, to, value));
    require(success && (data.length == 0 || abi.decode(data, (bool))), 'ExcaliburV2Pair: MINT_FAILED');
  }

  /**
   * @dev Claim EXC rewards from transaction fee mining
   */
  function withdrawAccEXCFromFees() external {
    require(msg.sender == tx.origin && !isContract(msg.sender), "contracts not allowed");

    uint excAmount = accountAccEXCFromFees[msg.sender];
    accountAccEXCFromFees[msg.sender] = 0;

    _safeMintExc(msg.sender, excAmount);
    emit WithdrawEXCFromFees(msg.sender, excAmount);
  }

  // requires the initial amount to have already been sent to the first pair
  function _swap(uint[] memory amounts, address[] memory path, address _to, address referrer) internal {
    if(!feeRebateDisabled) swapFeeRebate.updateEXCLastPrice();
    for (uint i; i < path.length - 1; i++) {
      (address input, address output) = (path[i], path[i + 1]);
      (address token0,) = UniswapV2Library.sortTokens(input, output);
      uint amountOut = amounts[i + 1];
      (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOut) : (amountOut, uint(0));
      address to = i < path.length - 2 ? UniswapV2Library.pairFor(factory, output, path[i + 2]) : _to;

      _updateAccountAccEXCFromFees(input, output, amountOut);

      IExcaliburV2Pair pair = IExcaliburV2Pair(UniswapV2Library.pairFor(factory, input, output));
      pair.swap(amount0Out, amount1Out, to, new bytes(0), referrer);
    }
  }

  function swapTokensForExactTokens(
    uint amountOut,
    uint amountInMax,
    address[] calldata path,
    address to,
    address referrer,
    uint deadline
  ) external override lock ensure(deadline) returns (uint[] memory amounts) {
    amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
    require(amounts[0] <= amountInMax, 'ExcaliburRouter: EXCESSIVE_INPUT_AMOUNT');

    TransferHelper.safeTransferFrom(
      path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
    );
    _swap(amounts, path, to, referrer);
  }

  function swapTokensForExactETH(
    uint amountOut,
    uint amountInMax,
    address[] calldata path,
    address to,
    address referrer,
    uint deadline
  )
  external
  override
  lock ensure(deadline)
  returns (uint[] memory amounts)
  {
    require(path[path.length - 1] == WETH, 'ExcaliburRouter: INVALID_PATH');
    amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
    require(amounts[0] <= amountInMax, 'ExcaliburRouter: EXCESSIVE_INPUT_AMOUNT');

    TransferHelper.safeTransferFrom(
      path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
    );
    _swap(amounts, path, address(this), referrer);
    IWETH(WETH).withdraw(amounts[amounts.length - 1]);
    TransferHelper.safeTransferETH(to, amounts[amounts.length - 1]);
  }

  function swapETHForExactTokens(uint amountOut, address[] calldata path, address to, address referrer, uint deadline)
  external
  override
  payable
  lock ensure(deadline)
  returns (uint[] memory amounts)
  {
    require(path[0] == WETH, 'ExcaliburRouter: INVALID_PATH');
    amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
    require(amounts[0] <= msg.value, 'ExcaliburRouter: EXCESSIVE_INPUT_AMOUNT');

    IWETH(WETH).deposit{value : amounts[0]}();
    assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]));
    _swap(amounts, path, to, referrer);
    // refund dust eth, if any
    if (msg.value > amounts[0]) TransferHelper.safeTransferETH(msg.sender, msg.value - amounts[0]);
  }

  // **** SWAP (supporting fee-on-transfer tokens) ****
  // requires the initial amount to have already been sent to the first pair
  function _swapSupportingFeeOnTransferTokens(address[] memory path, address _to, address referrer) internal {
    if(!feeRebateDisabled) swapFeeRebate.updateEXCLastPrice();
    for (uint i; i < path.length - 1; i++) {
      (address input, address output) = (path[i], path[i + 1]);
      (address token0,) = UniswapV2Library.sortTokens(input, output);
      IExcaliburV2Pair pair = IExcaliburV2Pair(UniswapV2Library.pairFor(factory, input, output));
      uint amountOutput;
      {// scope to avoid stack too deep errors
        (uint reserve0, uint reserve1,) = pair.getReserves();
        if (input != token0) (reserve0, reserve1) = (reserve1, reserve0);
        // permute values to force reserve0 == inputReserve
        uint amountInput = IERC20(input).balanceOf(address(pair)).sub(reserve0);
        amountOutput = UniswapV2Library.getAmountOut(amountInput, reserve0, reserve1, pair.feeAmount());
        _updateAccountAccEXCFromFees(input, output, amountOutput);
      }

      (uint amount0Out, uint amount1Out) = input == token0 ? (uint(0), amountOutput) : (amountOutput, uint(0));
      address to = i < path.length - 2 ? UniswapV2Library.pairFor(factory, output, path[i + 2]) : _to;
      pair.swap(amount0Out, amount1Out, to, new bytes(0), referrer);
    }
  }

  function swapExactTokensForTokensSupportingFeeOnTransferTokens(
    uint amountIn,
    uint amountOutMin,
    address[] calldata path,
    address to,
    address referrer,
    uint deadline
  ) external override lock ensure(deadline) {
    TransferHelper.safeTransferFrom(
      path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amountIn
    );
    uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
    _swapSupportingFeeOnTransferTokens(path, to, referrer);
    require(
      IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
      'ExcaliburRouter: INSUFFICIENT_OUTPUT_AMOUNT'
    );
  }

  function swapExactETHForTokensSupportingFeeOnTransferTokens(
    uint amountOutMin,
    address[] calldata path,
    address to,
    address referrer,
    uint deadline
  )
  external
  override
  payable
  lock ensure(deadline)
  {
    require(path[0] == WETH, 'ExcaliburRouter: INVALID_PATH');
    uint amountIn = msg.value;
    IWETH(WETH).deposit{value : amountIn}();
    assert(IWETH(WETH).transfer(UniswapV2Library.pairFor(factory, path[0], path[1]), amountIn));

    uint balanceBefore = IERC20(path[path.length - 1]).balanceOf(to);
    _swapSupportingFeeOnTransferTokens(path, to, referrer);
    require(
      IERC20(path[path.length - 1]).balanceOf(to).sub(balanceBefore) >= amountOutMin,
      'ExcaliburRouter: INSUFFICIENT_OUTPUT_AMOUNT'
    );
  }

  function swapExactTokensForETHSupportingFeeOnTransferTokens(
    uint amountIn,
    uint amountOutMin,
    address[] calldata path,
    address to,
    address referrer,
    uint deadline
  )
  external
  override
  lock ensure(deadline)
  {
    require(path[path.length - 1] == WETH, 'ExcaliburRouter: INVALID_PATH');
    TransferHelper.safeTransferFrom(
      path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amountIn
    );
    _swapSupportingFeeOnTransferTokens(path, address(this), referrer);
    uint amountOut = IERC20(WETH).balanceOf(address(this));
    require(amountOut >= amountOutMin, 'ExcaliburRouter: INSUFFICIENT_OUTPUT_AMOUNT');
    IWETH(WETH).withdraw(amountOut);
    TransferHelper.safeTransferETH(to, amountOut);
  }


  // **** LIBRARY FUNCTIONS ****
  function quote(uint amountA, uint reserveA, uint reserveB) external pure override returns (uint amountB) {
    return UniswapV2Library.quote(amountA, reserveA, reserveB);
  }

  function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut, uint feeAmount)
  external
  pure
  override
  returns (uint amountOut)
  {
    return UniswapV2Library.getAmountOut(amountIn, reserveIn, reserveOut, feeAmount);
  }

  function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut, uint feeAmount)
  external
  pure
  override
  returns (uint amountIn)
  {
    return UniswapV2Library.getAmountIn(amountOut, reserveIn, reserveOut, feeAmount);
  }

  function getAmountsOut(uint amountIn, address[] calldata path) external view returns (uint[] memory amounts) {
    return UniswapV2Library.getAmountsOut(factory, amountIn, path);
  }

  function getAmountsIn(uint amountOut, address[] calldata path) external view returns (uint[] memory amounts)
  {
    return UniswapV2Library.getAmountsIn(factory, amountOut, path);
  }
}
