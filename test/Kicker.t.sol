// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Kicker} from "../src/Kicker.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {KickerFactory} from "../src/KickerFactory.sol";
import {TaxSplit} from "../src/TaxSplit.sol";
import {IERC20, IPonsCurve, IPonsFactory} from "../src/Interfaces.sol";

// RH fork: forge test --fork-url $PONS_RPC -vv
contract KickerForkTest is Test {
    address constant GLD = 0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e;
    address constant UBIK = 0x812486EAea648819853F8E372dc9f1516C7868Bd;      // graduated, UBIK/GLD pool (hold)
    address constant FRESH = 0x080146fb5699885C59F181BAC62730a0a42A9b7A;     // on the curve, GLD pair (13.09) - a position with an exit
    address constant FRESH_CURVE = 0xd9399437833Fdf55B6aa70b49AE2c52eB18F08C1;
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;        // holds 6k GLD - donor for the test
    address constant PONS = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;      // pons v2 factory
    address constant ROUTER = 0xe33E9E479dF8802cb0866d5d05258bEc4cF62948;    // pons launchAndBuy router (the dev buy path every wallet uses)

    KickerFactory f;
    address platform = makeAddr("platform");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address whale = makeAddr("whale");
    address mallory = makeAddr("mallory");

    function setUp() public {
        f = new KickerFactory(platform, keeper);
        vm.startPrank(PM);
        IERC20(GLD).transfer(alice, 50e18);
        IERC20(GLD).transfer(carol, 50e18);
        IERC20(GLD).transfer(whale, 200e18);
        vm.stopPrank();
    }

    function _pot() internal returns (Kicker k) {
        address[] memory t = new address[](2); t[0] = UBIK; t[1] = FRESH;
        uint16[] memory w = new uint16[](2); w[0] = 5000; w[1] = 5000;
        uint8[] memory h = new uint8[](2); h[0] = 0; h[1] = 2;
        vm.prank(bob);
        k = Kicker(payable(f.create(GLD, t, w, h, 500, 1800, "gold pot", "GLD/K")));   // 5% sleeve, exit after 30 min
    }

    function test_buy_fees_1pct_and_cap() public {
        Kicker k = _pot();
        vm.startPrank(alice);
        IERC20(GLD).approve(address(k), 10e18);
        uint256 shares = k.buy(10e18, carol, 0);
        vm.stopPrank();
        assertEq(shares, 9.8e18 - 1e6, "first mint = net after 2% minus dead shares");
        assertEq(IERC20(GLD).balanceOf(bob), 0.1e18, "creator 1%");
        assertEq(IERC20(GLD).balanceOf(carol), 50e18 + 0.05e18, "ref 0.5%");
        assertEq(IERC20(GLD).balanceOf(platform), 0.05e18, "platform 0.5%");
        (uint256 navCore, uint256[] memory navLeg, uint256 navSleeve) = k.nav();
        console2.log("core GLD", navCore); console2.log("ubik value", navLeg[0]); console2.log("fresh liq value", navLeg[1]);
        assertApproxEqRel(navCore, 9.31e18, 0.01e18, "floor = 95% of net");
        assertLt(navSleeve, 0.49e18, "sleeve valued at liquidation, below spend");
        assertGt(navSleeve, 0.3e18, "but not absurdly");
        (bool ok,) = k.clippable(1); assertFalse(ok, "fresh leg: timer not elapsed");
        (ok,) = k.clippable(0); assertFalse(ok, "hold leg never clips");
    }

    function test_clip_by_timer() public {
        Kicker k = _pot();
        vm.startPrank(alice); IERC20(GLD).approve(address(k), 10e18); k.buy(10e18, address(0), 0); vm.stopPrank();
        vm.expectRevert(bytes("not clippable")); k.clip(1, 0);
        vm.warp(block.timestamp + 1801);
        (bool ok, bool grad) = k.clippable(1); assertTrue(ok); assertFalse(grad);
        (uint256 c0,,) = k.nav();
        vm.expectRevert(bytes("clipper only")); k.clip(1, 0);   // public clip is closed: sandwich
        uint256 keeper0 = IERC20(GLD).balanceOf(keeper);
        vm.prank(keeper); uint256 out = k.clip(1, 0);
        (uint256 c1,, uint256 s1) = k.nav();
        console2.log("clipped out", out); console2.log("core before/after", c0, c1);
        assertGt(c1, c0, "core grew by the clip");
        assertEq(IERC20(FRESH).balanceOf(address(k)), 0, "leg fully sold");
        assertEq(IERC20(GLD).balanceOf(keeper) - keeper0, out * 25 / 1e4, "bounty 0.25%");
        (ok,) = k.clippable(1); assertFalse(ok, "clipped once");
        assertGt(s1, 0, "hold leg (ubik) remains");
        // the next buyer splits by the current composition: the fresh leg is already clipped, not bought again
        vm.startPrank(carol); IERC20(GLD).approve(address(k), 5e18); k.buy(5e18, address(0), 0); vm.stopPrank();
        assertEq(IERC20(FRESH).balanceOf(address(k)), 0, "clipped leg is not rebought");
    }

    function test_clip_on_graduation() public {
        Kicker k = _pot();
        vm.startPrank(alice); IERC20(GLD).approve(address(k), 10e18); k.buy(10e18, address(0), 0); vm.stopPrank();
        // a whale pushes the curve to graduation: threshold 24.94 GLD
        vm.startPrank(whale); IERC20(GLD).approve(FRESH_CURVE, 40e18); IPonsCurve(FRESH_CURVE).buy(40e18, 0, whale); vm.stopPrank();
        bool grad = IPonsCurve(FRESH_CURVE).graduated(); bool ready = IPonsCurve(FRESH_CURVE).readyToGraduate();
        console2.log("graduated", grad); console2.log("readyToGraduate", ready);
        (bool ok, bool g) = k.clippable(1);
        // graduation and pool creation are different transactions: right after graduation there is no pool, clip waits
        assertFalse(ok, "between graduation and pool: wait"); assertEq(g, grad);
        if (grad) {
            (bool s,) = address(k.PONS()).call(abi.encodeWithSignature("createGraduatedPool(address)", FRESH));
            console2.log("createGraduatedPool", s);
            if (s) {
                (ok, g) = k.clippable(1); assertTrue(ok, "clip open once the pool exists"); assertTrue(g);
                vm.prank(keeper); uint256 out = k.clip(1, 0); console2.log("clip at graduation out", out); assertGt(out, 0);
            }
        }
    }

    function test_redeem_in_kind_and_to_core() public {
        Kicker k = _pot();
        vm.startPrank(alice); IERC20(GLD).approve(address(k), 10e18); uint256 s = k.buy(10e18, address(0), 0); vm.stopPrank();
        vm.startPrank(carol); IERC20(GLD).approve(address(k), 10e18); uint256 s2 = k.buy(10e18, address(0), 0); vm.stopPrank();
        uint256 g0 = IERC20(GLD).balanceOf(alice);
        vm.prank(alice); uint256 out = k.redeem(s, false, 0);
        assertApproxEqRel(out, 9.31e18, 0.05e18, "in-kind floor ~ what alice put into the floor");
        assertGt(IERC20(UBIK).balanceOf(alice), 0, "got ubik");
        assertGt(IERC20(FRESH).balanceOf(alice), 0, "got fresh");
        assertEq(IERC20(GLD).balanceOf(alice) - g0, out);
        vm.prank(carol); uint256 out2 = k.redeem(s2, true, 0);
        uint256 carolTotal = IERC20(GLD).balanceOf(carol) - 40e18;
        console2.log("to-core out", out2); console2.log("carol total back", carolTotal);
        assertGt(carolTotal, 9.6e18, "to-core: most of 9.8 net comes back (5% sleeve)");
        assertEq(k.totalSupply(), 1e6, "only dead shares left");
    }

    function test_grad_mode_ignores_timer() public {
        address[] memory t = new address[](1); t[0] = FRESH;
        uint16[] memory w = new uint16[](1); w[0] = 10000;
        uint8[] memory h = new uint8[](1); h[0] = 1;
        Kicker k = Kicker(payable(f.create(GLD, t, w, h, 500, 1800, "grad pot", "GRD/K")));
        vm.startPrank(alice); IERC20(GLD).approve(address(k), 10e18); k.buy(10e18, address(0), 0); vm.stopPrank();
        vm.warp(block.timestamp + 7 days);
        (bool ok,) = k.clippable(0); assertFalse(ok, "grad leg: timer means nothing");
    }

    function test_half_pot_and_no_rebuy_after_clip() public {
        address[] memory t = new address[](2); t[0] = UBIK; t[1] = FRESH;
        uint16[] memory w = new uint16[](2); w[0] = 5000; w[1] = 5000;
        uint8[] memory h = new uint8[](2); h[0] = 0; h[1] = 2;
        Kicker k = Kicker(payable(f.create(GLD, t, w, h, 5000, 1800, "half pot", "HLF/K")));
        vm.startPrank(alice); IERC20(GLD).approve(address(k), 20e18); uint256 s1 = k.buy(10e18, address(0), 0); vm.stopPrank();
        (uint256 c,,) = k.nav(); assertApproxEqRel(c, 4.9e18, 0.01e18, "half to the floor");
        vm.warp(block.timestamp + 1801);
        vm.prank(keeper); k.clip(1, 0);
        vm.prank(alice); k.redeem(s1, true, 0);
        assertEq(k.totalSupply(), 1e6, "only dead shares left");
        // empty pot: the first deposit splits by weights again, but the clipped leg is not bought
        vm.startPrank(alice); k.buy(10e18, address(0), 0); vm.stopPrank();
        assertEq(IERC20(FRESH).balanceOf(address(k)), 0, "clipped leg stays empty");
        assertGt(IERC20(UBIK).balanceOf(address(k)), 0, "hold leg bought");
    }

    function test_second_buy_keeps_composition_no_refund() public {
        Kicker k = _pot();
        vm.startPrank(alice); IERC20(GLD).approve(address(k), 10e18); k.buy(10e18, address(0), 0); vm.stopPrank();
        (uint256 c0,, uint256 s0) = k.nav();
        uint256 g = IERC20(GLD).balanceOf(carol);
        vm.startPrank(carol); IERC20(GLD).approve(address(k), 5e18); uint256 sh = k.buy(5e18, address(0), 0); vm.stopPrank();
        uint256 spent = g - IERC20(GLD).balanceOf(carol);
        console2.log("carol spent", spent); console2.log("shares", sh);
        assertGt(spent, 4.9e18, "no refund on a normal second buy");
        (uint256 c1,, uint256 s1) = k.nav();
        // the sleeve share after the second deposit is about the same as before it (the sleeve is topped up by composition)
        uint256 share0 = s0 * 1e4 / (c0 + s0); uint256 share1 = s1 * 1e4 / (c1 + s1);
        console2.log("sleeve share before/after bps", share0, share1);
        assertApproxEqAbs(share1, share0, 60, "sleeve share kept within 0.6pp");
    }

    function test_limits() public {
        address[] memory t = new address[](1); t[0] = UBIK;
        uint16[] memory w = new uint16[](1); w[0] = 10000;
        uint8[] memory h = new uint8[](1); h[0] = 0;
        vm.expectRevert(bytes("not a pons token of this pair")); f.create(address(0), t, w, h, 1000, 1800, "x", "X");
        vm.expectRevert(bytes("kick")); f.create(GLD, t, w, h, 5100, 1800, "x", "X");
        h[0] = 3; vm.expectRevert(bytes("mode")); f.create(GLD, t, w, h, 1000, 1800, "x", "X"); h[0] = 0;
        vm.expectRevert(bytes("exit")); f.create(GLD, t, w, h, 1000, 60, "x", "X");
    }

    function test_pure_floor_pot_no_legs() public {
        address[] memory t = new address[](0); uint16[] memory w = new uint16[](0); uint8[] memory h = new uint8[](0);
        Kicker k = Kicker(payable(f.create(GLD, t, w, h, 100, 1800, "gold floor", "GLD/F")));
        vm.startPrank(alice); IERC20(GLD).approve(address(k), 10e18); uint256 s = k.buy(10e18, address(0), 0); vm.stopPrank();
        (uint256 c,, uint256 sl) = k.nav(); assertEq(c, 9.8e18); assertEq(sl, 0);
        // donation to the floor (like collect): a share gets more expensive
        vm.prank(whale); IERC20(GLD).transfer(address(k), 1e18);
        vm.prank(alice); uint256 out = k.redeem(s, true, 0);
        assertApproxEqAbs(out, 10.8e18, 1e7, "floor + donation, all to the only holder (dead shares keep dust)");
    }

    function test_launch_token_from_pot_gld() public {
        Kicker k = _pot();
        vm.deal(bob, 1 ether);
        vm.startPrank(PM); IERC20(GLD).transfer(bob, 2e18); vm.stopPrank();
        uint256 fee = k.PONS().launchFee();
        vm.startPrank(bob);
        IERC20(GLD).approve(address(k), 0.4e18);
        (address token, address curve) = k.launch{value: fee}("banana", "BNN", "", "a pot launched this", "", "", 200, 0.4e18);
        vm.stopPrank();
        console2.log("token", token); console2.log("curve", curve);
        IPonsFactory.LaunchedToken memory L = k.PONS().getLaunchedToken(token);
        assertEq(L.creatorFeeRecipient, address(k), "tax recipient = pot");
        assertEq(L.pairToken, GLD); assertEq(L.creatorTaxBps, 200);
        assertGt(IERC20(token).balanceOf(bob), 0, "dev-buy landed with the builder, not taxed 99%");
        assertEq(IERC20(token).balanceOf(address(k)), 0, "pot keeps none of its own token");
        assertEq(k.launchedCount(), 1);
        // name with the suffix
        (bool ok, bytes memory d) = token.staticcall(abi.encodeWithSignature("name()")); assertTrue(ok);
        assertEq(abi.decode(d, (string)), "banana by kicker");
        // creator only
        // v0.3.3: launch is open to anyone (see test_anyone_can_launch_from_pot)
        // token trades → 2% tax → collect() sweeps the curve and pulls the escrow onto the floor (in GLD)
        vm.startPrank(whale); IERC20(GLD).approve(curve, 5e18); IPonsCurve(curve).buy(5e18, 0, whale); vm.stopPrank();
        (uint256 floor0,,) = k.nav();
        uint256 got = k.collect();
        (uint256 floor1,,) = k.nav();
        console2.log("collected GLD", got); console2.log("floor before/after", floor0, floor1);
        assertGt(got, 0, "creator tax reached the pot floor");
        assertEq(floor1 - floor0, got);
    }

    function test_collect_does_not_break_when_empty() public {
        Kicker k = _pot();
        try k.collect() returns (uint256 got) { assertEq(got, 0); } catch { /* the escrow may revert on zero - that is fine */ }
    }

    receive() external payable {}
}

