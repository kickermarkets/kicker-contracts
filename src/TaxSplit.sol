// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20, IPonsEscrow, IPonsHook} from "./Interfaces.sol";

interface ISplitPot { function core() external view returns (address); function factory() external view returns (address); }
interface ISplitFactory { function platform() external view returns (address); }
interface ISweepable { function sweepFees(uint256 minBuybackTokensOut) external; }

/// v0.5 launcher terms. One clone per token launched from a pot with terms; it is the token's creator fee recipient
/// on pons. Every collect splits what the escrow paid out: creatorBps to the launcher, PLATFORM_BPS to the platform,
/// burnBps held here until the pot buys the token back and burns it, the rest to the pot floor.
/// Terms are fixed at launch and cannot be changed by the pot, its builder, the keeper or the factory owner (the factory owner
/// can only repoint the platform address that receives the 10%). The launcher's share is pulled, never pushed, so no
/// launcher code runs inside the pot's collect; the only outside parties called are pons and the platform address.
contract TaxSplit {
    IPonsEscrow public constant ESCROW = IPonsEscrow(0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e);
    uint16 public constant PLATFORM_BPS = 1000;   // 10% of the tax to the platform address of the pot's factory

    address public pot;
    address public launcher;
    uint16 public creatorBps;
    uint16 public burnBps;
    uint256 public burnHeld;      // core units held for the buyback; released only to the pot's burn()
    uint64 public burnSince;      // the last time the buyback budget grew: BURN_GRACE after that anyone may burn (the keeper never burned it)
    uint256 public launcherOwed;  // accrued for the launcher; claimed with withdraw()

    event Split(uint256 total, uint256 toLauncher, uint256 toPlatform, uint256 toBurn, uint256 toPot);
    event Withdraw(address indexed to, uint256 amount);

    constructor() { pot = address(this); }   // the implementation itself can never be initialized; clones start from zero storage

    function initialize(address pot_, address launcher_, uint16 creatorBps_, uint16 burnBps_) external {
        require(pot == address(0), "init");
        pot = pot_; launcher = launcher_; creatorBps = creatorBps_; burnBps = burnBps_;
    }

    receive() external payable {}

    modifier onlyPot() { require(msg.sender == pot, "pot only"); _; }

    /// Sweep a curve on behalf of this recipient (pons lets the creator side sweep when no internal swap is needed).
    function sweep(address curve) external onlyPot { ISweepable(curve).sweepFees(0); }

    /// Sweep the token's pool fees on the hook on behalf of this recipient (after graduation).
    function sweepPool(address hook, bytes32 poolId, uint256 minConversionQuoteOut, uint256 minBuybackTokensOut) external onlyPot { IPonsHook(hook).sweepPoolFees(poolId, minConversionQuoteOut, minBuybackTokensOut); }

    /// Claim from the escrow and split everything that arrived since the last call. Returns what went to the pot.
    function collect() external onlyPot returns (uint256 toPot) {
        address core = ISplitPot(pot).core();
        if (core == address(0)) { try ESCROW.claim() {} catch {} } else { try ESCROW.claimToken(core) {} catch {} }
        uint256 fresh = _bal(core) - burnHeld - launcherOwed;
        if (fresh == 0) return 0;
        uint256 c = fresh * creatorBps / 1e4;
        uint256 p = fresh * PLATFORM_BPS / 1e4;
        uint256 b = fresh * burnBps / 1e4;
        toPot = fresh - c - p - b;
        if (b > 0) burnSince = uint64(block.timestamp);
        burnHeld += b; launcherOwed += c;
        // a platform address that cannot take the transfer forfeits its slice to the floor rather than freezing every collect
        if (p > 0 && !_send(core, ISplitFactory(ISplitPot(pot).factory()).platform(), p)) { toPot += p; p = 0; }
        _push(core, pot, toPot);
        emit Split(fresh, c, p, b, toPot);
    }

    /// The launcher takes what has accrued, to any address it names.
    function withdraw(address to) external returns (uint256 amt) {
        require(msg.sender == launcher && to != address(0), "launcher only");
        amt = launcherOwed; launcherOwed = 0;
        _push(ISplitPot(pot).core(), to, amt);
        emit Withdraw(to, amt);
    }

    /// Hand the held buyback budget to the pot, which buys the token and burns it in the same transaction.
    function release() external onlyPot returns (uint256 amt) {
        amt = burnHeld; burnHeld = 0;
        _push(ISplitPot(pot).core(), pot, amt);
    }

    /// The part of a released budget the market could not take (a clamped curve buy) comes back and waits for the next burn.
    function rehold(uint256 amt) external onlyPot { if (amt > 0) burnSince = uint64(block.timestamp); burnHeld += amt; }

    /// the launcher may hand its role to another address (a lost key would otherwise strand the share forever)
    function setLauncher(address to) external { require(msg.sender == launcher && to != address(0), "launcher only"); launcher = to; }

    function _bal(address t) internal view returns (uint256) { return t == address(0) ? address(this).balance : IERC20(t).balanceOf(address(this)); }

    function _send(address t, address to, uint256 amt) internal returns (bool) {
        if (t == address(0)) { (bool ok,) = to.call{value: amt}(""); return ok; }
        (bool s, bytes memory d) = t.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amt));
        return s && (d.length == 0 || abi.decode(d, (bool)));
    }

    function _push(address t, address to, uint256 amt) internal { if (amt == 0) return; require(_send(t, to, amt), "transfer"); }
}
