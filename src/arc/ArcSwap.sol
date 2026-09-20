// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
/// One-off: buy a hooked v4 token on Arc with USDC (0x3600 ERC-20 view) through the PoolManager. Test tool, not product.
import {IERC20, IPoolManager, IUnlockCallback, PoolKey, SwapParams} from "../Interfaces.sol";
contract ArcSwap is IUnlockCallback {
    IPoolManager public constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IERC20 public constant USDC = IERC20(0x3600000000000000000000000000000000000000);
    uint160 internal constant MIN_SQRT = 4295128739;
    uint160 internal constant MAX_SQRT = 1461446703485210103287273052203988822378723970342;
    receive() external payable {}
    function buy(address token, address hook, uint256 usdcIn, uint256 minOut) external returns (uint256 out) {
        USDC.transferFrom(msg.sender, address(this), usdcIn);
        out = abi.decode(PM.unlock(abi.encode(token, hook, usdcIn, msg.sender, true)), (uint256));
        require(out >= minOut, "slip");
    }
    /// sell tokens for USDC; the caller approves this contract for the tokens first
    function sell(address token, address hook, uint256 tokensIn, uint256 minOut) external returns (uint256 out) {
        IERC20(token).transferFrom(msg.sender, address(this), tokensIn);
        out = abi.decode(PM.unlock(abi.encode(token, hook, tokensIn, msg.sender, false)), (uint256));
        require(out >= minOut, "slip");
    }
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(PM), "pm");
        (address token, address hook, uint256 amountIn, address to, bool isBuy) = abi.decode(data, (address, address, uint256, address, bool));
        address u = address(USDC);
        (address c0, address c1) = u < token ? (u, token) : (token, u);
        address tokenIn = isBuy ? u : token; address tokenOut = isBuy ? token : u;
        bool zeroForOne = tokenIn == c0;
        int256 delta = PM.swap(PoolKey(c0, c1, 10000, 200, hook), SwapParams(zeroForOne, -int256(amountIn), zeroForOne ? MIN_SQRT + 1 : MAX_SQRT - 1), "");
        int256 a0 = delta >> 128; int256 a1 = int256(int128(int256(delta)));
        (int256 dIn, int256 dOut) = zeroForOne ? (a0, a1) : (a1, a0);
        PM.sync(tokenIn); IERC20(tokenIn).transfer(address(PM), uint256(-dIn)); PM.settle();
        PM.take(tokenOut, to, uint256(dOut));
        if (uint256(-dIn) < amountIn) IERC20(tokenIn).transfer(to, amountIn - uint256(-dIn));
        return abi.encode(uint256(dOut));
    }
}
