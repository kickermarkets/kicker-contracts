// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Kicker} from "./Kicker.sol";
import {TaxSplit} from "./TaxSplit.sol";

/// Factory of pots: EIP-1167 clones of one implementation, a registry, the platform address for the 0.5% fee.
/// v0.3: sleeve cap up to 50%, leg modes hold/grad/timer. v0.3.1: composition for the split is read before the deposit.
/// v0.3.2: keeper is the platform clipper, clip is keeper-only. v0.3.3: launch() open to anyone, collectRange.
/// v0.3.4: moveTax keeper-only, the KICKER ticker reserved for the keeper.
/// v0.4: taxToLegs mode (tax split by composition into the legs, collect builder/keeper only), createWithTax.
/// v0.5: launcher terms (launchWithTerms: launcher share, buyback-and-burn share, platform share) via TaxSplit clones.
contract KickerFactory {
    string public constant VERSION = "0.7.3";
    address public immutable impl;
    address public immutable splitImpl;   // v0.5: implementation of the per-token TaxSplit
    address public owner;
    address public platform;
    address public keeper;     // platform clipper: may clip any pot, collect on tax-mode pots, burn
    address[] public trusted;  // factories of other versions: their pots are legal moveTax targets (owner adds)
    address[] public all;
    mapping(address => bool) public isKicker;

    event Created(address indexed kicker, address indexed creator, address indexed core, string symbol);

    constructor(address platform_, address keeper_) { impl = address(new Kicker()); splitImpl = address(new TaxSplit()); owner = msg.sender; platform = platform_; keeper = keeper_; }

    function count() external view returns (uint256) { return all.length; }

    function create(address core, address[] calldata tokens, uint16[] calldata weights, uint8[] calldata modes, uint16 kick, uint32 exitAfter, string calldata name, string calldata symbol) external returns (address k) {
        return _create(core, tokens, weights, modes, kick, exitAfter, name, symbol, false);
    }

    /// v0.4: create with the taxToLegs flag; a separate name so existing clients never hit an overload
    function createWithTax(address core, address[] calldata tokens, uint16[] calldata weights, uint8[] calldata modes, uint16 kick, uint32 exitAfter, string calldata name, string calldata symbol, bool taxToLegs) external returns (address k) {
        return _create(core, tokens, weights, modes, kick, exitAfter, name, symbol, taxToLegs);
    }

    function _create(address core, address[] calldata tokens, uint16[] calldata weights, uint8[] calldata modes, uint16 kick, uint32 exitAfter, string calldata name, string calldata symbol, bool taxToLegs) internal returns (address k) {
        k = _clone(impl);
        Kicker(payable(k)).initialize(core, msg.sender, kick, exitAfter, name, symbol, taxToLegs);
        Kicker(payable(k)).setLegs(tokens, weights, modes);
        all.push(k); isKicker[k] = true;
        emit Created(k, msg.sender, core, symbol);
    }

    function setPlatform(address p) external { require(msg.sender == owner, "owner"); require(p != address(0), "zero"); platform = p; }
    function setOwner(address o) external { require(msg.sender == owner, "owner"); owner = o; }
    function setKeeper(address k) external { require(msg.sender == owner, "owner"); require(k != address(0), "zero"); keeper = k; }
    function addTrusted(address f) external { require(msg.sender == owner, "owner"); require(f.code.length > 0 && !KickerFactory(f).isKicker(address(0)), "not a factory"); trusted.push(f); }
    function trustedCount() external view returns (uint256) { return trusted.length; }
    /// a pot of this factory or of a trusted one: trust comes from this registry only, never from the target's own answer
    function knownKicker(address pot) external view returns (bool) {
        if (isKicker[pot]) return true;
        // a trusted entry without code (a typo, a retired chain) is skipped, not fatal: 0.5/0.6 carry one and their knownKicker reverts
        for (uint256 i; i < trusted.length; i++) { address f = trusted[i]; if (f.code.length == 0) continue; try KickerFactory(f).isKicker(pot) returns (bool ok) { if (ok) return true; } catch {} }
        return false;
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
}
