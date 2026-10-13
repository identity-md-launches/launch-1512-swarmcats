// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwarmCatsTestBase, SwarmCats} from "./SwarmCatsTestBase.sol";
import {ConfigurableReceiver, ReentrantReceiver, NonReceiver} from "./mocks/MintActors.sol";
import {IERC721A} from "erc721a/contracts/IERC721A.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract SwarmCatsAdversarialTest is SwarmCatsTestBase {
    function setUp() public override {
        super.setUp();
        vm.deal(address(this), 10 ether);
    }

    function test_safeMintChecksReceiverForEveryTokenAfterUpdatingAllState() public {
        ConfigurableReceiver receiver = new ConfigurableReceiver();
        receiver.configure(cats, false, 0, address(0));
        receiver.buy{value: 5 * FEE}(5);
        assertEq(receiver.tokenCalls(), 5);
        assertEq(receiver.observedSupply(), 5);
        assertEq(receiver.observedPublicMints(), 5);
        assertEq(cats.balanceOf(address(receiver)), 5);
    }

    function test_safeReserveMintExposesUpdatedReserveCounterToReceiver() public {
        ConfigurableReceiver receiver = new ConfigurableReceiver();
        cats = new SwarmCats(address(receiver), creator, platform, reserve);
        receiver.configure(cats, false, 0, address(0));
        vm.prank(address(receiver));
        cats.setProvenanceHash(PROVENANCE);
        receiver.buyReserve{value: 100 * FEE}(100);
        assertEq(receiver.tokenCalls(), 100);
        assertEq(receiver.observedSupply(), 100);
        assertEq(receiver.observedReserveMints(), 100);
    }

    function test_receiverMayTransferDuringCallbackWithoutRestoringAllowance() public {
        ConfigurableReceiver receiver = new ConfigurableReceiver();
        receiver.configure(cats, false, 0, alice);
        receiver.buy{value: 5 * FEE}(5);
        assertEq(cats.balanceOf(address(receiver)), 0);
        assertEq(cats.balanceOf(alice), 5);
        assertEq(cats.mintedPerWallet(address(receiver)), 5);
        for (uint256 i = 1; i <= 5; ++i) {
            assertEq(cats.ownerOf(i), alice);
        }
        vm.expectRevert(SwarmCats.WalletLimitExceeded.selector);
        receiver.buy{value: FEE}(1);
    }

    function test_lastReceiverRejectionRollsBackWholeBatchAndPayments() public {
        ConfigurableReceiver receiver = new ConfigurableReceiver();
        receiver.configure(cats, false, 5, address(0));
        uint256 beforeBalance = address(this).balance;
        vm.expectRevert(bytes("NFT rejected"));
        receiver.buy{value: 5 * FEE}(5);
        assertEq(address(this).balance, beforeBalance);
        assertEq(cats.totalSupply(), 0);
        assertEq(cats.mintedPerWallet(address(receiver)), 0);
        assertEq(receiver.tokenCalls(), 0);
        assertEq(creator.balance + platform.balance + reserve.balance, 0);
        receiver.configure(cats, false, 0, address(0));
        receiver.buy{value: FEE}(1);
        assertEq(cats.ownerOf(1), address(receiver));
    }

    function test_nonReceiverCannotMintAndSafeTransferRevertsWithoutChangingOwner() public {
        NonReceiver receiver = new NonReceiver();
        vm.expectRevert(IERC721A.TransferToNonERC721ReceiverImplementer.selector);
        receiver.buy{value: FEE}(cats);
        assertEq(cats.totalSupply(), 0);
        assertEq(cats.mintedPerWallet(address(receiver)), 0);
        _mint(alice, 1);
        vm.prank(alice);
        vm.expectRevert(IERC721A.TransferToNonERC721ReceiverImplementer.selector);
        cats.safeTransferFrom(alice, address(receiver), 1);
        assertEq(cats.ownerOf(1), alice);
    }

    function testFuzz_anyFailedFeeRecipientRollsBackEarlierPaymentsAndMint(uint256 failedIndex) public {
        failedIndex = bound(failedIndex, 0, 2);
        ConfigurableReceiver[3] memory recipients;
        for (uint256 i; i < 3; ++i) {
            recipients[i] = new ConfigurableReceiver();
        }
        cats = new SwarmCats(owner, address(recipients[0]), address(recipients[1]), address(recipients[2]));
        for (uint256 i; i < 3; ++i) {
            recipients[i].configure(cats, i == failedIndex, 0, address(0));
        }
        vm.prank(owner);
        cats.setProvenanceHash(PROVENANCE);
        uint256 failedAmount = 5 * FEE * (failedIndex == 2 ? 20 : 40) / 100;
        vm.expectRevert(
            abi.encodeWithSelector(SwarmCats.FeeTransferFailed.selector, address(recipients[failedIndex]), failedAmount)
        );
        _mint(alice, 5);
        assertEq(alice.balance, 10 ether);
        assertEq(cats.totalSupply(), 0);
        assertEq(cats.mintedPerWallet(alice), 0);
        assertEq(address(cats).balance, 0);
        for (uint256 i; i < 3; ++i) {
            assertEq(address(recipients[i]).balance, 0);
            assertEq(recipients[i].ethCalls(), 0);
        }
        recipients[failedIndex].configure(cats, false, 0, address(0));
        _mint(alice, 5);
        assertEq(cats.ownerOf(1), alice);
        assertEq(cats.totalSupply(), 5);
    }

    function test_failedReservePaymentRollsBackTeamAllowance() public {
        ConfigurableReceiver rejecting = new ConfigurableReceiver();
        cats = new SwarmCats(owner, creator, platform, address(rejecting));
        rejecting.configure(cats, true, 0, address(0));
        vm.prank(owner);
        cats.setProvenanceHash(PROVENANCE);
        vm.expectRevert(abi.encodeWithSelector(SwarmCats.FeeTransferFailed.selector, address(rejecting), 100 * FEE / 5));
        _reserveMint(100);
        assertEq(cats.reserveMinted(), 0);
        assertEq(cats.balanceOf(owner), 0);
        assertEq(owner.balance, 10 ether);
        assertEq(creator.balance, 0);
        assertEq(platform.balance, 0);
        rejecting.configure(cats, false, 0, address(0));
        _reserveMint(100);
        assertEq(cats.reserveMinted(), 100);
    }

    function test_reentrancyFromNftReceiverCannotEnterEitherMintPath() public {
        ReentrantReceiver attacker = _attacker(false, true, false);
        attacker.buy{value: 2 * FEE}(2);
        _assertBlocked(attacker);
        assertEq(cats.totalSupply(), 2);
        assertEq(cats.mintedPerWallet(address(attacker)), 2);
        assertEq(cats.reserveMinted(), 0);
    }

    function test_reentrancyFromReserveReceiverCannotEnterEitherMintPath() public {
        ReentrantReceiver attacker = _attacker(false, true, false);
        attacker.buyReserve{value: 2 * FEE}(2);
        _assertBlocked(attacker);
        assertEq(cats.totalSupply(), 2);
        assertEq(cats.reserveMinted(), 2);
        assertEq(cats.mintedPerWallet(address(attacker)), 0);
    }

    function test_reentrancyFromFeeRecipientCannotEnterEitherMintPath() public {
        ReentrantReceiver attacker = _attacker(true, false, false);
        _mint(alice, 2);
        _assertBlocked(attacker);
        assertEq(cats.totalSupply(), 2);
        assertEq(cats.reserveMinted(), 0);
        assertEq(cats.mintedPerWallet(address(attacker)), 0);
        assertEq(address(attacker).balance, 1 ether + 2 * FEE * 40 / 100);
    }

    function test_bubblingReentrancyFromReceiverRevertsAllMintState() public {
        ReentrantReceiver attacker = _attacker(false, true, true);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        attacker.buy{value: FEE}(1);
        assertEq(cats.totalSupply(), 0);
        assertEq(cats.mintedPerWallet(address(attacker)), 0);
        assertEq(address(attacker).balance, 1 ether);
    }

    function test_bubblingReentrancyFromPayoutRevertsAllMintState() public {
        ReentrantReceiver attacker = _attacker(true, false, true);
        vm.expectRevert(abi.encodeWithSelector(SwarmCats.FeeTransferFailed.selector, address(attacker), FEE * 40 / 100));
        _mint(alice, 1);
        assertEq(cats.totalSupply(), 0);
        assertEq(cats.mintedPerWallet(alice), 0);
        assertEq(alice.balance, 10 ether);
    }

    function _attacker(bool onEth, bool onNft, bool bubble) private returns (ReentrantReceiver attacker) {
        attacker = new ReentrantReceiver();
        cats = new SwarmCats(address(attacker), address(attacker), platform, reserve);
        attacker.configure(cats, onEth, onNft, bubble);
        vm.deal(address(attacker), 1 ether);
        vm.prank(address(attacker));
        cats.setProvenanceHash(PROVENANCE);
    }

    function _assertBlocked(ReentrantReceiver attacker) private view {
        assertFalse(attacker.unexpectedSuccess());
        assertEq(attacker.publicBlocked(), 1);
        assertEq(attacker.reserveBlocked(), 1);
        assertEq(attacker.publicError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(attacker.reserveError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }
}
