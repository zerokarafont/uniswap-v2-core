pragma solidity =0.5.16;

import './interfaces/IUniswapV2Pair.sol';
import './UniswapV2ERC20.sol';
import './libraries/Math.sol';
import './libraries/UQ112x112.sol';
import './interfaces/IERC20.sol';
import './interfaces/IUniswapV2Factory.sol';
import './interfaces/IUniswapV2Callee.sol';

contract UniswapV2Pair is IUniswapV2Pair, UniswapV2ERC20 {
    using SafeMath for uint256;
    using UQ112x112 for uint224;

    // 10**3是微不足道的，因为单位都是1 / 10 ** 18, 即一个erc20 token = 10 ** 18
    /**
    Pair智能合约对应的LPS是有18位小数的（以太坊中最大的小数位数），理论上有一种情况是LPS的最小量（即1e-18 LPS）价值非常大，
    导致后续小流动性提供者很难再提供流动性了，因为提供流动性的成本太高了，例如1e-18 LPS = $100的话，因为这个是最小单位了，
    所以要增加流动性就至少质押$100美金才能获得LPS，而且随着LPS增值，流动性成本越来越高，不利于维持交易的流动性。
    在Uniswap白皮书中把这种极端情况认为是一种可能的人为攻击，为了提高这种攻击的成本，在新创建流动性池的时候，设置了一个最小流动性值MINIMUM_LIQUIDITY=1e-15，
    即LPS最小单位的1000倍，任何流动性池在启用之初都要在零地址中锁定1e-15的LPS，也就是说1e-15的LPS对应价值的币会被永久锁定拿不出来，因为零地址相当于销毁了这部分LP
    这样大大提高了(想垄断流动性的攻击者)的攻击成本
    Uniswap深度科普 - JasonW的文章 - 知乎 https://zhuanlan.zhihu.com/p/380749685
     */
    uint256 public constant MINIMUM_LIQUIDITY = 10**3;
    bytes4 private constant SELECTOR = bytes4(keccak256(bytes('transfer(address,uint256)')));

    address public factory;
    address public token0;
    address public token1;

    /**另一个复杂的问题是，有人有可能将资产发送到配对合同中——从而改变其余额和边际价格——而不会触发预言机更新。
    如果合约只是检查自己的余额并根据当前价格更新预言机，攻击者可以通过在区块中第一次调用资产之前立即向合同发送资产来操作预言机 */
    // 缓存储备量
    uint112 private reserve0; // uses single storage slot, accessible via getReserves
    uint112 private reserve1; // uses single storage slot, accessible via getReserves
    uint32 private blockTimestampLast; // uses single storage slot, accessible via getReserves

    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint256 public kLast; // reserve0 * reserve1, as of immediately after the most recent liquidity event

    uint256 private unlocked = 1;
    /**
        @dev 锁定以防止重入攻击
     */
    modifier lock() {
        require(unlocked == 1, 'UniswapV2: LOCKED');
        unlocked = 0;
        _;
        unlocked = 1;
    }

    function getReserves()
        public
        view
        returns (
            uint112 _reserve0,
            uint112 _reserve1,
            uint32 _blockTimestampLast
        )
    {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function _safeTransfer(
        address token,
        address to,
        uint256 value
    ) private {
        (bool success, bytes memory data) = token.call(abi.encodeWithSelector(SELECTOR, to, value));
        // TODO:
        require(success && (data.length == 0 || abi.decode(data, (bool))), 'UniswapV2: TRANSFER_FAILED');
    }

    event Mint(address indexed sender, uint256 amount0, uint256 amount1);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed to);
    event Swap(
        address indexed sender,
        uint256 amount0In,
        uint256 amount1In,
        uint256 amount0Out,
        uint256 amount1Out,
        address indexed to
    );
    event Sync(uint112 reserve0, uint112 reserve1);

    constructor() public {
        factory = msg.sender;
    }

    // called once by the factory at time of deployment
    function initialize(address _token0, address _token1) external {
        require(msg.sender == factory, 'UniswapV2: FORBIDDEN'); // sufficient check
        token0 = _token0;
        token1 = _token1;
    }

    /**
      * @dev 记录区块时间 更新储备量
        @param balance0 新的储备量0
        @param balance1 新的储备量1
        @param _reserve0 旧的储备量0 用来制造价格预言机
        @param _reserve1 旧的储备量1 用来制造价格预言机
     */
    // update reserves and, on the first call per block, price accumulators
    function _update(
        uint256 balance0,
        uint256 balance1,
        uint112 _reserve0,
        uint112 _reserve1
    ) private {
        // 确保没有溢出
        require(balance0 <= uint112(-1) && balance1 <= uint112(-1), 'UniswapV2: OVERFLOW');
        // blocktime为uint即uint256类型，将 uint256 转为 uint32
        // 32位的时间戳要到02/07/2106才会溢出，足够用了
        uint32 blockTimestamp = uint32(block.timestamp % 2**32);
        // TODO: 这里会发生溢出的原因是，如果有多个请求都在pending中，到底是那个block的请求先完成是不确定的，所以链上blockTimestampLast的更新值不是按照blockTimestamp先来后到(由小到大)的顺序
        uint32 timeElapsed = blockTimestamp - blockTimestampLast; // overflow is desired
        //  但是这里做了timeElapsed > 0 的判断，避免了溢出的问题
        if (timeElapsed > 0 && _reserve0 != 0 && _reserve1 != 0) {
            // * never overflows, and + overflow is desired
            // https://docs.uniswap.org/protocol/V2/concepts/core-concepts/oracles
            // https://github.com/Uniswap/v2-periphery/blob/master/contracts/examples/ExampleOracleSimple.sol 基于UniswapV2构建的24小时TWAP Oracle实现
            price0CumulativeLast += uint256(UQ112x112.encode(_reserve1).uqdiv(_reserve0)) * timeElapsed;
            price1CumulativeLast += uint256(UQ112x112.encode(_reserve0).uqdiv(_reserve1)) * timeElapsed;
        }
        reserve0 = uint112(balance0);
        reserve1 = uint112(balance1);
        blockTimestampLast = blockTimestamp;
        emit Sync(reserve0, reserve1);
    }

    // if fee is on, mint liquidity equivalent to 1/6th of the growth in sqrt(k)
    /**
     * @dev
     * note 如果收取费用，Mint流动性相当于sqrt（k）增长的1/6
     */
    function _mintFee(uint112 _reserve0, uint112 _reserve1) private returns (bool feeOn) {
        // 收税地址
        address feeTo = IUniswapV2Factory(factory).feeTo();
        feeOn = feeTo != address(0);
        uint256 _kLast = kLast; // gas savings
        if (feeOn) {
            if (_kLast != 0) {
                uint256 rootK = Math.sqrt(uint256(_reserve0).mul(_reserve1));
                // 计算K值的平方根
                uint256 rootKLast = Math.sqrt(_kLast);
                if (rootK > rootKLast) {
                    //分子 = LP erc20总量 * (rootK - rootKLast)
                    uint256 numerator = totalSupply.mul(rootK.sub(rootKLast));
                    //分母 = rootK * 5 + rootKLast
                    uint256 denominator = rootK.mul(5).add(rootKLast);
                    //流动性 = 分子 / 分母
                    uint256 liquidity = numerator / denominator;
                    // 如果流动性 > 0 将流动性铸造给feeTo地址
                    // TODO: 这里是铸造了LP token ?
                    if (liquidity > 0) _mint(feeTo, liquidity);
                }
            }
        } else if (_kLast != 0) {
            kLast = 0;
        }
    }

    // this low-level function should be called from a contract which performs important safety checks
    function mint(address to) external lock returns (uint256 liquidity) {
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        // 在更新储备量之前，uniswap的周边合约会先调用 addLiquidity removeLiquidity swap等方法修改pair合约中token0 token1的数量
        uint256 balance0 = IERC20(token0).balanceOf(address(this));
        uint256 balance1 = IERC20(token1).balanceOf(address(this));
        // TODO: 这里不会溢出吗? 如果是移除流动性的情况
        // 获取用户增加的token0数量
        uint256 amount0 = balance0.sub(_reserve0);
        // 获取用户增加的token1数量
        uint256 amount1 = balance1.sub(_reserve1);

        bool feeOn = _mintFee(_reserve0, _reserve1);
        uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        if (_totalSupply == 0) {
            // TODO: 在uniswap v1中，初始流动性份额LP Share设置为存入以太坊(wei)的数量，取决于最初存入流动资金的比率，因为V1都是ETH/token 对,  ...
            // 但是在v2中支持任意的ERC20对, 而且存在路由功能，所以V1那种和ETH挂钩的方式不适用了，我们需要一个计算LP Share的公式保证任何时候流动性份额的价值基本上和最初存入流动性资金的比率无关
            // 需要MINIMUM_LIQUIDITY的原因https://learnblockchain.cn/article/3004
            // 这里的sub是SafeMath， 是有溢出检查的，总之最小的LP Supply要大于等于10**3
            // https://rskswap.com/audit.html#orgc7f8ae1
            liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
            //
            _mint(address(0), MINIMUM_LIQUIDITY); // permanently lock the first MINIMUM_LIQUIDITY tokens
        } else {
            liquidity = Math.min(amount0.mul(_totalSupply) / _reserve0, amount1.mul(_totalSupply) / _reserve1);
        }
        require(liquidity > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_MINTED');
        _mint(to, liquidity);

        // 记录区块时间 更新储备量
        _update(balance0, balance1, _reserve0, _reserve1);
        // 存入流动性时收取费用, 需要更新K值
        if (feeOn) kLast = uint256(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Mint(msg.sender, amount0, amount1);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function burn(address to) external lock returns (uint256 amount0, uint256 amount1) {
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        uint256 balance0 = IERC20(_token0).balanceOf(address(this));
        uint256 balance1 = IERC20(_token1).balanceOf(address(this));
        // 获取当前pair合约的LP token
        uint256 liquidity = balanceOf[address(this)];

        bool feeOn = _mintFee(_reserve0, _reserve1);
        // LP 总量
        uint256 _totalSupply = totalSupply; // gas savings, must be defined here since totalSupply can update in _mintFee
        amount0 = liquidity.mul(balance0) / _totalSupply; // using balances ensures pro-rata distribution
        amount1 = liquidity.mul(balance1) / _totalSupply; // using balances ensures pro-rata distribution
        require(amount0 > 0 && amount1 > 0, 'UniswapV2: INSUFFICIENT_LIQUIDITY_BURNED');
        _burn(address(this), liquidity);
        _safeTransfer(_token0, to, amount0);
        _safeTransfer(_token1, to, amount1);
        balance0 = IERC20(_token0).balanceOf(address(this));
        balance1 = IERC20(_token1).balanceOf(address(this));
        // 更新储备量
        _update(balance0, balance1, _reserve0, _reserve1);
        // 撤销流动性时收取费用，需要更新K值
        if (feeOn) kLast = uint256(reserve0).mul(reserve1); // reserve0 and reserve1 are up-to-date
        emit Burn(msg.sender, amount0, amount1, to);
    }

    // this low-level function should be called from a contract which performs important safety checks
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external lock {
        require(amount0Out > 0 || amount1Out > 0, 'UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT');
        (uint112 _reserve0, uint112 _reserve1, ) = getReserves(); // gas savings
        require(amount0Out < _reserve0 && amount1Out < _reserve1, 'UniswapV2: INSUFFICIENT_LIQUIDITY');

        uint256 balance0;
        uint256 balance1;
        {
            // scope for _token{0,1}, avoids stack too deep errors
            address _token0 = token0;
            address _token1 = token1;
            require(to != _token0 && to != _token1, 'UniswapV2: INVALID_TO');
            if (amount0Out > 0) _safeTransfer(_token0, to, amount0Out); // optimistically transfer tokens
            if (amount1Out > 0) _safeTransfer(_token1, to, amount1Out); // optimistically transfer tokens
            // 对使用data参数。具体来说，如果data.length等于 0，则合约假设已经收到付款，并简单地将代币转移到该to地址。
            // 但是，如果data.length大于 0，说明to地址是个合约地址，然后在to地址上调用以下函数实行闪兑
            // TODO:
            if (data.length > 0) IUniswapV2Callee(to).uniswapV2Call(msg.sender, amount0Out, amount1Out, data);
            balance0 = IERC20(_token0).balanceOf(address(this));
            balance1 = IERC20(_token1).balanceOf(address(this));
        }
        // 取出的amount0和amount1有一个为0

        uint256 amount0In = balance0 > _reserve0 - amount0Out ? balance0 - (_reserve0 - amount0Out) : 0;
        uint256 amount1In = balance1 > _reserve1 - amount1Out ? balance1 - (_reserve1 - amount1Out) : 0;
        require(amount0In > 0 || amount1In > 0, 'UniswapV2: INSUFFICIENT_INPUT_AMOUNT');
        {
            // scope for reserve{0,1}Adjusted, avoids stack too deep errors
            uint256 balance0Adjusted = balance0.mul(1000).sub(amount0In.mul(3));
            uint256 balance1Adjusted = balance1.mul(1000).sub(amount1In.mul(3));
            // 确认路由合约收过税
            require(
                balance0Adjusted.mul(balance1Adjusted) >= uint256(_reserve0).mul(_reserve1).mul(1000**2),
                'UniswapV2: K'
            );
        }

        _update(balance0, balance1, _reserve0, _reserve1);
        emit Swap(msg.sender, amount0In, amount1In, amount0Out, amount1Out, to);
    }

    /**
        @dev 通过发送一部分token到to地址来平衡余额和储备量
        此接口可以吸引套利机器人来搬砖获取差价利润, 并且因为有利可图，实际上利用了外部用户主动帮助了合约对的平衡，总不能自己每次手动sync()
        大部分情况下利润微薄
     */
    // force balances to match reserves
    function skim(address to) external lock {
        address _token0 = token0; // gas savings
        address _token1 = token1; // gas savings
        _safeTransfer(_token0, to, IERC20(_token0).balanceOf(address(this)).sub(reserve0));
        _safeTransfer(_token1, to, IERC20(_token1).balanceOf(address(this)).sub(reserve1));
    }

    /**
        @dev 在不触发mint() burn() swap()的情况下强制平衡余额和储备量
        TODO: 什么情况下需要, 直接发送token到pair而不mint会破坏平衡
        https://learnblockchain.cn/article/3004 中提到了垄断交易对攻击
     */
    // force reserves to match balances
    function sync() external lock {
        _update(IERC20(token0).balanceOf(address(this)), IERC20(token1).balanceOf(address(this)), reserve0, reserve1);
    }
}
