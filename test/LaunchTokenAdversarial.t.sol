// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "src/LaunchToken.sol";

contract LaunchTokenAdversarialTest is Test {
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    LaunchToken private token;
    address private holder;
    address private spender;
    address private recipient;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function setUp() public {
        holder = makeAddr("token holder");
        spender = makeAddr("token spender");
        recipient = makeAddr("token recipient");
        token = new LaunchToken();
        token.transfer(holder, SUPPLY);
    }

    function test_zeroTransfersEmitEventsWithoutAnAllowanceOrBalance() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(recipient, holder, 0);
        vm.prank(recipient);
        assertTrue(token.transfer(holder, 0));

        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(recipient, holder, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(recipient, holder, 0));

        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.allowance(recipient, spender), 0);
    }

    function test_approvalReplacesRatherThanAddsAndCanBeRevoked() public {
        vm.startPrank(holder);
        token.approve(spender, 100);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(holder, spender, 3);
        assertTrue(token.approve(spender, 3));
        assertEq(token.allowance(holder, spender), 3);
        token.approve(spender, 0);
        vm.stopPrank();

        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(holder, recipient, 1);
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
        assertEq(token.allowance(holder, spender), 0);
    }

    function test_infiniteApprovalSurvivesRepeatedSpendsAndCanBeReplaced() public {
        vm.prank(holder);
        token.approve(spender, type(uint256).max);
        vm.startPrank(spender);
        token.transferFrom(holder, recipient, 1);
        token.transferFrom(holder, recipient, SUPPLY - 1);
        vm.stopPrank();

        assertEq(token.allowance(holder, spender), type(uint256).max);
        assertEq(token.balanceOf(holder), 0);
        assertEq(token.balanceOf(recipient), SUPPLY);
        vm.prank(holder);
        token.approve(spender, 1);
        assertEq(token.allowance(holder, spender), 1);
    }

    function test_selfTransferMovesNoBalanceButDelegatedTransferConsumesAllowance() public {
        vm.startPrank(holder);
        token.transfer(holder, SUPPLY);
        token.approve(spender, SUPPLY);
        vm.stopPrank();
        vm.prank(spender);
        token.transferFrom(holder, holder, SUPPLY);

        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.allowance(holder, spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_holderNeedsItsOwnAllowanceForTransferFrom() public {
        vm.startPrank(holder);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, holder, 0, 1));
        token.transferFrom(holder, recipient, 1);
        token.approve(holder, 1);
        token.transferFrom(holder, recipient, 1);
        vm.stopPrank();

        assertEq(token.allowance(holder, holder), 0);
        assertEq(token.balanceOf(holder), SUPPLY - 1);
        assertEq(token.balanceOf(recipient), 1);
    }

    function test_failedBalanceCheckRollsBackFiniteAllowanceConsumption() public {
        vm.prank(holder);
        token.approve(spender, SUPPLY + 1);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, SUPPLY, SUPPLY + 1)
        );
        token.transferFrom(holder, recipient, SUPPLY + 1);

        assertEq(token.allowance(holder, spender), SUPPLY + 1);
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_uint256MaxTransferFailsWithoutChangingInfiniteApproval() public {
        vm.prank(holder);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, holder, SUPPLY, type(uint256).max)
        );
        token.transferFrom(holder, recipient, type(uint256).max);

        assertEq(token.allowance(holder, spender), type(uint256).max);
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
    }

    function test_zeroRecipientFailureRollsBackAllowanceConsumption() public {
        vm.prank(holder);
        token.approve(spender, 1);
        vm.prank(spender);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(holder, address(0), 1);

        assertEq(token.allowance(holder, spender), 1);
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_zeroValueDoesNotMakeZeroAddressesValid() public {
        vm.startPrank(holder);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
        // transferFrom validates the allowance owner before reaching its sender check.
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidApprover.selector, address(0)));
        token.transferFrom(address(0), recipient, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transferFrom(holder, address(0), 0);
        vm.stopPrank();
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(holder), SUPPLY);
    }

    function test_finiteApprovalCannotBeReusedAfterFullSpend() public {
        vm.prank(holder);
        token.approve(spender, 1);
        vm.startPrank(spender);
        token.transferFrom(holder, recipient, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        token.transferFrom(holder, recipient, 1);
        vm.stopPrank();

        assertEq(token.balanceOf(holder), SUPPLY - 1);
        assertEq(token.balanceOf(recipient), 1);
        assertEq(token.allowance(holder, spender), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_finiteApprovalSpendsExactlyOnce(uint256 approved, uint256 amount) public {
        approved = bound(approved, 0, SUPPLY);
        amount = bound(amount, 0, approved);
        vm.prank(holder);
        token.approve(spender, approved);
        vm.prank(spender);
        assertTrue(token.transferFrom(holder, recipient, amount));

        assertEq(token.balanceOf(holder), SUPPLY - amount);
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.allowance(holder, spender), approved - amount);
        assertEq(token.allowance(holder, recipient), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_arbitraryApprovalIsReplacedAndCannotBeUsedByAnotherSpender(uint256 first, uint256 second) public {
        vm.startPrank(holder);
        token.approve(spender, first);
        token.approve(spender, second);
        vm.stopPrank();
        assertEq(token.allowance(holder, spender), second);

        vm.prank(recipient);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, recipient, 0, 1));
        token.transferFrom(holder, recipient, 1);
        assertEq(token.allowance(holder, spender), second);
        assertEq(token.balanceOf(holder), SUPPLY);
        assertEq(token.balanceOf(recipient), 0);
    }
}
