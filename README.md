# Swarm Cats — Sepolia contracts

This Foundry project implements the contract stage of the approved **evm_project** launch: Loom (`LOOM`) as `LaunchToken`, and the `SwarmCats` ERC-721 collection. Sepolia is the sole release target (chain ID **11155111**).

The approved workflow contains a final sentence requesting an `evm_contracts` launch without an ERC-20. That conflicts with its explicit evm_project requirements and the supplied project acceptance checks. This contribution implements evm_project with the required standard token. The NFT itself has no dependency on LOOM.

## Build and check

```sh
forge build
forge test
forge fmt --check
python3 scripts/check_dependencies.py
python3 scripts/export_abis.py --check
```

Solidity is pinned to **0.8.26**, targeting Cancun, with optimization enabled (200 runs) and `bytecode_hash = "none"`. All required dependencies are [vendored at pinned releases](docs/DEPENDENCIES.md). No FFI, filesystem cheatcode permissions, runtime package downloads, RPC, keys, or environment variables are required by the tests. The compiler is supplied by the verification environment.

Tests cover successful and rejected mints, the 10,000-token boundary, lifetime wallet and reserve limits, fee conservation, zero recipients, access control, metadata immutability, royalties, ordinary transfers, ERC-721 receivers, rollback at each fee recipient, both mint paths under reentrancy, fixed ERC-20 supply, factory ownership, constructor independence, runtime sizes, and forbidden opcodes. Stateful tests compare randomized mint/transfer/pause sequences with a separate ownership and accounting model.

After changing source, run `forge build` and `python3 scripts/export_abis.py` to refresh the delivered ABIs. [ABI documentation](docs/ABI.md) describes the public surface; the JSON files are generated from the pinned compiler's artifacts.

## Deployment handoff

The separate manifest assignment produces `launch.json`; this source contribution does not produce one. Services perform source publication, attestation, admission, deployment, explorer verification, and the subsequent frontend stage. No transaction has been broadcast by this contribution. A separate contributor must review the accepted source and concrete manifest before release; local tests and [security notes](docs/SECURITY.md) are not that independent review.

| Artifact | Source | Nonpayable constructor arguments, in ABI order |
| --- | --- | --- |
| LaunchToken | `src/LaunchToken.sol` | None |
| SwarmCats | `src/SwarmCats.sol` | `address initialOwner`, `address creator`, `address platform`, `address reserve` |

For this test release **all four SwarmCats arguments are `$owner`**, resolving to **0x02b4bd9cc103fd502b2f3f601e29e6ae2039ac85**. That address is supplied by the approved launch context, not hard-coded into contract authority. Each role is checked for a nonzero address; constructors neither call external contracts nor require code at an address. The factory does not become the NFT owner. No initializer is needed or exposed, and there are no proxies, upgrades, linked external libraries, or constructor funding requirements.

Collection name, symbol, supply, fee, wallet limit, reserve limit, and royalty rate are constants, so there are no string constructor arguments. Deploy the standard token and the single application artifact `SwarmCats`. The NFT constructor does not take `$token` and receives no launch-token allocation.

The launch service handles the LOOM allocation: exactly 1,000,000,000 tokens at 18 decimals (`10^27` units) are minted once to the deploying factory. The stated launch split is 10% to the swarm distributor, 80% to the pool, and 10% to the launch payer (or the policy treasury when applicable). The ERC-20 has no additional mint, owner, pause, fee, blocklist, or upgrade interface. The native-ETH pool uses the supplied policy values: fee **12500 (1.25%)**, tick spacing **60**, and manifest initial price **79228162514264337593543950336**. The deployer derives the effective opening price from the **20 ETH** opening market cap. These are service/manifest responsibilities; neither application contract creates a pool or charges swap fees.

## Minting and accounting

