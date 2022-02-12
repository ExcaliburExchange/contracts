pragma solidity =0.5.16;

import './interfaces/IExcaliburV2Factory.sol';
import './ExcaliburV2Pair.sol';

contract ExcaliburV2Factory is IExcaliburV2Factory {
    bytes32 public constant INIT_CODE_PAIR_HASH = keccak256(abi.encodePacked(type(ExcaliburV2Pair).creationCode));

    address public owner;
    address public feeTo;

    //uint public constant FEE_DENOMINATOR = 100000;
    uint public constant OWNER_FEE_SHARE_MAX = 50000; // 50%
    uint public ownerFeeShare = 50000; // default value = 50%

    uint public constant REFERER_FEE_SHARE_MAX = 20000; // 20%
    mapping(address => uint) public referrersFeeShare; // fees are taken from the user input

    mapping(address => mapping(address => address)) public getPair;
    address[] public allPairs;

    event FeeToTransferred(address indexed prevFeeTo, address indexed newFeeTo);
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);
    event OwnerFeeShareUpdated(uint prevOwnerFeeShare, uint ownerFeeShare);
    event OwnershipTransferred(address indexed prevOwner, address indexed newOwner);
    event ReferrerFeeShareUpdated(address referrer, uint prevReferrerFeeShare, uint referrerFeeShare);

    constructor(address feeTo_) public {
        owner = msg.sender;
        feeTo = feeTo_;
    }

    /**
     * @dev Throws if called by any account other than the owner.
     */
    modifier onlyOwner() {
        require(owner == msg.sender, "ExcaliburV2Factory: caller is not the owner");
        _;
    }

    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, 'ExcaliburV2Factory: IDENTICAL_ADDRESSES');
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'ExcaliburV2Factory: ZERO_ADDRESS');
        require(getPair[token0][token1] == address(0), 'ExcaliburV2Factory: PAIR_EXISTS'); // single check is sufficient
        bytes memory bytecode = type(ExcaliburV2Pair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        assembly {
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        IExcaliburV2Pair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setOwner(address _owner) external onlyOwner {
        require(_owner != address(0), "ExcaliburV2Factory: zero address");
        emit OwnershipTransferred(owner, _owner);
        owner = _owner;
    }

    function setFeeTo(address _feeTo) external onlyOwner {
        emit FeeToTransferred(feeTo, _feeTo);
        feeTo = _feeTo;
    }

    /**
     * @dev Updates the share of fees attributed to the owner (FeeManager)
     *
     * Must only be called by owner
     */
    function setOwnerFeeShare(uint newOwnerFeeShare) external onlyOwner {
        require(newOwnerFeeShare > 0, "ExcaliburV2Factory: ownerFeeShare mustn't exceed minimum");
        require(newOwnerFeeShare <= OWNER_FEE_SHARE_MAX, "ExcaliburV2Factory: ownerFeeShare mustn't exceed maximum");
        uint prevOwnerFeeShare = ownerFeeShare;
        ownerFeeShare = newOwnerFeeShare;
        emit OwnerFeeShareUpdated(prevOwnerFeeShare, ownerFeeShare);
    }

    /**
     * @dev Updates the share of fees attributed to the given referrer when a swap went through him
     *
     * Must only be called by owner
     */
    function setRefererFeeShare(address referrer, uint referrerFeeShare) external onlyOwner {
        require(referrerFeeShare <= REFERER_FEE_SHARE_MAX, "ExcaliburV2Factory: referrerFeeShare mustn't exceed maximum");
        uint prevReferrerFeeShare = referrersFeeShare[referrer];
        referrersFeeShare[referrer] = referrerFeeShare;
        emit ReferrerFeeShareUpdated(referrer, prevReferrerFeeShare, referrerFeeShare);
    }
}
