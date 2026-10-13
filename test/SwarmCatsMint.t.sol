// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwarmCatsTestBase, SwarmCats} from "./SwarmCatsTestBase.sol";
import {IERC721A} from "erc721a/contracts/IERC721A.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract SwarmCatsMintTest is SwarmCatsTestBase {
    event Minted(address indexed minter, uint256 firstId, uint256 quantity);
    event FeesDistributed(uint256 creatorAmount, uint256 platformAmount, uint256 reserveAmount);

    function test_configuration() public view {
        assertEq(cats.name(), "Swarm Cats");
        assertEq(cats.symbol(), "SCAT");
        assertEq(cats.owner(), owner);
        assertEq(cats.CREATOR(), creator);
        assertEq(cats.PLATFORM(), platform);
        assertEq(cats.RESERVE(), reserve);
        assertEq(cats.MAX_SUPPLY(), 10_000);
        assertEq(cats.MINT_FEE(), FEE);
        assertEq(cats.MAX_PER_WALLET(), 5);
        assertEq(cats.MAX_RESERVE_SUPPLY(), 100);
        assertEq(cats.totalSupply(), 0);
        assertFalse(cats.paused());
    }

    function test_batchMintSequentialIdsAndExactSplit() public {
        vm.expectEmit(true, false, false, true, address(cats));
        emit Minted(alice, 1, 5);
        vm.expectEmit(false, false, false, true, address(cats));
        emit FeesDistributed(0.001 ether, 0.001 ether, 0.0005 ether);
        _mint(alice, 5);
        assertEq(cats.totalSupply(), 5);
        assertEq(cats.balanceOf(alice), 5);
        assertEq(cats.mintedPerWallet(alice), 5);
        for (uint256 i = 1; i <= 5; ++i) {
            assertEq(cats.ownerOf(i), alice);
        }
        assertEq(creator.balance, 0.001 ether);
        assertEq(platform.balance, 0.001 ether);
        assertEq(reserve.balance, 0.0005 ether);
        assertEq(alice.balance, 10 ether - 5 * FEE);
        assertEq(address(cats).balance, 0);

        vm.expectEmit(true, false, false, true, address(cats));
        emit Minted(bob, 6, 2);
        _mint(bob, 2);
        assertEq(cats.ownerOf(6), bob);
        assertEq(cats.ownerOf(7), bob);
    }

    function testFuzz_validQuantityConservesFees(uint256 quantity) public {
        quantity = bound(quantity, 1, 5);
        _mint(alice, quantity);
        uint256 paid = FEE * quantity;
        assertEq(cats.totalSupply(), quantity);
        assertEq(cats.balanceOf(alice), quantity);
        assertEq(creator.balance, paid * 40 / 100);
        assertEq(platform.balance, paid * 40 / 100);
        assertEq(reserve.balance, paid * 20 / 100);
        assertEq(creator.balance + platform.balance + reserve.balance, paid);
        assertEq(address(cats).balance, 0);
    }

    function test_multipleMintsShareLifetimeLimit() public {
        _mint(alice, 2);
        _mint(alice, 3);
        vm.expectRevert(SwarmCats.WalletLimitExceeded.selector);
        _mint(alice, 1);
        assertEq(cats.totalSupply(), 5);
        assertEq(cats.mintedPerWallet(alice), 5);
    }

    function test_transferringAwayDoesNotRestoreMintAllowance() public {
        _mint(alice, 5);
        vm.startPrank(alice);
        for (uint256 i = 1; i <= 5; ++i) {
            cats.transferFrom(alice, bob, i);
        }
        vm.stopPrank();
        assertEq(cats.balanceOf(alice), 0);
        vm.expectRevert(SwarmCats.WalletLimitExceeded.selector);
        _mint(alice, 1);
        _mint(bob, 5);
        assertEq(cats.balanceOf(bob), 10);
        assertEq(cats.mintedPerWallet(bob), 5);
    }

    function testFuzz_rejectInvalidQuantity(uint256 quantity) public {
        vm.assume(quantity == 0 || quantity > 5);
        vm.prank(alice);
        vm.expectRevert(SwarmCats.InvalidQuantity.selector);
        cats.mint(quantity);
        assertEq(cats.totalSupply(), 0);
    }

    function testFuzz_rejectIncorrectValue(uint256 quantity, uint256 value) public {
        quantity = bound(quantity, 1, 5);
        value = bound(value, 0, 1 ether);
        vm.assume(value != FEE * quantity);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SwarmCats.IncorrectMintFee.selector, FEE * quantity, value));
        cats.mint{value: value}(quantity);
        assertEq(alice.balance, 10 ether);
        assertEq(cats.mintedPerWallet(alice), 0);
        assertEq(cats.totalSupply(), 0);
        assertEq(creator.balance + platform.balance + reserve.balance, 0);
    }

    function test_reserveMintChargesFeeAndAllowsOneHundred() public {
        vm.expectEmit(true, false, false, true, address(cats));
        emit Minted(owner, 1, 100);
        _reserveMint(100);
        assertEq(cats.reserveMinted(), 100);
        assertEq(cats.totalSupply(), 100);
        assertEq(cats.balanceOf(owner), 100);
        assertEq(cats.ownerOf(1), owner);
        assertEq(cats.ownerOf(100), owner);
        assertEq(cats.mintedPerWallet(owner), 0);
        assertEq(owner.balance, 10 ether - 100 * FEE);
        assertEq(creator.balance, 0.02 ether);
        assertEq(platform.balance, 0.02 ether);
        assertEq(reserve.balance, 0.01 ether);
        _mint(owner, 5);
        assertEq(cats.balanceOf(owner), 105);
        vm.expectRevert(SwarmCats.WalletLimitExceeded.selector);
        _mint(owner, 1);
    }

    function test_reserveCapAppliesAcrossCallsAndOwnershipTransfers() public {
        _reserveMint(60);
        _reserveMint(40);
        vm.expectRevert(SwarmCats.ReserveLimitExceeded.selector);
        _reserveMint(1);
        vm.prank(owner);
        cats.transferOwnership(alice);
        vm.prank(alice);
        cats.acceptOwnership();
        vm.prank(alice);
        vm.expectRevert(SwarmCats.ReserveLimitExceeded.selector);
        cats.reserveMint{value: FEE}(1);
        assertEq(cats.reserveMinted(), 100);
    }

    function test_reserveMintPaysNewOwnerWithoutChangingFeeRecipients() public {
        _reserveMint(2);
        vm.prank(owner);
        cats.transferOwnership(alice);
        vm.prank(alice);
        cats.acceptOwnership();
        vm.prank(alice);
        cats.reserveMint{value: 3 * FEE}(3);
        assertEq(cats.ownerOf(3), alice);
        assertEq(cats.ownerOf(5), alice);
        assertEq(cats.reserveMinted(), 5);
        assertEq(cats.CREATOR(), creator);
        assertEq(creator.balance, FEE * 5 * 40 / 100);
    }

    function test_nonOwnerCannotReserveMint() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        cats.reserveMint{value: FEE}(1);
    }

    function testFuzz_reserveRejectsInvalidQuantity(uint256 quantity) public {
        vm.assume(quantity == 0 || quantity > 100);
        vm.prank(owner);
        vm.expectRevert(SwarmCats.InvalidQuantity.selector);
        cats.reserveMint(quantity);
    }

    function test_reserveMintRejectsUnderAndOverpayment() public {
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(SwarmCats.IncorrectMintFee.selector, 2 * FEE, 0));
        cats.reserveMint(2);
        vm.expectRevert(abi.encodeWithSelector(SwarmCats.IncorrectMintFee.selector, 2 * FEE, 2 * FEE + 1));
        cats.reserveMint{value: 2 * FEE + 1}(2);
        vm.stopPrank();
        assertEq(cats.reserveMinted(), 0);
        assertEq(cats.totalSupply(), 0);
    }

    function test_publicCanSellOutAndReserveCannotExceedGlobalCap() public {
        _fillPublicSupply(10_000);
        assertEq(cats.totalSupply(), 10_000);
        assertEq(cats.ownerOf(10_000), address(uint160(0x100000 + 1999)));
        vm.expectRevert(SwarmCats.MaxSupplyExceeded.selector);
        _mint(alice, 1);
        vm.expectRevert(SwarmCats.MaxSupplyExceeded.selector);
        _reserveMint(1);
        vm.expectRevert(IERC721A.OwnerQueryForNonexistentToken.selector);
        cats.ownerOf(10_001);
        assertEq(creator.balance + platform.balance + reserve.balance, 5 ether);
    }

    function test_publicAndReserveShareTheSameTenThousandTokenCap() public {
        _reserveMint(99);
        _fillPublicSupply(9900);
        vm.expectRevert(SwarmCats.MaxSupplyExceeded.selector);
        _mint(alice, 2);
        _reserveMint(1);
        assertEq(cats.ownerOf(10_000), owner);
        assertEq(cats.totalSupply(), 10_000);
        assertEq(cats.reserveMinted(), 100);
        vm.expectRevert(SwarmCats.MaxSupplyExceeded.selector);
        _mint(alice, 1);
    }

    function test_pauseBlocksBothMintsButNotTransfersOrApprovals() public {
        _mint(alice, 2);
        vm.prank(owner);
        cats.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _mint(bob, 1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _reserveMint(1);
        vm.prank(alice);
        cats.approve(bob, 1);
        vm.prank(bob);
        cats.transferFrom(alice, bob, 1);
        vm.prank(alice);
        cats.setApprovalForAll(bob, true);
        vm.prank(bob);
        cats.safeTransferFrom(alice, bob, 2);
        assertEq(cats.balanceOf(bob), 2);
        assertEq(creator.balance + platform.balance + reserve.balance, 2 * FEE);
        vm.prank(owner);
        cats.unpause();
        _mint(bob, 1);
        _reserveMint(1);
    }

    function test_plainTransfersRequireAuthorizationAndClearApproval() public {
        _mint(alice, 5);
        vm.prank(bob);
        vm.expectRevert(IERC721A.TransferCallerNotOwnerNorApproved.selector);
        cats.transferFrom(alice, bob, 3);
        vm.startPrank(alice);
        cats.approve(bob, 3);
        vm.stopPrank();
        vm.prank(bob);
        cats.transferFrom(alice, bob, 3);
        assertEq(cats.getApproved(3), address(0));
        assertEq(cats.ownerOf(2), alice);
        assertEq(cats.ownerOf(3), bob);
        assertEq(cats.ownerOf(4), alice);
        assertEq(cats.balanceOf(alice), 4);
        assertEq(cats.balanceOf(bob), 1);
        vm.prank(alice);
        vm.expectRevert(IERC721A.TransferToZeroAddress.selector);
        cats.transferFrom(alice, address(0), 1);
    }

    function test_sameRecipientAddressesReceiveAllFees() public {
        SwarmCats same = new SwarmCats(owner, owner, owner, owner);
        vm.prank(owner);
        same.setProvenanceHash(PROVENANCE);
        uint256 beforeBalance = owner.balance;
        vm.prank(alice);
        same.mint{value: 5 * FEE}(5);
        assertEq(owner.balance, beforeBalance + 5 * FEE);
        assertEq(address(same).balance, 0);
        vm.prank(owner);
        same.reserveMint{value: 100 * FEE}(100);
        assertEq(owner.balance, beforeBalance + 5 * FEE);
        assertEq(same.totalSupply(), 105);
    }

    function test_preexistingEthIsNotDistributedAsMintFees() public {
        vm.deal(address(cats), 7 ether);
        _mint(alice, 1);
        assertEq(address(cats).balance, 7 ether);
        assertEq(creator.balance + platform.balance + reserve.balance, FEE);
    }

    function test_plainEthTransfersRevert() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(cats).call{value: 1 wei}("");
        assertFalse(ok);
        assertEq(address(cats).balance, 0);
    }
}
