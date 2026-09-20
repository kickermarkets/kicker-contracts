// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "../Interfaces.sol";

/// Argus Portal #7 on Arc: the launchpad this pot launches through. The pot is the creator of every token it launches,
/// so the creator share of their tax is credited to the pot on each token's splitter and pulled by collect().
interface IArgusPortal {
    struct Params { string name; string symbol; uint256 totalSupply; uint256 startFdvUsdc6; uint256 bondFdvUsdc6; uint16 buyTaxBps; uint16 sellTaxBps; uint16 creatorBps; uint16 burnBps; uint16 dividendBps; uint16 liquidityBps; uint256 devBuyQuote; address quoteAsset; uint8 expectConvert; }
    struct Meta { string imageURI; string website; string twitter; string telegram; string description; }
    function launch(Params calldata p, Meta calldata meta, bytes32 salt, bytes32 hookSalt) external returns (address token);
    function launches(address token) external view returns (address creator, int24 tickStart, bool tokenIsToken0, address locker, address hook, address splitter, uint16 buyTaxBps, uint16 sellTaxBps, uint256 positionId, int24 tickBond, address quoteAsset);
    function predictHook(address creator, bytes32 salt, bytes32 hookSalt, uint16 buyTaxBps, uint16 sellTaxBps, address quote) external view returns (address hook, uint160 mask, bool valid);
}
interface IArgusSplitter { function distribute() external; function claim(address account) external; function claimableQuote6(address) external view returns (uint256); }
interface IArcPotFactory { function platform() external view returns (address); }