// ETH core: native paths of the curve and the pool
contract KickerEthForkTest is Test {
    address constant PIKACHU = 0x4BE69DcB06f53F42F66317C7B1Cf12e095267Da4;   // graduated, ETH (hold)
    address constant SIDEBET = 0x18a66C43c93e73Be5071D71996781854aD406ec4;   // graduated, ETH (hold)
    address constant STACK = 0x3Bd73A113B6543402e30A6fb48B79CB006d039aC;     // curve, ETH (position)
    KickerFactory f;
    address platform = makeAddr("platform");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public { f = new KickerFactory(platform, makeAddr("keeper")); vm.deal(alice, 10 ether); vm.deal(bob, 10 ether); }

    function test_eth_core_full_cycle() public {
        address[] memory t = new address[](3); t[0] = PIKACHU; t[1] = SIDEBET; t[2] = STACK;
        uint16[] memory w = new uint16[](3); w[0] = 4000; w[1] = 4000; w[2] = 2000;
        uint8[] memory h = new uint8[](3); h[0] = 0; h[1] = 0; h[2] = 2;
        Kicker k = Kicker(payable(f.create(address(0), t, w, h, 500, 1800, "eth pot", "ETH/K")));
        vm.prank(alice); uint256 s1 = k.buy{value: 1 ether}(1 ether, bob, 0);
        assertEq(s1, 0.98 ether - 1e6); assertEq(bob.balance, 10 ether + 0.005 ether, "ref in eth"); assertEq(platform.balance, 0.005 ether);
        (uint256 c, uint256[] memory nl, uint256 s) = k.nav();
        console2.log("core", c); console2.log("pika", nl[0]); console2.log("sidebet", nl[1]); console2.log("stack", nl[2]); console2.log("sleeve", s);
        assertApproxEqRel(c, 0.931 ether, 0.01e18);
        assertGt(nl[0], 0); assertGt(nl[1], 0); assertGt(nl[2], 0);
        vm.warp(block.timestamp + 1801 + 1 days);   // a day past the deadline: anyone may clip
        uint256 out = k.clip(2, 0); assertGt(out, 0, "stack clipped by timer into eth");
        uint256 a0 = alice.balance;
        vm.prank(alice); uint256 red = k.redeem(s1, true, 0);
        assertEq(alice.balance - a0, red);
        assertGt(red, 0.96 ether, "round trip in eth");
    }

    /// v0.5 terms on an ETH floor: launch with dev buy, tax accrues in the split, withdraw and burn in ETH, invariant bal == held + owed
    function test_eth_terms_cycle() public {
        address[] memory t = new address[](0); uint16[] memory w = new uint16[](0); uint8[] memory h = new uint8[](0);
        Kicker k = Kicker(payable(f.create(address(0), t, w, h, 100, 1800, "eth floor", "EF/K")));
        vm.prank(alice); k.buy{value: 1 ether}(1 ether, address(0), 0);
        address mallory = makeAddr("mallory"); vm.deal(mallory, 2 ether);
        uint256 fee = k.PONS().launchFee();
        vm.prank(mallory); (address token, address curve) = k.launchWithTerms{value: fee + 0.05 ether}("e", "E", "", "", "", "", 300, 0.05 ether, 4000, 3000);
        assertGt(IERC20(token).balanceOf(mallory), 0, "dev buy delivered");
        vm.prank(bob); IPonsCurve(curve).buy{value: 0.5 ether}(0.5 ether, 0, bob);
        (uint256 f0,,) = k.nav();
        vm.prank(alice); uint256 got = k.collect();
        (uint256 f1,,) = k.nav();
        (, address split,,,) = k.terms(token);
        uint256 owed = TaxSplit(payable(split)).launcherOwed(); uint256 held = TaxSplit(payable(split)).burnHeld();
        assertEq(split.balance, owed + held, "split holds exactly owed + held");
        assertGt(got, 0); assertEq(f1 - f0, got); assertApproxEqRel(owed, got * 4000 / 2000, 0.001e18, "40 : 20"); assertApproxEqRel(held, got * 3000 / 2000, 0.001e18, "30 : 20");
        uint256 m0 = mallory.balance; vm.prank(mallory); TaxSplit(payable(split)).withdraw(mallory); assertEq(mallory.balance - m0, owed);
        address keeper = f.keeper(); uint256 sup0 = IERC20Supply(token).totalSupply();
        vm.prank(keeper); (uint256 coreIn, uint256 burned) = k.burn(token, 0);
        (uint256 f2,,) = k.nav();
        assertEq(f2, f1, "burn never moves the floor"); assertGt(burned, 0); assertEq(sup0 - IERC20Supply(token).totalSupply(), burned, "burned out of the supply");
        assertEq(split.balance, TaxSplit(payable(split)).burnHeld() + TaxSplit(payable(split)).launcherOwed(), "invariant after burn");
        assertLe(coreIn, held);
    }

    receive() external payable {}
}

