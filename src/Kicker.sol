// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20, IERC20Meta, IPonsCurve, IPonsFactory, IPonsEscrow, IPonsHook, IPoolManager, IUnlockCallback, PoolKey, SwapParams} from "./Interfaces.sol";
import {TaxSplit} from "./TaxSplit.sol";

interface IKickerFactory { function platform() external view returns (address); function keeper() external view returns (address); function knownKicker(address) external view returns (bool); function splitImpl() external view returns (address); }

/// A pot: a floor in the pair asset of pons (ETH or a tokenized stock) plus a sleeve of tokens from the same pair,
/// capped as a share of every deposit. buy() splits a deposit by the live composition and mints shares by min-ratio;
/// a leg has three modes: hold (stays), grad (clip() sells it into the floor on graduation), timer (on graduation or
/// by timer); redeem() pays out in kind or into the floor; collect() pulls the creator tax of tokens launched from this
/// pot out of the pons escrow into the floor. The floor never buys the sleeve; a clipped leg is never bought again.
/// v0.3.2: buys revert while a graduated leg has no pool yet (the leg would otherwise be valued at zero and given away);
/// dead shares on the first mint; clip is keeper-only (a timer leg: anyone one day after its deadline) because a public
/// clip with a caller-supplied minCoreOut was sandwichable in one transaction; redeem into the floor hands an unsellable
/// leg out in kind; fees are charged on what was actually invested, not on the refunded part.
/// v0.4: taxToLegs mode - collected tax is split by composition like a buy, kickBps of it buys the legs.
/// v0.5: launcher terms - a token launched with creatorBps/burnBps gets its own TaxSplit as fee recipient: part of
/// its tax to the launcher, part buys the token back and burns it, the rest to the floor.
contract Kicker is IUnlockCallback {
    // ---- erc20 ----
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // ---- kicker ----
    struct Leg { address token; address curve; int24 tickSpacing; uint16 weightBps; uint8 mode; uint64 boughtAt; bool clipped; }
    uint8 public constant MODE_HOLD = 0;    // stays forever
    uint8 public constant MODE_GRAD = 1;    // clip only on graduation
    uint8 public constant MODE_TIMER = 2;   // clip on graduation or by timer
    uint16 public constant MAX_KICK = 5000; // at most half of a deposit goes to the sleeve
    IPonsFactory public constant PONS = IPonsFactory(0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e);
    IPoolManager public constant PM = IPoolManager(0x8366a39CC670B4001A1121B8F6A443A643e40951);
    address public constant HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    IPonsEscrow public constant ESCROW = IPonsEscrow(0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e);
    uint256 public constant CREATOR_BPS = 100;   // 1% of a buy to the pot builder
    uint256 public constant REF_BPS = 50;        // 0.5% to the referrer (no referrer: to the builder)
    uint256 public constant PLATFORM_BPS = 50;   // 0.5% to the platform
    uint256 public constant BOUNTY_BPS = 25;
    uint256 public constant MAX_LEGS = 6;
    uint256 public constant DEAD_SHARES = 1e6;      // burned on the first mint so supply never returns to zero
    uint256 public constant MIN_FIRST = 1e12;       // minimum first deposit, in core units
    uint256 public constant MAX_LEG_TAX = 500;      // a leg whose creator tax is above 5% would shave every pot buy
    uint256 public constant CLIP_GRACE = 1 days;    // timer leg: one day after its deadline anyone may clip
    uint256 public constant BURN_GRACE = 7 days;    // a buyback budget untouched for a week may be burned by anyone
    uint16 public constant MAX_TERMS_BPS = 8000;    // launcher share + burn share of the tax; the floor keeps at least 10% after the platform's 10%
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint160 internal constant MIN_SQRT = 4295128739;
    uint160 internal constant MAX_SQRT = 1461446703485210103287273052203988822378723970342;

    address public factory;
    address public core;      // address(0) = native
    address public creator;
    uint16 public kickBps;    // share of a deposit that goes to the sleeve (the cap on downside)
    uint32 public exitAfter;  // seconds: a timer leg is sold by timer if graduation did not happen
    bool public taxToLegs;    // v0.4: collected tax is split by composition like a buy (kickBps into the legs); collect is then builder/keeper only
    Leg[] public legs;
    bool private _locked;
    bool private _legsSet;

    // v0.5: terms of a token launched from this pot (zero split = classic launch, the pot itself is the recipient)
    struct Terms { address launcher; address split; uint16 creatorBps; uint16 burnBps; address burnTarget; }   // v0.6: burnTarget = the token the burn budget buys and burns (the launched token itself, or any pons token of the same pair, e.g. $KICKER)
    mapping(address => Terms) public terms;

    event Buy(address indexed buyer, address indexed ref, uint256 coreIn, uint256 shares);
    event Redeem(address indexed owner, uint256 shares, bool toCore, uint256 coreOut);
    event Clip(address indexed caller, uint256 indexed leg, uint256 tokensSold, uint256 coreOut, uint256 bounty, bool graduated);
    event Collect(address indexed caller, uint256 coreIn);
    event TaxKick(uint256 coreIn, uint256 toLegs);   // v0.4: part of the tax went into the legs
    event Launched(address indexed token, address indexed curve, address indexed by, string name, uint16 taxBps, uint256 devBuy);
    event LaunchTerms(address indexed token, address indexed launcher, address split, uint16 creatorBps, uint16 burnBps, address burnTarget);   // v0.5, burnTarget v0.6
    event Burn(address indexed token, address indexed caller, uint256 coreIn, uint256 tokensBurned, address burned);        // v0.5; burned = the token that went to dead (v0.6)
    address[] public launched;
    mapping(address => bool) public adopted;   // v0.7.3: tokens registered by adopt() (launched on pons by a wallet with this pot as recipient)
    uint256 public pendingKick;   // v0.7: tax collected by launchers on a tax-mode pot, waiting for the keeper's collect to feed the legs   // tokens launched from this pot: their creator tax flows here, or through their TaxSplit (v0.5 terms)
    event Fees(address indexed creator, address indexed ref, address indexed platform, uint256 c, uint256 r, uint256 p);

    modifier lock() { require(!_locked, "locked"); _locked = true; _; _locked = false; }

    constructor() { factory = address(this); }   // the implementation itself can never be initialized; clones start from zero storage

    /// two calls from the factory in one transaction: the fields, then the legs (a single ten-argument call does not fit the factory's stack even via ir)
    function initialize(address core_, address creator_, uint16 kick, uint32 exitAfter_, string calldata name_, string calldata symbol_, bool taxToLegs_) external {
        require(factory == address(0), "init");
        require(kick >= 100 && kick <= MAX_KICK, "kick");       // 1-50% of a deposit to the sleeve: the worst-case cap
        require(exitAfter_ >= 600 && exitAfter_ <= 7 days, "exit");
        factory = msg.sender; core = core_; creator = creator_; kickBps = kick; exitAfter = exitAfter_; name = name_; symbol = symbol_; taxToLegs = taxToLegs_;
    }

    function setLegs(address[] calldata tokens, uint16[] calldata weights, uint8[] calldata modes) external {
        require(msg.sender == factory && !_legsSet, "init");
        _legsSet = true;
        require(!taxToLegs || tokens.length > 0, "tax mode needs legs");
        require(tokens.length <= MAX_LEGS && tokens.length == weights.length && tokens.length == modes.length, "legs");   // zero legs = pure floor
        uint256 sum;
        for (uint256 i; i < tokens.length; i++) {
            IPonsFactory.LaunchedToken memory L = PONS.getLaunchedToken(tokens[i]);
            require(L.exists && L.pairToken == core, "not a pons token of this pair");
            require(IPonsCurve(L.curve).creatorTaxBps() <= MAX_LEG_TAX, "leg tax");
            for (uint256 j; j < i; j++) require(tokens[j] != tokens[i], "dup");
            require(modes[i] <= MODE_TIMER, "mode");
            legs.push(Leg(tokens[i], L.curve, L.tickSpacing, weights[i], modes[i], 0, false));
            sum += weights[i];
        }
        require(tokens.length == 0 || sum == 10000, "weights");
    }

    receive() external payable {}

    function legCount() external view returns (uint256) { return legs.length; }

    // ---- buy ----
    function buy(uint256 coreIn, address ref, uint256 minShares) external payable lock returns (uint256 shares) {
        require(coreIn > 0, "zero");
        if (core == address(0)) require(msg.value == coreIn, "value");
        else { require(msg.value == 0, "value"); _pull(core, msg.sender, coreIn); }
        if (ref == msg.sender || ref == creator || ref == address(this)) ref = address(0);
        // fees are sized from coreIn but paid at the end from what was actually invested: a thin curve's refund is not charged
        uint256 fees = coreIn * (CREATOR_BPS + REF_BPS + PLATFORM_BPS) / 1e4;
        uint256 net = coreIn - fees;

        uint256 n = legs.length;
        uint256 coreBefore = _coreBal() - coreIn;
        uint256[] memory before = new uint256[](n);
        uint256[] memory spend = new uint256[](n);
        // composition BEFORE this deposit (the fresh coreIn is already on the balance and must not inflate the floor), legs at marginal price
        uint256 total = coreBefore; uint256[] memory v = new uint256[](n);
        for (uint256 i; i < n; i++) {
            before[i] = IERC20(legs[i].token).balanceOf(address(this));
            // a leg that is held but cannot be bought or priced (graduated without a pool yet, or in the pre-graduation
            // window) would read as zero, drop out of the min-ratio and be handed to the buyer for free: wait for the pool
            if (_dead(i)) continue;   // rescued leg: zero in the composition, never bought, never waited for
            require(before[i] == 0 || _buyable(i), "pool pending");
            v[i] = before[i] * priceInCore(i) / 1e18; total += v[i];
        }
        // empty pot (first deposit, or every holder left and only dead shares remain): split by weights
        bool empty = totalSupply == 0 || total == 0;
        if (empty) {
            uint256 sleeve = net * kickBps / 1e4;
            for (uint256 i; i < n; i++) if (!legs[i].clipped && !_dead(i)) spend[i] = sleeve * legs[i].weightBps / 1e4;   // a clipped or dead leg's weight stays in the floor
        } else {
            // on a curve the spend is grossed up by fee and tax so the leg is not the limiting one in the min-ratio
            uint256 sum;
            for (uint256 i; i < n; i++) {
                spend[i] = net * v[i] / total;
                if (spend[i] > 0 && !IPonsCurve(legs[i].curve).graduated()) { uint256 bps = IPonsCurve(legs[i].curve).feeBps() + IPonsCurve(legs[i].curve).creatorTaxBps(); spend[i] = spend[i] * 1e4 / (1e4 - bps); }
                sum += spend[i];
            }
            if (sum > net) for (uint256 i; i < n; i++) spend[i] = spend[i] * net / sum;
        }
        for (uint256 i; i < n; i++) if (spend[i] > 0) { require(_buyLeg(i, spend[i]), "pool pending"); if (legs[i].boughtAt == 0) legs[i].boughtAt = uint64(block.timestamp); }

        uint256 refund;
        if (empty) {
            require(net >= MIN_FIRST, "dust");
            if (totalSupply == 0) { _mint(DEAD, DEAD_SHARES); shares = net - DEAD_SHARES; }   // as in Uniswap v2: supply never returns to zero
            else shares = net;                                                                // dead shares already exist, the dust goes to them
        } else {
            uint256 ratio = type(uint256).max;
            if (coreBefore > 0) ratio = (_coreBal() - fees - coreBefore) * 1e18 / coreBefore;   // fees are still on the balance and are not part of the composition
            for (uint256 i; i < n; i++) if (before[i] > 0 && spend[i] > 0) {
                uint256 rr = (IERC20(legs[i].token).balanceOf(address(this)) - before[i]) * 1e18 / before[i];
                if (rr < ratio) ratio = rr;
            }
            require(ratio != type(uint256).max, "empty");
            shares = totalSupply * ratio / 1e18;
            // as in Balancer: everything deposited beyond the limiting leg is returned to the buyer,
            // otherwise one thin curve's slippage would be paid as a gift to existing holders
            uint256 keepCore = coreBefore + coreBefore * ratio / 1e18;
            uint256 bal = _coreBal() - fees;   // fees are still on the balance
            if (bal > keepCore) refund = bal - keepCore;
            for (uint256 i; i < n; i++) if (before[i] > 0) {
                uint256 keep = before[i] + before[i] * ratio / 1e18;
                uint256 have = IERC20(legs[i].token).balanceOf(address(this));
                if (have > keep) _push(legs[i].token, msg.sender, have - keep);
            }
        }
        require(shares >= minShares && shares > 0, "slippage");
        _mint(msg.sender, shares);
        // fees on the invested part: coreIn minus refund; the difference goes back to the buyer with the refund
        uint256 invested = coreIn - refund;
        uint256 c = invested * CREATOR_BPS / 1e4; uint256 r = invested * REF_BPS / 1e4; uint256 p = invested * PLATFORM_BPS / 1e4;
        if (ref == address(0)) { c += r; r = 0; }
        address platform = IKickerFactory(factory).platform();
        _push(core, creator, c); if (r > 0) _push(core, ref, r); _push(core, platform, p);
        emit Fees(creator, ref, platform, c, r, p);
        uint256 back = refund + (fees - c - r - p);
        if (back > 0) _push(core, msg.sender, back);
        emit Buy(msg.sender, ref, coreIn, shares);
    }

    /// a leg "rescued" by pons (phase 3: curve closed, no pool will come) is worth zero forever; treated like a clipped
    /// leg, otherwise 1 wei of it on the balance would freeze buys for good
    function _dead(uint256 i) internal view returns (bool) { return PONS.getLaunchedToken(legs[i].token).phase == 3; }

    /// can the leg be bought and priced right now: on the curve - while not waiting for graduation; after graduation - once the pool exists
    function _buyable(uint256 i) internal view returns (bool) {
        IPonsCurve cv = IPonsCurve(legs[i].curve);
        if (cv.graduated()) return priceInCore(i) != 0;
        return !cv.readyToGraduate();
    }
    /// the same test for any pons token of the pair (v0.6 burn targets)
    function _buyable(address curve, address token, int24 ts) internal view returns (bool) {
        IPonsCurve cv = IPonsCurve(curve);
        if (cv.graduated()) return _price(token, curve, ts) != 0;
        return !cv.readyToGraduate();
    }

    // ---- redeem ----
    function redeem(uint256 shares, bool toCore, uint256 minCoreOut) external lock returns (uint256 coreOut) {
        require(shares > 0 && balanceOf[msg.sender] >= shares, "shares");
        uint256 supply = totalSupply;
        _burn(msg.sender, shares);
        uint256 coreBefore = _coreBal();
        for (uint256 i; i < legs.length; i++) {
            uint256 amt = IERC20(legs[i].token).balanceOf(address(this)) * shares / supply;
            if (amt == 0) continue;
            if (!toCore || !_sellLeg(i, amt)) _push(legs[i].token, msg.sender, amt);   // unsellable (pool not created yet) goes out in kind, never silently
        }
        coreOut = coreBefore * shares / supply + (_coreBal() - coreBefore);
        // v0.7.2: the set-aside legs' share (pendingKick) is real core too: a leaver takes its pro-rata so nobody who stays gets it for free
        if (pendingKick > 0) { uint256 pk = pendingKick * shares / supply; pendingKick -= pk; coreOut += pk; }
        require(coreOut >= minCoreOut, "slippage");
        _push(core, msg.sender, coreOut);
        emit Redeem(msg.sender, shares, toCore, coreOut);
    }

    // ---- clip: the exit rule of a curve leg ----
    /// allowed when the leg is not hold, has been bought, and either graduated (pool exists) or (timer) its timer ran out
    function clippable(uint256 i) public view returns (bool ok, bool graduated) {
        Leg memory L = legs[i];
        if (L.mode == MODE_HOLD || L.clipped || L.boughtAt == 0) return (false, false);
        if (IERC20(L.token).balanceOf(address(this)) == 0) return (false, false);
        graduated = IPonsCurve(L.curve).graduated();
        if (graduated) return (priceInCore(i) != 0, true);                 // graduation: sold in the first minute the pool exists
        if (IPonsCurve(L.curve).readyToGraduate()) return (false, false);  // the window between curve and pool: wait
        ok = L.mode == MODE_TIMER && block.timestamp >= uint256(L.boughtAt) + exitAfter;
    }

    /// who may clip: the factory keeper (it sets an honest minCoreOut; a public clip was sandwichable in one transaction:
    /// crash the leg, clip at the bottom, buy back plus bounty, and the pot builder is as much a stranger to holders as
    /// anyone). A timer leg one day after its deadline: anyone, so the exit never depends on the keeper; a grad leg
    /// without a keeper stays in the pot, redeem always works
    function canClip(address who, uint256 i) public view returns (bool) {
        if (who == IKickerFactory(factory).keeper()) return true;
        Leg memory L = legs[i];
        return L.mode == MODE_TIMER && L.boughtAt != 0 && block.timestamp >= uint256(L.boughtAt) + exitAfter + CLIP_GRACE;
    }

    function clip(uint256 i, uint256 minCoreOut) external lock returns (uint256 coreOut) {
        (bool ok, bool graduated) = clippable(i);
        require(ok, "not clippable");
        require(canClip(msg.sender, i), "clipper only");
        uint256 held = IERC20(legs[i].token).balanceOf(address(this));
        uint256 coreBefore = _coreBal();
        require(_sellLeg(i, held), "pool pending");
        coreOut = _coreBal() - coreBefore;
        require(coreOut >= minCoreOut, "slippage");
        legs[i].clipped = true;
        uint256 bounty = coreOut * BOUNTY_BPS / 1e4;
        _push(core, msg.sender, bounty);
        emit Clip(msg.sender, i, held, coreOut, bounty, graduated);
    }

    // ---- collect: creator tax of tokens whose fee recipient is this pot (or its TaxSplit), from the pons escrow into the floor ----
    /// pons credits the escrow only after a sweep; on the curve the creator side (this pot) may sweep itself, after
    /// graduation only the pons operator can (internal swap). So: sweep the pot's own curves, then claim.
    function collect() external returns (uint256 coreIn) { return collectRange(0, launched.length); }

    /// a range [from, to) of launched tokens: a full walk over hundreds of launches is expensive in gas
    function collectRange(uint256 from, uint256 to) public lock returns (uint256 coreIn) {
        // v0.4 "tax buys the kicker": kickBps of the tax goes into the legs by weight, like a first deposit. Buying a leg at
        // market on an open call is sandwichable (the same reason clip is gated), so while there is a leg to buy, collect
        // is builder/keeper only. When nothing can be bought (every leg clipped, dead or in its graduation window) collect
        // is open to anyone: the tax must not sit in the escrow when the builder and the keeper are gone. Checked before any external call.
        bool feed = taxToLegs && _taxLegOpen();
        if (!feed && pendingKick > 0) pendingKick = 0;   // v0.7.2: no leg to feed any more (all clipped, dead or graduated): the set-aside becomes floor
        if (feed) {
            require(msg.sender == creator || msg.sender == IKickerFactory(factory).keeper(), "creator or keeper");
            require(totalSupply != 0, "no holders");   // tax on a pot without holders would go whole to the first depositor
        }
        if (to > launched.length) to = launched.length;
        uint256 before = _coreBal();
        for (uint256 i = from; i < to; i++) _sweepAndSplit(launched[i]);
        if (core == address(0)) { try ESCROW.claim() {} catch {} } else { try ESCROW.claimToken(core) {} catch {} }
        coreIn = _coreBal() - before;
        emit Collect(msg.sender, coreIn);
        if (feed && (coreIn > 0 || pendingKick > 0)) {
            uint256 sleeve = coreIn * kickBps / 1e4 + pendingKick; pendingKick = 0;   // pendingKick is already the legs' share
            uint256 spent;
            for (uint256 i; i < legs.length; i++) {
                if (!_taxLegBuyable(i)) continue;
                uint256 amt = sleeve * legs[i].weightBps / 1e4;
                if (amt == 0) continue;
                // bought through an external self-call: a reverting leg (pool hook, dust on the curve) leaves its share on the
                // floor instead of breaking the whole collect; slippage is capped at 3% off the spot read on entry
                try this.buyLegForTax(i, amt, priceInCore(i)) { spent += amt; if (legs[i].boughtAt == 0) legs[i].boughtAt = uint64(block.timestamp); } catch {}
            }
            emit TaxKick(coreIn, spent);
        }
    }

    /// v0.7: the launcher of a token with terms collects its own token without waiting for the keeper. The split pays the launcher
    /// and the platform; the pot's part lands on the floor as is (no leg buy, so nothing to sandwich), which is why this is open
    /// on tax-mode pots too. The keeper's full collect() still feeds the legs with what it collects.
    function collectToken(address token) external lock returns (uint256 coreIn) {
        Terms memory T = terms[token];
        require(T.split != address(0) && (msg.sender == TaxSplit(payable(T.split)).launcher() || msg.sender == IKickerFactory(factory).keeper() || msg.sender == creator), "launcher only");
        require(totalSupply != 0, "no holders");
        uint256 before = _coreBal();
        _sweepAndSplit(token);
        coreIn = _coreBal() - before;
        // on a tax-mode pot the legs' share is not bought here (no market op on an open call): it is set aside as pendingKick,
        // outside the floor, and bought on the keeper's next collect. The floor part lands now; floor per K only rises.
        if (taxToLegs && _taxLegOpen() && coreIn > 0) { uint256 kick = coreIn * kickBps / 1e4; pendingKick += kick; coreIn -= kick; }
        emit Collect(msg.sender, coreIn);
    }

    /// one launched token: sweep its curve (pons credits the escrow only after a sweep), then let its split (v0.5) pay out.
    /// A token with terms has its own recipient: the split pays the launcher and the platform, keeps the burn budget and pushes the rest here
    function _sweepAndSplit(address token) internal {
        (address curve, , ) = _launchInfo(token);
        address split = terms[token].split;
        if (curve != address(0) && !IPonsCurve(curve).graduated()) {
            if (split == address(0)) { try IPonsCurve(curve).sweepFees(0) {} catch {} }
            else { try TaxSplit(payable(split)).sweep(curve) {} catch {} }
        }
        if (split != address(0)) { try TaxSplit(payable(split)).collect() {} catch {} }
    }

    function _launchInfo(address token) internal view returns (address curve, int24 ts, uint8 phase) {
        IPonsFactory.LaunchedToken memory L = PONS.getLaunchedToken(token);
        return (L.curve, L.tickSpacing, L.phase);
    }

    /// a leg the tax may buy now: not clipped, not dead, timer not expired (clip would sell it right back), buyable
    function _taxLegBuyable(uint256 i) internal view returns (bool) {
        Leg memory L = legs[i];
        if (L.clipped || _dead(i)) return false;
        // an expired timer or a graduated grad/timer leg is checked directly rather than through clippable(): that one
        // answers false for a zero balance, and the tax would buy a leg that gets clipped straight back
        if (L.mode == MODE_TIMER && L.boughtAt != 0 && block.timestamp >= uint256(L.boughtAt) + exitAfter) return false;
        if (L.mode != MODE_HOLD && IPonsCurve(L.curve).graduated()) return false;
        return _buyable(i);
    }
    function _taxLegOpen() internal view returns (bool) { for (uint256 i; i < legs.length; i++) if (_taxLegBuyable(i)) return true; return false; }

    /// only from collectRange (a self-call for try/catch): buy the leg with amt of core and receive at least 97% of the spot px
    function buyLegForTax(uint256 i, uint256 amt, uint256 px) external {
        require(msg.sender == address(this), "self");
        IPonsCurve cv = IPonsCurve(legs[i].curve);
        uint256 expect;
        if (!cv.graduated()) {
            // curve: fee and leg tax (up to 1% + 5%) come off the input, then x*y=k on the reserves; 3% margin
            (uint256 q, uint256 t) = cv.getReserves();
            uint256 net = amt * (1e4 - cv.feeBps() - cv.creatorTaxBps()) / 1e4;
            expect = q + net == 0 ? 0 : t * net / (q + net) * 97 / 100;
        } else {
            // v4 pool: spot on entry minus 20% for price impact in a thin pool (buy() has no cap at all); protects against
            // an in-block sandwich beyond the builder/keeper gate, not against a price pumped beforehand - the caller sees that
            require(px > 0, "no price");
            expect = amt * 1e18 / px * 80 / 100;
        }
        uint256 before = IERC20(legs[i].token).balanceOf(address(this));
        require(_buyLeg(i, amt), "pool pending");
        uint256 got = IERC20(legs[i].token).balanceOf(address(this)) - before;
        require(got >= expect, "slip");
    }

    // ---- v0.5 burn: the buyback budget of a token launched with burnBps buys the token and sends it to the dead address ----
    /// keeper only, like clip: a market buy with a caller-supplied minimum is sandwichable by the caller itself, and the pot
    /// builder is a stranger to the launcher's terms. BURN_GRACE after the budget last grew, anyone may burn, so the buyback never
    /// depends on the keeper (a budget that keeps growing stays keeper-only until the keeper lets it sit for a week). What the market cannot take (a clamped curve buy) goes back to the split; a rescued token (no market)
    /// forfeits its budget to the floor so the split never holds value forever.
    function canBurn(address who, address token) public view returns (bool) {
        if (who == IKickerFactory(factory).keeper()) return true;
        address split = terms[token].split;
        return split != address(0) && TaxSplit(payable(split)).burnHeld() > 0 && block.timestamp >= uint256(TaxSplit(payable(split)).burnSince()) + BURN_GRACE;
    }

    function burn(address token, uint256 minTokensOut) external lock returns (uint256 coreIn, uint256 burned) {
        require(canBurn(msg.sender, token), "keeper only");
        Terms memory T = terms[token];
        require(T.split != address(0), "no terms");
        coreIn = TaxSplit(payable(T.split)).release();
        require(coreIn > 0, "nothing to burn");
        address target = T.burnTarget == address(0) ? token : T.burnTarget;
        (address curve, int24 ts, uint8 phase) = _launchInfo(target);
        // v0.7: a dead target falls back to the launched token; a target that merely has no market yet makes the burn wait
        if (target != token && phase == 3) { target = token; (curve, ts, phase) = _launchInfo(token); }   // a dead target: the launched token burns instead
        require(target == token || _buyable(curve, target, ts), "target pending");   // a target with no market yet: the budget waits, nothing else burns
        if (phase == 3) { emit Burn(token, msg.sender, coreIn, 0, target); return (coreIn, 0); }   // dead token: the budget becomes floor
        uint256 before = IERC20(target).balanceOf(address(this));
        uint256 c0 = _coreBal();
        require(_buyAny(target, curve, ts, coreIn), "pool pending");
        uint256 spent = c0 - _coreBal();
        if (spent < coreIn) { _push(core, T.split, coreIn - spent); TaxSplit(payable(T.split)).rehold(coreIn - spent); coreIn = spent; }
        burned = IERC20(target).balanceOf(address(this)) - before;
        require(burned >= minTokensOut && burned > 0, "slippage");
        _burnToken(target, burned);
        emit Burn(token, msg.sender, coreIn, burned, target);
    }

    /// v0.7.3: a pons token burns for real (burn() lowers totalSupply, pons and the trackers show it); anything else goes to the dead address
    function _burnToken(address token, uint256 amt) internal {
        uint256 b0 = IERC20(token).balanceOf(address(this));
        (bool ok,) = token.call(abi.encodeWithSelector(0x42966c68, amt));   // burn(uint256), ERC20Burnable on every pons token
        uint256 b1 = IERC20(token).balanceOf(address(this));
        if (!ok || b1 > b0 - amt) _push(token, DEAD, b1 - (b0 - amt));   // no burn(), or a burn that took less: the rest goes to the dead address
    }

    /// core units waiting in the token's split for the next burn()
    function burnOwed(address token) external view returns (uint256) { address s = terms[token].split; return s == address(0) ? 0 : TaxSplit(payable(s)).burnHeld(); }

    // ---- launch a token from the pot: the pot is the launcher and the creator fee recipient, the name ends in "by kicker" ----
    /// anyone may launch: a pot is a public launchpad. With the classic launch the whole creator tax goes to the pot's holders;
    /// with terms (v0.5) the launcher, a buyback and the platform take their shares first.
    /// The launch fee is paid in ETH (msg.value), the dev buy in the floor asset: for ETH also in msg.value, for an ERC20
    /// by transferFrom. The dev buy is bought by the pot (the launcher side is exempt from the snipe tax) and handed to the caller.
    function launch(string calldata name_, string calldata symbol_, string calldata logo, string calldata description, string calldata twitter, string calldata telegram, uint16 taxBps, uint256 devBuy) external payable lock returns (address token, address curve) {
        return _launch(name_, symbol_, logo, description, twitter, telegram, taxBps, devBuy, 0, 0, address(0));
    }

    /// v0.5: the same launch with terms. creatorBps of the tax accrues to the launcher (msg.sender; launch from a wallet that can
    /// call the split's withdraw), burnBps buys the token back and burns it, 10% to the platform, the rest to the floor.
    /// Terms are fixed forever in a TaxSplit clone that is the token's recipient. On a tax-mode pot the collect that accrues the
    /// launcher's share is builder/keeper gated like every collect there.
    function launchWithTerms(string calldata name_, string calldata symbol_, string calldata logo, string calldata description, string calldata twitter, string calldata telegram, uint16 taxBps, uint256 devBuy, uint16 creatorBps, uint16 burnBps) external payable lock returns (address token, address curve) {
        return _launch(name_, symbol_, logo, description, twitter, telegram, taxBps, devBuy, creatorBps, burnBps, address(0));
    }

    /// v0.6: the same launch, but the burn budget buys and burns burnTarget instead of the launched token. burnTarget must be a
    /// pons token of this pot's pair (e.g. the pot's own kicker coin), so every launch from the pot can shrink its supply.
    function launchWithTermsTarget(string calldata name_, string calldata symbol_, string calldata logo, string calldata description, string calldata twitter, string calldata telegram, uint16 taxBps, uint256 devBuy, uint16 creatorBps, uint16 burnBps, address burnTarget) external payable lock returns (address token, address curve) {
        require(burnTarget != address(0) && burnBps > 0, "target");
        IPonsFactory.LaunchedToken memory L = PONS.getLaunchedToken(burnTarget);
        require(L.exists && L.pairToken == core, "pair"); require(L.phase != 3, "dead target");
        return _launch(name_, symbol_, logo, description, twitter, telegram, taxBps, devBuy, creatorBps, burnBps, burnTarget);
    }

    function _launch(string calldata name_, string calldata symbol_, string calldata logo, string calldata description, string calldata twitter, string calldata telegram, uint16 taxBps, uint256 devBuy, uint16 creatorBps, uint16 burnBps, address burnTarget) internal returns (address token, address curve) {
        require(keccak256(bytes(symbol_)) != keccak256("KICKER") || msg.sender == IKickerFactory(factory).keeper(), "reserved");   // the platform ticker only from the platform wallet
        address split = _split(creatorBps, burnBps);
        uint256 fee = PONS.launchFee();
        if (core == address(0)) { require(msg.value == fee + devBuy, "value"); }
        else { require(msg.value == fee, "value"); if (devBuy > 0) _pull(core, msg.sender, devBuy); }
        (token, curve) = PONS.launchToken{value: fee}(_params(name_, symbol_, logo, description, twitter, telegram, taxBps, split == address(0) ? address(this) : split), 0, core);
        launched.push(token);
        if (split != address(0)) { terms[token] = Terms(msg.sender, split, creatorBps, burnBps, burnTarget); emit LaunchTerms(token, msg.sender, split, creatorBps, burnBps, burnTarget); }
        if (devBuy > 0) _devBuy(token, curve, devBuy);
        emit Launched(token, curve, msg.sender, string.concat(name_, " by kicker"), taxBps, devBuy);
    }

    // ---- v0.7.3: a launch made on pons by a wallet (the wallet is the creator there, the dev buy is the router's first buy that
    // bot decoders read; a pot buying for itself they do not see) with this pot or a split of this pot as the creator fee recipient ----
    /// the split's address before it exists: the wallet names it as creatorFeeRecipient on pons, then adopt() puts the split there.
    /// the terms are hashed into the address, so nobody can adopt the token under other terms
    function predictSplit(address launcher, uint16 creatorBps, uint16 burnBps, address burnTarget, bytes32 salt) public view returns (address) {
        require(uint256(creatorBps) + burnBps > 0 && uint256(creatorBps) + burnBps <= MAX_TERMS_BPS, "terms");   // zero terms name the pot itself as recipient, never a split
        bytes32 s = keccak256(abi.encode(launcher, creatorBps, burnBps, burnTarget, salt));
        bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), address(this), s, keccak256(_cloneCode(IKickerFactory(factory).splitImpl()))));
        return address(uint160(uint256(h)));
    }

    /// register a pons token whose creator fee recipient is this pot (classic: the whole tax to the floor) or a split predicted by
    /// predictSplit (terms). anyone may call: the recipient on pons is the proof. the launcher of a terms launch is pons' deployer
    function adopt(address token, uint16 creatorBps, uint16 burnBps, address burnTarget, bytes32 salt) external lock {
        require(!adopted[token] && terms[token].split == address(0), "known");
        IPonsFactory.LaunchedToken memory L = PONS.getLaunchedToken(token);
        require(L.exists && L.pairToken == core && L.deployer != address(this), "not ours");   // the pot's own launches are listed at launch
        // the launcher, the builder or the keeper: every entry costs collect() a sweep, so a stranger cannot pad the list for free
        require(msg.sender == L.deployer || msg.sender == creator || msg.sender == IKickerFactory(factory).keeper(), "launcher only");
        adopted[token] = true;
        if (creatorBps == 0 && burnBps == 0) { require(L.creatorFeeRecipient == address(this), "recipient"); }
        else {
            if (burnTarget != address(0)) { require(burnBps > 0, "target"); IPonsFactory.LaunchedToken memory T = PONS.getLaunchedToken(burnTarget); require(T.exists && T.pairToken == core, "pair"); }   // a target that died meanwhile is handled by burn() (it burns the launched token instead); refusing here would strand the tax
            address split = predictSplit(L.deployer, creatorBps, burnBps, burnTarget, salt);
            require(L.creatorFeeRecipient == split, "recipient");
            require(split.code.length == 0, "split used");   // one split per token: a reused salt would pool two tokens' budgets in one split
            require(_clone2(IKickerFactory(factory).splitImpl(), keccak256(abi.encode(L.deployer, creatorBps, burnBps, burnTarget, salt))) == split, "split");
            TaxSplit(payable(split)).initialize(address(this), L.deployer, creatorBps, burnBps);
            terms[token] = Terms(L.deployer, split, creatorBps, burnBps, burnTarget);
            emit LaunchTerms(token, L.deployer, split, creatorBps, burnBps, burnTarget);
        }
        launched.push(token);
        emit Launched(token, L.curve, L.deployer, IERC20Meta(token).name(), L.creatorTaxBps, 0);
    }

    /// v0.5: a TaxSplit clone for a launch with terms; zero terms = classic launch, no clone
    function _split(uint16 creatorBps, uint16 burnBps) internal returns (address split) {
        require(uint256(creatorBps) + burnBps <= MAX_TERMS_BPS, "terms");
        if (creatorBps == 0 && burnBps == 0) return address(0);
        split = _clone(IKickerFactory(factory).splitImpl());
        TaxSplit(payable(split)).initialize(address(this), msg.sender, creatorBps, burnBps);
    }

    function _params(string calldata name_, string calldata symbol_, string calldata logo, string calldata description, string calldata twitter, string calldata telegram, uint16 taxBps, address recipient) internal view returns (IPonsFactory.TokenParams memory p) {
        p = IPonsFactory.TokenParams({
            name: string.concat(name_, " by kicker"), symbol: symbol_, logo: logo, description: description,
            socials: IPonsFactory.Socials({ twitter: twitter, telegram: telegram, discord: "", website: string.concat("https://kicker.markets/pot?k=", _hex(address(this))), farcaster: "" }),
            creatorFeeRecipient: recipient, creatorTaxBps: taxBps, buybackEnabled: false,
            expectedEconomics: PONS.previewLaunchEconomics(0, core),
            salt: keccak256(abi.encodePacked(address(this), symbol_, block.timestamp, launched.length)) });
    }

    /// the dev buy is bought by the pot on the fresh curve and handed to the caller; what the curve did not take (clamping) goes back to the caller
    function _devBuy(address token, address curve, uint256 devBuy) internal {
        uint256 before = IERC20(token).balanceOf(address(this));
        uint256 c0 = _coreBal();
        if (core == address(0)) IPonsCurve(curve).buy{value: devBuy}(devBuy, 0, address(this));
        else { IERC20(core).approve(curve, devBuy); IPonsCurve(curve).buy(devBuy, 0, address(this)); }
        uint256 got = IERC20(token).balanceOf(address(this)) - before;
        if (got > 0) _push(token, msg.sender, got);
        uint256 spent = c0 - _coreBal();
        if (spent < devBuy) _push(core, msg.sender, devBuy - spent);
    }

    function launchedCount() external view returns (uint256) { return launched.length; }

    /// after graduation: sweep fees off the hook. The fee recipient side calls it when no conversion is needed (otherwise pons
    /// refuses and its operator sweeps). minQuote/minBuyback as in pons
    function sweepPool(address token, uint256 minConversionQuoteOut, uint256 minBuybackTokensOut) external lock {
        // v0.7: the launcher of a token with terms may sweep its own pool fees too (the hook converts, the caller only names minimums)
        address sp = terms[token].split;
        require(msg.sender == creator || (sp != address(0) && msg.sender == TaxSplit(payable(sp)).launcher()), "creator only");
        IPonsFactory.LaunchedToken memory L = PONS.getLaunchedToken(token);
        require(L.exists, "unknown");
        (address c0, address c1) = core < token ? (core, token) : (token, core);
        bytes32 id = keccak256(abi.encode(PoolKey(c0, c1, L.poolFee, L.tickSpacing, HOOK)));
        address split = terms[token].split;   // pons lets only the fee recipient sweep: for a token with terms that is its split
        if (split == address(0)) IPonsHook(HOOK).sweepPoolFees(id, minConversionQuoteOut, minBuybackTokensOut);
        else TaxSplit(payable(split)).sweepPool(HOOK, id, minConversionQuoteOut, minBuybackTokensOut);
    }

    /// move the tax of a token launched here to another pot of the same platform (version migration): only to a kicker
    /// whose factory shares the same platform. What the escrow already holds is taken by collect() before the move.
    /// Keeper only: a pot builder could otherwise redirect the tax of tokens that strangers launched into the pot.
    /// A token with launcher terms cannot be moved: its terms are a promise to the launcher.
    function moveTax(address token, address newPot) external lock {
        require(msg.sender == IKickerFactory(factory).keeper(), "keeper only");
        require(terms[token].split == address(0), "has terms");
        // trust only the factory registry (the target could lie about its factory); same floor asset, or the tax could not be claimed
        require(IKickerFactory(factory).knownKicker(newPot) && Kicker(payable(newPot)).core() == core, "not a kicker");
        PONS.transferCreatorFeeRecipient(token, newPot);
    }

    function _hex(address a) internal pure returns (string memory) {
        bytes memory h = "0123456789abcdef"; bytes memory out = new bytes(42); out[0] = "0"; out[1] = "x";
        uint160 v = uint160(a);
        for (uint256 i = 41; i > 1; i--) { out[i] = h[v & 15]; v >>= 4; }
        return string(out);
    }

    function _cloneCode(address target) internal pure returns (bytes memory) {
        return abi.encodePacked(hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", target, hex"5af43d82803e903d91602b57fd5bf3");
    }
    function _clone2(address target, bytes32 salt) internal returns (address instance) {
        bytes memory code = _cloneCode(target);
        assembly ("memory-safe") { instance := create2(0, add(code, 0x20), mload(code), salt) }
        require(instance != address(0), "clone");
    }
    function _clone(address target) internal returns (address instance) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, 0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, target))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create(0, ptr, 0x37)
        }
        require(instance != address(0), "clone");
    }

    // ---- nav ----
    /// price of a leg in core (1e18 = 1 core per 1e18 token): curve by reserves (marginal), pool by slot0
    function priceInCore(uint256 i) public view returns (uint256) {
        Leg memory L = legs[i];
        return _price(L.token, L.curve, L.tickSpacing);
    }

    function _price(address token, address curve, int24 ts) internal view returns (uint256) {
        if (!IPonsCurve(curve).graduated()) {
            (uint256 q, uint256 t) = IPonsCurve(curve).getReserves();
            return t == 0 ? 0 : q * 1e18 / t;
        }
        (address c0, address c1) = core < token ? (core, token) : (token, core);
        bytes32 id = keccak256(abi.encode(PoolKey(c0, c1, PONS.getLaunchedToken(token).poolFee, ts, HOOK)));
        uint160 sqrtP = uint160(uint256(PM.extsload(keccak256(abi.encode(id, uint256(6))))));
        if (sqrtP == 0) return 0;
        uint256 pQ96 = _mulDiv(sqrtP, sqrtP, 1 << 96);            // c1 per c0, Q96
        if (token == c0) return _mulDiv(pQ96, 1e18, 1 << 96);     // core = c1: core per token = p
        return _mulDiv(1e18, 1 << 96, pQ96);                     // core = c0: core per token = 1/p
    }

    /// value of a leg if the whole holding were sold: on the curve by the invariant minus fee and tax (liquidation
    /// value, not marginal); in the pool by slot0 (pool depth is not cheap to read)
    function legValue(uint256 i) public view returns (uint256) {
        Leg memory L = legs[i];
        uint256 held = IERC20(L.token).balanceOf(address(this));
        if (held == 0) return 0;
        IPonsCurve cv = IPonsCurve(L.curve);
        if (cv.graduated()) return held * priceInCore(i) / 1e18;
        (uint256 q, uint256 t) = cv.getReserves();
        uint256 out = _mulDiv(q, held, t + held);
        uint256 bps = cv.feeBps() + cv.creatorTaxBps();
        return out * (1e4 - bps) / 1e4;
    }

    function _nav() internal view returns (uint256 navCore, uint256[] memory navLeg, uint256 navSleeve) {
        navCore = _coreBal();
        navLeg = new uint256[](legs.length);
        for (uint256 i; i < legs.length; i++) {
            navLeg[i] = legValue(i);
            navSleeve += navLeg[i];
        }
    }

    function nav() external view returns (uint256 navCore, uint256[] memory navLeg, uint256 navSleeve) { return _nav(); }

    // ---- buy and sell paths of a leg ----
    /// false = cannot buy right now (graduated without a pool / pre-graduation window); the caller decides
    function _buyLeg(uint256 i, uint256 amt) internal returns (bool) { Leg memory L = legs[i]; return _buyAny(L.token, L.curve, L.tickSpacing, amt); }

    function _buyAny(address token, address curve, int24 ts, uint256 amt) internal returns (bool) {
        IPonsCurve cv = IPonsCurve(curve);
        if (cv.graduated()) { if (_price(token, curve, ts) == 0) return false; _swap(token, ts, true, amt); return true; }
        if (cv.readyToGraduate()) return false;
        if (core == address(0)) cv.buy{value: amt}(amt, 0, address(this));
        else { IERC20(core).approve(curve, amt); cv.buy(amt, 0, address(this)); }
        return true;
    }

    function _sellLeg(uint256 i, uint256 amt) internal returns (bool) {
        Leg memory L = legs[i];
        IPonsCurve cv = IPonsCurve(L.curve);
        if (cv.graduated()) { if (priceInCore(i) == 0) return false; _swap(L.token, L.tickSpacing, false, amt); return true; }
        if (cv.readyToGraduate()) return false;
        IERC20(L.token).approve(L.curve, amt);
        try cv.sell(amt, 0, address(this)) { return true; } catch { return false; }   // dust sells to zero and reverts: hand it out in kind
    }

    function _swap(address token, int24 ts, bool coreToToken, uint256 amountIn) internal returns (uint256 out) {
        out = abi.decode(PM.unlock(abi.encode(token, ts, coreToToken, amountIn)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(PM), "pm");
        (address token, int24 ts, bool coreToToken, uint256 amountIn) = abi.decode(data, (address, int24, bool, uint256));
        (address c0, address c1) = core < token ? (core, token) : (token, core);
        address tokenIn = coreToToken ? core : token;
        bool zeroForOne = tokenIn == c0;
        int256 delta = PM.swap(PoolKey(c0, c1, PONS.getLaunchedToken(token).poolFee, ts, HOOK), SwapParams(zeroForOne, -int256(amountIn), zeroForOne ? MIN_SQRT + 1 : MAX_SQRT - 1), "");
        int256 a0 = delta >> 128;
        int256 a1 = int256(int128(int256(delta)));
        (int256 dIn, int256 dOut) = zeroForOne ? (a0, a1) : (a1, a0);
        uint256 owed = uint256(-dIn);
        uint256 out = uint256(dOut);
        if (tokenIn == address(0)) PM.settle{value: owed}();
        else { PM.sync(tokenIn); _push(tokenIn, address(PM), owed); PM.settle(); }
        PM.take(coreToToken ? token : core, address(this), out);
        return abi.encode(out);
    }

    // ---- helpers ----
    /// the floor: the pot's core balance minus pendingKick (v0.7: the legs' share of tax a launcher collected, held until the
    /// keeper's collect buys the legs; it is not floor, so nav, redeem and buy never see it and floor per K never dips)
    function _coreBal() internal view returns (uint256) { uint256 b = core == address(0) ? address(this).balance : IERC20(core).balanceOf(address(this)); return b - pendingKick; }   // reverts if pendingKick ever exceeded the balance: unreachable, and loud if not

    function _push(address t, address to, uint256 amt) internal {
        if (amt == 0) return;
        if (t == address(0)) { (bool ok,) = to.call{value: amt}(""); require(ok, "eth"); return; }
        (bool s, bytes memory d) = t.call(abi.encodeWithSelector(IERC20.transfer.selector, to, amt));
        require(s && (d.length == 0 || abi.decode(d, (bool))), "transfer");
    }

    function _pull(address t, address from, uint256 amt) internal {
        (bool s, bytes memory d) = t.call(abi.encodeWithSelector(IERC20.transferFrom.selector, from, address(this), amt));
        require(s && (d.length == 0 || abi.decode(d, (bool))), "transferFrom");
    }

    function _mulDiv(uint256 a, uint256 b, uint256 d) internal pure returns (uint256 result) {
        unchecked {
            uint256 p0; uint256 p1;
            assembly ("memory-safe") { let mm := mulmod(a, b, not(0)) p0 := mul(a, b) p1 := sub(sub(mm, p0), lt(mm, p0)) }
            if (p1 == 0) return p0 / d;
            require(d > p1, "mulDiv");
            uint256 rmd; assembly ("memory-safe") { rmd := mulmod(a, b, d) p1 := sub(p1, gt(rmd, p0)) p0 := sub(p0, rmd) }
            uint256 tw = d & (0 - d);
            assembly ("memory-safe") { d := div(d, tw) p0 := div(p0, tw) tw := add(div(sub(0, tw), tw), 1) }
            p0 |= p1 * tw;
            uint256 inv = (3 * d) ^ 2;
            for (uint256 i; i < 6; i++) inv *= 2 - d * inv;
            result = p0 * inv;
        }
    }

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
