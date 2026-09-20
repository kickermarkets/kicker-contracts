// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20, IPonsEscrow} from "./Interfaces.sol";

interface IKickerRegistry { function isKicker(address) external view returns (bool); }
interface IKickerCore { function core() external view returns (address); }

/// Creator fee recipient of the $KICKER token: claims from the pons escrow and forwards to the target.
/// The target can only be a pot of one of the factories fixed at deployment; it can never be a wallet.
/// The owner chooses which pot to feed (for example a pot of a newer version) and nothing else.
contract FeeRouter {
    IPonsEscrow public constant ESCROW = IPonsEscrow(0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e);
    address public owner;
    address public target;
    address[] public factories;

    event Target(address indexed target);
    event Routed(address indexed asset, address indexed target, uint256 amount);

    constructor(address[] memory factories_, address target_) {
        owner = msg.sender; factories = factories_;
        require(_isPot(target_), "not a pot"); target = target_; emit Target(target_);
    }

    receive() external payable {}

    function factoryCount() external view returns (uint256) { return factories.length; }

    function _isPot(address t) internal view returns (bool) {
        for (uint256 i; i < factories.length; i++) if (IKickerRegistry(factories[i]).isKicker(t)) return true;
        return false;
    }

    function setTarget(address t) external { require(msg.sender == owner, "owner"); require(_isPot(t), "not a pot"); target = t; emit Target(t); }
    function setOwner(address o) external { require(msg.sender == owner, "owner"); owner = o; }

    /// anyone: claim from the escrow (if any) and forward the whole balance of the asset to the target
    function route(address asset) external returns (uint256 amount) {
        require(asset == IKickerCore(target).core(), "asset != core");   // a foreign asset would be stuck in the pot forever: a pot has no sweep
        if (asset == address(0)) {
            try ESCROW.claim() {} catch {}
            amount = address(this).balance;
            if (amount > 0) { (bool ok,) = target.call{value: amount}(""); require(ok, "eth"); }
        } else {
            try ESCROW.claimToken(asset) {} catch {}
            amount = IERC20(asset).balanceOf(address(this));
            if (amount > 0) require(IERC20(asset).transfer(target, amount), "transfer");
        }
        emit Routed(asset, target, amount);
    }
}
