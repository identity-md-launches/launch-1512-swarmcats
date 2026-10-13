// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {SwarmCats} from "../src/SwarmCats.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract FactoryFixture {
    function deploy(address owner) external returns (LaunchToken token, SwarmCats cats) {
        token = new LaunchToken();
        cats = new SwarmCats(owner, owner, owner, owner);
    }
}

contract RejectAllCalls {
    fallback() external {
        revert("constructor must not call dependencies");
    }
}

contract DeploymentTest is Test {
    function test_factoryDeploymentUsesExplicitOwnerAndPreservesTokenAllocation() public {
        vm.chainId(11155111);
        address launchOwner = address(bytes20(hex"02b4bd9cc103fd502b2f3f601e29e6ae2039ac85"));
        FactoryFixture factory = new FactoryFixture();
        (LaunchToken token, SwarmCats cats) = factory.deploy(launchOwner);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(factory)), 1e27);
        assertEq(token.balanceOf(address(cats)), 0);
        assertEq(cats.owner(), launchOwner);
        assertEq(cats.CREATOR(), launchOwner);
        assertEq(cats.PLATFORM(), launchOwner);
        assertEq(cats.RESERVE(), launchOwner);
        assertEq(cats.totalSupply(), 0);
        assertFalse(cats.provenanceSet());
        assertEq(cats.baseURI(), "");
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(factory)));
        cats.pause();
        vm.prank(launchOwner);
        cats.setProvenanceHash(keccak256("real commitment supplied after launch"));
        assertEq(token.balanceOf(address(factory)), 1e27);
    }

    function test_constructorDoesNotRequireCodeOrCallRecipients() public {
        address empty = makeAddr("undeployed owner and recipients");
        assertEq(empty.code.length, 0);
        SwarmCats noCode = new SwarmCats(empty, empty, empty, empty);
        assertEq(noCode.owner(), empty);
        RejectAllCalls sentinel = new RejectAllCalls();
        address rejecting = address(sentinel);
        SwarmCats noCalls = new SwarmCats(rejecting, rejecting, rejecting, rejecting);
        assertEq(noCalls.owner(), rejecting);
    }

    function test_runtimeSizeAndForbiddenOpcodesMatchProjectFloor() public {
        LaunchToken token = new LaunchToken();
        address owner = makeAddr("owner");
        SwarmCats cats = new SwarmCats(owner, owner, owner, owner);
        _checkRuntime(address(token));
        _checkRuntime(address(cats));
    }

    function _checkRuntime(address deployed) private view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden runtime opcode");
        }
    }
}
