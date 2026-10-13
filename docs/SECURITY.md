# Security and review handoff

These are implementation notes and a local test record, **not an independent adversarial review or audit**. The separate review assignment must evaluate the accepted source together with the generated manifest. Source publication, signed artifact linkage, admission, and deployment policy are handled by services.

## Controls and covered failure cases

| Area | Control and local evidence |
| --- | --- |
| Privileged authority | Four explicit constructor addresses; zero roles rejected. Factory fixture proves the NFT owner is the supplied owner. All owner setters reject outsiders. Two-step ownership transfer is tested. |
| Lifetime limits | Independent public mint counters survive transfers; a separate global team counter survives ownership changes. Tests sell out all 10,000 IDs using public and mixed mint paths. |
| Mint payment | Exact per-token fee before external calls; contract holds no routine fees. Fuzz and stateful tests check conservation and the 40/40/20 split. |
| Reentrancy | Both mint paths share OpenZeppelin ReentrancyGuard. Counters and ERC721A supply/ownership update before callbacks. Tests attempt both mint entrypoints from NFT receivers, fee recipients, and an authorized owner contract. |
| Settlement rejection | Failed NFT acceptance or any of the three ETH payouts reverts all state and all earlier transfers. Tests reject the last NFT and each fee recipient and then retry successfully. |
| Receiver transfers | Safe mint receivers may transfer NFTs during callbacks without renewing lifetime allowance. Tests check balances, ownership, and counters. |
| Provenance | Nonzero, owner-set once, before any mint; both mint paths require configuration. Tests cover unset, set, replacement attempts and post-mint attempts. |
| Metadata | Seed has an explicit once-only flag, including zero seed. Freeze locks both URI setters forever. Tests include freeze before a base URI, post-freeze seed recording, and nonexistent IDs. |
| Token | OpenZeppelin ERC20, one constructor mint to factory, no admin/mint/burn extension. Exact transfers, allowance failures, fixed supply, and unsupported admin selectors tested. |
| Launch compatibility | Nonpayable static constructors, no dependency calls or code checks; ordinary vendored dependencies. Runtime tests scan PUSH-aware bytecode for forbidden DELEGATECALL, CALLCODE and SELFDESTRUCT and enforce EIP-170 size. |

## Explicit trust and availability assumptions

- The owner can pause public and reserve minting indefinitely and alter both URI strings until freezing. Transfers stay available. The owner can also permanently renounce control; renouncing before provenance setup or while paused strands minting. This is documented, tested OpenZeppelin behavior.
- The owner can mint up to 100 team NFTs, paying the same fee. These consume the shared supply but are not reserved in advance. Five further public mints follow the same rules as any other address.
- The owner is trusted to submit the actual art provenance digest and an oracle-provided reveal seed. There is no oracle address or proof verifier in the approved interface. The seed is a recorded attestation; it neither changes IDs nor proves fair allocation. The off-chain art pipeline must publish a reproducible provenance procedure and oracle evidence.
- Setting a base URI makes metadata visible independently of the seed. Freezing an empty or incorrect URI is permanent. URI freezing cannot guarantee content availability, nor can it freeze server content at an HTTP URL.
- Immediate fee forwarding means **any immutable recipient can block all minting by rejecting ETH**. The contract deliberately implements the requested immediate split, with atomic rollback instead of pull payments. The three specified recipients are the same launch owner; if that address is a contract, it must accept ETH. An owner contract using reserve mint must also accept ERC-721 callbacks.
- The five-mint limit is per address, not per person; transfers are unrestricted and Sybil addresses are possible. There is no allowlist or identity verification.
- ERC-2981 royalties depend on marketplace cooperation and do not charge ordinary transfers. Fee recipients and the royalty receiver never follow later ownership changes.
- No regular custody remains after successful minting. Forced ETH or tokens sent directly to the collection have no recovery interface. The contracts cannot upgrade or change economic constants after deployment.

## Local tools and remaining review

`forge build`, `forge test`, `forge fmt --check`, dependency integrity checking, and ABI comparison are the reproducible local checks. Tests include fuzzing and 128 stateful invariant runs at depth 64. They use local fixture accounts and no network or environment values. The provided protected tests were read as the acceptance definitions; the deployment suite reproduces their relevant supply, constructor, runtime-size, and opcode checks without their external environment inputs. The independent verifier remains authoritative.

Local verification on 2026-10-13 used Foundry 1.8.3 and Solidity 0.8.26:

| Check | Result |
| --- | --- |
| `forge build` and `forge build --sizes` | Passed; LaunchToken runtime 1,722 bytes, SwarmCats runtime 8,415 bytes; no external library link references |
| `forge test` | 60 passing entries, zero failures/skips: 59 unit/fuzz tests plus a grouped invariant suite containing three properties |
| `forge test --offline --threads 4` launched with an empty process environment | Passed; invariant campaign completed 128 runs and 8,192 calls with zero unexpected reverts |
| `forge fmt --check` | Passed |
| `python3 scripts/export_abis.py --check` | Both delivered ABIs match the build artifacts |
| `python3 scripts/check_dependencies.py` | All 48 vendored files match the recorded upstream hashes |

Foundry's heuristic lint can flag the checked ETH call and events following callbacks: `_pay` is private, its recipients are immutable, both callers are under the shared reentrancy guard, all mint accounting is already updated, and failure reverts the transaction. `Minted` records the original recipient rather than final ownership, which is tracked by `Transfer` events. These paths have adversarial tests; a heuristic warning is not evidence that callbacks can bypass the guard.

Slither, Mythril, a live oracle integration, a Sepolia broadcast, and explorer verification are not claimed as completed. The final reviewer should check the concrete manifest against the four intended `$owner` roles, runtime bytecode, this reserve-mint interpretation, and the metadata/recipient availability assumptions. The later services and frontend must use the attested deployment handoff rather than assumed addresses.
