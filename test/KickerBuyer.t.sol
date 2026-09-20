// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
// RH fork: forge test --fork-url $RPC --match-contract KickerBuyerForkTest -vv
import {Test, console2} from "forge-std/Test.sol";
import {KickerBuyer, IBurnable} from "../src/KickerBuyer.sol";
import {KickerFactory} from "../src/KickerFactory.sol";
import {Kicker} from "../src/Kicker.sol";
import {IERC20} from "../src/Interfaces.sol";

contract KickerBuyerForkTest is Test {
    address constant GLD = 0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e;
    address constant KICKER = 0x8a4B4202DCb9D5519cfe20829d526E06f5F3e32A;
    address constant PM = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address keeper = makeAddr("keeper"); address bob = makeAddr("bob"); address alice = makeAddr("alice");
    KickerBuyer buyer; KickerFactory f;

    function setUp() public {
        // the factory is created first with a placeholder platform, then repointed at the buyer (owner-only setPlatform)
        f = new KickerFactory(address(this), keeper);
        buyer = new KickerBuyer(GLD, KICKER, address(f), 0x6131B5fae19EA4f9D964eAc0408E4408b66337b5);
        f.setPlatform(address(buyer));
        vm.deal(alice, 1 ether); vm.startPrank(PM); IERC20(GLD).transfer(alice, 2e18); vm.stopPrank();
    }

    function test_platform_fee_lands_on_buyer_and_burns_kicker() public {
        address[] memory t = new address[](0); uint16[] memory w = new uint16[](0); uint8[] memory h = new uint8[](0);
        vm.prank(bob); Kicker k = Kicker(payable(f.create(GLD, t, w, h, 100, 1800, "floor", "FLR/K")));
        vm.startPrank(alice); IERC20(GLD).approve(address(k), 1e18); k.buy(1e18, address(0), 0); vm.stopPrank();
        uint256 got = IERC20(GLD).balanceOf(address(buyer));
        assertEq(got, 1e18 * 50 / 1e4, "0.5% of the buy reached the buyer");
        // nobody but the keeper burns; nothing can leave any other way (no withdraw exists)
        vm.prank(bob); vm.expectRevert(bytes("keeper only")); buyer.burn(0);
        uint256 sup0 = IBurnable(KICKER).totalSupply();
        vm.prank(keeper); (uint256 gldIn, uint256 burned) = buyer.burn(0);
        assertEq(gldIn, got); assertGt(burned, 0);
        assertEq(sup0 - IBurnable(KICKER).totalSupply(), burned, "KICKER burned out of the supply");
        assertEq(IERC20(KICKER).balanceOf(address(buyer)), 0); assertEq(IERC20(GLD).balanceOf(address(buyer)), 0, "buyer holds nothing after");
        assertEq(buyer.burnedTotal(), burned); assertEq(buyer.spentTotal(), gldIn);
        vm.prank(keeper); vm.expectRevert(bytes("nothing to burn")); buyer.burn(0);
        console2.log("gld in", gldIn); console2.log("kicker burned", burned);
    }

    function test_eth_floor_fee_reaches_buyer_and_bad_convert_keeps_it() public {
        address[] memory t = new address[](0); uint16[] memory w = new uint16[](0); uint8[] memory h = new uint8[](0);
        vm.prank(bob); Kicker k = Kicker(payable(f.create(address(0), t, w, h, 100, 1800, "eth floor", "E/K")));
        vm.prank(alice); k.buy{value: 0.5 ether}(0.5 ether, address(0), 0);
        assertEq(address(buyer).balance, 0.5 ether * 50 / 1e4, "0.5% of the ETH buy reached the buyer through receive()");
        // a convert with bogus calldata reverts at the router and the ETH stays; a convert that yields less than minGldOut reverts too
        vm.prank(keeper); vm.expectRevert(); buyer.convert(address(0), hex"deadbeef", 1);
        assertEq(address(buyer).balance, 0.5 ether * 50 / 1e4, "nothing left the contract");
    }

    function test_slippage_guard_and_wrong_pair() public {
        vm.startPrank(PM); IERC20(GLD).transfer(address(buyer), 0.1e18); vm.stopPrank();
        vm.prank(keeper); vm.expectRevert(bytes("slippage")); buyer.burn(type(uint256).max);
        vm.expectRevert(bytes("pair")); new KickerBuyer(address(0), KICKER, address(f), address(1));
        // convert refuses gld/kicker and a non-keeper
        vm.prank(bob); vm.expectRevert(bytes("keeper only")); buyer.convert(address(0), "", 1);
        vm.prank(keeper); vm.expectRevert(bytes("asset")); buyer.convert(GLD, "", 1);
    }
}
