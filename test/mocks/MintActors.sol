// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SwarmCats} from "../../src/SwarmCats.sol";

/// @dev Test fixtures only; none are launch artifacts.
contract ConfigurableReceiver {
    SwarmCats public cats;
    bool public rejectEth;
    uint256 public rejectTokenId;
    uint256 public ethCalls;
    uint256 public tokenCalls;
    uint256 public observedSupply;
    uint256 public observedPublicMints;
    uint256 public observedReserveMints;
    address public forwardTo;

    function configure(SwarmCats target, bool rejectPayment, uint256 rejectedId, address recipient) external {
        cats = target;
        rejectEth = rejectPayment;
        rejectTokenId = rejectedId;
        forwardTo = recipient;
    }

    function buy(uint256 quantity) external payable {
        cats.mint{value: msg.value}(quantity);
    }

    function buyReserve(uint256 quantity) external payable {
        cats.reserveMint{value: msg.value}(quantity);
    }

    function onERC721Received(address, address, uint256 tokenId, bytes calldata) external returns (bytes4) {
        require(msg.sender == address(cats), "wrong NFT");
        require(tokenId != rejectTokenId, "NFT rejected");
        ++tokenCalls;
        observedSupply = cats.totalSupply();
        observedPublicMints = cats.mintedPerWallet(address(this));
        observedReserveMints = cats.reserveMinted();
        if (forwardTo != address(0)) cats.transferFrom(address(this), forwardTo, tokenId);
        return this.onERC721Received.selector;
    }

    receive() external payable {
        require(!rejectEth, "ETH rejected");
        ++ethCalls;
    }
}

contract ReentrantReceiver {
    SwarmCats public cats;
    bool public attackOnEth;
    bool public attackOnNft;
    bool public bubbleFailure;
    uint256 public attempts;
    uint256 public publicBlocked;
    uint256 public reserveBlocked;
    bool public unexpectedSuccess;
    bytes4 public publicError;
    bytes4 public reserveError;

    function configure(SwarmCats target, bool onEth, bool onNft, bool bubble) external {
        cats = target;
        attackOnEth = onEth;
        attackOnNft = onNft;
        bubbleFailure = bubble;
    }

    function buy(uint256 quantity) external payable {
        cats.mint{value: msg.value}(quantity);
    }

    function buyReserve(uint256 quantity) external payable {
        cats.reserveMint{value: msg.value}(quantity);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        require(msg.sender == address(cats), "wrong NFT");
        if (attackOnNft) _attack();
        return this.onERC721Received.selector;
    }

    receive() external payable {
        if (attackOnEth) _attack();
    }

    function _attack() private {
        ++attempts;
        // Stop runaway recursion if the target regresses; the test can then observe successful entry.
        if (attempts > 1) return;
        if (bubbleFailure) {
            cats.mint{value: 0.0005 ether}(1);
            return;
        }
        try cats.mint{value: 0.0005 ether}(1) {
            unexpectedSuccess = true;
        } catch (bytes memory reason) {
            ++publicBlocked;
            publicError = bytes4(reason);
        }
        try cats.reserveMint{value: 0.0005 ether}(1) {
            unexpectedSuccess = true;
        } catch (bytes memory reason) {
            ++reserveBlocked;
            reserveError = bytes4(reason);
        }
    }
}

contract NonReceiver {
    function buy(SwarmCats cats) external payable {
        cats.mint{value: msg.value}(1);
    }
}