/// A floor pot on Arc: a vault with erc-20 shares (K) whose floor is USDC. Anyone may launch a token on Argus through the
/// pot; the pot is the token's creator, so the creator share of its trading tax accrues to the pot and collect() moves it
/// onto the floor. USDC leaves the pot only by redeem, so floor nav per K only goes up. No legs, no clips, no admin.
/// The pool line of the Robinhood pots without the curve and without the sleeve. v0.2: launch open to anyone, the name
/// suffix in the contract, at most MAX_LAUNCHES tokens per pot and a launch fee that stays on the floor (a full pot is retired,
/// the next one comes from the factory); buy/redeem crank every launched token, so pending tax is never skimmable.
contract ArcPot {
    // ---- erc20 ----
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ---- pot ----
    IArgusPortal public constant PORTAL = IArgusPortal(0xB021Be536808f551b31789422Fd28a6c9c6e97Da);
    IERC20 public constant USDC = IERC20(0x3600000000000000000000000000000000000000);   // erc-20 view of the gas token, 6 decimals
    uint256 public constant CREATOR_BPS = 100;    // 1% of a buy to the pot builder
    uint256 public constant REF_BPS = 50;         // 0.5% to the referrer (no referrer: to the builder)
    uint256 public constant PLATFORM_BPS = 50;    // 0.5% to the platform
    uint256 public constant DEAD_SHARES = 1e6;    // burned on the first mint so supply never returns to zero
    uint256 public constant MIN_FIRST = 1e5;      // 0.1 USDC minimum first deposit
    uint16 public constant MAX_TAX_BPS = 1000;    // Argus: 1-10% per side
    uint256 public constant MAX_LAUNCHES = 16;    // bounded so buy/redeem can crank every launch (16 x 750k gas worst case, Arc block 30M)
    uint256 public constant LAUNCH_FEE = 1e6;     // 1 USDC per launch, stays on the floor: filling a pot with junk pays its holders
    uint256 public constant CRANK_GAS = 600_000;  // gas handed to a splitter's distribute(); a splitter that burns gas cannot burn the caller's
    uint256 public constant CLAIM_GAS = 150_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public factory;
    address public creator;
    address[] public launched;
    mapping(address => bool) public isLaunched;
    bool private _locked;

    event Buy(address indexed buyer, address indexed ref, uint256 usdcIn, uint256 shares);
    event Redeem(address indexed owner, uint256 shares, uint256 usdcOut);
    event Collect(address indexed caller, uint256 usdcIn);
    event Launched(address indexed token, address indexed by, string name, uint16 buyTaxBps, uint16 sellTaxBps, uint256 devBuy);
    event Fees(address indexed creator, address indexed ref, address indexed platform, uint256 c, uint256 r, uint256 p);

    modifier lock() { require(!_locked, "locked"); _locked = true; _; _locked = false; }

    constructor() { factory = address(this); }   // the implementation itself can never be initialized

    function initialize(address creator_, string calldata name_, string calldata symbol_) external {
        require(factory == address(0), "init");
        factory = msg.sender; creator = creator_; name = name_; symbol = symbol_;
    }

    receive() external payable {}   // native USDC and the erc-20 view are one balance on Arc; both paths land here

    function floor() public view returns (uint256) { return USDC.balanceOf(address(this)); }
    function launchedCount() external view returns (uint256) { return launched.length; }

    // ---- buy: mint shares at the current floor per share ----
    function buy(uint256 usdcIn, address ref, uint256 minShares) external lock returns (uint256 shares) {
        require(usdcIn > 0, "zero");
        if (ref == msg.sender || ref == creator || ref == address(this)) ref = address(0);
        _collect(0, launched.length);   // pending tax accrues to the holders who were in before this buy, not to the new shares
        uint256 before = floor();
        _pull(msg.sender, usdcIn);
        uint256 c = usdcIn * CREATOR_BPS / 1e4; uint256 r = usdcIn * REF_BPS / 1e4; uint256 p = usdcIn * PLATFORM_BPS / 1e4;
        if (ref == address(0)) { c += r; r = 0; }
        uint256 net = usdcIn - c - r - p;
        if (totalSupply == 0) {
            require(net >= MIN_FIRST, "dust");
            _mint(DEAD, DEAD_SHARES); shares = net * 1e12 - DEAD_SHARES;   // shares are 18-decimal, the floor is 6-decimal
        } else {
            require(before > 0, "empty");
            shares = totalSupply * net / before;
        }
        require(shares >= minShares && shares > 0, "slippage");
        _mint(msg.sender, shares);
        address platform = IArcPotFactory(factory).platform();
        _push(creator, c); if (r > 0) _push(ref, r); _push(platform, p);
        emit Fees(creator, ref, platform, c, r, p);
        emit Buy(msg.sender, ref, usdcIn, shares);
    }

    // ---- redeem: the pro-rata floor, always ----
    function redeem(uint256 shares, uint256 minUsdcOut) external lock returns (uint256 usdcOut) { return _redeem(shares, minUsdcOut, true); }
    /// the same without the argus crank: if a splitter ever breaks the crank, the exit still works (the leaver forgoes what is pending)
    function redeemNoCollect(uint256 shares, uint256 minUsdcOut) external lock returns (uint256 usdcOut) { return _redeem(shares, minUsdcOut, false); }

    function _redeem(uint256 shares, uint256 minUsdcOut, bool crank) internal returns (uint256 usdcOut) {
        require(shares > 0 && balanceOf[msg.sender] >= shares, "shares");
        if (crank) _collect(0, launched.length);   // the leaver takes its share of what is pending too
        usdcOut = floor() * shares / totalSupply;
        _burn(msg.sender, shares);
        require(usdcOut >= minUsdcOut, "slippage");
        _push(msg.sender, usdcOut);
        emit Redeem(msg.sender, shares, usdcOut);
    }

    // ---- launch a token on Argus with the pot as its creator ----
    /// anyone may launch: a pot is a public launchpad, the tax of every token launched from it goes to the pot's holders (v0.2, as
    /// on the Robinhood pots). The caller pays LAUNCH_FEE plus the dev buy (approve USDC to the pot first); the tokens go to the
    /// caller, the fee stays on the floor. The name gets the suffix " by kicker". creatorBps is forced to 10000: the whole creator
    /// allocation of the tax goes to this pot. A pot holds at most MAX_LAUNCHES tokens; a full pot keeps collecting but launches no more.
    /// hookSalt is mined by the caller so the hook address carries the flags Argus requires (predictHook says if it is valid).
    function launch(IArgusPortal.Params memory p, IArgusPortal.Meta calldata meta, bytes32 salt, bytes32 hookSalt) external lock returns (address token) {
        require(launched.length < MAX_LAUNCHES, "full");
        require(bytes(p.name).length > 0 && bytes(p.name).length <= 24, "name");
        p.name = string.concat(p.name, " by kicker");
        require(p.buyTaxBps <= MAX_TAX_BPS && p.sellTaxBps <= MAX_TAX_BPS && (p.buyTaxBps > 0 || p.sellTaxBps > 0), "tax");
        p.creatorBps = 10000; p.burnBps = 0; p.dividendBps = 0; p.liquidityBps = 0;
        p.quoteAsset = address(USDC); p.expectConvert = 1;
        _pull(msg.sender, LAUNCH_FEE + p.devBuyQuote);
        if (p.devBuyQuote > 0) USDC.approve(address(PORTAL), p.devBuyQuote);
        uint256 f0 = floor() - p.devBuyQuote;   // the fee is already counted in: only the unspent part of the dev buy is refunded
        token = PORTAL.launch(p, meta, salt, hookSalt);
        if (p.devBuyQuote > 0) USDC.approve(address(PORTAL), 0);
        launched.push(token); isLaunched[token] = true;
        // the dev buy lands on the pot (it is the creator): hand the tokens and any unspent quote to the caller
        uint256 got = IERC20(token).balanceOf(address(this)); if (got > 0) _pushToken(token, msg.sender, got);
        uint256 f1 = floor(); if (f1 > f0) _push(msg.sender, f1 - f0);
        emit Launched(token, msg.sender, p.name, p.buyTaxBps, p.sellTaxBps, p.devBuyQuote);
    }

    // ---- collect: pull the creator share of every launched token onto the floor ----
    /// anyone. distribute() cranks the splitter (sells collected tokens for USDC and credits the shares), claim() pays the pot.
    function collect() external lock returns (uint256 usdcIn) { return _collect(0, launched.length); }
    function collectRange(uint256 from, uint256 to) external lock returns (uint256 usdcIn) { return _collect(from, to); }

    function _collect(uint256 from, uint256 to) internal returns (uint256 usdcIn) {
        if (to > launched.length) to = launched.length;
        uint256 before = floor();
        for (uint256 i = from; i < to; i++) {
            (,,,,, address splitter,,,,,) = PORTAL.launches(launched[i]);
            if (splitter == address(0)) continue;
            // low-level calls with a gas cap: a splitter that reverts or burns its gas is skipped and cannot take the caller's gas with it
            (bool ok,) = splitter.call{gas: CRANK_GAS}(abi.encodeWithSelector(IArgusSplitter.distribute.selector)); ok;
            (ok,) = splitter.call{gas: CLAIM_GAS}(abi.encodeWithSelector(IArgusSplitter.claim.selector, address(this))); ok;
        }
        usdcIn = floor() - before;
        if (usdcIn > 0 || from < to) emit Collect(msg.sender, usdcIn);
    }

    /// stray tokens (airdrops, mistakes) go to the builder; USDC and the pot's own launched tokens never leave this way
    function skim(address t) external { require(t != address(USDC) && !isLaunched[t], "usdc"); _pushToken(t, creator, IERC20(t).balanceOf(address(this))); }

    /// what collect() would bring now, before the crank (the crank can add the tokens the splitter still holds)
    function collectable() external view returns (uint256 total) {
        for (uint256 i; i < launched.length; i++) { (,,,,, address s,,,,,) = PORTAL.launches(launched[i]); if (s != address(0)) total += IArgusSplitter(s).claimableQuote6(address(this)); }
    }

    // ---- helpers: USDC moves through the erc-20 view; a failed transfer reverts the whole action ----
    function _push(address to, uint256 amt) internal { if (amt == 0) return; require(USDC.transfer(to, amt), "transfer"); }
    function _pull(address from, uint256 amt) internal { require(USDC.transferFrom(from, address(this), amt), "transferFrom"); }
    function _pushToken(address t, address to, uint256 amt) internal { (bool s, bytes memory d) = t.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amt)); require(s && (d.length == 0 || abi.decode(d, (bool))), "token"); }

    // ---- erc20 ----
    function transfer(address to, uint256 v) external returns (bool) { _move(msg.sender, to, v); return true; }
    function approve(address sp, uint256 v) external returns (bool) { allowance[msg.sender][sp] = v; emit Approval(msg.sender, sp, v); return true; }
    function transferFrom(address f, address to, uint256 v) external returns (bool) {
        uint256 a = allowance[f][msg.sender]; if (a != type(uint256).max) allowance[f][msg.sender] = a - v;
        _move(f, to, v); return true;
    }
    function _move(address f, address to, uint256 v) internal { balanceOf[f] -= v; balanceOf[to] += v; emit Transfer(f, to, v); }
    function _mint(address to, uint256 v) internal { totalSupply += v; balanceOf[to] += v; emit Transfer(address(0), to, v); }
    function _burn(address f, uint256 v) internal { balanceOf[f] -= v; totalSupply -= v; emit Transfer(f, address(0), v); }
}

/// Factory of Arc pots: minimal-proxy clones, a registry, the platform address for the 0.5%.
contract ArcPotFactory {
    string public constant VERSION = "arc-0.2.1";
    address public immutable impl;
    address public owner;
    address public platform;
    address[] public all;
    mapping(address => bool) public isPot;
    event Created(address indexed pot, address indexed creator, string symbol);

    constructor(address platform_) { impl = address(new ArcPot()); owner = msg.sender; platform = platform_; }
    function count() external view returns (uint256) { return all.length; }

    function create(string calldata name, string calldata symbol) external returns (address k) {
        bytes20 target = bytes20(impl);
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), target)
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            k := create(0, ptr, 0x37)
        }
        require(k != address(0), "clone");
        ArcPot(payable(k)).initialize(msg.sender, name, symbol);
        all.push(k); isPot[k] = true;
        emit Created(k, msg.sender, symbol);
    }

    function setPlatform(address p) external { require(msg.sender == owner && p != address(0), "owner"); platform = p; }
    function setOwner(address o) external { require(msg.sender == owner, "owner"); owner = o; }
}