contract FeeRouterForkTest is Test {
    address constant GLD = 0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e;
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    function test_route_only_to_pots() public {
        KickerFactory f = new KickerFactory(makeAddr("platform"), makeAddr("keeper"));
        address[] memory t = new address[](0); uint16[] memory w = new uint16[](0); uint8[] memory m = new uint8[](0);
        address pot = f.create(GLD, t, w, m, 100, 1800, "a", "A/K"); address pot2 = f.create(GLD, t, w, m, 100, 1800, "b", "B/K");
        address[] memory fs = new address[](1); fs[0] = address(f);
        vm.expectRevert(bytes("not a pot")); new FeeRouter(fs, makeAddr("wallet"));
        FeeRouter r = new FeeRouter(fs, pot);
        vm.prank(PM); IERC20(GLD).transfer(address(r), 1e18);
        assertEq(r.route(GLD), 1e18); assertEq(IERC20(GLD).balanceOf(pot), 1e18);
        vm.deal(address(r), 0.5 ether); vm.expectRevert(bytes("asset != core")); r.route(address(0));   // a foreign asset is never routed into the pot
        vm.expectRevert(bytes("not a pot")); r.setTarget(makeAddr("wallet"));
        vm.prank(makeAddr("x")); vm.expectRevert(bytes("owner")); r.setTarget(pot2);
        r.setTarget(pot2);
        vm.prank(PM); IERC20(GLD).transfer(address(r), 2e18);
        r.route(GLD); assertEq(IERC20(GLD).balanceOf(pot2), 2e18);
    }
}

