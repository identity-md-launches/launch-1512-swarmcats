// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwarmCatsTestBase, SwarmCats} from "./SwarmCatsTestBase.sol";
import {IERC721A} from "erc721a/contracts/IERC721A.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract SwarmCatsMetadataTest is SwarmCatsTestBase {
    event ProvenanceSet(bytes32 provenanceHash);
    event Revealed(bytes32 seed);
    event MetadataFrozen();
    event BaseURISet(string uri);
    event UnrevealedURISet(string uri);

    function test_provenanceIsRequiredBeforeEitherMintPath() public {
        SwarmCats fresh = new SwarmCats(owner, creator, platform, reserve);
        assertFalse(fresh.provenanceSet());
        assertEq(fresh.PROVENANCE_HASH(), bytes32(0));
        vm.prank(alice);
        vm.expectRevert(SwarmCats.ProvenanceNotSet.selector);
        fresh.mint{value: FEE}(1);
        vm.prank(owner);
        vm.expectRevert(SwarmCats.ProvenanceNotSet.selector);
        fresh.reserveMint{value: FEE}(1);
        vm.prank(owner);
        vm.expectEmit(false, false, false, true, address(fresh));
        emit ProvenanceSet(PROVENANCE);
        fresh.setProvenanceHash(PROVENANCE);
        vm.prank(alice);
        fresh.mint{value: FEE}(1);
        assertEq(fresh.totalSupply(), 1);
    }

    function test_provenanceCannotBeSetToZeroOrChangedBeforeMinting() public {
        SwarmCats fresh = new SwarmCats(owner, creator, platform, reserve);
        vm.startPrank(owner);
        vm.expectRevert(SwarmCats.InvalidProvenanceHash.selector);
        fresh.setProvenanceHash(bytes32(0));
        fresh.setProvenanceHash(PROVENANCE);
        vm.expectRevert(SwarmCats.ProvenanceAlreadySet.selector);
        fresh.setProvenanceHash(keccak256("replacement"));
        vm.stopPrank();
        assertEq(fresh.PROVENANCE_HASH(), PROVENANCE);
        assertTrue(fresh.provenanceSet());
    }

    function test_provenanceCannotChangeAfterPublicMint() public {
        _mint(alice, 1);
        vm.prank(owner);
        vm.expectRevert(SwarmCats.MintingAlreadyStarted.selector);
        cats.setProvenanceHash(keccak256("replacement"));
        assertEq(cats.PROVENANCE_HASH(), PROVENANCE);
    }

    function test_provenanceCannotChangeAfterReserveMint() public {
        _reserveMint(1);
        vm.prank(owner);
        vm.expectRevert(SwarmCats.MintingAlreadyStarted.selector);
        cats.setProvenanceHash(keccak256("replacement"));
    }

    function test_defaultUrisEmptyAndNonexistentIdsRevert() public {
        assertEq(cats.baseURI(), "");
        assertEq(cats.unrevealedURI(), "");
        _mint(alice, 1);
        assertEq(cats.tokenURI(1), "");
        vm.expectRevert(IERC721A.URIQueryForNonexistentToken.selector);
        cats.tokenURI(0);
        vm.expectRevert(IERC721A.URIQueryForNonexistentToken.selector);
        cats.tokenURI(2);
        vm.expectRevert(IERC721A.OwnerQueryForNonexistentToken.selector);
        cats.ownerOf(0);
    }

    function test_uriSwitchesOnBaseUriAndUsesDecimalIdAndJsonSuffix() public {
        _mint(alice, 5);
        _mint(bob, 5);
        vm.startPrank(owner);
        vm.expectEmit(false, false, false, true, address(cats));
        emit UnrevealedURISet("ipfs://test-placeholder/hidden.json");
        cats.setUnrevealedURI("ipfs://test-placeholder/hidden.json");
        assertEq(cats.tokenURI(1), "ipfs://test-placeholder/hidden.json");
        assertEq(cats.tokenURI(10), "ipfs://test-placeholder/hidden.json");
        vm.expectEmit(false, false, false, true, address(cats));
        emit BaseURISet("ipfs://test-collection/");
        cats.setBaseURI("ipfs://test-collection/");
        assertEq(cats.tokenURI(1), "ipfs://test-collection/1.json");
        assertEq(cats.tokenURI(10), "ipfs://test-collection/10.json");
        assertFalse(cats.revealed());
        cats.setBaseURI("");
        assertEq(cats.tokenURI(1), "ipfs://test-placeholder/hidden.json");
        vm.stopPrank();
    }

    function testFuzz_revealStoresExactlyOneSeed(bytes32 seed) public {
        assertFalse(cats.revealed());
        vm.startPrank(owner);
        vm.expectEmit(false, false, false, true, address(cats));
        emit Revealed(seed);
        cats.setRevealSeed(seed);
        assertTrue(cats.revealed());
        assertEq(cats.revealSeed(), seed);
        vm.expectRevert(SwarmCats.RevealAlreadySet.selector);
        cats.setRevealSeed(keccak256("second seed"));
        vm.stopPrank();
    }

    function test_zeroRevealSeedCannotBeUsedToRevealTwice() public {
        vm.startPrank(owner);
        cats.setRevealSeed(bytes32(0));
        assertTrue(cats.revealed());
        vm.expectRevert(SwarmCats.RevealAlreadySet.selector);
        cats.setRevealSeed(bytes32(0));
        vm.stopPrank();
    }

    function test_revealSeedDoesNotShuffleOrChangeTokenUri() public {
        _mint(alice, 1);
        vm.startPrank(owner);
        cats.setBaseURI("ipfs://test-collection/");
        cats.setRevealSeed(keccak256("oracle output"));
        vm.stopPrank();
        assertEq(cats.tokenURI(1), "ipfs://test-collection/1.json");
        assertEq(cats.ownerOf(1), alice);
    }

    function test_freezeLocksBothUrisAndCannotBeRepeated() public {
        _mint(alice, 1);
        vm.startPrank(owner);
        cats.setBaseURI("ipfs://test-collection/");
        cats.setUnrevealedURI("ipfs://test-placeholder/hidden.json");
        vm.expectEmit(false, false, false, true, address(cats));
        emit MetadataFrozen();
        cats.freezeMetadata();
        assertTrue(cats.metadataFrozen());
        vm.expectRevert(SwarmCats.MetadataIsFrozen.selector);
        cats.setBaseURI("ipfs://replacement/");
        vm.expectRevert(SwarmCats.MetadataIsFrozen.selector);
        cats.setBaseURI("");
        vm.expectRevert(SwarmCats.MetadataIsFrozen.selector);
        cats.setUnrevealedURI("replacement");
        vm.expectRevert(SwarmCats.MetadataIsFrozen.selector);
        cats.freezeMetadata();
        cats.setRevealSeed(keccak256("oracle output"));
        vm.stopPrank();
        assertEq(cats.tokenURI(1), "ipfs://test-collection/1.json");
        _mint(alice, 1);
    }

    function test_freezeWithEmptyBasePermanentlyUsesUnrevealedUri() public {
        _mint(alice, 1);
        vm.startPrank(owner);
        cats.setUnrevealedURI("ipfs://test-placeholder/hidden.json");
        cats.freezeMetadata();
        vm.expectRevert(SwarmCats.MetadataIsFrozen.selector);
        cats.setUnrevealedURI("replacement");
        vm.expectRevert(SwarmCats.MetadataIsFrozen.selector);
        cats.setBaseURI("ipfs://test-collection/");
        vm.stopPrank();
        assertEq(cats.tokenURI(1), "ipfs://test-placeholder/hidden.json");
    }

    function test_royaltiesAndInterfaceSupport() public view {
        assertEq(cats.ROYALTY_BPS(), 500);
        (address receiver, uint256 amount) = cats.royaltyInfo(1, 2 ether);
        assertEq(receiver, creator);
        assertEq(amount, 0.1 ether);
        assertTrue(cats.supportsInterface(0x01ffc9a7)); // ERC-165
        assertTrue(cats.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(cats.supportsInterface(0x5b5e139f)); // ERC-721 metadata
        assertTrue(cats.supportsInterface(0x2a55205a)); // ERC-2981
        assertFalse(cats.supportsInterface(0xffffffff));
        assertFalse(cats.supportsInterface(0x780e9d63)); // No ERC721Enumerable claim
    }

    function testFuzz_royaltyRounding(uint256 price, uint256 tokenId) public view {
        price = bound(price, 0, type(uint128).max);
        (address receiver, uint256 amount) = cats.royaltyInfo(tokenId, price);
        assertEq(receiver, creator);
        assertEq(amount, price / 20);
    }
}

