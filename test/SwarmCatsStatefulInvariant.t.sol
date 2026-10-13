// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SwarmCats} from "src/SwarmCats.sol";
import {IERC721A} from "erc721a/contracts/IERC721A.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/// @dev Actors and fee recipients are disjoint. Model updates come from successful inputs,
/// never from the collection's balances, counters, owner, or approval getters.
contract SwarmCatsStatefulHandler is Test {
    uint256 private constant FEE = 0.0005 ether;
    uint256 private constant ACTOR_COUNT = 6;
    bytes32 public constant COMMITMENT = keccak256("stateful collection commitment");
    SwarmCats public immutable cats;
    address[6] public actors;
    address public modelOwner;
    address public modelPendingOwner;
    mapping(address => uint256) public publicMints;
    mapping(address => uint256) public modelBalance;
    mapping(uint256 => address) public tokenOwner;
    mapping(uint256 => address) public tokenApproval;
    mapping(address => mapping(address => bool)) public operatorApproval;
    uint256 public minted;
    uint256 public teamMints;
    uint256 public successfulTransfers;
    uint256 public rejectedCalls;
    uint256 public acceptedOwnerships;
    bool public modelPaused;
    bool public modelFrozen;
    bool public modelRevealed;
    bytes32 public modelSeed;
    string public modelBaseURI;
    string public modelUnrevealedURI;

    constructor(SwarmCats target, address[6] memory participants) {
        cats = target;
        actors = participants;
        modelOwner = participants[0];
    }

    function mint(bool team, uint256 actorSeed, uint256 quantitySeed) external {
        address actor = team && modelOwner != address(0) ? modelOwner : actors[actorSeed % ACTOR_COUNT];
        uint256 remaining = team ? 100 - teamMints : 5 - publicMints[actor];
        uint256 quantity = remaining == 0 ? 1 : bound(quantitySeed, 1, remaining);
        bytes memory data = team ? abi.encodeCall(cats.reserveMint, (quantity)) : abi.encodeCall(cats.mint, (quantity));
        bytes memory expected;
        if (team && actor != modelOwner) {
            expected = _unauthorized(actor);
        } else if (modelPaused) {
            expected = abi.encodeWithSelector(Pausable.EnforcedPause.selector);
        } else if (remaining == 0) {
            expected = abi.encodeWithSelector(
                team ? SwarmCats.ReserveLimitExceeded.selector : SwarmCats.WalletLimitExceeded.selector
            );
        }
        if (!_call(actor, data, FEE * quantity, expected)) return;
        if (team) teamMints += quantity;
        else publicMints[actor] += quantity;
        modelBalance[actor] += quantity;
        for (uint256 i; i < quantity; ++i) {
            tokenOwner[++minted] = actor;
        }
    }

    /// @dev Rejected inputs are submitted, not filtered out. Their ETH and state must roll back.
    function invalidMint(uint256 actorSeed, uint256 modeSeed, uint256 quantitySeed) external {
        address actor = actors[actorSeed % ACTOR_COUNT];
        uint256 mode = modeSeed % 4;
        uint256 quantity = mode == 0 ? 0 : mode == 1 ? bound(quantitySeed, 6, type(uint256).max) : 1;
        uint256 value = mode < 2 ? 0 : mode == 2 ? FEE - 1 : FEE + 1;
        bytes memory expected;
        if (modelPaused) expected = abi.encodeWithSelector(Pausable.EnforcedPause.selector);
        else if (mode < 2) expected = abi.encodeWithSelector(SwarmCats.InvalidQuantity.selector);
        else if (publicMints[actor] == 5) expected = abi.encodeWithSelector(SwarmCats.WalletLimitExceeded.selector);
        else expected = abi.encodeWithSelector(SwarmCats.IncorrectMintFee.selector, FEE, value);
        _call(actor, abi.encodeCall(cats.mint, (quantity)), value, expected);
    }

    function setPaused(bool desired) external {
        address caller = _adminCaller();
        bytes memory expected;
        if (modelOwner == address(0)) {
            expected = _unauthorized(caller);
        } else if (desired == modelPaused) {
            expected =
                abi.encodeWithSelector(desired ? Pausable.EnforcedPause.selector : Pausable.ExpectedPause.selector);
        }
        bytes memory data = desired ? abi.encodeCall(cats.pause, ()) : abi.encodeCall(cats.unpause, ());
        if (_call(caller, data, 0, expected)) modelPaused = desired;
    }

    /// @dev A zero candidate cancels the pending transfer; it never acts as a transaction sender.
    function proposeOwner(uint256 candidateSeed, bool cancel) external {
        address candidate = cancel ? address(0) : actors[candidateSeed % ACTOR_COUNT];
        address caller = _adminCaller();
        bytes memory expected = modelOwner == address(0) ? _unauthorized(caller) : bytes("");
        if (_call(caller, abi.encodeCall(cats.transferOwnership, (candidate)), 0, expected)) {
            modelPendingOwner = candidate;
        }
    }

    function acceptOwner(uint256 callerSeed, bool usePending) external {
        address caller =
            usePending && modelPendingOwner != address(0) ? modelPendingOwner : actors[callerSeed % ACTOR_COUNT];
        bytes memory expected = caller != modelPendingOwner ? _unauthorized(caller) : bytes("");
        if (_call(caller, abi.encodeCall(cats.acceptOwnership, ()), 0, expected)) {
            modelOwner = caller;
            modelPendingOwner = address(0);
            ++acceptedOwnerships;
        }
    }

    /// @dev Renunciation is deliberately rare so ordinary sequences keep exercising owner actions.
    function renounce(uint256 gate) external {
        if (gate % 32 != 0) return;
        address caller = _adminCaller();
        bytes memory expected = modelOwner == address(0) ? _unauthorized(caller) : bytes("");
        if (_call(caller, abi.encodeCall(cats.renounceOwnership, ()), 0, expected)) {
            modelOwner = address(0);
            modelPendingOwner = address(0);
        }
    }

    function metadata(uint256 actionSeed, bytes32 seed, bool unauthorized) external {
        uint256 action = actionSeed % 5;
        address caller = unauthorized ? _notOwner() : _adminCaller();
        string memory uri =
            uint256(seed) % 3 == 0 ? "" : uint256(seed) % 3 == 1 ? "ipfs://stateful-first/" : "ipfs://stateful-second/";
        bytes memory data;
        if (action == 0) data = abi.encodeCall(cats.setBaseURI, (uri));
        else if (action == 1) data = abi.encodeCall(cats.setUnrevealedURI, (uri));
        else if (action == 2) data = abi.encodeCall(cats.freezeMetadata, ());
        else if (action == 3) data = abi.encodeCall(cats.setRevealSeed, (seed));
        else data = abi.encodeCall(cats.setProvenanceHash, (seed));

        bytes memory expected;
        if (caller != modelOwner) {
            expected = _unauthorized(caller);
        } else if (action <= 2 && modelFrozen) {
            expected = abi.encodeWithSelector(SwarmCats.MetadataIsFrozen.selector);
        } else if (action == 3 && modelRevealed) {
            expected = abi.encodeWithSelector(SwarmCats.RevealAlreadySet.selector);
        } else if (action == 4) {
            expected = abi.encodeWithSelector(
                minted == 0 ? SwarmCats.ProvenanceAlreadySet.selector : SwarmCats.MintingAlreadyStarted.selector
            );
        }
        if (!_call(caller, data, 0, expected)) return;
        if (action == 0) {
            modelBaseURI = uri;
        } else if (action == 1) {
            modelUnrevealedURI = uri;
        } else if (action == 2) {
            modelFrozen = true;
        } else if (action == 3) {
            modelRevealed = true;
            modelSeed = seed;
        }
    }

    function unauthorizedAdmin(uint256 actionSeed) external {
        address caller = _notOwner();
        uint256 action = actionSeed % 5;
        bytes memory data;
        if (action == 0) data = abi.encodeCall(cats.reserveMint, (1));
        else if (action == 1) data = abi.encodeCall(cats.pause, ());
        else if (action == 2) data = abi.encodeCall(cats.unpause, ());
        else if (action == 3) data = abi.encodeCall(cats.transferOwnership, (caller));
        else data = abi.encodeCall(cats.renounceOwnership, ());
        _call(caller, data, action == 0 ? FEE : 0, _unauthorized(caller));
    }

    function approveToken(uint256 tokenSeed, uint256 approvedSeed, bool revoke, uint256 callerSeed) external {
        if (minted == 0) return;
        uint256 id = bound(tokenSeed, 1, minted);
        address owner = tokenOwner[id];
        address caller = callerSeed % 2 == 0 ? owner : actors[(callerSeed / 2) % ACTOR_COUNT];
        address approved = revoke ? address(0) : actors[approvedSeed % ACTOR_COUNT];
        bool authorized = caller == owner || operatorApproval[owner][caller];
        bytes memory expected =
            authorized ? bytes("") : abi.encodeWithSelector(IERC721A.ApprovalCallerNotOwnerNorApproved.selector);
        if (_call(caller, abi.encodeCall(cats.approve, (approved, id)), 0, expected)) tokenApproval[id] = approved;
    }

    function setOperator(uint256 ownerSeed, uint256 operatorSeed, bool approved) external {
        address owner = actors[ownerSeed % ACTOR_COUNT];
        address operator = actors[operatorSeed % ACTOR_COUNT];
        // Self-operator approval is immaterial to authorization; exercise distinct actors.
        if (owner == operator) operator = actors[(operatorSeed % ACTOR_COUNT + 1) % ACTOR_COUNT];
        _call(owner, abi.encodeCall(cats.setApprovalForAll, (operator, approved)), 0, bytes(""));
        operatorApproval[owner][operator] = approved;
    }

    function transferToken(uint256 tokenSeed, uint256 callerSeed, uint256 toSeed, uint256 modeSeed, bool safe)
        external
    {
        if (minted == 0) return;
        uint256 id = bound(tokenSeed, 1, minted);
        address from = tokenOwner[id];
        uint256 mode = modeSeed % 4;
        address caller = mode == 0 || mode == 3 ? from : actors[callerSeed % ACTOR_COUNT];
        if (mode == 1 && tokenApproval[id] != address(0)) caller = tokenApproval[id];
        address to = mode == 3 ? address(0) : actors[toSeed % ACTOR_COUNT];
        bytes memory expected;
        if (caller != from && caller != tokenApproval[id] && !operatorApproval[from][caller]) {
            expected = abi.encodeWithSelector(IERC721A.TransferCallerNotOwnerNorApproved.selector);
        } else if (to == address(0)) {
            expected = abi.encodeWithSelector(IERC721A.TransferToZeroAddress.selector);
        }
        bytes memory data = safe
            ? abi.encodeWithSignature("safeTransferFrom(address,address,uint256)", from, to, id)
            : abi.encodeCall(cats.transferFrom, (from, to, id));
        if (!_call(caller, data, 0, expected)) return;
        --modelBalance[from];
        ++modelBalance[to];
        tokenOwner[id] = to;
        tokenApproval[id] = address(0);
        ++successfulTransfers;
    }

    function assertModel() external view {
        assertEq(cats.owner(), modelOwner, "two-step owner");
        assertEq(cats.pendingOwner(), modelPendingOwner, "pending owner");
        assertEq(cats.paused(), modelPaused, "mint pause");
        assertEq(cats.metadataFrozen(), modelFrozen, "freeze is permanent");
        assertEq(cats.revealed(), modelRevealed, "reveal is permanent");
        assertEq(cats.revealSeed(), modelSeed, "first reveal seed survives");
        assertEq(cats.baseURI(), modelBaseURI, "base URI");
        assertEq(cats.unrevealedURI(), modelUnrevealedURI, "unrevealed URI");
        assertTrue(cats.provenanceSet());
        assertEq(cats.PROVENANCE_HASH(), COMMITMENT, "commitment is immutable");
        assertEq(cats.totalSupply(), minted);
        assertEq(cats.reserveMinted(), teamMints);
        assertLe(teamMints, 100);
        uint256 publicTotal;
        uint256 balanceTotal;
        for (uint256 i; i < ACTOR_COUNT; ++i) {
            address actor = actors[i];
            assertEq(cats.balanceOf(actor), modelBalance[actor]);
            assertEq(cats.mintedPerWallet(actor), publicMints[actor]);
            assertLe(publicMints[actor], 5);
            publicTotal += publicMints[actor];
            balanceTotal += modelBalance[actor];
            for (uint256 j; j < ACTOR_COUNT; ++j) {
                assertEq(cats.isApprovedForAll(actor, actors[j]), operatorApproval[actor][actors[j]]);
            }
        }
        assertEq(minted, publicTotal + teamMints);
        assertEq(balanceTotal, minted);
        for (uint256 id = 1; id <= minted; ++id) {
            assertEq(cats.ownerOf(id), tokenOwner[id], "token ownership");
            assertEq(cats.getApproved(id), tokenApproval[id], "token approval clears on transfer");
        }
        if (minted != 0) {
            assertEq(cats.tokenURI(1), _uri(1));
            assertEq(cats.tokenURI(minted), _uri(minted));
        }
    }

    function _uri(uint256 id) private view returns (string memory) {
        return
            bytes(modelBaseURI).length == 0 ? modelUnrevealedURI : string.concat(modelBaseURI, vm.toString(id), ".json");
    }

    function _adminCaller() private view returns (address) {
        return modelOwner == address(0) ? actors[0] : modelOwner;
    }

    function _notOwner() private view returns (address) {
        return actors[0] == modelOwner ? actors[1] : actors[0];
    }

    function _unauthorized(address caller) private pure returns (bytes memory) {
        return abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller);
    }

    function _call(address caller, bytes memory data, uint256 value, bytes memory expected) private returns (bool) {
        if (value != 0) vm.deal(caller, value);
        uint256 balanceBefore = caller.balance;
        vm.prank(caller);
        (bool success, bytes memory result) = address(cats).call{value: value}(data);
        if (expected.length == 0) {
            assertTrue(success, "modeled valid action reverted");
        } else {
            assertFalse(success, "invalid action succeeded");
            assertEq(result, expected, "wrong rejection");
            assertEq(caller.balance, balanceBefore, "failed action retained payment");
            ++rejectedCalls;
        }
        return success;
    }
}

