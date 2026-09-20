// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
import {Script, console2} from "forge-std/Script.sol";
import {ArcProbe} from "../src/arc/ArcProbe.sol";
contract DeployArcProbe is Script { function run() external { vm.startBroadcast(); ArcProbe p = new ArcProbe(); console2.log("probe", address(p)); vm.stopBroadcast(); } }
import {ArcSwap} from "../src/arc/ArcSwap.sol";
contract DeployArcSwap is Script { function run() external { vm.startBroadcast(); ArcSwap s = new ArcSwap(); console2.log("swap", address(s)); vm.stopBroadcast(); } }
import {ArcPotFactory, ArcPot} from "../src/arc/ArcPot.sol";
// PLATFORM=<A> forge script script/ArcProbe.s.sol:DeployArcPot --rpc-url $ARC_RPC --broadcast --private-key $PK --legacy
contract DeployArcPot is Script { function run() external { vm.startBroadcast(); ArcPotFactory f = new ArcPotFactory(vm.envAddress("PLATFORM")); console2.log("factory", address(f)); console2.log("impl", f.impl()); address k = f.create("dollar pot", "USDC/K"); console2.log("pot", k); vm.stopBroadcast(); } }
