// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwarmCatsTestBase, SwarmCats} from "./SwarmCatsTestBase.sol";
import {ConfigurableReceiver} from "./mocks/MintActors.sol";
import {IERC721A} from "erc721a/contracts/IERC721A.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev Exercises receiver failures after a transfer has already changed ownership and approval.
contract SwarmCatsTransferProbe {
    enum Response {
        Accept,
        WrongSelector,
        EmptyRevert,
        CustomRevert
    }

    SwarmCats public immutable cats;
    Response public response;
    address public forwardTo;
    address public operator;
    address public from;
    uint256 public tokenId;
    uint256 public calls;
    bytes public data;
    address public observedOwner;
    address public observedApproval;

    error ReceiverRejected(uint256 tokenId);

    constructor(SwarmCats target) {
        cats = target;
    }

    function configure(Response nextResponse, address nextForwardTo) external {
        response = nextResponse;
        forwardTo = nextForwardTo;
    }

    function onERC721Received(address caller, address previousOwner, uint256 id, bytes calldata payload)
        external
        returns (bytes4)
    {
        require(msg.sender == address(cats), "unexpected collection");
        ++calls;
        operator = caller;
        from = previousOwner;
        tokenId = id;
        data = payload;
        observedOwner = cats.ownerOf(id);
        observedApproval = cats.getApproved(id);
        if (forwardTo != address(0)) cats.transferFrom(address(this), forwardTo, id);
        if (response == Response.WrongSelector) return bytes4(0xffffffff);
        if (response == Response.EmptyRevert) {
            assembly {
                revert(0, 0)
            }
        }
        if (response == Response.CustomRevert) revert ReceiverRejected(id);
        return this.onERC721Received.selector;
    }
}

/// @dev An approved successor exercises admin functions while receiving a mint fee.
contract SwarmCatsAdminFeeReceiver {
    SwarmCats public cats;
    uint256 public calls;

    function configure(SwarmCats target) external {
        cats = target;
    }

    receive() external payable {
        ++calls;
        cats.acceptOwnership();
        cats.setBaseURI("ipfs://callback/");
        cats.setUnrevealedURI("ipfs://callback-hidden.json");
        cats.setRevealSeed(keccak256("callback seed"));
        cats.freezeMetadata();
        cats.pause();
    }
}