/// @dev Requirements: plain ERC-721 authorization, lifetime mint limits, immediate fee
/// conservation, owner-only configuration, and irreversible provenance/reveal/URI freezing.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract SwarmCatsStatefulInvariantTest is Test {
    SwarmCats private cats;
    SwarmCatsStatefulHandler private handler;
    address private creator;
    address private platform;
    address private reserve;

    function setUp() public {
        address[6] memory participants;
        for (uint256 i; i < participants.length; ++i) {
            participants[i] = makeAddr(string.concat("stateful actor ", vm.toString(i)));
        }
        creator = makeAddr("stateful creator");
        platform = makeAddr("stateful platform");
        reserve = makeAddr("stateful reserve");
        cats = new SwarmCats(participants[0], creator, platform, reserve);
        handler = new SwarmCatsStatefulHandler(cats, participants);
        bytes32 commitment = handler.COMMITMENT();
        vm.prank(participants[0]);
        cats.setProvenanceHash(commitment);

        // Seed real tokens so even a sequence that freezes or renounces immediately can
        // exercise ERC-721 transfers, approvals and tokenURI throughout the campaign.
        handler.mint(false, 1, 3);
        handler.mint(false, 2, 2);
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.mint.selector;
        selectors[1] = handler.invalidMint.selector;
        selectors[2] = handler.setPaused.selector;
        selectors[3] = handler.proposeOwner.selector;
        selectors[4] = handler.acceptOwner.selector;
        selectors[5] = handler.renounce.selector;
        selectors[6] = handler.metadata.selector;
        selectors[7] = handler.unauthorizedAdmin.selector;
        selectors[8] = handler.approveToken.selector;
        selectors[9] = handler.setOperator.selector;
        selectors[10] = handler.transferToken.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_modelAndFeeConservationSurviveEveryAction() public view {
        handler.assertModel();
        uint256 paid = handler.minted() * 0.0005 ether;
        assertEq(creator.balance, paid * 2 / 5);
        assertEq(platform.balance, paid * 2 / 5);
        assertEq(reserve.balance, paid / 5);
        assertEq(creator.balance + platform.balance + reserve.balance, paid);
        assertEq(address(cats).balance, 0);
        assertEq(cats.CREATOR(), creator);
        assertEq(cats.PLATFORM(), platform);
        assertEq(cats.RESERVE(), reserve);
        (address royaltyRecipient, uint256 royalty) = cats.royaltyInfo(1, 1 ether);
        assertEq(royaltyRecipient, creator);
        assertEq(royalty, 0.05 ether);
    }

    function test_handlerExercisesRevocationOwnershipAndIrreversibleStates() public {
        handler.approveToken(2, 3, false, 0);
        handler.transferToken(2, 3, 4, 1, true);
        handler.transferToken(2, 3, 3, 2, false); // The old approved account lost authorization.
        handler.setOperator(1, 3, true);
        handler.transferToken(1, 3, 4, 2, false);
        handler.setOperator(1, 3, false);
        handler.transferToken(3, 3, 4, 2, true); // Revoked operator cannot transfer the remaining NFT.
        handler.proposeOwner(4, false);
        handler.acceptOwner(4, true);
        handler.mint(true, 0, 60);
        handler.proposeOwner(5, false);
        handler.acceptOwner(5, true);
        handler.mint(true, 0, 40);
        handler.mint(true, 0, 1); // Reserve allowance is global across owners.
        handler.setPaused(true);
        handler.mint(false, 3, 1);
        handler.transferToken(4, 0, 5, 0, true); // Transfers remain available while minting is paused.
        handler.setPaused(false);
        handler.invalidMint(3, 0, 0);
        handler.invalidMint(3, 1, type(uint256).max);
        handler.invalidMint(3, 2, 1);
        handler.invalidMint(3, 3, 1);
        handler.metadata(0, bytes32(uint256(1)), false);
        handler.metadata(1, bytes32(uint256(2)), false);
        handler.metadata(3, bytes32(0), false);
        handler.metadata(2, bytes32(0), false);
        handler.metadata(0, bytes32(uint256(2)), false);
        handler.metadata(1, bytes32(0), false);
        handler.metadata(3, bytes32(uint256(1)), false);
        handler.metadata(4, bytes32(uint256(1)), false);
        handler.proposeOwner(4, false);
        handler.renounce(0);
        handler.acceptOwner(4, false);
        handler.metadata(0, bytes32(uint256(2)), false);
        handler.unauthorizedAdmin(0);
        invariant_modelAndFeeConservationSurviveEveryAction();
        assertEq(handler.successfulTransfers(), 3);
        assertEq(handler.acceptedOwnerships(), 2);
        assertEq(handler.teamMints(), 100);
        assertGe(handler.rejectedCalls(), 15);
        assertTrue(handler.modelFrozen());
        assertTrue(handler.modelRevealed());
        assertEq(handler.modelOwner(), address(0));
        assertEq(handler.modelPendingOwner(), address(0));
    }
}
