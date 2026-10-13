// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmCats} from "src/SwarmCats.sol";
import {IERC721A} from "erc721a/contracts/IERC721A.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @dev Start with 9,990 genuinely minted NFTs so short random sequences reach the global cap.
/// Ghost state is initialized from the fixture and updated from successful input actions only.
contract SwarmCatsSupplyBoundaryHandler is Test {
    uint256 private constant FEE = 0.0005 ether;
    SwarmCats public immutable cats;
    address public immutable admin;
    address[8] public actors;
    uint256[8] public publicMints;
    mapping(uint256 => address) public expectedOwner;
    mapping(address => uint256) public expectedBalance;
    uint256 public minted = 9_990;
    uint256 public teamMints = 90;
    uint256 public feesPaid = 9_990 * FEE;
    uint256 public donated;
    bool public isPaused;

    constructor(SwarmCats target, address owner) {
        cats = target;
        admin = owner;
        expectedBalance[owner] = 90;
        expectedOwner[9_990] = owner;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = address(uint160(uint256(keccak256(abi.encode("cap actor", i)))));
        }
    }

    function publicMint(uint256 actorSeed, uint256 quantitySeed) external {
        uint256 index = actorSeed % actors.length;
        address actor = actors[index];
        uint256 quantity = bound(quantitySeed, 1, 5);
        uint256 payment = FEE * quantity;
        bytes4 failure;
        if (isPaused) failure = Pausable.EnforcedPause.selector;
        else if (publicMints[index] + quantity > 5) failure = SwarmCats.WalletLimitExceeded.selector;
        else if (minted + quantity > 10_000) failure = SwarmCats.MaxSupplyExceeded.selector;

        vm.deal(actor, payment);
        vm.prank(actor);
        if (failure != bytes4(0)) vm.expectRevert(failure);
        cats.mint{value: payment}(quantity);
        if (failure != bytes4(0)) {
            assertEq(actor.balance, payment, "failed public mint consumed ETH");
            return;
        }
        assertEq(actor.balance, 0, "public mint did not charge the exact fee");
        publicMints[index] += quantity;
        _record(actor, quantity);
    }

    function reserveMint(uint256 quantitySeed) external {
        uint256 quantity = bound(quantitySeed, 1, 10);
        uint256 payment = FEE * quantity;
        bytes4 failure;
        if (isPaused) failure = Pausable.EnforcedPause.selector;
        else if (teamMints + quantity > 100) failure = SwarmCats.ReserveLimitExceeded.selector;
        else if (minted + quantity > 10_000) failure = SwarmCats.MaxSupplyExceeded.selector;

        vm.deal(admin, payment);
        vm.prank(admin);
        if (failure != bytes4(0)) vm.expectRevert(failure);
        cats.reserveMint{value: payment}(quantity);
        if (failure != bytes4(0)) {
            assertEq(admin.balance, payment, "failed reserve mint consumed ETH");
            return;
        }
        assertEq(admin.balance, 0, "reserve mint did not charge the exact fee");
        teamMints += quantity;
        _record(admin, quantity);
    }

    function transferTail(uint256 tokenSeed, uint256 recipientSeed) external {
        uint256 id = bound(tokenSeed, 9_990, minted);
        address from = expectedOwner[id];
        uint256 recipient = recipientSeed % 9;
        address to = recipient == 8 ? admin : actors[recipient];
        vm.prank(from);
        cats.transferFrom(from, to, id);
        expectedOwner[id] = to;
        --expectedBalance[from];
        ++expectedBalance[to];
    }

    function setPaused(bool paused) external {
        if (paused == isPaused) return;
        vm.prank(admin);
        if (paused) cats.pause();
        else cats.unpause();
        isPaused = paused;
    }

    /// @dev Model unsolicited ETH independently: mint fees may not spend a preexisting balance.
    function unsolicitedEth(uint256 amountSeed) external {
        uint256 amount = bound(amountSeed, 1, 1 ether);
        vm.deal(address(cats), address(cats).balance + amount);
        donated += amount;
    }

    function _record(address recipient, uint256 quantity) private {
        for (uint256 i; i < quantity; ++i) {
            expectedOwner[++minted] = recipient;
        }
        expectedBalance[recipient] += quantity;
        feesPaid += quantity * FEE;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SwarmCatsSupplyBoundaryTest is Test {
    uint256 private constant FEE = 0.0005 ether;
    SwarmCats private cats;
    SwarmCatsSupplyBoundaryHandler private handler;
    address private owner;
    address private creator;
    address private platform;
    address private reserve;

    function setUp() public {
        owner = makeAddr("cap owner");
        creator = makeAddr("cap creator");
        platform = makeAddr("cap platform");
        reserve = makeAddr("cap reserve");
        cats = new SwarmCats(owner, creator, platform, reserve);
        vm.prank(owner);
        cats.setProvenanceHash(keccak256("cap provenance"));
        // Use the public API: no storage writes or replacement runtime to reach the boundary.
        for (uint256 i; i < 1_980; ++i) {
            address buyer = address(uint160(uint256(keccak256(abi.encode("cap initial buyer", i)))));
            vm.deal(buyer, 5 * FEE);
            vm.prank(buyer);
            cats.mint{value: 5 * FEE}(5);
        }
        vm.deal(owner, 90 * FEE);
        vm.prank(owner);
        cats.reserveMint{value: 90 * FEE}(90);
        assertEq(cats.totalSupply(), 9_990);

        handler = new SwarmCatsSupplyBoundaryHandler(cats, owner);
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.publicMint.selector;
        selectors[1] = handler.reserveMint.selector;
        selectors[2] = handler.transferTail.selector;
        selectors[3] = handler.setPaused.selector;
        selectors[4] = handler.unsolicitedEth.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_supplyAndAllowancesMatchSuccessfulCalls() public view {
        assertEq(cats.totalSupply(), handler.minted());
        assertLe(cats.totalSupply(), 10_000);
        assertEq(cats.reserveMinted(), handler.teamMints());
        assertLe(handler.teamMints(), 100);
        assertEq(cats.mintedPerWallet(owner), 0, "reserve mints consumed the owner's public allowance");
        uint256 count = 9_900 + handler.teamMints();
        for (uint256 i; i < 8; ++i) {
            uint256 mints = handler.publicMints(i);
            assertEq(cats.mintedPerWallet(handler.actors(i)), mints);
            assertLe(mints, 5);
            count += mints;
        }
        assertEq(count, cats.totalSupply());
        assertEq(cats.paused(), handler.isPaused());
    }

    function invariant_feesAreConservedWithoutSpendingUnsolicitedEth() public view {
        uint256 paid = handler.feesPaid();
        assertEq(paid, handler.minted() * FEE);
        assertEq(creator.balance, paid * 2 / 5);
        assertEq(platform.balance, paid * 2 / 5);
        assertEq(reserve.balance, paid / 5);
        assertEq(creator.balance + platform.balance + reserve.balance, paid);
        assertEq(address(cats).balance, handler.donated());
    }

    function invariant_finalBatchOwnershipAndBalancesStayConsistent() public view {
        for (uint256 id = 9_990; id <= handler.minted(); ++id) {
            assertEq(cats.ownerOf(id), handler.expectedOwner(id));
        }
        uint256 totalBalances = 9_900 + cats.balanceOf(owner);
        assertEq(cats.balanceOf(owner), handler.expectedBalance(owner));
        for (uint256 i; i < 8; ++i) {
            address actor = handler.actors(i);
            assertEq(cats.balanceOf(actor), handler.expectedBalance(actor));
            totalBalances += cats.balanceOf(actor);
        }
        assertEq(totalBalances, handler.minted());
    }

    function test_partialBatchCannotCrossCapAndFailureDoesNotConsumeFinalSlot() public {
        handler.publicMint(0, 5);
        handler.reserveMint(4);
        assertEq(cats.totalSupply(), 9_999);
        handler.publicMint(1, 2); // Two valid wallet slots, only one global slot.
        assertEq(cats.totalSupply(), 9_999);
        assertEq(cats.mintedPerWallet(handler.actors(1)), 0);
        handler.publicMint(1, 1);
        assertEq(cats.ownerOf(10_000), handler.actors(1));
        handler.reserveMint(1); // Six reserve slots remain, but the global supply is exhausted.
        assertEq(cats.reserveMinted(), 94);
        _assertAllInvariants();
    }

    function test_soldOutRemainsClosedAfterTransfersAndPauseCycle() public {
        handler.reserveMint(10);
        handler.setPaused(true);
        handler.transferTail(10_000, 0);
        handler.setPaused(false);
        handler.publicMint(1, 1);
        handler.reserveMint(1);
        assertEq(cats.totalSupply(), 10_000);
        assertEq(cats.ownerOf(10_000), handler.actors(0));
        vm.expectRevert(IERC721A.OwnerQueryForNonexistentToken.selector);
        cats.ownerOf(10_001);
        _assertAllInvariants();
    }

    function test_finalTokenUriUsesFiveDigitIdAndCannotBeChangedAfterFreeze() public {
        handler.unsolicitedEth(1 wei);
        handler.reserveMint(10);
        vm.startPrank(owner);
        cats.setBaseURI("ipfs://collection/");
        cats.freezeMetadata();
        vm.expectRevert(SwarmCats.MetadataIsFrozen.selector);
        cats.setBaseURI("ipfs://replacement/");
        vm.stopPrank();
        assertEq(cats.tokenURI(9_999), "ipfs://collection/9999.json");
        assertEq(cats.tokenURI(10_000), "ipfs://collection/10000.json");
        vm.expectRevert(IERC721A.URIQueryForNonexistentToken.selector);
        cats.tokenURI(10_001);
        _assertAllInvariants();
    }

    function _assertAllInvariants() private view {
        invariant_supplyAndAllowancesMatchSuccessfulCalls();
        invariant_feesAreConservedWithoutSpendingUnsolicitedEth();
        invariant_finalBatchOwnershipAndBalancesStayConsistent();
    }
}
