// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC721A} from "erc721a/contracts/ERC721A.sol";
import {ERC2981} from "@openzeppelin/contracts/token/common/ERC2981.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Swarm Cats
/// @notice A capped ERC721A collection with atomic fee splitting and owner-managed metadata.
/// @dev Reserve mints are the sole exception to the lifetime public mint limit; all mints pay fees.
contract SwarmCats is ERC721A, ERC2981, Ownable2Step, Pausable, ReentrancyGuard {
    uint256 public constant MAX_SUPPLY = 10_000;
    uint256 public constant MINT_FEE = 0.0005 ether;
    uint256 public constant MAX_PER_WALLET = 5;
    uint256 public constant MAX_RESERVE_SUPPLY = 100;
    uint96 public constant ROYALTY_BPS = 500;

    address public immutable CREATOR;
    address public immutable PLATFORM;
    address public immutable RESERVE;

    /// @notice Number of public mints by an address, unaffected by transfers or reserve mints.
    mapping(address => uint256) public mintedPerWallet;
    uint256 public reserveMinted;

    string public baseURI;
    string public unrevealedURI;
    bytes32 public PROVENANCE_HASH;
    bool public provenanceSet;
    bytes32 public revealSeed;
    bool public revealed;
    bool public metadataFrozen;

    error InvalidRecipient();
    error InvalidQuantity();
    error WalletLimitExceeded();
    error ReserveLimitExceeded();
    error MaxSupplyExceeded();
    error IncorrectMintFee(uint256 expected, uint256 received);
    error FeeTransferFailed(address recipient, uint256 amount);
    error ProvenanceNotSet();
    error InvalidProvenanceHash();
    error ProvenanceAlreadySet();
    error MintingAlreadyStarted();
    error RevealAlreadySet();
    error MetadataIsFrozen();

    event Minted(address indexed minter, uint256 firstId, uint256 quantity);
    event FeesDistributed(uint256 creatorAmount, uint256 platformAmount, uint256 reserveAmount);
    event ProvenanceSet(bytes32 provenanceHash);
    event Revealed(bytes32 seed);
    event MetadataFrozen();
    event BaseURISet(string uri);
    event UnrevealedURISet(string uri);

    /// @param initialOwner The launch owner, explicitly supplied by the factory as $owner.
    /// @param creator Immutable recipient of 40% of mint fees and 5% secondary-sale royalties.
    /// @param platform Immutable recipient of 40% of mint fees.
    /// @param reserve Immutable recipient of 20% of mint fees (distinct from the team NFT allowance).
    /// @dev Nonpayable, static arguments only, and no external calls or code-presence checks.
    constructor(address initialOwner, address creator, address platform, address reserve)
        ERC721A("Swarm Cats", "SCAT")
        Ownable(initialOwner)
    {
        if (creator == address(0) || platform == address(0) || reserve == address(0)) {
            revert InvalidRecipient();
        }
        CREATOR = creator;
        PLATFORM = platform;
        RESERVE = reserve;
        _setDefaultRoyalty(creator, ROYALTY_BPS);
    }

    /// @notice Mint 1–5 NFTs, with a lifetime limit of five public mints for the caller.
    /// @dev All effects and payments revert if any NFT receiver or fee recipient rejects the call.
    function mint(uint256 quantity) external payable nonReentrant whenNotPaused {
        if (quantity == 0 || quantity > MAX_PER_WALLET) revert InvalidQuantity();
        if (mintedPerWallet[msg.sender] + quantity > MAX_PER_WALLET) revert WalletLimitExceeded();
        _checkMint(quantity);
        mintedPerWallet[msg.sender] += quantity;
        _mintAndSplit(msg.sender, quantity);
    }

    /// @notice Mint to the current owner, using the collection-wide allowance of 100 team NFTs.
    /// @dev Pays the same fee per NFT, shares the global cap, and respects the mint pause.
    /// There are no withheld slots: public minting can consume the entire supply first.
    function reserveMint(uint256 quantity) external payable nonReentrant onlyOwner whenNotPaused {
        if (quantity == 0 || quantity > MAX_RESERVE_SUPPLY) revert InvalidQuantity();
        if (reserveMinted + quantity > MAX_RESERVE_SUPPLY) revert ReserveLimitExceeded();
        _checkMint(quantity);
        reserveMinted += quantity;
        _mintAndSplit(msg.sender, quantity);
    }

    /// @notice Commit the off-chain art provenance before the first mint. It cannot be replaced.
    function setProvenanceHash(bytes32 provenanceHash) external onlyOwner {
        if (totalSupply() != 0) revert MintingAlreadyStarted();
        if (provenanceSet) revert ProvenanceAlreadySet();
        if (provenanceHash == bytes32(0)) revert InvalidProvenanceHash();
        PROVENANCE_HASH = provenanceHash;
        provenanceSet = true;
        emit ProvenanceSet(provenanceHash);
    }

    /// @notice Record the owner's oracle-provided seed exactly once, including a possible zero seed.
    /// @dev This is an owner attestation, not on-chain oracle verification. It does not shuffle IDs.
    function setRevealSeed(bytes32 seed) external onlyOwner {
        if (revealed) revert RevealAlreadySet();
        revealSeed = seed;
        revealed = true;
        emit Revealed(seed);
    }

    /// @notice Set the prefix used in baseURI + tokenId + '.json'; include the trailing slash.
    function setBaseURI(string calldata uri) external onlyOwner {
        if (metadataFrozen) revert MetadataIsFrozen();
        baseURI = uri;
        emit BaseURISet(uri);
    }

    function setUnrevealedURI(string calldata uri) external onlyOwner {
        if (metadataFrozen) revert MetadataIsFrozen();
        unrevealedURI = uri;
        emit UnrevealedURISet(uri);
    }

    /// @notice Permanently lock both URI settings, including when the base URI is still empty.
    function freezeMetadata() external onlyOwner {
        if (metadataFrozen) revert MetadataIsFrozen();
        metadataFrozen = true;
        emit MetadataFrozen();
    }

    /// @notice Pause public and reserve mints. ERC-721 transfers and approvals stay available.
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        if (!_exists(tokenId)) revert URIQueryForNonexistentToken();
        if (bytes(baseURI).length == 0) return unrevealedURI;
        return string.concat(baseURI, _toString(tokenId), ".json");
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721A, ERC2981) returns (bool) {
        return ERC721A.supportsInterface(interfaceId) || ERC2981.supportsInterface(interfaceId);
    }

    function _startTokenId() internal pure override returns (uint256) {
        return 1;
    }

    function _checkMint(uint256 quantity) private view {
        if (!provenanceSet) revert ProvenanceNotSet();
        if (totalSupply() + quantity > MAX_SUPPLY) revert MaxSupplyExceeded();
        uint256 expected = MINT_FEE * quantity;
        if (msg.value != expected) revert IncorrectMintFee(expected, msg.value);
    }

    function _mintAndSplit(address to, uint256 quantity) private {
        uint256 firstId = _nextTokenId();
        // ERC721A updates ownership, balances and total supply before receiver callbacks.
        _safeMint(to, quantity);
        emit Minted(to, firstId, quantity);

        uint256 creatorAmount = msg.value * 40 / 100;
        uint256 platformAmount = msg.value * 40 / 100;
        uint256 reserveAmount = msg.value - creatorAmount - platformAmount;
        _pay(CREATOR, creatorAmount);
        _pay(PLATFORM, platformAmount);
        _pay(RESERVE, reserveAmount);
        emit FeesDistributed(creatorAmount, platformAmount, reserveAmount);
    }

    function _pay(address recipient, uint256 amount) private {
        (bool success,) = payable(recipient).call{value: amount}("");
        if (!success) revert FeeTransferFailed(recipient, amount);
    }
}
