# Contract ABI handoff

Generated interfaces: [`LaunchToken.json`](abi/LaunchToken.json) and [`SwarmCats.json`](abi/SwarmCats.json). Run `forge build` then `python3 scripts/export_abis.py` to regenerate, or add `--check` to detect drift. Constructors are nonpayable; only `mint` and `reserveMint` accept ETH on SwarmCats.

## LaunchToken

Constructor: `constructor()`.

The interface is the OpenZeppelin ERC-20 surface: `name`, `symbol`, `decimals`, `totalSupply`, `balanceOf`, `allowance`, `approve`, `transfer`, and `transferFrom`, with standard `Transfer` and `Approval` events and ERC-6093 errors. Name is Loom, symbol LOOM, decimals 18, and immutable total supply `1000000000000000000000000000`. No post-construction mint or administrative methods exist.

## SwarmCats

Constructor: `constructor(address initialOwner, address creator, address platform, address reserve)`. All four resolve to `$owner` in this release. Collection constants are exposed through `MAX_SUPPLY()`, `MINT_FEE()`, `MAX_PER_WALLET()`, `MAX_RESERVE_SUPPLY()`, and `ROYALTY_BPS()`.

| Method | Access / mutability | Behavior |
| --- | --- | --- |
| `mint(uint256 quantity)` | Public, payable | 1–5 per call, five public mints over the caller's lifetime, exact fee, provenance required, respects pause/global cap |
| `reserveMint(uint256 quantity)` | Owner, payable | Mint to current owner; 100 total team allowance, exact fee, provenance required, respects pause/global cap |
| `mintedPerWallet(address)` | View | Lifetime **public** mints, excluding reserve mints and incoming transfers |
| `reserveMinted()` / `totalSupply()` | View | Team mints used / total NFTs minted; no exposed burn function |
| `CREATOR()` / `PLATFORM()` / `RESERVE()` | View | Immutable fee recipients |
| `setProvenanceHash(bytes32)` | Owner | Nonzero commitment, exactly once and before first mint |
| `PROVENANCE_HASH()` / `provenanceSet()` | View | Commitment and configuration status |
| `setRevealSeed(bytes32)` | Owner | Record one oracle seed; no on-chain oracle verification or ID remapping |
| `revealSeed()` / `revealed()` | View | Recorded seed and one-time status |
| `setBaseURI(string)` / `setUnrevealedURI(string)` | Owner | Update URI strings before freeze |
| `baseURI()` / `unrevealedURI()` | View | Current metadata settings |
| `freezeMetadata()` / `metadataFrozen()` | Owner / view | Permanently lock both URI setters / read lock |
| `pause()` / `unpause()` / `paused()` | Owner / owner / view | Mint availability only; no effect on transfers |
| `tokenURI(uint256)` | View | Hidden URI if base is empty, otherwise base + decimal ID + `.json`; nonexistent IDs revert |
| `royaltyInfo(uint256,uint256 salePrice)` | View | Returns `(CREATOR, floor(salePrice * 500 / 10000))`; standard ERC-2981 reporting |
| `supportsInterface(bytes4)` | View | ERC-165, ERC-721, ERC-721 metadata, and ERC-2981; not ERC721Enumerable |
| `owner()` / `pendingOwner()` | View | Current and nominated administrator |
| `transferOwnership(address)` / `acceptOwnership()` | Owner / nominee | Two-step administrative transfer; zero nominee cancels pending transfer |
| `renounceOwnership()` | Owner | Irreversibly remove administrator |

The remaining surface is standard ERC-721: `name`, `symbol`, `balanceOf`, `ownerOf`, `approve`, `getApproved`, `setApprovalForAll`, `isApprovedForAll`, `transferFrom`, and both `safeTransferFrom` overloads. Transfers and approvals have no protocol fee. Contract recipients of safe transfers and mints must implement `onERC721Received`.

### Events

| Event signature | Indexed fields | Meaning |
| --- | --- | --- |
| `Minted(address,uint256,uint256)` | Minter address | Batch recipient at mint time, first ID, quantity; emitted on both mint paths |
| `FeesDistributed(uint256,uint256,uint256)` | None | Creator, platform, and reserve ETH amounts for this batch |
| `ProvenanceSet(bytes32)` | None | Permanent commitment recorded |
| `Revealed(bytes32)` | None | Permanent seed recorded |
| `MetadataFrozen()` | None | URI settings permanently locked |
| `BaseURISet(string)` / `UnrevealedURISet(string)` | None | URI setting updated |

ERC-721 `Transfer`, `Approval`, `ApprovalForAll`, Ownable `OwnershipTransferred` / `OwnershipTransferStarted`, and Pausable `Paused` / `Unpaused` are also included. `Minted` describes the original mint recipient, **not** necessarily the holder at transaction end: a contract receiver can transfer its NFT during its callback. Process standard `Transfer` logs to track ownership.

### Application errors

| Error | Cause |
| --- | --- |
| `InvalidRecipient()` | Zero creator, platform, or reserve constructor argument |
| `InvalidQuantity()` | Zero quantity or above per-call public/reserve maximum |
| `WalletLimitExceeded()` | Lifetime public mint allowance exhausted |
| `ReserveLimitExceeded()` | Collection-wide team allowance exhausted |
| `MaxSupplyExceeded()` | Batch would exceed 10,000 NFTs |
| `IncorrectMintFee(uint256 expected,uint256 received)` | Payment differs from exact quantity times fee |
| `FeeTransferFailed(address recipient,uint256 amount)` | One immutable recipient rejected ETH; entire mint reverted |
| `ProvenanceNotSet()` | Mint attempted before provenance commitment |
| `InvalidProvenanceHash()` | Zero commitment |
| `ProvenanceAlreadySet()` | Attempt to change commitment before minting |
| `MintingAlreadyStarted()` | Provenance setter called after a mint |
| `RevealAlreadySet()` | Second reveal seed submission |
| `MetadataIsFrozen()` | URI change or another freeze after freezing |

OpenZeppelin ownership, pause and reentrancy errors and ERC721A transfer/approval/query errors are retained in the JSON ABI. `OwnableInvalidOwner(address)` rejects a zero initial owner. There is no fallback or receive function; unrelated selectors and direct ETH sends revert.
