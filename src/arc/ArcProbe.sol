// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// Probe for Arc (chain 5042): can a contract be the creator of an Argus launch and claim the creator share?
/// One-off test contract, not part of the kicker product. Owner-only launch and withdraw; claim is open.
interface IERC20 { function balanceOf(address) external view returns (uint256); function transfer(address, uint256) external returns (bool); function transferFrom(address, address, uint256) external returns (bool); function approve(address, uint256) external returns (bool); }

interface IArgusPortal {
    struct Params { string name; string symbol; uint256 totalSupply; uint256 startFdvUsdc6; uint256 bondFdvUsdc6; uint16 buyTaxBps; uint16 sellTaxBps; uint16 creatorBps; uint16 burnBps; uint16 dividendBps; uint16 liquidityBps; uint256 devBuyQuote; address quoteAsset; uint8 expectConvert; }
    struct Meta { string imageURI; string website; string twitter; string telegram; string description; }
    function launch(Params calldata p, Meta calldata meta, bytes32 salt, bytes32 hookSalt) external returns (address token);
    function launches(address token) external view returns (address creator, int24 tickStart, bool tokenIsToken0, address locker, address hook, address splitter, uint16 buyTaxBps, uint16 sellTaxBps, uint256 positionId, int24 tickBond, address quoteAsset);
}

interface IArgusSplitter { function claim(address account) external; function claimableQuote6(address) external view returns (uint256); }

contract ArcProbe {
    IArgusPortal public constant PORTAL = IArgusPortal(0xB021Be536808f551b31789422Fd28a6c9c6e97Da);
    IERC20 public constant USDC = IERC20(0x3600000000000000000000000000000000000000);
    address public owner;
    address[] public tokens;
    event Launched(address indexed token);
    event Claimed(address indexed token, address indexed splitter, uint256 usdcIn);

    constructor() { owner = msg.sender; }
    receive() external payable {}

    /// the probe is the creator; the dev buy is pulled from the owner and forwarded through the portal's transferFrom
    function launch(IArgusPortal.Params calldata p, IArgusPortal.Meta calldata meta, bytes32 salt, bytes32 hookSalt) external returns (address token) {
        require(msg.sender == owner, "owner");
        if (p.devBuyQuote > 0) { USDC.transferFrom(msg.sender, address(this), p.devBuyQuote); USDC.approve(address(PORTAL), p.devBuyQuote); }
        token = PORTAL.launch(p, meta, salt, hookSalt);
        tokens.push(token);
        emit Launched(token);
    }

    /// anyone: pull the creator share for a token launched by this probe into the probe (the "floor")
    function claim(address token) external returns (uint256 usdcIn) {
        (,,,,, address splitter,,,,,) = PORTAL.launches(token);
        uint256 before = USDC.balanceOf(address(this)) + address(this).balance;
        IArgusSplitter(splitter).claim(address(this));
        usdcIn = USDC.balanceOf(address(this)) + address(this).balance - before;
        emit Claimed(token, splitter, usdcIn);
    }

    function splitterOf(address token) external view returns (address s) { (,,,,, s,,,,,) = PORTAL.launches(token); }

    function withdraw(address t) external {
        require(msg.sender == owner, "owner");
        if (t == address(0)) { (bool ok,) = owner.call{value: address(this).balance}(""); require(ok); }
        else IERC20(t).transfer(owner, IERC20(t).balanceOf(address(this)));
    }
}
