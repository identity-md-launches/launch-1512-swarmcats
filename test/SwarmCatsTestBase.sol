// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmCats} from "../src/SwarmCats.sol";

abstract contract SwarmCatsTestBase is Test {
    uint256 internal constant FEE = 0.0005 ether;
    bytes32 internal constant PROVENANCE = keccak256("test art commitment");
    SwarmCats internal cats;
    address internal owner;
    address internal creator;
    address internal platform;
    address internal reserve;
    address internal alice;
    address internal bob;

    function setUp() public virtual {
        owner = makeAddr("owner");
        creator = makeAddr("creator");
        platform = makeAddr("platform");
        reserve = makeAddr("reserve");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        cats = new SwarmCats(owner, creator, platform, reserve);
        vm.prank(owner);
        cats.setProvenanceHash(PROVENANCE);
        vm.deal(owner, 10 ether);
        vm.deal(alice, 10 ether);
        vm.deal(bob, 10 ether);
    }

    function _mint(address minter, uint256 quantity) internal {
        vm.prank(minter);
        cats.mint{value: FEE * quantity}(quantity);
    }

    function _reserveMint(uint256 quantity) internal {
        vm.prank(owner);
        cats.reserveMint{value: FEE * quantity}(quantity);
    }

    function _fillPublicSupply(uint256 quantity) internal {
        uint256 remaining = quantity;
        uint256 index;
        while (remaining != 0) {
            address minter = address(uint160(0x100000 + index++));
            uint256 batch = remaining > 5 ? 5 : remaining;
            vm.deal(minter, FEE * batch);
            _mint(minter, batch);
            remaining -= batch;
        }
    }
}