/// v0.3.2 regressions from the adversarial review of 14.09: three HIGHs with fork PoCs, each must revert now
contract KickerV032RegressionTest is Test {
    address constant GLD = 0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e;
    address constant FRESH = 0x080146fb5699885C59F181BAC62730a0a42A9b7A;
    address constant FRESH_CURVE = 0xd9399437833Fdf55B6aa70b49AE2c52eB18F08C1;
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    KickerFactory f;
    address platform = makeAddr("platform");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address whale = makeAddr("whale");
    address mallory = makeAddr("mallory");

    function setUp() public {
        f = new KickerFactory(platform, keeper);
        vm.startPrank(PM);
        IERC20(GLD).transfer(alice, 100e18); IERC20(GLD).transfer(mallory, 500e18); IERC20(GLD).transfer(whale, 200e18);
        vm.stopPrank();
    }

    function _gradPot(uint8 mode, uint16 kick) internal returns (Kicker k) {
        address[] memory t = new address[](1); t[0] = FRESH;
        uint16[] memory w = new uint16[](1); w[0] = 10000;
        uint8[] memory h = new uint8[](1); h[0] = mode;
        vm.prank(bob);
        k = Kicker(payable(f.create(GLD, t, w, h, kick, 600, "p", "P")));
    }

    /// 1. the "graduated, no pool yet" window: buy reverts, redeem to core pays the leg in kind; once the pool exists everything works
    function test_graduation_window_buy_reverts_redeem_in_kind() public {
        Kicker k = _gradPot(1, 5000);
        vm.startPrank(alice); IERC20(GLD).approve(address(k), 10e18); uint256 sa = k.buy(10e18, address(0), 0); vm.stopPrank();
        vm.startPrank(whale); IERC20(GLD).approve(FRESH_CURVE, 40e18); IPonsCurve(FRESH_CURVE).buy(40e18, 0, whale); vm.stopPrank();
        assertTrue(IPonsCurve(FRESH_CURVE).graduated()); assertEq(k.priceInCore(0), 0, "no pool yet");
        vm.startPrank(mallory); IERC20(GLD).approve(address(k), 100e18);
        vm.expectRevert(bytes("pool pending")); k.buy(100e18, address(0), 0);
        vm.stopPrank();
        // redeem to core in the window: the leg in kind, not silently left in the pot
        uint256 half = sa / 2; uint256 f0 = IERC20(FRESH).balanceOf(alice);
        vm.prank(alice); k.redeem(half, true, 0);
        assertGt(IERC20(FRESH).balanceOf(alice) - f0, 0, "unsellable leg handed over in kind");
        (bool ok,) = address(k.PONS()).call(abi.encodeWithSignature("createGraduatedPool(address)", FRESH)); assertTrue(ok);
        assertGt(k.priceInCore(0), 0);
        vm.startPrank(mallory); uint256 sm = k.buy(100e18, address(0), 0); vm.stopPrank();
        assertGt(sm, 0, "buys resume once the pool exists");
        uint256 a0 = IERC20(GLD).balanceOf(alice);
        vm.prank(alice); k.redeem(sa - half, true, 0);
        assertGt(IERC20(GLD).balanceOf(alice) - a0, 4e18, "alice keeps her leg exposure");
    }

    /// 3. first depositor: 1 wei reverts; a donation does not break the share price for the next one
    function test_first_depositor_and_donation_harmless() public {
        address[] memory t = new address[](0); uint16[] memory w = new uint16[](0); uint8[] memory h = new uint8[](0);
        Kicker k = Kicker(payable(f.create(GLD, t, w, h, 100, 600, "floor", "F")));
        vm.startPrank(mallory); IERC20(GLD).approve(address(k), type(uint256).max);
        vm.expectRevert(bytes("dust")); k.buy(1, address(0), 0);
        uint256 sm = k.buy(1e12 * 2, address(0), 0);           // minimum deposit
        IERC20(GLD).transfer(address(k), 10e18);                // donation
        vm.stopPrank();
        vm.startPrank(alice); IERC20(GLD).approve(address(k), type(uint256).max);
        uint256 sa = k.buy(10e18, address(0), 0);              // used to revert with "slippage"
        vm.stopPrank();
        assertGt(sa, 1e6, "shares stay fine-grained after a donation");
        uint256 a0 = IERC20(GLD).balanceOf(alice);
        vm.prank(alice); k.redeem(sa, true, 0);
        assertApproxEqRel(IERC20(GLD).balanceOf(alice) - a0, 9.8e18, 0.001e18, "alice gets her own money back, not less");
        vm.prank(mallory); k.redeem(sm, true, 0);
        assertLt(IERC20(GLD).balanceOf(mallory), 500e18, "the donor did not profit from the donation");
    }

    /// 3b. every holder left, tax landed on the floor: the next depositor gets shares fairly, not the whole floor for 1 wei
    function test_floor_without_holders_not_captured() public {
        address[] memory t = new address[](0); uint16[] memory w = new uint16[](0); uint8[] memory h = new uint8[](0);
        Kicker k = Kicker(payable(f.create(GLD, t, w, h, 100, 600, "floor", "F")));
        vm.startPrank(alice); IERC20(GLD).approve(address(k), type(uint256).max); uint256 sa = k.buy(1e18, address(0), 0); k.redeem(sa, true, 0); vm.stopPrank();
        assertEq(k.totalSupply(), 1e6, "dead shares remain");
        vm.prank(whale); IERC20(GLD).transfer(address(k), 5e18);   // like collect() after everyone left
        vm.startPrank(mallory); IERC20(GLD).approve(address(k), type(uint256).max);
        vm.expectRevert(bytes("slippage")); k.buy(1e12 * 2, address(0), 0);   // dust: shares would round to zero, revert instead of gifting the floor
        uint256 sm = k.buy(1e18, address(0), 0);
        uint256 m0 = IERC20(GLD).balanceOf(mallory); k.redeem(sm, true, 0); vm.stopPrank();
        assertApproxEqRel(IERC20(GLD).balanceOf(mallory) - m0, 0.98e18, 0.001e18, "1 GLD in, 0.98 out: the 5 GLD floor stays with the dead shares, not the buyer");
    }

    /// 2. clip: a stranger cannot (sandwich closed); the keeper can; a timer leg a day later - anyone
    function test_clip_gated_to_keeper_and_creator() public {
        Kicker k = _gradPot(2, 5000);
        vm.startPrank(alice); IERC20(GLD).approve(address(k), 20e18); k.buy(20e18, address(0), 0); vm.stopPrank();
        vm.warp(block.timestamp + 601);
        vm.prank(mallory); vm.expectRevert(bytes("clipper only")); k.clip(0, 0);
        assertFalse(k.canClip(mallory, 0)); assertTrue(k.canClip(keeper, 0)); assertFalse(k.canClip(bob, 0), "creator is a stranger to holders too");
        vm.prank(bob); vm.expectRevert(bytes("clipper only")); k.clip(0, 0);
        vm.warp(block.timestamp + 1 days);
        assertTrue(k.canClip(mallory, 0), "grace over: anyone");
        vm.prank(keeper); uint256 out = k.clip(0, 0); assertGt(out, 0);
    }

    /// fees on the amount invested: no fee on the refund from a thin curve
    function test_fees_not_charged_on_refund() public {
        Kicker k = _gradPot(0, 5000);
        vm.startPrank(alice); IERC20(GLD).approve(address(k), 100e18); k.buy(1e18, address(0), 0);
        uint256 c0 = IERC20(GLD).balanceOf(bob); uint256 p0 = IERC20(GLD).balanceOf(platform); uint256 a0 = IERC20(GLD).balanceOf(alice);
        k.buy(60e18, address(0), 0);   // 50% sleeve on the curve: the leg is capped, part of the floor comes back
        vm.stopPrank();
        uint256 spent = a0 - IERC20(GLD).balanceOf(alice);
        uint256 fee = IERC20(GLD).balanceOf(bob) - c0 + IERC20(GLD).balanceOf(platform) - p0;
        assertLt(spent, 60e18, "part refunded");
        assertApproxEqRel(fee, spent * 200 / 1e4, 0.02e18, "2% of what stayed invested, not of 60"); assertLt(fee, 60e18 * 200 / 1e4, "less than 2% of the gross");
    }

    /// N1: moveTax trusts only the factory registry, not the target's answer
    function test_moveTax_only_to_known_kicker() public {
        address[] memory t = new address[](0); uint16[] memory w = new uint16[](0); uint8[] memory h = new uint8[](0);
        vm.prank(bob); Kicker k = Kicker(payable(f.create(GLD, t, w, h, 100, 600, "a", "A")));
        vm.deal(bob, 1 ether); vm.startPrank(bob); IERC20(GLD).approve(address(k), 0);
        (address tok,) = k.launch{value: k.PONS().launchFee()}("x", "X", "", "", "", "", 100, 0);
        FakePot fake = new FakePot(GLD, platform);
        vm.stopPrank();
        vm.prank(keeper); vm.expectRevert(bytes("not a kicker")); k.moveTax(tok, address(fake));
        KickerFactory f2 = new KickerFactory(platform, keeper);   // "a new version"
        address pot2 = f2.create(GLD, t, w, h, 100, 600, "b", "B");
        vm.prank(keeper); vm.expectRevert(bytes("not a kicker")); k.moveTax(tok, pot2);   // not trusted yet
        f.addTrusted(address(f2));
        vm.prank(bob); vm.expectRevert(bytes("keeper only")); k.moveTax(tok, pot2);   // v0.3.4: the creator cannot
        vm.prank(keeper); k.moveTax(tok, pot2);
        assertEq(k.PONS().getLaunchedToken(tok).creatorFeeRecipient, pot2, "tax moved to the trusted new pot");
    }

    /// v0.3.3: anyone may launch from a pot; the tax goes to the pot, the dev buy to the launcher
    function test_anyone_can_launch_from_pot() public {
        address[] memory t = new address[](0); uint16[] memory w = new uint16[](0); uint8[] memory h = new uint8[](0);
        vm.prank(bob); Kicker k = Kicker(payable(f.create(GLD, t, w, h, 100, 600, "a", "A")));
        vm.deal(mallory, 1 ether);
        vm.startPrank(mallory); IERC20(GLD).approve(address(k), 1e18);
        uint256 fee = k.PONS().launchFee();
        vm.expectRevert(bytes("reserved")); k.launch{value: fee}("fake", "KICKER", "", "", "", "", 200, 0);
        vm.stopPrank(); vm.deal(keeper, 1 ether); vm.prank(keeper); (address real,) = k.launch{value: fee}("kicker", "KICKER", "", "", "", "", 100, 0); assertTrue(real != address(0), "keeper launches the real one");
        vm.startPrank(mallory);
        (address tok,) = k.launch{value: fee}("stranger", "STR", "", "", "", "", 200, 1e18);
        vm.stopPrank();
        assertEq(k.PONS().getLaunchedToken(tok).creatorFeeRecipient, address(k), "pot takes the tax");
        assertGt(IERC20(tok).balanceOf(mallory), 0, "dev buy went to the launcher");
        assertEq(k.launchedCount(), 2);
        k.collectRange(0, 1);
    }
}

contract FakePot {
    address public core; address public platform; address public factory;
    constructor(address c, address p) { core = c; platform = p; factory = address(this); }
    function isKicker(address) external pure returns (bool) { return true; }
    function knownKicker(address) external pure returns (bool) { return true; }
    function keeper() external pure returns (address) { return address(0); }
}

