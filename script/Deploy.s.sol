// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {KickerFactory} from "../src/KickerFactory.sol";
import {Kicker} from "../src/Kicker.sol";
import {FeeRouter} from "../src/FeeRouter.sol";
import {KickerBuyer} from "../src/KickerBuyer.sol";

// forge script script/Deploy.s.sol --rpc-url $RPC --broadcast --private-key $PK
// PLATFORM - the platform address for the 0.5% fee
contract Deploy is Script {
    function run() external {
        address platform = vm.envAddress("PLATFORM");
        vm.startBroadcast();
        KickerFactory f = new KickerFactory(platform, vm.envAddress("KEEPER"));
        console2.log("factory", address(f)); console2.log("impl", f.impl());
        vm.stopBroadcast();
    }
}

// $KICKER tax router: FACTORIES - factories whose pots may be the target; TARGET - the pot the tax flows to
contract DeployRouter is Script {
    function run() external {
        vm.startBroadcast();
        FeeRouter r = new FeeRouter(vm.envAddress("FACTORIES", ","), vm.envAddress("TARGET"));
        console2.log("router", address(r));
        vm.stopBroadcast();
    }
}

// showcase pot: FACTORY, CORE, TOKENS (comma-separated), WEIGHTS (bps), MODES (0 hold, 1 grad, 2 timer), KICK (bps), EXIT (seconds), NAME, SYMBOL
contract CreateKicker is Script {
    function run() external {
        KickerFactory f = KickerFactory(vm.envAddress("FACTORY"));
        address core = vm.envAddress("CORE");
        address[] memory t = vm.envAddress("TOKENS", ",");
        uint256[] memory w = vm.envUint("WEIGHTS", ",");
        uint16[] memory ws = new uint16[](w.length); for (uint256 i; i < w.length; i++) ws[i] = uint16(w[i]);
        uint256[] memory m = vm.envUint("MODES", ",");
        uint8[] memory h = new uint8[](m.length); for (uint256 i; i < m.length; i++) h[i] = uint8(m[i]);
        vm.startBroadcast();
        address k = f.create(core, t, ws, h, uint16(vm.envUint("KICK")), uint32(vm.envUint("EXIT")), vm.envString("NAME"), vm.envString("SYMBOL"));
        console2.log("kicker", k);
        vm.stopBroadcast();
    }
}

// the platform's share turns into a KICKER burn: FACTORY - whose keeper() may burn/convert; ROUTER - the KyberSwap aggregator
contract DeployBuyer is Script {
    function run() external {
        vm.startBroadcast();
        KickerBuyer b = new KickerBuyer(0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e, 0x8a4B4202DCb9D5519cfe20829d526E06f5F3e32A, vm.envAddress("FACTORY"), vm.envAddress("ROUTER"));
        console2.log("buyer", address(b));
        vm.stopBroadcast();
    }
}
