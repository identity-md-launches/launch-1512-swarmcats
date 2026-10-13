// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmCats} from "../src/SwarmCats.sol";

/// @dev The model records only successful actions; it never reads implementation counters to update itself.
contract SwarmCatsHandler is Test {
    SwarmCats public immutable cats;
    address public immutable admin;
    address[8] public actors;
    uint256[8] public publicMints;
    mapping(uint256 => address) public expectedOwner;
    mapping(address => uint256) public expectedBalance;
    uint256 public teamMints;
    uint256 public minted;
    uint256 public feesPaid;
    bool public isPaused;
    uint256 private constant FEE = 0.0005 ether;

    constructor(SwarmCats target, address owner) {
        cats = target;
        admin = owner;
        for (uint256 i; i < 8; ++i) {
            actors[i] = address(uint160(0x200000 + i));
        }
    }

    function publicMint(uint256 actorSeed, uint256 quantitySeed) external {
        uint256 index = actorSeed % 8;
        uint256 remaining = 5 - publicMints[index];
        if (isPaused || remaining == 0) return;
        uint256 quantity = bound(quantitySeed, 1, remaining);
        address actor = actors[index];
        vm.deal(actor, FEE * quantity);
        vm.prank(actor);
        cats.mint{value: FEE * quantity}(quantity);
        publicMints[index] += quantity;
        _recordMint(actor, quantity);
    }

    function teamMint(uint256 quantitySeed) external {
        if (isPaused || teamMints == 100) return;
        uint256 quantity = bound(quantitySeed, 1, 100 - teamMints);
        vm.deal(admin, FEE * quantity);
        vm.prank(admin);
        cats.reserveMint{value: FEE * quantity}(quantity);
        teamMints += quantity;
        _recordMint(admin, quantity);
    }

    function transferNft(uint256 tokenSeed, uint256 recipientSeed) external {
        if (minted == 0) return;
        uint256 tokenId = bound(tokenSeed, 1, minted);
        address from = expectedOwner[tokenId];
        address to = recipientSeed % 9 == 8 ? admin : actors[recipientSeed % 8];
        vm.prank(from);
        cats.transferFrom(from, to, tokenId);
        --expectedBalance[from];
        ++expectedBalance[to];
        expectedOwner[tokenId] = to;
    }

    function setPaused(bool paused) external {
        if (paused == isPaused) return;
        vm.prank(admin);
        if (paused) cats.pause();
        else cats.unpause();
        isPaused = paused;
    }

    function invalidPayment(uint256 actorSeed, uint256 valueSeed) external {
        uint256 value = bound(valueSeed, 0, FEE - 1);
        address actor = actors[actorSeed % 8];
        vm.deal(actor, FEE);
        vm.prank(actor);
        (bool success,) = address(cats).call{value: value}(abi.encodeCall(cats.mint, (1)));
        assertFalse(success);
        assertEq(actor.balance, FEE);
    }

    function _recordMint(address actor, uint256 quantity) private {
        for (uint256 i; i < quantity; ++i) {
            expectedOwner[++minted] = actor;
        }
        expectedBalance[actor] += quantity;
        feesPaid += FEE * quantity;
    }
}

contract SwarmCatsInvariantTest is Test {
    SwarmCats private cats;
    SwarmCatsHandler private handler;
    address private owner;
    address private creator;
    address private platform;
    address private reserve;
    bytes32 private constant PROVENANCE = keccak256("invariant art commitment");

    function setUp() public {
        owner = makeAddr("invariant owner");
        creator = makeAddr("invariant creator");
        platform = makeAddr("invariant platform");
        reserve = makeAddr("invariant reserve");
        cats = new SwarmCats(owner, creator, platform, reserve);
        vm.prank(owner);
        cats.setProvenanceHash(PROVENANCE);
        handler = new SwarmCatsHandler(cats, owner);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.publicMint.selector;
        selectors[1] = handler.teamMint.selector;
        selectors[2] = handler.transferNft.selector;
        selectors[3] = handler.setPaused.selector;
        selectors[4] = handler.invalidPayment.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_supplyLimitsAndLifetimeCounters() public view {
        assertEq(cats.totalSupply(), handler.minted());
        assertLe(cats.totalSupply(), 10_000);
        assertEq(cats.reserveMinted(), handler.teamMints());
        assertLe(handler.teamMints(), 100);
        uint256 publicTotal;
        for (uint256 i; i < 8; ++i) {
            uint256 count = handler.publicMints(i);
            assertEq(cats.mintedPerWallet(handler.actors(i)), count);
            assertLe(count, 5);
            publicTotal += count;
        }
        assertEq(handler.minted(), publicTotal + handler.teamMints());
        assertEq(cats.paused(), handler.isPaused());
        assertEq(cats.PROVENANCE_HASH(), PROVENANCE);
    }

    function invariant_allFeesImmediatelyConserved() public view {
        uint256 paid = handler.feesPaid();
        assertEq(paid, cats.totalSupply() * 0.0005 ether);
        assertEq(creator.balance, paid * 40 / 100);
        assertEq(platform.balance, paid * 40 / 100);
        assertEq(reserve.balance, paid * 20 / 100);
        assertEq(creator.balance + platform.balance + reserve.balance, paid);
        assertEq(address(cats).balance, 0);
    }

    function invariant_ownershipAndBalancesMatchTransfers() public view {
        uint256 minted = handler.minted();
        for (uint256 id = 1; id <= minted; ++id) {
            assertEq(cats.ownerOf(id), handler.expectedOwner(id));
        }
        uint256 balances = cats.balanceOf(owner);
        assertEq(balances, handler.expectedBalance(owner));
        for (uint256 i; i < 8; ++i) {
            address actor = handler.actors(i);
            uint256 actual = cats.balanceOf(actor);
            assertEq(actual, handler.expectedBalance(actor));
            balances += actual;
        }
        assertEq(balances, minted);
    }
}
