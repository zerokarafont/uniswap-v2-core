pragma solidity =0.5.16;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

contract UniswapV2Factory is IUniswapV2Factory {
    address public feeTo; // 收税地址
    address public feeToSetter; // 拥有设置收税地址权限的(管理员)地址

    mapping(address => mapping(address => address)) public getPair; // token0 => (token1 => pairAddr), 存储与token0配对的所有token1的pair地址
    address[] public allPairs;

    event PairCreated(address indexed token0, address indexed token1, address pair, uint256);

    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter;
    }

    function allPairsLength() external view returns (uint256) {
        return allPairs.length;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');
        // 因为地址的底层是uint160 所以要有大小排序
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
        // 这里只检查单一方向即可, 因为创建的时候是会双向创建映射的
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS');
        // 获得包含创建合同字节码的内存字节数组。它可以在内联汇编中构建自定义创建例程，尤其是使用 create2 操作码。 不能在合同本身或派生的合同访问此属性。 因为会引起循环引用
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        // solidity 0.6.1以上不需要这样低级的写法了
        assembly {
            /**
             * @dev: create2方法 - 在已知交易对及salt的情况下创建一个新的交易对,返回新的交易对地址(针对此算法可以提前知道交易对的地址)
             * @notice 转注释2
             * @notice create2(V, P, N, S) - V: 发送V数量wei以太,P: 起始内存地址,N: bytecode长度,S: salt
             * @param {uint} 指创建合约后向合约发送x数量wei的以太币
             * @param {bytes} add(bytecode, 32) opcode的add方法,将bytecode偏移后32位字节处,因为前32位字节存的是bytecode长度
             * @param {bytes} mload(bytecode) opcode的方法,获得bytecode长度
             * @param {bytes} salt 盐值
             * @return {address} 返回新的交易对地址
             */
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        IUniswapV2Pair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    /**
     * @dev 设置收税地址
     */
    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    /**
     *  @dev 设置管理员地址
     */
    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
