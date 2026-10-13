// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "src/LaunchToken.sol";

/// @dev The model begins from known allocations, and changes only by requested amounts.
/// It never reads the token's balances or allowances to decide the expected outcome.
contract LaunchTokenSequenceHandler is Test {
    uint256 public constant SUPPLY = 1_000_000_000 ether;
    LaunchToken public immutable token;
    address[4] public actors;
    mapping(address => uint256) public expectedBalance;
    mapping(address => mapping(address => uint256)) public expectedAllowance;

    constructor(address[4] memory actors_) {
        actors = actors_;
        token = new LaunchToken();
        for (uint256 i; i < actors.length; ++i) {
            token.transfer(actors[i], SUPPLY / actors.length);
            expectedBalance[actors[i]] = SUPPLY / actors.length;
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = _actor(fromSeed);
        address to = _recipient(toSeed);
        uint256 amount = bound(amountSeed, 0, expectedBalance[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _move(from, to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 amount = bound(amountSeed, 0, SUPPLY);
        _approve(owner, spender, amount);
    }

    function approveInfinite(uint256 ownerSeed, uint256 spenderSeed) external {
        _approve(_actor(ownerSeed), _actor(spenderSeed), type(uint256).max);
    }

    function revoke(uint256 ownerSeed, uint256 spenderSeed) external {
        _approve(_actor(ownerSeed), _actor(spenderSeed), 0);
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        address to = _recipient(toSeed);
        uint256 allowance = expectedAllowance[owner][spender];
        uint256 available = expectedBalance[owner];
        uint256 amount = bound(amountSeed, 0, available < allowance ? available : allowance);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        if (allowance != type(uint256).max) expectedAllowance[owner][spender] -= amount;
        _move(owner, to, amount);
    }

    function rejectInsufficientBalance(uint256 ownerSeed, uint256 toSeed) external {
        address owner = _actor(ownerSeed);
        uint256 balance = expectedBalance[owner];
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, balance + 1)
        );
        token.transfer(_recipient(toSeed), balance + 1);
    }

    function rejectInsufficientAllowance(uint256 ownerSeed, uint256 spenderSeed, uint256 approvedSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 approved = bound(approvedSeed, 0, SUPPLY);
        _approve(owner, spender, approved);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, approved, approved + 1)
        );
        token.transferFrom(owner, spender, approved + 1);
    }

    function rejectDelegatedInsufficientBalance(uint256 ownerSeed, uint256 spenderSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 balance = expectedBalance[owner];
        // A finite approval forces transferFrom to restore the spent allowance when the transfer fails.
        _approve(owner, spender, balance + 1);
        vm.prank(spender);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balance, balance + 1)
        );
        token.transferFrom(owner, spender, balance + 1);
    }

    function rejectZeroRecipient(uint256 ownerSeed, uint256 amountSeed) external {
        address owner = _actor(ownerSeed);
        uint256 amount = bound(amountSeed, 0, expectedBalance[owner]);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        token.transfer(address(0), amount);
    }

    function _approve(address owner, address spender, uint256 amount) private {
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        expectedAllowance[owner][spender] = amount;
    }

    function _move(address from, address to, uint256 amount) private {
        expectedBalance[from] -= amount;
        expectedBalance[to] += amount;
    }

    function _actor(uint256 seed) private view returns (address) {
        return actors[seed % actors.length];
    }

    function _recipient(uint256 seed) private view returns (address) {
        uint256 index = seed % (actors.length + 1);
        // A transfer to the token itself remains part of circulating supply, with no burn or recovery privilege.
        return index == actors.length ? address(token) : actors[index];
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenInvariantTest is StdInvariant, Test {
    uint256 private constant SUPPLY = 1_000_000_000 ether;
    LaunchTokenSequenceHandler private handler;
    LaunchToken private token;

    function setUp() public {
        address[4] memory actors = [
            makeAddr("token invariant alice"),
            makeAddr("token invariant bob"),
            makeAddr("token invariant carol"),
            makeAddr("token invariant dave")
        ];
        handler = new LaunchTokenSequenceHandler(actors);
        token = handler.token();

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.approveInfinite.selector;
        selectors[3] = handler.revoke.selector;
        selectors[4] = handler.transferFrom.selector;
        selectors[5] = handler.rejectInsufficientBalance.selector;
        selectors[6] = handler.rejectInsufficientAllowance.selector;
        selectors[7] = handler.rejectDelegatedInsufficientBalance.selector;
        selectors[8] = handler.rejectZeroRecipient.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_balancesMatchIndependentModelAndSupplyIsConserved() public view {
        uint256 total;
        for (uint256 i; i < 4; ++i) {
            address actor = handler.actors(i);
            uint256 balance = token.balanceOf(actor);
            assertEq(balance, handler.expectedBalance(actor), "actor balance differs from ghost ledger");
            total += balance;
        }
        uint256 tokenBalance = token.balanceOf(address(token));
        assertEq(tokenBalance, handler.expectedBalance(address(token)), "token custody differs from ghost ledger");
        total += tokenBalance;
        assertEq(total, SUPPLY, "tracked balances do not conserve the fixed supply");
        assertEq(token.totalSupply(), SUPPLY, "supply changed during a call sequence");
        assertEq(token.balanceOf(address(handler)), 0, "deployer regained tokens without a transfer");
        assertEq(token.balanceOf(address(0)), 0, "tokens were assigned to zero address");
    }

    function invariant_allowancesMatchIndependentModel() public view {
        for (uint256 i; i < 4; ++i) {
            address owner = handler.actors(i);
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actors(j);
                assertEq(
                    token.allowance(owner, spender),
                    handler.expectedAllowance(owner, spender),
                    "allowance replacement, spend or rollback differs from model"
                );
            }
            assertEq(token.allowance(owner, address(handler)), 0, "handler was never approved");
            assertEq(token.allowance(owner, address(0)), 0, "zero address was never approved");
        }
    }
}
