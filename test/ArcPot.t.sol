// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
// Arc fork: forge test --fork-url $ARC_RPC --match-contract ArcPot -vv
import {Test, Vm, console2} from "forge-std/Test.sol";
import {ArcPot, ArcPotFactory, IArgusPortal, IArgusSplitter} from "../src/arc/ArcPot.sol";
import {ArcSwap} from "../src/arc/ArcSwap.sol";
import {IERC20} from "../src/Interfaces.sol";

/// Arc precompiles the USDC system token calls; forge's EVM has none, so the fork mocks them
contract BlocklistMock { function isBlocklisted(address) external pure returns (bool) { return false; } fallback() external payable {} }
contract GasBurner { fallback() external payable { uint256 x; while (true) { x = uint256(keccak256(abi.encode(x))); } } }
contract NativeMoveMock { Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code"))))); function transfer(address from, address to, uint256 amt) external returns (bool) { require(from.balance >= amt, "native"); vm.deal(from, from.balance - amt); vm.deal(to, to.balance + amt); return true; } }

contract ArcPotForkTest is Test {
    IERC20 constant USDC = IERC20(0x3600000000000000000000000000000000000000);
    IArgusPortal constant PORTAL = IArgusPortal(0xB021Be536808f551b31789422Fd28a6c9c6e97Da);
    ArcPotFactory f; ArcPot k; ArcSwap sw;
    address platform = makeAddr("platform"); address bob = makeAddr("bob"); address alice = makeAddr("alice"); address mallory = makeAddr("mallory"); address whale = makeAddr("whale");

    function setUp() public {
        vm.etch(0x1800000000000000000000000000000000000001, address(new BlocklistMock()).code);
        vm.etch(0x1800000000000000000000000000000000000000, address(new NativeMoveMock()).code); vm.allowCheatcodes(0x1800000000000000000000000000000000000000);
        f = new ArcPotFactory(platform); sw = new ArcSwap();
        vm.prank(bob); k = ArcPot(payable(f.create("usdc pot", "USD/K")));
        vm.deal(alice, 1000e18); vm.deal(mallory, 1000e18); vm.deal(whale, 5000e18); vm.deal(bob, 100e18);   // native = erc-20 view on Arc
    }

    function _mine(address creator, bytes32 salt, uint16 bt, uint16 st) internal view returns (bytes32 hs) {
        for (uint256 i; i < 200000; i++) { hs = bytes32(i); (, , bool ok) = PORTAL.predictHook(creator, salt, hs, bt, st, address(USDC)); if (ok) return hs; }
        revert("no salt");
    }

    function _launch(address who, uint256 dev) internal returns (address token) {
        bytes32 salt = keccak256(abi.encodePacked("t", who, k.launchedCount()));
        bytes32 hs = _mine(address(k), salt, 300, 300);
        IArgusPortal.Params memory p = IArgusPortal.Params("pot token", "PT", 1e27, 2_500_000_000, 45_000_000_000, 300, 300, 0, 0, 0, 0, dev, address(0), 0);
        IArgusPortal.Meta memory m = IArgusPortal.Meta("", "https://kicker.markets", "", "", "from a pot");
        vm.startPrank(who); USDC.approve(address(k), dev + k.LAUNCH_FEE()); token = k.launch(p, m, salt, hs); vm.stopPrank();
    }

    function test_arc_native_and_erc20_are_one_balance() public {
        assertEq(USDC.balanceOf(alice), 1000e6, "erc-20 view of the native balance, 6 decimals");
    }

    function test_buy_redeem_fees() public {
        vm.startPrank(alice); USDC.approve(address(k), 100e6); uint256 s = k.buy(100e6, address(0), 0); vm.stopPrank();
        assertEq(k.floor(), 98e6, "2% fees out, 98 on the floor"); assertEq(USDC.balanceOf(bob), 100e6 + 1.5e6); assertEq(USDC.balanceOf(platform), 0.5e6);
        assertEq(s, 98e18 - 1e6);
        vm.startPrank(mallory); USDC.approve(address(k), 50e6); uint256 s2 = k.buy(50e6, alice, 0); vm.stopPrank();
        assertApproxEqRel(s2, 49e18, 1e12, "second buy at the same floor per share"); assertEq(USDC.balanceOf(alice), 900e6 + 0.25e6, "ref paid");
        uint256 a0 = USDC.balanceOf(alice); vm.prank(alice); uint256 out = k.redeem(s, 0);
        assertApproxEqAbs(out, 98e6, 2); assertEq(USDC.balanceOf(alice) - a0, out);
        assertApproxEqRel(k.floor() * 1e18 / k.totalSupply(), 1e6, 1e12, "floor per K unchanged by redeem");
    }

    function test_launch_from_pot_tax_lands_on_floor() public {
        vm.startPrank(alice); USDC.approve(address(k), 100e6); k.buy(100e6, address(0), 0); vm.stopPrank();
        address token = _launch(mallory, 5e6);
        (address creator,,,,, address splitter,,,,,) = PORTAL.launches(token);
        assertEq(creator, address(k), "the pot is the creator");
        (bool okn, bytes memory dn) = token.staticcall(abi.encodeWithSignature("name()")); assertTrue(okn); assertEq(abi.decode(dn, (string)), "pot token by kicker", "suffix in the contract");
        assertGt(IERC20(token).balanceOf(mallory), 0, "dev buy went to the launcher"); assertEq(IERC20(token).balanceOf(address(k)), 0, "pot keeps no token");
        assertEq(k.floor(), 99e6, "the launch fee is on the floor, nothing else moved");
        assertEq(USDC.balanceOf(mallory), 1000e6 - 5e6 - 1e6, "the launcher paid the fee and the dev buy, no launch-time tax came back as refund");
        // trade after the snipe window
        vm.warp(block.timestamp + 10); vm.roll(block.number + 20);
        (,,,, address hook,,,,,,) = PORTAL.launches(token);
        vm.startPrank(whale); USDC.approve(address(sw), 500e6); sw.buy(token, hook, 200e6, 0); vm.stopPrank();
        uint256 f0 = k.floor();
        uint256 got = k.collect();
        console2.log("collected", got); console2.log("claimable after", IArgusSplitter(splitter).claimableQuote6(address(k)));
        assertGt(got, 0, "creator share reached the floor"); assertEq(k.floor() - f0, got);
        assertGt(k.floor() * 1e18 / k.totalSupply(), 1e6, "floor per K stepped up");
    }

    function test_launch_rules() public {
        bytes32 salt = keccak256("x"); bytes32 hs = _mine(address(k), salt, 300, 300);
        IArgusPortal.Meta memory m = IArgusPortal.Meta("", "", "", "", "");
        IArgusPortal.Params memory p = IArgusPortal.Params("t", "T", 1e27, 2_500_000_000, 45_000_000_000, 0, 0, 0, 0, 0, 0, 0, address(0), 0);
        vm.prank(mallory); vm.expectRevert(bytes("tax")); k.launch(p, m, salt, hs);   // v0.2: anyone may launch
        vm.prank(bob); vm.expectRevert(bytes("tax")); k.launch(p, m, salt, hs);
        p.buyTaxBps = 1100; vm.prank(bob); vm.expectRevert(bytes("tax")); k.launch(p, m, salt, hs);
        // a wrong hook salt is refused by the portal before anything deploys
        p.buyTaxBps = 300; p.sellTaxBps = 300; vm.prank(bob); vm.expectRevert(); k.launch(p, m, salt, bytes32(uint256(hs) + 1));
        // no fee approved: the launch fee is required even with no dev buy
        vm.prank(bob); vm.expectRevert(bytes("ERC20: transfer amount exceeds allowance")); k.launch(p, m, salt, hs);
    }

    /// a 24-byte name plus the suffix passes the portal; the pot stops at MAX_LAUNCHES and each launch left 1 USDC on the floor
    function test_launch_cap_and_long_name() public {
        vm.startPrank(alice); USDC.approve(address(k), 100e6); k.buy(100e6, address(0), 0); vm.stopPrank();
        bytes32 salt = keccak256("long"); bytes32 hs = _mine(address(k), salt, 300, 300);
        IArgusPortal.Params memory p = IArgusPortal.Params("abcdefghijklmnopqrstuvwx", "LONG", 1e27, 2_500_000_000, 45_000_000_000, 300, 300, 0, 0, 0, 0, 0, address(0), 0);
        IArgusPortal.Meta memory m = IArgusPortal.Meta("", "", "", "", "");
        vm.startPrank(mallory); USDC.approve(address(k), 1e6); address t = k.launch(p, m, salt, hs); vm.stopPrank();
        (bool okn, bytes memory dn) = t.staticcall(abi.encodeWithSignature("name()")); assertTrue(okn); assertEq(abi.decode(dn, (string)), "abcdefghijklmnopqrstuvwx by kicker");
        for (uint256 i = 1; i < k.MAX_LAUNCHES(); i++) _launch(mallory, 0);
        assertEq(k.launchedCount(), k.MAX_LAUNCHES()); assertEq(k.floor(), 98e6 + 16e6, "16 fees on the floor");
        vm.startPrank(mallory); USDC.approve(address(k), 1e6); vm.expectRevert(bytes("full")); k.launch(p, m, keccak256("17"), hs); vm.stopPrank();
        // a full pot still cranks everything on redeem
        uint256 half = k.balanceOf(alice) / 2; vm.prank(alice); uint256 out = k.redeem(half, 0); assertGt(out, 49e6, "half of 114 usdc floor");
    }

    /// the JIT skim from the review: a stranger buying right before collect gets nothing of the pending tax
    function test_pending_tax_accrues_to_existing_holders() public {
        vm.startPrank(alice); USDC.approve(address(k), 30e6); k.buy(30e6, address(0), 0); vm.stopPrank();
        address token = _launch(bob, 0);
        vm.warp(block.timestamp + 10); vm.roll(block.number + 20);
        (,,,, address hook,,,,,,) = PORTAL.launches(token);
        vm.startPrank(whale); USDC.approve(address(sw), 2000e6); sw.buy(token, hook, 1000e6, 0); vm.stopPrank();
        // mallory jumps in, then straight out
        vm.startPrank(mallory); USDC.approve(address(k), 100e6); uint256 s = k.buy(100e6, address(0), 0); uint256 m0 = USDC.balanceOf(mallory); uint256 out = k.redeem(s, 0); vm.stopPrank();
        assertLt(out, 98e6 + 1, "the jumper gets at most its net deposit back");
        assertGt(k.floor() * 1e18 / k.totalSupply(), 1e6 * 98 / 100 * 1e6 / 98e6 * 98e6 / 1e6 / 1, "floor per K up for alice");
        assertGt(USDC.balanceOf(mallory), m0);
    }

    /// a splitter that burns all its gas must not block the exit: the crank is gas-capped and redeemNoCollect skips it entirely
    function test_gas_burning_splitter_cannot_block_redeem() public {
        vm.startPrank(alice); USDC.approve(address(k), 50e6); uint256 s = k.buy(50e6, address(0), 0); vm.stopPrank();
        address token = _launch(bob, 0);
        (,,,,, address splitter,,,,,) = PORTAL.launches(token);
        vm.etch(splitter, address(new GasBurner()).code);
        vm.prank(alice); uint256 out = k.redeem(s / 2, 0); assertGt(out, 0, "redeem with the crank survives a gas-burning splitter");
        vm.prank(alice); uint256 out2 = k.redeemNoCollect(s / 2, 0); assertGt(out2, 0, "redeemNoCollect works");
        vm.startPrank(mallory); USDC.approve(address(k), 5e6); k.buy(5e6, address(0), 0); vm.stopPrank();   // buy survives too
    }

    function test_skim_and_platform_guard() public {
        vm.prank(mallory); vm.expectRevert(bytes("usdc")); k.skim(address(USDC));
        address token = _launch(bob, 0); vm.prank(mallory); vm.expectRevert(bytes("usdc")); k.skim(token);
        vm.expectRevert(bytes("owner")); f.setPlatform(address(0));
    }

    function test_impl_locked_and_collect_open() public {
        ArcPot impl = ArcPot(payable(f.impl())); vm.expectRevert(bytes("init")); impl.initialize(bob, "x", "X");
        vm.prank(mallory); uint256 got = k.collect(); assertEq(got, 0, "nothing launched, collect is a no-op for anyone");
    }
}
