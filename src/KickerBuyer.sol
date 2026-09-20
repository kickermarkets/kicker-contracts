// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20, IPonsFactory, IPoolManager, IUnlockCallback, PoolKey, SwapParams} from "./Interfaces.sol";

interface IKeeperSource { function keeper() external view returns (address); }

/// The platform's share, turned into a burn of the platform coin.
/// Set as the `platform` address of every KickerFactory: the 0.5% of each buy and the 10% of each collect with terms land here
/// instead of a wallet. The keeper converts whatever arrived (ETH, NVDA, GLD) into GLD off-chain and calls burn(): the whole GLD
/// balance buys $KICKER in its pons pool and goes to the dead address. Nothing here can be withdrawn by anyone: the only exit for
/// value is the burn. The keeper (read from the factory, so it rotates with setKeeper) chooses when; minimum outputs guard both
/// the conversion and the burn. convert() can only call the aggregator router fixed at deploy.
interface IBurnable { function burn(uint256) external; function totalSupply() external view returns (uint256); }

contract KickerBuyer is IUnlockCallback {
    IPoolManager public constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    IPonsFactory public constant PONS = IPonsFactory(0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e);
    address public constant HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    uint160 internal constant MIN_SQRT = 4295128739;
    uint160 internal constant MAX_SQRT = 1461446703485210103287273052203988822378723970342;

    address public immutable gld;       // the quote the burn spends
    address public immutable kicker;    // the coin that burns
    address public immutable factory;   // whose keeper() may burn and convert (setKeeper on the factory rotates it)
    address public immutable router;    // the only address convert() may call: the KyberSwap aggregator on this chain
    uint256 public burnedTotal;         // KICKER sent to dead by this contract
    uint256 public spentTotal;          // GLD spent on it

    event Burned(address indexed caller, uint256 gldIn, uint256 kickerBurned);
    event Received(address indexed token, uint256 amount);
    event Converted(address indexed asset, uint256 gldOut);

    constructor(address gld_, address kicker_, address factory_, address router_) {
        require(PONS.getLaunchedToken(kicker_).pairToken == gld_, "pair");
        gld = gld_; kicker = kicker_; factory = factory_; router = router_;
    }
    function keeper() public view returns (address) { return IKeeperSource(factory).keeper(); }
    modifier onlyKeeper() { require(msg.sender == keeper(), "keeper only"); _; }

    /// keeper only: turn a non-GLD asset that arrived here (ETH or NVDA from the other floors) into GLD on this contract through
    /// the aggregator. The calldata is built off-chain (recipient must be this contract); the GLD delta is checked here.
    function convert(address asset, bytes calldata data, uint256 minGldOut) external onlyKeeper returns (uint256 gldOut) {
        require(asset != gld && asset != kicker && minGldOut > 0, "asset");
        uint256 g0 = IERC20(gld).balanceOf(address(this));
        if (asset == address(0)) { (bool ok,) = router.call{value: address(this).balance}(data); require(ok, "router"); }
        else { require(IERC20(asset).approve(router, IERC20(asset).balanceOf(address(this))), "approve"); (bool ok,) = router.call(data); require(ok, "router"); }
        gldOut = IERC20(gld).balanceOf(address(this)) - g0;
        require(gldOut >= minGldOut, "slippage");
        emit Converted(asset, gldOut);
    }

    receive() external payable { emit Received(address(0), msg.value); }

    /// keeper only: every GLD on the balance buys KICKER in the pons pool and burns it. minKickerOut is the sandwich guard.
    function burn(uint256 minKickerOut) external onlyKeeper returns (uint256 gldIn, uint256 burned) {
        gldIn = IERC20(gld).balanceOf(address(this));
        require(gldIn > 0, "nothing to burn");
        IPonsFactory.LaunchedToken memory L = PONS.getLaunchedToken(kicker);
        require(L.phase != 3, "dead");
        burned = abi.decode(PM.unlock(abi.encode(L.tickSpacing, L.poolFee, gldIn)), (uint256));
        require(burned >= minKickerOut && burned > 0, "slippage");
        burned = IERC20(kicker).balanceOf(address(this));   // KICKER sent here directly burns with it
        // v2: out of the supply (every pons token is ERC20Burnable); a burn that does not take falls back to the dead address so GLD never sticks here
        (bool ok,) = kicker.call(abi.encodeWithSelector(0x42966c68, burned)); if (!ok || IERC20(kicker).balanceOf(address(this)) != 0) require(IERC20(kicker).transfer(0x000000000000000000000000000000000000dEaD, IERC20(kicker).balanceOf(address(this))), "transfer");
        burnedTotal += burned; spentTotal += gldIn;
        emit Burned(msg.sender, gldIn, burned);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(PM), "pm");
        (int24 ts, uint24 fee, uint256 amountIn) = abi.decode(data, (int24, uint24, uint256));
        (address c0, address c1) = gld < kicker ? (gld, kicker) : (kicker, gld);
        bool zeroForOne = gld == c0;
        int256 delta = PM.swap(PoolKey(c0, c1, fee, ts, HOOK), SwapParams(zeroForOne, -int256(amountIn), zeroForOne ? MIN_SQRT + 1 : MAX_SQRT - 1), "");
        int256 a0 = delta >> 128;
        int256 a1 = int256(int128(int256(delta)));
        (int256 dIn, int256 dOut) = zeroForOne ? (a0, a1) : (a1, a0);
        require(dOut > 0, "out");
        PM.sync(gld); require(IERC20(gld).transfer(address(PM), uint256(-dIn)), "settle"); PM.settle();
        PM.take(kicker, address(this), uint256(dOut));
        return abi.encode(uint256(dOut));
    }
}