contract KickerTaxModeTest is KickerForkTest {
    function _taxPot() internal returns (Kicker k) {
        address[] memory t = new address[](1); t[0] = UBIK;   // one hold leg in a pool: a market buy is always possible
        uint16[] memory w = new uint16[](1); w[0] = 10000;
        uint8[] memory h = new uint8[](1); h[0] = 0;
        vm.prank(bob);
        k = Kicker(payable(f.createWithTax(GLD, t, w, h, 5000, 1800, "kicker pot x", "KICKX/K", true)));
        assertTrue(k.taxToLegs());
    }

    function test_tax_mode_needs_legs() public {
        address[] memory t = new address[](0); uint16[] memory w = new uint16[](0); uint8[] memory h = new uint8[](0);
        vm.expectRevert(bytes("tax mode needs legs"));
        f.createWithTax(GLD, t, w, h, 100, 1800, "x", "X", true);
        // without the flag as before: pure floor
        Kicker k = Kicker(payable(f.create(GLD, t, w, h, 100, 1800, "x", "X")));
        assertFalse(k.taxToLegs());
    }

    function test_tax_mode_collect_buys_leg_by_kick() public {
        Kicker k = _taxPot();
        // first deposit so the pot is not empty (otherwise the tax goes to the first depositor)
        vm.startPrank(alice); IERC20(GLD).approve(address(k), 2e18); k.buy(2e18, address(0), 0); vm.stopPrank();
        // launch from the pot and trade → tax in the escrow
        vm.deal(bob, 1 ether); vm.startPrank(PM); IERC20(GLD).transfer(bob, 2e18); vm.stopPrank();
        uint256 fee = k.PONS().launchFee();
        vm.startPrank(bob); IERC20(GLD).approve(address(k), 0.4e18);
        (, address curve) = k.launch{value: fee}("banana", "BNN", "", "", "", "", 200, 0.4e18);
        vm.stopPrank();
        vm.startPrank(whale); IERC20(GLD).approve(curve, 5e18); IPonsCurve(curve).buy(5e18, 0, whale); vm.stopPrank();
        // a stranger's collect reverts in this mode
        vm.prank(alice); vm.expectRevert(bytes("creator or keeper")); k.collect();
        uint256 ubik0 = IERC20(UBIK).balanceOf(address(k));
        (uint256 floor0,,) = k.nav();
        vm.prank(bob); uint256 got = k.collect();
        (uint256 floor1,,) = k.nav();
        uint256 ubik1 = IERC20(UBIK).balanceOf(address(k));
        console2.log("collected", got); console2.log("floor delta", floor1 - floor0); console2.log("ubik bought", ubik1 - ubik0);
        assertGt(got, 0, "tax collected");
        assertGt(ubik1, ubik0, "half of the tax bought the leg");
        assertApproxEqRel(floor1 - floor0, got / 2, 0.02e18, "half of the tax stayed on the floor");
        // the keeper can too
        vm.prank(keeper); k.collect();
    }

    function test_tax_mode_no_holders_reverts_and_stays_in_escrow() public {
        Kicker k = _taxPot();   // nobody bought shares
        vm.deal(bob, 1 ether); vm.startPrank(PM); IERC20(GLD).transfer(bob, 2e18); vm.stopPrank();
        uint256 fee = k.PONS().launchFee();
        vm.startPrank(bob); IERC20(GLD).approve(address(k), 0.4e18);
        (, address curve) = k.launch{value: fee}("banana", "BNN", "", "", "", "", 200, 0.4e18);
        vm.stopPrank();
        vm.startPrank(whale); IERC20(GLD).approve(curve, 5e18); IPonsCurve(curve).buy(5e18, 0, whale); vm.stopPrank();
        vm.prank(bob); vm.expectRevert(bytes("no holders")); k.collect();
        // the first depositor enters, now the tax can be collected and is shared
        vm.startPrank(alice); IERC20(GLD).approve(address(k), 1e18); k.buy(1e18, address(0), 0); vm.stopPrank();
        vm.prank(bob); uint256 got = k.collect(); assertGt(got, 0);
    }

    function test_tax_mode_open_collect_when_nothing_buyable() public {
        // a curve leg in the pre-graduation window cannot be bought → nothing to buy → collect is open to anyone, tax to the floor
        address[] memory t = new address[](1); t[0] = FRESH;
        uint16[] memory w = new uint16[](1); w[0] = 10000;
        uint8[] memory h = new uint8[](1); h[0] = 0;
        vm.prank(bob); Kicker k = Kicker(payable(f.createWithTax(GLD, t, w, h, 5000, 1800, "x", "X", true)));
        vm.startPrank(alice); IERC20(GLD).approve(address(k), 1e18); k.buy(1e18, address(0), 0); vm.stopPrank();
        // push the FRESH curve to readyToGraduate: then _buyable = false
        uint256 need = k.PONS().getLaunchedToken(FRESH).graduationThreshold;
        vm.startPrank(PM); IERC20(GLD).approve(FRESH_CURVE, need); try IPonsCurve(FRESH_CURVE).buy(need, 0, PM) {} catch {} vm.stopPrank();
        if (IPonsCurve(FRESH_CURVE).readyToGraduate() || IPonsCurve(FRESH_CURVE).graduated()) {
            vm.prank(carol); try k.collect() {} catch Error(string memory r) { assertTrue(keccak256(bytes(r)) != keccak256("creator or keeper"), "must be open when nothing buyable"); }
        }
    }

    function test_tax_mode_curve_leg_with_tax_gets_bought() public {
        // a curve leg with tax (FRESH, while still on the curve): the slippage check must account for the leg's fee and tax
        if (IPonsCurve(FRESH_CURVE).graduated() || IPonsCurve(FRESH_CURVE).readyToGraduate()) return;
        address[] memory t = new address[](1); t[0] = FRESH;
        uint16[] memory w = new uint16[](1); w[0] = 10000;
        uint8[] memory h = new uint8[](1); h[0] = 0;
        vm.prank(bob); Kicker k = Kicker(payable(f.createWithTax(GLD, t, w, h, 5000, 1800, "x", "X", true)));
        vm.startPrank(alice); IERC20(GLD).approve(address(k), 1e18); k.buy(1e18, address(0), 0); vm.stopPrank();
        vm.deal(bob, 1 ether); vm.startPrank(PM); IERC20(GLD).transfer(bob, 2e18); vm.stopPrank();
        uint256 fee = k.PONS().launchFee();
        vm.startPrank(bob); IERC20(GLD).approve(address(k), 0.4e18);
        (, address curve) = k.launch{value: fee}("banana", "BNN", "", "", "", "", 200, 0.4e18);
        vm.stopPrank();
        vm.startPrank(whale); IERC20(GLD).approve(curve, 5e18); IPonsCurve(curve).buy(5e18, 0, whale); vm.stopPrank();
        uint256 leg0 = IERC20(FRESH).balanceOf(address(k));
        vm.prank(bob); uint256 got = k.collect();
        uint256 leg1 = IERC20(FRESH).balanceOf(address(k));
        console2.log("collected", got); console2.log("fresh leg bought", leg1 - leg0);
        assertGt(got, 0); assertGt(leg1, leg0, "curve leg with fee+tax must still be bought within the bound");
    }

    function test_tax_mode_kicker_pool_leg_like_kickx() public {
        // like KICKX/K: a $KICKER leg in a thin v4 pool (~$7k), 3.5 GLD of tax → a 1.75 GLD buy must pass the 20% bound
        address KICKER = 0x8a4B4202DCb9D5519cfe20829d526E06f5F3e32A;
        address[] memory t = new address[](1); t[0] = KICKER;
        uint16[] memory w = new uint16[](1); w[0] = 10000;
        uint8[] memory h = new uint8[](1); h[0] = 0;
        vm.prank(bob); Kicker k = Kicker(payable(f.createWithTax(GLD, t, w, h, 5000, 1800, "kicker pot x", "KICKX/K", true)));
        vm.startPrank(alice); IERC20(GLD).approve(address(k), 1e18); k.buy(1e18, address(0), 0); vm.stopPrank();
        vm.deal(bob, 1 ether); vm.startPrank(PM); IERC20(GLD).transfer(bob, 2e18); vm.stopPrank();
        uint256 fee = k.PONS().launchFee();
        vm.startPrank(bob); IERC20(GLD).approve(address(k), 0.4e18);
        (, address curve) = k.launch{value: fee}("banana", "BNN", "", "", "", "", 200, 0.4e18);
        vm.stopPrank();
        vm.startPrank(whale); IERC20(GLD).approve(curve, 5e18); IPonsCurve(curve).buy(5e18, 0, whale); vm.stopPrank();
        uint256 leg0 = IERC20(KICKER).balanceOf(address(k)); (uint256 floor0,,) = k.nav();
        vm.prank(bob); uint256 got = k.collect();
        uint256 leg1 = IERC20(KICKER).balanceOf(address(k)); (uint256 floor1,,) = k.nav();
        console2.log("collected", got); console2.log("kicker bought", leg1 - leg0); console2.log("floor delta", floor1 - floor0);
        assertGt(leg1, leg0, "tax bought KICKER in the v4 pool");
        assertApproxEqRel(floor1 - floor0, got / 2, 0.02e18);
    }

    function test_floor_mode_collect_open_to_anyone() public {
        Kicker k = _pot();   // a plain pot without the flag
        vm.prank(alice); try k.collect() {} catch { revert("floor mode collect must not revert on caller"); }
    }

    // ---- v0.5 launcher terms ----
    address constant DEADADDR = 0x000000000000000000000000000000000000dEaD;
    function _supply(address t) internal view returns (uint256) { return IERC20Supply(t).totalSupply(); }   // v0.7.3: a burn lowers totalSupply, nothing goes to dead

    function _info(address token) internal view returns (address curve, int24 ts, uint8 phase) { IPonsFactory.LaunchedToken memory L = IPonsFactory(0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e).getLaunchedToken(token); return (L.curve, L.tickSpacing, L.phase); }
    function _floorPot() internal returns (Kicker k) {
        address[] memory t = new address[](0); uint16[] memory w = new uint16[](0); uint8[] memory h = new uint8[](0);
        vm.prank(bob); k = Kicker(payable(f.create(GLD, t, w, h, 100, 1800, "floor", "FLR/K")));
        vm.startPrank(alice); IERC20(GLD).approve(address(k), 2e18); k.buy(2e18, address(0), 0); vm.stopPrank();
    }

    function _launchTerms(Kicker k, address who, uint16 creatorBps, uint16 burnBps) internal returns (address token, address curve) {
        vm.deal(who, 1 ether); vm.startPrank(PM); IERC20(GLD).transfer(who, 1e18); vm.stopPrank();
        uint256 fee = k.PONS().launchFee();
        vm.startPrank(who); IERC20(GLD).approve(address(k), 0.2e18);
        (token, curve) = k.launchWithTerms{value: fee}("terms", "TRM", "", "", "", "", 300, 0.2e18, creatorBps, burnBps);
        vm.stopPrank();
    }

    function test_terms_split_pays_launcher_platform_burn_floor() public {
        Kicker k = _floorPot();
        (address token, address curve) = _launchTerms(k, mallory, 3000, 2000);
        (address launcher, address split, uint16 cb, uint16 bb,) = k.terms(token);
        assertEq(launcher, mallory); assertEq(cb, 3000); assertEq(bb, 2000); assertTrue(split != address(0));
        assertEq(k.PONS().getLaunchedToken(token).creatorFeeRecipient, split, "recipient is the split");
        // trade -> 3% tax
        vm.startPrank(whale); IERC20(GLD).approve(curve, 5e18); IPonsCurve(curve).buy(5e18, 0, whale); vm.stopPrank();
        uint256 m0 = IERC20(GLD).balanceOf(mallory); uint256 p0 = IERC20(GLD).balanceOf(platform);
        (uint256 floor0,,) = k.nav();
        vm.prank(alice); uint256 got = k.collect();   // floor pot: open to anyone
        (uint256 floor1,,) = k.nav();
        // the launcher's share is pulled, not pushed: nothing moved to mallory yet, withdraw() pays it out
        assertEq(IERC20(GLD).balanceOf(mallory), m0, "no push to the launcher inside collect");
        vm.prank(alice); vm.expectRevert(bytes("launcher only")); TaxSplit(payable(split)).withdraw(alice);
        vm.prank(mallory); TaxSplit(payable(split)).withdraw(mallory);
        uint256 m = IERC20(GLD).balanceOf(mallory) - m0; uint256 pl = IERC20(GLD).balanceOf(platform) - p0; uint256 held = k.burnOwed(token);
        uint256 total = m + pl + held + got;
        console2.log("total tax", total); console2.log("launcher", m); console2.log("platform", pl); console2.log("burn held", held); console2.log("floor", got);
        assertGt(total, 0, "tax reached the split");
        assertApproxEqRel(m, total * 3000 / 1e4, 0.001e18, "30% to the launcher");
        assertApproxEqRel(pl, total * 1000 / 1e4, 0.001e18, "10% to the platform");
        assertApproxEqRel(held, total * 2000 / 1e4, 0.001e18, "20% held for the burn");
        assertEq(floor1 - floor0, got, "the rest is floor");
        assertApproxEqRel(got, total * 4000 / 1e4, 0.001e18, "40% to the floor");
        // burn: keeper only (the builder is a stranger to the launcher's terms); after a week anyone
        vm.prank(alice); vm.expectRevert(bytes("keeper only")); k.burn(token, 0);
        vm.prank(bob); vm.expectRevert(bytes("keeper only")); k.burn(token, 0);
        assertFalse(k.canBurn(alice, token)); vm.warp(block.timestamp + 7 days); assertTrue(k.canBurn(alice, token)); vm.warp(block.timestamp - 7 days);
        uint256 dead0 = IERC20(token).balanceOf(DEADADDR); uint256 sup0 = _supply(token);
        (uint256 f0,,) = k.nav();
        vm.prank(keeper); (uint256 coreIn, uint256 burned) = k.burn(token, 0);
        (uint256 f1,,) = k.nav();
        assertEq(coreIn, held); assertGt(burned, 0);
        assertEq(sup0 - _supply(token), burned, "burned out of the supply"); assertEq(IERC20(token).balanceOf(DEADADDR), dead0, "nothing to dead");
        assertEq(IERC20(token).balanceOf(address(k)), 0, "pot keeps none");
        assertEq(f1, f0, "the burn budget never touches the floor");
        assertEq(k.burnOwed(token), 0);
        vm.prank(keeper); vm.expectRevert(bytes("nothing to burn")); k.burn(token, 0);
    }

    // ---- v0.6: the burn budget may target the pot's own kicker coin instead of the launched token ----
    function test_terms_burn_target_kicker_like_kickb() public {
        address KICKER = 0x8a4B4202DCb9D5519cfe20829d526E06f5F3e32A;
        address[] memory t = new address[](1); t[0] = KICKER;
        uint16[] memory w = new uint16[](1); w[0] = 10000;
        uint8[] memory h = new uint8[](1); h[0] = 0;
        vm.prank(bob); Kicker k = Kicker(payable(f.createWithTax(GLD, t, w, h, 5000, 1800, "kicker pot b", "KICKB/K", true)));
        vm.startPrank(alice); IERC20(GLD).approve(address(k), 1e18); k.buy(1e18, address(0), 0); vm.stopPrank();
        vm.deal(mallory, 1 ether); vm.startPrank(PM); IERC20(GLD).transfer(mallory, 1e18); vm.stopPrank();
        uint256 fee = k.PONS().launchFee();
        // a target that is not a pons token of this pair is refused; burnBps 0 with a target is refused
        vm.startPrank(mallory); IERC20(GLD).approve(address(k), 0.4e18);
        vm.expectRevert(bytes("pair")); k.launchWithTermsTarget{value: fee}("t", "T", "", "", "", "", 300, 0.2e18, 4000, 3000, address(0xBEEF));
        vm.expectRevert(bytes("target")); k.launchWithTermsTarget{value: fee}("t", "T", "", "", "", "", 300, 0.2e18, 4000, 0, KICKER);
        (address token, address curve) = k.launchWithTermsTarget{value: fee}("terms t", "TRT", "", "", "", "", 300, 0.2e18, 4000, 3000, KICKER);
        vm.stopPrank();
        (,,,, address target) = k.terms(token); assertEq(target, KICKER, "burn target recorded");
        vm.startPrank(whale); IERC20(GLD).approve(curve, 5e18); IPonsCurve(curve).buy(5e18, 0, whale); vm.stopPrank();
        uint256 leg0 = IERC20(KICKER).balanceOf(address(k)); (uint256 floor0,,) = k.nav();
        vm.prank(bob); uint256 got = k.collect();   // tax mode: builder or keeper
        uint256 leg1 = IERC20(KICKER).balanceOf(address(k)); (uint256 floor1,,) = k.nav();
        assertGt(got, 0); assertGt(leg1, leg0, "the floor part of the tax still buys KICKER into the leg");
        assertApproxEqRel(floor1 - floor0, got / 2, 0.02e18, "half of the floor part stays gold");
        uint256 held = k.burnOwed(token); assertGt(held, 0, "30% held for the burn");
        // burn buys KICKER, not the launched token, and sends it to dead; the leg and the floor do not move
        uint256 supK0 = _supply(KICKER); uint256 deadT0 = IERC20(token).balanceOf(DEADADDR); uint256 supT0 = _supply(token);
        uint256 legB = IERC20(KICKER).balanceOf(address(k)); (uint256 fB,,) = k.nav();
        vm.prank(keeper); (uint256 coreIn, uint256 burned) = k.burn(token, 0);
        assertEq(coreIn, held); assertGt(burned, 0);
        assertEq(supK0 - _supply(KICKER), burned, "KICKER burned out of its supply");
        assertEq(IERC20(token).balanceOf(DEADADDR), deadT0, "the launched token was not burned"); assertEq(_supply(token), supT0);
        assertEq(IERC20(KICKER).balanceOf(address(k)), legB, "the leg is untouched");
        (uint256 fA,,) = k.nav(); assertEq(fA, fB, "the floor is untouched");
        console2.log("collected", got); console2.log("kicker burned", burned); console2.log("burn budget", coreIn);
    }

    // ---- v0.7: the launcher collects its own token on a tax-mode pot; the pot's part lands on the floor, no leg buy ----
    function test_launcher_collects_own_token_on_tax_mode_pot() public {
        address KICKER = 0x8a4B4202DCb9D5519cfe20829d526E06f5F3e32A;
        address[] memory t = new address[](1); t[0] = KICKER; uint16[] memory w = new uint16[](1); w[0] = 10000; uint8[] memory h = new uint8[](1); h[0] = 0;
        vm.prank(bob); Kicker k = Kicker(payable(f.createWithTax(GLD, t, w, h, 5000, 1800, "kicker pot b", "KICKB/K", true)));
        vm.startPrank(alice); IERC20(GLD).approve(address(k), 1e18); k.buy(1e18, address(0), 0); vm.stopPrank();
        vm.deal(mallory, 1 ether); vm.startPrank(PM); IERC20(GLD).transfer(mallory, 1e18); vm.stopPrank();
        uint256 fee = k.PONS().launchFee();
        vm.startPrank(mallory); IERC20(GLD).approve(address(k), 0.2e18);
        (address token, address curve) = k.launchWithTerms{value: fee}("mine", "MINE", "", "", "", "", 300, 0.2e18, 4000, 0);
        vm.stopPrank();
        vm.startPrank(whale); IERC20(GLD).approve(curve, 5e18); IPonsCurve(curve).buy(5e18, 0, whale); vm.stopPrank();
        // the tax-mode gate keeps collect() for the builder/keeper, but the launcher may collect its own token
        vm.prank(mallory); vm.expectRevert(bytes("creator or keeper")); k.collect();
        vm.prank(alice); vm.expectRevert(bytes("launcher only")); k.collectToken(token);
        (uint256 floor0,,) = k.nav(); uint256 leg0 = IERC20(KICKER).balanceOf(address(k));
        vm.prank(mallory); uint256 got = k.collectToken(token);
        (uint256 floor1,,) = k.nav(); uint256 leg1 = IERC20(KICKER).balanceOf(address(k));
        assertGt(got, 0, "the floor part arrived"); assertEq(floor1 - floor0, got, "the floor part is on the floor"); assertEq(leg1, leg0, "no leg buy on the launcher's collect");
        assertGt(k.pendingKick(), 0, "the legs' share is set aside outside the floor"); assertApproxEqRel(k.pendingKick(), got, 0.001e18, "half and half at kick 50%");
        // floor per K did not move down for anyone and does not move on the keeper's feed either
        uint256 perK1 = floor1 * 1e18 / k.totalSupply();
        (, address split,,,) = k.terms(token); assertGt(TaxSplit(payable(split)).launcherOwed(), 0, "the launcher's share accrued without the keeper");
        vm.prank(mallory); TaxSplit(payable(split)).withdraw(mallory);
        // the keeper's next collect feeds the leg from what the launcher collected, even with nothing new in the escrow
        vm.prank(bob); k.collect();
        assertGt(IERC20(KICKER).balanceOf(address(k)), leg1, "the keeper's collect bought the leg from pendingKick"); assertEq(k.pendingKick(), 0);
        (uint256 floor2,,) = k.nav(); assertGe(floor2 * 1e18 / k.totalSupply(), perK1, "floor per K never dipped");
        // v0.7.2: a leaver takes its pro-rata of a set-aside; nothing hides from redeem
        vm.prank(mallory); k.collectToken(token);   // may be 0 fresh; set aside whatever came
        { uint256 pk0 = k.pendingKick(); uint256 half = k.balanceOf(alice) / 2; uint256 sup = k.totalSupply();
          vm.prank(alice); k.redeem(half, true, 0);
          assertApproxEqAbs(k.pendingKick(), pk0 - pk0 * half / sup, 2, "pendingKick shrank pro-rata with the redeem"); }
        // setLauncher moves the right to collect
        vm.prank(mallory); TaxSplit(payable(split)).setLauncher(alice);
        vm.prank(mallory); vm.expectRevert(bytes("launcher only")); k.collectToken(token);
        vm.prank(alice); k.collectToken(token);
    }

    /// v0.7: a burn target that has no market yet makes the burn wait instead of burning the launched token
    function test_burn_target_pending_waits() public {
        Kicker k = _floorPot();
        // launch a curve-stage coin to be the target of a second launch
        (address target,) = _launchTerms(k, bob, 0, 0);
        vm.deal(mallory, 1 ether); vm.startPrank(PM); IERC20(GLD).transfer(mallory, 1e18); vm.stopPrank();
        uint256 fee = k.PONS().launchFee();
        vm.startPrank(mallory); IERC20(GLD).approve(address(k), 0.2e18);
        (address token, address curve) = k.launchWithTermsTarget{value: fee}("t", "T", "", "", "", "", 300, 0.2e18, 0, 5000, target);
        vm.stopPrank();
        vm.startPrank(whale); IERC20(GLD).approve(curve, 5e18); IPonsCurve(curve).buy(5e18, 0, whale); vm.stopPrank();
        vm.prank(alice); k.collect();
        assertGt(k.burnOwed(token), 0);
        // a target in its graduation window has no market: the burn waits, the budget stays in the split
        (address tCurve,,) = _info(target);
        vm.mockCall(tCurve, abi.encodeWithSelector(IPonsCurve.readyToGraduate.selector), abi.encode(true));
        uint256 owed0 = k.burnOwed(token);
        vm.prank(keeper); vm.expectRevert(bytes("target pending")); k.burn(token, 0);
        assertEq(k.burnOwed(token), owed0, "budget untouched"); vm.clearMockedCalls();
        // happy path: the target burns, never the launched token
        uint256 deadT0 = IERC20(token).balanceOf(DEADADDR); uint256 supTg0 = _supply(target);
        vm.prank(keeper); (, uint256 burned) = k.burn(token, 0);
        assertEq(supTg0 - _supply(target), burned, "the target burned out of its supply"); assertEq(IERC20(token).balanceOf(DEADADDR), deadT0, "the launched token did not");
    }

    function test_terms_limits_and_no_move() public {
        Kicker k = _floorPot();
        vm.deal(mallory, 1 ether); vm.startPrank(PM); IERC20(GLD).transfer(mallory, 1e18); vm.stopPrank();
        uint256 fee = k.PONS().launchFee();
        vm.startPrank(mallory);
        vm.expectRevert(bytes("terms")); k.launchWithTerms{value: fee}("t", "T", "", "", "", "", 100, 0, 5000, 3001);
        vm.stopPrank();
        (address token,) = _launchTerms(k, mallory, 5000, 0);
        // moveTax refuses a token with terms even for the keeper
        address[] memory t = new address[](0); uint16[] memory w = new uint16[](0); uint8[] memory h = new uint8[](0);
        vm.prank(bob); address other = f.create(GLD, t, w, h, 100, 1800, "o", "O/K");
        vm.prank(keeper); vm.expectRevert(bytes("has terms")); k.moveTax(token, other);
        // a classic launch has no split and moves as before
        vm.deal(bob, 1 ether); vm.startPrank(bob);
        (address classic,) = k.launch{value: fee}("c", "C", "", "", "", "", 100, 0);
        vm.stopPrank();
        (, address split,,,) = k.terms(classic); assertEq(split, address(0));
        assertEq(k.PONS().getLaunchedToken(classic).creatorFeeRecipient, address(k));
        vm.prank(keeper); k.moveTax(classic, other);
        assertEq(k.PONS().getLaunchedToken(classic).creatorFeeRecipient, other);
    }

    function test_terms_burn_clamped_returns_unspent_to_split() public {
        Kicker k = _floorPot();
        (address token, address curve) = _launchTerms(k, mallory, 0, 8000);
        vm.startPrank(whale); IERC20(GLD).approve(curve, 50e18); IPonsCurve(curve).buy(5e18, 0, whale); vm.stopPrank();
        vm.prank(alice); k.collect();
        uint256 held = k.burnOwed(token); assertGt(held, 1e18, "big budget");
        // fill the curve to just under the threshold so the pot's buy gets clamped
        // pons clamps early buys per tx: fill in a loop after the launch window until 0.3 GLD of room is left
        vm.warp(block.timestamp + 1 hours);
        vm.startPrank(PM); IERC20(GLD).transfer(whale, 100e18); vm.stopPrank();
        vm.startPrank(whale); IERC20(GLD).approve(curve, 300e18);
        for (uint256 i; i < 60; i++) { uint256 room = IPonsCurve(curve).graduationThreshold() - IPonsCurve(curve).realQuoteReserve(); if (room <= 0.3e18) break; IPonsCurve(curve).buy(room - 0.3e18 > 5e18 ? 5e18 : room - 0.3e18, 0, whale); }
        vm.stopPrank();
        (uint256 f0,,) = k.nav();
        vm.prank(keeper); (uint256 coreIn, uint256 burned) = k.burn(token, 0);
        (uint256 f1,,) = k.nav();
        assertGt(burned, 0); assertLt(coreIn, held, "only the part the curve took counts");
        assertEq(f1, f0, "the unspent budget went back to the split, not to the floor");
        assertApproxEqAbs(k.burnOwed(token), held - coreIn, 1, "the rest waits for the next burn");
    }

    function test_terms_impl_locked_and_devbuy_refund() public {
        Kicker impl = Kicker(payable(f.impl()));
        vm.expectRevert(bytes("init")); impl.initialize(GLD, bob, 100, 1800, "x", "X", false);
        TaxSplit s = TaxSplit(payable(f.splitImpl()));
        vm.expectRevert(bytes("init")); s.initialize(address(this), bob, 1, 1);
        // an oversized dev buy: the curve takes what fits, the rest comes back to the launcher
        Kicker k = _floorPot();
        vm.deal(mallory, 1 ether); vm.startPrank(PM); IERC20(GLD).transfer(mallory, 40e18); vm.stopPrank();
        uint256 fee = k.PONS().launchFee(); uint256 g0 = IERC20(GLD).balanceOf(mallory); (uint256 f0,,) = k.nav();
        vm.startPrank(mallory); IERC20(GLD).approve(address(k), 40e18);
        k.launchWithTerms{value: fee}("big", "BIG", "", "", "", "", 100, 40e18, 0, 0);
        vm.stopPrank();
        (uint256 f1,,) = k.nav();
        assertEq(f1, f0, "the pot keeps none of the dev buy");
        assertLt(g0 - IERC20(GLD).balanceOf(mallory), 40e18, "the unspent dev buy came back");
    }

    function test_terms_in_tax_mode_pot_feeds_legs_from_floor_part_only() public {
        Kicker k = _taxPot();
        vm.startPrank(alice); IERC20(GLD).approve(address(k), 2e18); k.buy(2e18, address(0), 0); vm.stopPrank();
        (address token, address curve) = _launchTerms(k, mallory, 2000, 2000);
        vm.startPrank(whale); IERC20(GLD).approve(curve, 5e18); IPonsCurve(curve).buy(5e18, 0, whale); vm.stopPrank();
        uint256 ubik0 = IERC20(UBIK).balanceOf(address(k)); (uint256 floor0,,) = k.nav();
        vm.prank(bob); uint256 got = k.collect();
        (uint256 floor1,,) = k.nav();
        assertGt(got, 0); assertGt(IERC20(UBIK).balanceOf(address(k)), ubik0, "half of the floor part bought the leg");
        assertApproxEqRel(floor1 - floor0, got / 2, 0.02e18);
        assertGt(k.burnOwed(token), 0, "burn budget waits in the split");
        assertApproxEqRel(k.burnOwed(token), got * 2000 / 5000, 0.001e18, "burn : floor = 20 : 50");
    }

    // ---- v0.7.3: a wallet launches on pons itself (creator = the wallet, the dev buy = the router's first buy) and the pot adopts the token ----
    function _routerLaunch(address who, address recipient, uint16 taxBps, uint256 dev) internal returns (address token, address curve) {
        vm.deal(who, 1 ether); vm.startPrank(PM); IERC20(GLD).transfer(who, 1e18); vm.stopPrank();
        uint256 fee = IPonsFactory(PONS).launchFee();
        IPonsFactory.TokenParams memory p = IPonsFactory.TokenParams({ name: "wallet launch by kicker", symbol: "WLT", logo: "", description: "", socials: IPonsFactory.Socials("", "", "", "", ""),
            creatorFeeRecipient: recipient, creatorTaxBps: taxBps, buybackEnabled: false, expectedEconomics: IPonsFactory(PONS).previewLaunchEconomics(0, GLD), salt: keccak256(abi.encode(who, recipient, block.timestamp, gasleft())) });
        vm.startPrank(who); IERC20(GLD).approve(ROUTER, dev);
        address[] memory ex = new address[](0);
        (token, curve) = IPonsRouter(ROUTER).launchAndBuy{value: fee}(p, 0, GLD, dev, 0, who, ex);
        vm.stopPrank();
    }

    function test_adopt_classic_wallet_launch_lists_and_collects() public {
        Kicker k = _floorPot();
        (address token, address curve) = _routerLaunch(mallory, address(k), 200, 0.1e18);
        IPonsFactory.LaunchedToken memory L = IPonsFactory(PONS).getLaunchedToken(token);
        assertEq(L.deployer, mallory, "the wallet is the creator on pons"); assertEq(L.creatorFeeRecipient, address(k));
        assertGt(IERC20(token).balanceOf(mallory), 0, "the dev buy landed in the wallet");
        uint256 n0 = k.launchedCount();
        vm.prank(alice); vm.expectRevert(bytes("launcher only")); k.adopt(token, 0, 0, address(0), bytes32(0));   // a stranger cannot pad the list
        vm.prank(mallory); k.adopt(token, 0, 0, address(0), bytes32(0));   // the launcher (pons deployer); the builder and the keeper may too
        assertEq(k.launchedCount(), n0 + 1); assertEq(k.launched(n0), token); assertTrue(k.adopted(token));
        vm.prank(mallory); vm.expectRevert(bytes("known")); k.adopt(token, 0, 0, address(0), bytes32(0));
        // a pot-side launch is listed at launch and cannot be listed twice through adopt
        (address own,) = _launchTerms(k, carol, 0, 0); uint256 n1 = k.launchedCount(); vm.prank(keeper); vm.expectRevert(bytes("not ours")); k.adopt(own, 0, 0, address(0), bytes32(0)); assertEq(k.launchedCount(), n1);
        // tax lands on the floor through the usual collect
        vm.startPrank(whale); IERC20(GLD).approve(curve, 5e18); IPonsCurve(curve).buy(5e18, 0, whale); vm.stopPrank();
        (uint256 f0,,) = k.nav(); vm.prank(alice); uint256 got = k.collect(); (uint256 f1,,) = k.nav();
        assertGt(got, 0, "tax collected"); assertEq(f1 - f0, got, "all of it to the floor");
    }

    function test_adopt_terms_wallet_launch_split_at_predicted_address() public {
        Kicker k = _floorPot();
        bytes32 salt = keccak256("s1");
        address split = k.predictSplit(mallory, 3000, 2000, address(0), salt);
        assertEq(split.code.length, 0, "not deployed yet");
        (address token, address curve) = _routerLaunch(mallory, split, 300, 0.1e18);
        // wrong terms or wrong salt do not match the recipient
        vm.prank(mallory); vm.expectRevert(bytes("recipient")); k.adopt(token, 3000, 1000, address(0), salt);
        vm.prank(mallory); vm.expectRevert(bytes("recipient")); k.adopt(token, 3000, 2000, address(0), keccak256("s2"));
        vm.prank(mallory); vm.expectRevert(bytes("recipient")); k.adopt(token, 0, 0, address(0), bytes32(0));
        vm.prank(keeper); k.adopt(token, 3000, 2000, address(0), salt);   // the keeper may finish a launcher's terms
        // the same salt cannot bind a second token to the same split
        (address token2,) = _routerLaunch(mallory, split, 300, 0.05e18);
        vm.prank(mallory); vm.expectRevert(bytes("split used")); k.adopt(token2, 3000, 2000, address(0), salt);
        // a burn target off the pair is refused; zero terms never predict a split
        vm.expectRevert(bytes("terms")); k.predictSplit(mallory, 0, 0, address(0), salt);
        address split3 = k.predictSplit(mallory, 1000, 1000, UBIK, keccak256("s3"));
        (address token3,) = _routerLaunch(mallory, split3, 300, 0.05e18);
        vm.prank(mallory); k.adopt(token3, 1000, 1000, UBIK, keccak256("s3"));   // UBIK is a GLD-pair pons token: a valid target
        address split4 = k.predictSplit(mallory, 1000, 1000, address(0x1234), keccak256("s4"));
        (address token4,) = _routerLaunch(mallory, split4, 300, 0.05e18);
        vm.prank(mallory); vm.expectRevert(bytes("pair")); k.adopt(token4, 1000, 1000, address(0x1234), keccak256("s4"));
        assertGt(split.code.length, 0, "split deployed at the predicted address");
        (address launcher, address sp, uint16 cb, uint16 bb,) = k.terms(token);
        assertEq(launcher, mallory); assertEq(sp, split); assertEq(cb, 3000); assertEq(bb, 2000);
        assertEq(TaxSplit(payable(split)).launcher(), mallory); assertEq(TaxSplit(payable(split)).pot(), address(k));
        // the split works like one made by the pot: trade, collect, withdraw, burn out of the supply
        vm.startPrank(whale); IERC20(GLD).approve(curve, 5e18); IPonsCurve(curve).buy(5e18, 0, whale); vm.stopPrank();
        uint256 m0 = IERC20(GLD).balanceOf(mallory);
        vm.prank(alice); uint256 got = k.collect();
        assertGt(got, 0);
        vm.prank(mallory); TaxSplit(payable(split)).withdraw(mallory);
        uint256 m = IERC20(GLD).balanceOf(mallory) - m0; uint256 held = k.burnOwed(token);
        assertGt(m, 0, "launcher share"); assertGt(held, 0, "burn budget");
        assertApproxEqRel(m * 2, held * 3, 0.01e18, "launcher : burn = 30 : 20");
        uint256 sup0 = _supply(token);
        vm.prank(keeper); (, uint256 burned) = k.burn(token, 0);
        assertGt(burned, 0); assertEq(sup0 - _supply(token), burned, "burned out of the supply");
    }

    function test_adopt_rejects_other_pair_and_unknown() public {
        Kicker k = _floorPot();   // GLD pot
        vm.prank(alice); vm.expectRevert(); k.adopt(address(0x1234), 0, 0, address(0), bytes32(0));
        // a token on another pair naming the pot as recipient is not ours
        vm.deal(mallory, 1 ether); uint256 fee = IPonsFactory(PONS).launchFee();
        IPonsFactory.TokenParams memory p = IPonsFactory.TokenParams({ name: "eth one", symbol: "ETHO", logo: "", description: "", socials: IPonsFactory.Socials("", "", "", "", ""),
            creatorFeeRecipient: address(k), creatorTaxBps: 100, buybackEnabled: false, expectedEconomics: IPonsFactory(PONS).previewLaunchEconomics(0, address(0)), salt: keccak256("e") });
        vm.prank(mallory); (address token,) = IPonsFactory(PONS).launchToken{value: fee}(p, 0, address(0));
        vm.prank(mallory); vm.expectRevert(bytes("not ours")); k.adopt(token, 0, 0, address(0), bytes32(0));
    }
}

interface IERC20Supply { function totalSupply() external view returns (uint256); }
interface IPonsRouter { function launchAndBuy(IPonsFactory.TokenParams calldata params, uint256 quoteAmount, address quoteToken, uint256 amountIn, uint256 minOut, address recipient, address[] calldata exempt) external payable returns (address token, address curve); }