contract SwarmCatsAdminTest is SwarmCatsTestBase {
    function test_allOwnerFunctionsRejectUnauthorizedCaller() public {
        bytes[] memory calls = new bytes[](9);
        calls[0] = abi.encodeCall(cats.setBaseURI, ("ipfs://unauthorized/"));
        calls[1] = abi.encodeCall(cats.setUnrevealedURI, ("ipfs://unauthorized.json"));
        calls[2] = abi.encodeCall(cats.setRevealSeed, (keccak256("unauthorized")));
        calls[3] = abi.encodeCall(cats.setProvenanceHash, (keccak256("unauthorized")));
        calls[4] = abi.encodeCall(cats.freezeMetadata, ());
        calls[5] = abi.encodeCall(cats.pause, ());
        calls[6] = abi.encodeCall(cats.unpause, ());
        calls[7] = abi.encodeCall(cats.transferOwnership, (alice));
        calls[8] = abi.encodeCall(cats.renounceOwnership, ());
        bytes memory expected = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(alice);
            (bool success, bytes memory result) = address(cats).call(calls[i]);
            assertFalse(success);
            assertEq(result, expected);
        }
    }

    function test_constructorRejectsZeroOwnerAndAnyZeroRecipient() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new SwarmCats(address(0), creator, platform, reserve);
        vm.expectRevert(SwarmCats.InvalidRecipient.selector);
        new SwarmCats(owner, address(0), platform, reserve);
        vm.expectRevert(SwarmCats.InvalidRecipient.selector);
        new SwarmCats(owner, creator, address(0), reserve);
        vm.expectRevert(SwarmCats.InvalidRecipient.selector);
        new SwarmCats(owner, creator, platform, address(0));
    }

    function test_ownershipTransferRequiresAcceptanceAndPreservesConfiguration() public {
        vm.prank(owner);
        cats.transferOwnership(alice);
        assertEq(cats.owner(), owner);
        assertEq(cats.pendingOwner(), alice);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        cats.acceptOwnership();
        vm.prank(alice);
        cats.acceptOwnership();
        assertEq(cats.owner(), alice);
        assertEq(cats.pendingOwner(), address(0));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        cats.pause();
        vm.prank(alice);
        cats.pause();
        assertTrue(cats.paused());
        assertEq(cats.CREATOR(), creator);
        assertEq(cats.PLATFORM(), platform);
        assertEq(cats.RESERVE(), reserve);
        assertEq(cats.PROVENANCE_HASH(), PROVENANCE);
        (address receiver, uint256 royalty) = cats.royaltyInfo(1, 1 ether);
        assertEq(receiver, creator);
        assertEq(royalty, 0.05 ether);
    }

    function test_ownershipTransferCanBeCancelled() public {
        vm.startPrank(owner);
        cats.transferOwnership(alice);
        cats.transferOwnership(address(0));
        vm.stopPrank();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cats.acceptOwnership();
        assertEq(cats.owner(), owner);
    }

    function test_renouncingOwnershipIsIrreversibleAndClearsPendingOwner() public {
        vm.startPrank(owner);
        cats.transferOwnership(alice);
        cats.renounceOwnership();
        vm.stopPrank();
        assertEq(cats.owner(), address(0));
        assertEq(cats.pendingOwner(), address(0));
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        cats.pause();
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cats.acceptOwnership();
        _mint(bob, 1);
    }

    function test_pauseTransitionsRejectDuplicates() public {
        vm.startPrank(owner);
        vm.expectRevert(Pausable.ExpectedPause.selector);
        cats.unpause();
        cats.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        cats.pause();
        cats.unpause();
        vm.stopPrank();
        assertFalse(cats.paused());
    }
}