- `mint(quantity)` accepts 1–5 NFTs, with `msg.value == quantity * 500000000000000` wei (**0.0005 ETH each**, plus transaction gas). There is no additional sale price. Each address can publicly mint at most five over its lifetime. Transfers do not restore this allowance, and incoming transfers do not consume it. An address can hold more than five NFTs.
- IDs begin at **1** and end at **10000**, shared by public and team mints. ERC721A batches ownership writes and emits ordinary ERC-721 `Transfer` events for every token. Mints use safe receiver callbacks for contract callers.
- `reserveMint(quantity)` is owner-only, payable, and delivers to the **current owner**. It permits a cumulative **100 team NFTs** across ownership changes, pays the same per-token fee, respects pausing, and shares the 10,000 cap. It is the explicit exception to the public five-per-wallet rule; the owner may also use their five public mints. No slots are withheld from public minting, so the team must mint before public sellout if it wants the full allowance.
- Each mint immediately forwards **40% to CREATOR, 40% to PLATFORM, and 20% to RESERVE**. The roles are immutable. The reserve fee recipient is separate in meaning from the team NFT allowance. With all recipients set to the owner, the owner receives all fees; an owner's own reserve-mint fee consequently returns to that owner after the three transfers.
- A failed NFT receiver or ETH recipient reverts the entire transaction, including supply, counters, earlier transfers, and fees. No partial mint, pending withdrawal, or refund transaction remains. Gas already spent is not refunded. Both mint paths share a reentrancy guard.
- Normal minting leaves no ETH in the collection. Unsolicited ETH transfers revert. ETH forced onto the address is not counted as mint fees and has no recovery function. There is no withdrawal or sweep privilege.
- Transfers and approvals are plain ERC-721 operations: no transfer fee, holding cap, or transfer pause. ERC-2981 reports **5% to CREATOR**, rounded down, without enforcing payment by marketplaces. Ownership transfers do not change this receiver.

## Metadata and reveal

`baseURI` and `unrevealedURI` start empty. For an existing token, `tokenURI(id)` is `unrevealedURI` while the base is empty; otherwise it is the exact concatenation `baseURI + decimal(id) + ".json"`. Include a trailing slash when setting a directory URI. Nonexistent IDs revert.

The owner must set a **nonzero** `PROVENANCE_HASH` once, while total supply is zero. Both mint paths revert `ProvenanceNotSet` until this commitment exists. This prevents an early public mint from making it permanently impossible to record the commitment. The contract starts unpaused, so minting becomes available immediately after the commitment unless the owner pauses first.

`setRevealSeed(bytes32)` records the owner's oracle-provided seed once and emits `Revealed`. A separate boolean enforces one-time use even for a zero seed. The contract does **not** contact an oracle, verify a randomness proof, derive entropy from block data, or shuffle token IDs. The owner is responsible for obtaining and publishing the oracle evidence. Setting the seed does not switch the URI; setting the base URI does. This follows the specified deterministic tokenURI formula.

`freezeMetadata()` is irreversible and locks **both** base and unrevealed URI setters. It does not block minting or the one-time seed/provenance actions, whose own restrictions still apply. Freezing while the base is empty permanently leaves tokens on the current unrevealed URI, even if that is empty. Validate the pinned content first. A frozen URI does not guarantee the availability or immutability of content behind a mutable HTTP endpoint; use the intended content-addressed IPFS data.

## After launch

No unknown service address, subscription ID, signer, metadata CID, seed, or provenance hash is supplied as a dummy constructor value. The following owner actions use the explicit post-deployment settings requested by the brief:

| Owner action | Value and source | Timing / responsibility |
| --- | --- | --- |
| `pause()` / `unpause()` | Owner's operational decision | Optionally pause before publishing provenance; both mint paths honor the pause. Transfers remain available. |
| `setProvenanceHash(bytes32)` | Actual nonzero provenance digest from the already-generated art/metadata pipeline | Exactly once, before **any** mint. Publish the ordering and hashing procedure with the artwork. |
| `setUnrevealedURI(string)` | Actual pinned placeholder metadata URI from the metadata publisher, if used | Before metadata freeze; initially empty. |
| `setRevealSeed(bytes32)` | Actual output obtained from the chosen oracle process | Exactly once. Publish the oracle evidence; the contract trusts the owner to submit it correctly. |
| `setBaseURI(string)` | Actual IPFS directory URI for the existing metadata, including `/` | After pinning and validating files `1.json` through `10000.json`; may change until freeze. No art is generated by this assignment. |
| `freezeMetadata()` | No argument | Once final metadata has been checked and is available. Irreversible. |

The owner controls mint availability and mutable metadata. OpenZeppelin's two-step ownership transfer is available: call `transferOwnership(nextOwner)`, then the proposed owner calls `acceptOwnership()`. The existing owner retains authority until acceptance. `transferOwnership(address(0))` cancels a pending transfer. `renounceOwnership()` permanently removes administration and clears any pending owner; doing so while paused or before required setup can permanently prevent minting. Renunciation does not set `metadataFrozen` automatically.

The independent reviewer must inspect the four actual constructor roles and these operational assumptions. The deployment service must hand the frontend the attested chain ID, NFT address, token address, and exact pool key. A later mint site can use `totalSupply`, `MINT_FEE`, `MAX_PER_WALLET`, `mintedPerWallet`, `paused`, and `provenanceSet` to present mint availability. Index `Transfer` logs and confirm `ownerOf` to show a wallet's current NFTs; ERC721Enumerable is not implemented. The site's contract link must use the attested address on Sepolia Etherscan. No live address is invented here.