/// forge-config: default.fuzz.runs = 1000
contract SwarmCatsAdditionalAdversarialTest is SwarmCatsTestBase {
    address internal carol;

    function setUp() public override {
        super.setUp();
        carol = makeAddr("carol");
        vm.deal(address(this), 10 ether);
    }

    function test_lateMintRejectionRollsBackForwardedTokensWithoutErasingEarlierMints() public {
        ConfigurableReceiver receiver = new ConfigurableReceiver();
        receiver.configure(cats, false, 0, address(0));
        _mint(bob, 5);
        receiver.buy{value: FEE}(1);
        receiver.configure(cats, false, 10, alice);
        uint256 payerBefore = address(this).balance;

        vm.expectRevert(bytes("NFT rejected"));
        receiver.buy{value: 4 * FEE}(4);

        assertEq(address(this).balance, payerBefore);
        assertEq(cats.totalSupply(), 6);
        assertEq(cats.mintedPerWallet(address(receiver)), 1);
        assertEq(cats.mintedPerWallet(bob), 5);
        assertEq(cats.balanceOf(bob), 5);
        assertEq(cats.balanceOf(address(receiver)), 1);
        assertEq(cats.balanceOf(alice), 0);
        assertEq(receiver.tokenCalls(), 1);
        assertEq(cats.ownerOf(5), bob);
        assertEq(cats.ownerOf(6), address(receiver));
        vm.expectRevert(IERC721A.OwnerQueryForNonexistentToken.selector);
        cats.ownerOf(7);
        _assertFeeTotals(6);

        receiver.configure(cats, false, 0, alice);
        receiver.buy{value: 4 * FEE}(4);
        assertEq(cats.totalSupply(), 10);
        assertEq(cats.mintedPerWallet(address(receiver)), 5);
        assertEq(cats.balanceOf(address(receiver)), 1);
        assertEq(cats.balanceOf(alice), 4);
        for (uint256 id = 7; id <= 10; ++id) {
            assertEq(cats.ownerOf(id), alice);
        }
        _assertFeeTotals(10);
    }

    function test_lastFeeFailureRollsBackOwnershipAcceptanceAndAllCallbackAdminChanges() public {
        SwarmCatsAdminFeeReceiver first = new SwarmCatsAdminFeeReceiver();
        ConfigurableReceiver last = new ConfigurableReceiver();
        cats = new SwarmCats(owner, address(first), platform, address(last));
        first.configure(cats);
        last.configure(cats, true, 0, address(0));
        vm.startPrank(owner);
        cats.setProvenanceHash(PROVENANCE);
        cats.setBaseURI("ipfs://original/");
        cats.setUnrevealedURI("ipfs://original-hidden.json");
        cats.transferOwnership(address(first));
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(SwarmCats.FeeTransferFailed.selector, address(last), FEE / 5));
        _mint(alice, 1);

        assertEq(cats.owner(), owner);
        assertEq(cats.pendingOwner(), address(first));
        assertEq(cats.baseURI(), "ipfs://original/");
        assertEq(cats.unrevealedURI(), "ipfs://original-hidden.json");
        assertFalse(cats.revealed());
        assertEq(cats.revealSeed(), bytes32(0));
        assertFalse(cats.metadataFrozen());
        assertFalse(cats.paused());
        assertEq(cats.PROVENANCE_HASH(), PROVENANCE);
        assertEq(cats.totalSupply(), 0);
        assertEq(cats.mintedPerWallet(alice), 0);
        assertEq(alice.balance, 10 ether);
        assertEq(first.calls(), 0);
        assertEq(last.ethCalls(), 0);
        assertEq(address(first).balance, 0);
        assertEq(platform.balance, 0);
        assertEq(address(last).balance, 0);
        assertEq(address(cats).balance, 0);

        // The same callback path succeeds once the final payment is accepted, proving
        // that the first rejection came after all of the earlier callback's changes.
        last.configure(cats, false, 0, address(0));
        _mint(alice, 1);
        assertEq(cats.owner(), address(first));
        assertEq(cats.pendingOwner(), address(0));
        assertTrue(cats.metadataFrozen());
        assertTrue(cats.revealed());
        assertTrue(cats.paused());
        assertEq(cats.ownerOf(1), alice);
        assertEq(cats.tokenURI(1), "ipfs://callback/1.json");
        assertEq(first.calls(), 1);
        assertEq(last.ethCalls(), 1);
        assertEq(address(first).balance + platform.balance + address(last).balance, FEE);
    }

    function testFuzz_safeTransferForwardsExactDataAndOperator(bytes memory data) public {
        _mint(alice, 1);
        SwarmCatsTransferProbe receiver = new SwarmCatsTransferProbe(cats);
        vm.prank(alice);
        cats.approve(bob, 1);
        vm.prank(bob);
        cats.safeTransferFrom(alice, address(receiver), 1, data);

        assertEq(receiver.calls(), 1);
        assertEq(receiver.operator(), bob);
        assertEq(receiver.from(), alice);
        assertEq(receiver.tokenId(), 1);
        assertEq(receiver.data(), data);
        assertEq(receiver.observedOwner(), address(receiver));
        assertEq(receiver.observedApproval(), address(0));
        assertEq(cats.ownerOf(1), address(receiver));
        assertEq(cats.balanceOf(alice), 0);
        assertEq(cats.balanceOf(address(receiver)), 1);
        assertEq(cats.mintedPerWallet(alice), 1);
        assertEq(cats.mintedPerWallet(address(receiver)), 0);
        _assertFeeTotals(1);
    }

    function test_wrongReceiverSelectorRollsBackNestedTransferAndRestoresApproval() public {
        _assertSafeTransferFailure(SwarmCatsTransferProbe.Response.WrongSelector);
    }

    function test_emptyReceiverRevertRollsBackNestedTransferAndRestoresApproval() public {
        _assertSafeTransferFailure(SwarmCatsTransferProbe.Response.EmptyRevert);
    }

    function test_customReceiverRevertBubblesAndRestoresApproval() public {
        _assertSafeTransferFailure(SwarmCatsTransferProbe.Response.CustomRevert);
    }

    function test_tokenApprovalAndOldOwnersOperatorCannotMoveTransferredToken() public {
        _mint(alice, 2);
        vm.startPrank(alice);
        cats.approve(bob, 1);
        cats.setApprovalForAll(bob, true);
        cats.transferFrom(alice, carol, 1);
        vm.stopPrank();
        assertEq(cats.getApproved(1), address(0));
        assertTrue(cats.isApprovedForAll(alice, bob));
        assertFalse(cats.isApprovedForAll(carol, bob));

        vm.startPrank(bob);
        vm.expectRevert(IERC721A.TransferCallerNotOwnerNorApproved.selector);
        cats.transferFrom(carol, bob, 1);
        vm.expectRevert(IERC721A.ApprovalCallerNotOwnerNorApproved.selector);
        cats.approve(bob, 1);
        cats.transferFrom(alice, bob, 2);
        vm.stopPrank();

        assertEq(cats.ownerOf(1), carol);
        assertEq(cats.ownerOf(2), bob);
        assertEq(cats.balanceOf(alice), 0);
        assertEq(cats.balanceOf(bob), 1);
        assertEq(cats.balanceOf(carol), 1);
        _assertFeeTotals(2);
    }

    function test_replacingAndRevokingTokenApprovalImmediatelyRevokesAuthority() public {
        _mint(alice, 1);
        vm.startPrank(alice);
        cats.approve(bob, 1);
        cats.approve(carol, 1);
        vm.stopPrank();
        vm.prank(bob);
        vm.expectRevert(IERC721A.TransferCallerNotOwnerNorApproved.selector);
        cats.transferFrom(alice, bob, 1);
        assertEq(cats.getApproved(1), carol);

        vm.prank(alice);
        cats.approve(address(0), 1);
        vm.prank(carol);
        vm.expectRevert(IERC721A.TransferCallerNotOwnerNorApproved.selector);
        cats.transferFrom(alice, carol, 1);
        assertEq(cats.getApproved(1), address(0));
        assertEq(cats.ownerOf(1), alice);
        assertEq(cats.balanceOf(alice), 1);
    }

    function test_revokedOperatorCannotTransferOrCreateNewApprovals() public {
        _mint(alice, 2);
        vm.prank(alice);
        cats.setApprovalForAll(bob, true);
        vm.prank(bob);
        cats.approve(carol, 1);
        vm.prank(alice);
        cats.setApprovalForAll(bob, false);
        vm.startPrank(bob);
        vm.expectRevert(IERC721A.TransferCallerNotOwnerNorApproved.selector);
        cats.safeTransferFrom(alice, bob, 2);
        vm.expectRevert(IERC721A.ApprovalCallerNotOwnerNorApproved.selector);
        cats.approve(bob, 2);
        vm.stopPrank();

        // Revoking a collection-wide operator does not revoke an independent
        // per-token approval, even if that operator originally granted it.
        vm.prank(carol);
        cats.transferFrom(alice, carol, 1);
        assertEq(cats.ownerOf(1), carol);
        assertEq(cats.ownerOf(2), alice);
        assertFalse(cats.isApprovedForAll(alice, bob));
        assertEq(cats.getApproved(1), address(0));
    }

    function test_selfTransferClearsTokenApprovalWithoutChangingBalancesOrMintAllowance() public {
        _mint(alice, 5);
        vm.prank(alice);
        cats.approve(bob, 3);
        vm.prank(bob);
        cats.transferFrom(alice, alice, 3);
        assertEq(cats.balanceOf(alice), 5);
        assertEq(cats.getApproved(3), address(0));
        assertEq(cats.mintedPerWallet(alice), 5);
        assertEq(cats.totalSupply(), 5);
        for (uint256 id = 1; id <= 5; ++id) {
            assertEq(cats.ownerOf(id), alice);
        }
        vm.prank(bob);
        vm.expectRevert(IERC721A.TransferCallerNotOwnerNorApproved.selector);
        cats.transferFrom(alice, bob, 3);
        vm.expectRevert(SwarmCats.WalletLimitExceeded.selector);
        _mint(alice, 1);
        _assertFeeTotals(5);
    }

    function test_incorrectFromAndNonexistentTransfersPreserveExistingApprovals() public {
        _mint(alice, 1);
        vm.prank(alice);
        cats.approve(bob, 1);
        vm.startPrank(bob);
        vm.expectRevert(IERC721A.TransferFromIncorrectOwner.selector);
        cats.transferFrom(carol, bob, 1);
        vm.expectRevert(IERC721A.OwnerQueryForNonexistentToken.selector);
        cats.transferFrom(alice, bob, 0);
        vm.expectRevert(IERC721A.OwnerQueryForNonexistentToken.selector);
        cats.transferFrom(alice, bob, type(uint256).max);
        vm.expectRevert(IERC721A.OwnerQueryForNonexistentToken.selector);
        cats.approve(bob, 2);
        vm.stopPrank();
        vm.expectRevert(IERC721A.ApprovalQueryForNonexistentToken.selector);
        cats.getApproved(2);
        vm.expectRevert(IERC721A.BalanceQueryForZeroAddress.selector);
        cats.balanceOf(address(0));
        assertEq(cats.ownerOf(1), alice);
        assertEq(cats.getApproved(1), bob);
        assertEq(cats.balanceOf(alice), 1);
        assertEq(cats.balanceOf(bob), 0);
        _assertFeeTotals(1);
    }

    function testFuzz_transferInsideMixedBatchesPreservesEveryOtherOwner(uint256 reserveQuantity, uint256 selectedId)
        public
    {
        reserveQuantity = bound(reserveQuantity, 1, 100);
        selectedId = bound(selectedId, 1, reserveQuantity + 10);
        _mint(alice, 5);
        _reserveMint(reserveQuantity);
        _mint(bob, 5);
        _transferRoundTripAtBatchBoundary(reserveQuantity, selectedId);
    }

    function test_firstAndLastIdsOfAdjacentBatchesPreserveLazyOwnership() public {
        _mint(alice, 5);
        _reserveMint(100);
        _mint(bob, 5);
        uint256[7] memory ids = [uint256(1), 5, 6, 55, 105, 106, 110];
        for (uint256 i; i < ids.length; ++i) {
            _transferRoundTripAtBatchBoundary(100, ids[i]);
        }
    }

    function test_replacingPendingOwnerRevokesNomineeAndDoesNotResetReserveAllowance() public {
        _reserveMint(99);
        vm.prank(owner);
        cats.transferOwnership(alice);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cats.pause();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cats.reserveMint{value: FEE}(1);
        vm.stopPrank();

        vm.prank(owner);
        cats.transferOwnership(bob);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cats.acceptOwnership();
        assertEq(cats.owner(), owner);
        assertEq(cats.pendingOwner(), bob);
        vm.prank(bob);
        cats.acceptOwnership();

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        cats.reserveMint{value: FEE}(1);
        vm.startPrank(bob);
        cats.reserveMint{value: FEE}(1);
        vm.expectRevert(SwarmCats.ReserveLimitExceeded.selector);
        cats.reserveMint{value: FEE}(1);
        vm.stopPrank();
        assertEq(cats.reserveMinted(), 100);
        assertEq(cats.ownerOf(99), owner);
        assertEq(cats.ownerOf(100), bob);
        assertEq(cats.balanceOf(owner), 99);
        assertEq(cats.balanceOf(bob), 1);
        _assertFeeTotals(100);
    }

    function _assertSafeTransferFailure(SwarmCatsTransferProbe.Response response) private {
        _mint(alice, 5);
        SwarmCatsTransferProbe receiver = new SwarmCatsTransferProbe(cats);
        receiver.configure(response, carol);
        vm.prank(alice);
        cats.approve(bob, 3);
        if (response == SwarmCatsTransferProbe.Response.CustomRevert) {
            vm.expectRevert(abi.encodeWithSelector(SwarmCatsTransferProbe.ReceiverRejected.selector, 3));
        } else {
            vm.expectRevert(IERC721A.TransferToNonERC721ReceiverImplementer.selector);
        }
        vm.prank(bob);
        cats.safeTransferFrom(alice, address(receiver), 3, hex"00ff010203");
        assertEq(receiver.calls(), 0);
        assertEq(cats.ownerOf(2), alice);
        assertEq(cats.ownerOf(3), alice);
        assertEq(cats.ownerOf(4), alice);
        assertEq(cats.getApproved(3), bob);
        assertEq(cats.balanceOf(alice), 5);
        assertEq(cats.balanceOf(address(receiver)), 0);
        assertEq(cats.balanceOf(carol), 0);
        assertEq(cats.totalSupply(), 5);
        assertEq(cats.mintedPerWallet(alice), 5);
        _assertFeeTotals(5);

        receiver.configure(SwarmCatsTransferProbe.Response.Accept, carol);
        vm.prank(bob);
        cats.safeTransferFrom(alice, address(receiver), 3, hex"00ff010203");
        assertEq(receiver.calls(), 1);
        assertEq(cats.ownerOf(3), carol);
        assertEq(cats.getApproved(3), address(0));
        assertEq(cats.balanceOf(alice), 4);
        assertEq(cats.balanceOf(address(receiver)), 0);
        assertEq(cats.balanceOf(carol), 1);
    }

    function _transferRoundTripAtBatchBoundary(uint256 reserveQuantity, uint256 selectedId) private {
        uint256 supply = reserveQuantity + 10;
        address originalOwner = _expectedBatchOwner(reserveQuantity, selectedId);
        vm.prank(originalOwner);
        cats.approve(carol, selectedId);
        vm.prank(carol);
        cats.transferFrom(originalOwner, carol, selectedId);
        assertEq(cats.getApproved(selectedId), address(0));
        for (uint256 id = 1; id <= supply; ++id) {
            assertEq(cats.ownerOf(id), id == selectedId ? carol : _expectedBatchOwner(reserveQuantity, id));
        }
        assertEq(cats.balanceOf(alice), 5 - (originalOwner == alice ? 1 : 0));
        assertEq(cats.balanceOf(owner), reserveQuantity - (originalOwner == owner ? 1 : 0));
        assertEq(cats.balanceOf(bob), 5 - (originalOwner == bob ? 1 : 0));
        assertEq(cats.balanceOf(carol), 1);

        vm.prank(carol);
        cats.transferFrom(carol, originalOwner, selectedId);
        for (uint256 id = 1; id <= supply; ++id) {
            assertEq(cats.ownerOf(id), _expectedBatchOwner(reserveQuantity, id));
        }
        assertEq(cats.balanceOf(alice), 5);
        assertEq(cats.balanceOf(owner), reserveQuantity);
        assertEq(cats.balanceOf(bob), 5);
        assertEq(cats.balanceOf(carol), 0);
        assertEq(cats.totalSupply(), supply);
        assertEq(cats.reserveMinted(), reserveQuantity);
        assertEq(cats.mintedPerWallet(alice), 5);
        assertEq(cats.mintedPerWallet(owner), 0);
        assertEq(cats.mintedPerWallet(bob), 5);
        _assertFeeTotals(supply);
    }

    function _expectedBatchOwner(uint256 reserveQuantity, uint256 tokenId) private view returns (address) {
        if (tokenId <= 5) return alice;
        if (tokenId <= 5 + reserveQuantity) return owner;
        return bob;
    }

    function _assertFeeTotals(uint256 minted) private view {
        assertEq(creator.balance, minted * FEE * 40 / 100);
        assertEq(platform.balance, minted * FEE * 40 / 100);
        assertEq(reserve.balance, minted * FEE * 20 / 100);
        assertEq(address(cats).balance, 0);
    }
}
