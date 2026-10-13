// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract LaunchTokenTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    LaunchToken private token;
    address private alice;
    address private bob;

    function setUp() public {
        token = new LaunchToken();
        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    function test_exactSupplyAndMetadata() public view {
        assertEq(token.name(), "Loom");
        assertEq(token.symbol(), "LOOM");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
    }

    function testFuzz_transferMovesExactAmountAndConservesSupply(uint256 amount) public {
        amount = bound(amount, 0, SUPPLY);
        assertTrue(token.transfer(alice, amount));
        assertEq(token.balanceOf(alice), amount);
        assertEq(token.balanceOf(address(this)), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_allowanceTransferAndUnauthorizedFailure() public {
        token.transfer(alice, 100 ether);
        vm.prank(alice);
        assertTrue(token.approve(bob, 60 ether));
        vm.prank(bob);
        assertTrue(token.transferFrom(alice, bob, 40 ether));
        assertEq(token.allowance(alice, bob), 20 ether);
        assertEq(token.balanceOf(alice), 60 ether);
        assertEq(token.balanceOf(bob), 40 ether);
        vm.prank(bob);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 20 ether, 21 ether)
        );
        token.transferFrom(alice, bob, 21 ether);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_transfersRejectInsufficientBalanceAndZeroRecipient() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 0, 1));
        token.transfer(bob, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 1);
    }

    function test_noAdminMintUpgradePauseOrBurnEntrypointsEvenForDeployer() public {
        bytes[] memory calls = new bytes[](13);
        calls[0] = abi.encodeWithSignature("mint(address,uint256)", alice, 1 ether);
        calls[1] = abi.encodeWithSignature("mint(uint256)", 1 ether);
        calls[2] = abi.encodeWithSignature("mint()");
        calls[3] = abi.encodeWithSignature("issue(uint256)", 1 ether);
        calls[4] = abi.encodeWithSignature("setOwner(address)", alice);
        calls[5] = abi.encodeWithSignature("transferOwnership(address)", alice);
        calls[6] = abi.encodeWithSignature("upgradeTo(address)", alice);
        calls[7] = abi.encodeWithSignature("initialize(address)", alice);
        calls[8] = abi.encodeWithSignature("pause()");
        calls[9] = abi.encodeWithSignature("unpause()");
        calls[10] = abi.encodeWithSignature("setMinter(address)", alice);
        calls[11] = abi.encodeWithSignature("burn(uint256)", 1 ether);
        calls[12] = abi.encodeWithSignature("setFee(uint256)", 1);
        for (uint256 i; i < calls.length; ++i) {
            (bool deployerSuccess,) = address(token).call(calls[i]);
            assertFalse(deployerSuccess);
            vm.prank(alice);
            (bool outsiderSuccess,) = address(token).call(calls[i]);
            assertFalse(outsiderSuccess);
            assertEq(token.totalSupply(), SUPPLY);
            assertEq(token.balanceOf(address(this)), SUPPLY);
            assertEq(token.balanceOf(alice), 0);
        }
    }
}
