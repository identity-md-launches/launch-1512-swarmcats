# Foundry test coverage

Run the complete suite with `forge build --offline` and `forge test --offline`.
All dependencies are already vendored in the repository. The tests use local
deployments and require no RPC endpoint, environment configuration, wallet key,
or external service.

The original deployment, mint, metadata, callback, and conservation tests remain
in place. The added suites cover these complementary properties:

| Suite | Coverage |
| --- | --- |
| `LaunchTokenAdversarial.t.sol` | Approval replacement/revocation, infinite allowances, zero and self transfers, unauthorized spending, maximum amounts, and atomic rollback of failed delegated transfers. |
| `LaunchTokenInvariant.t.sol` | Fixed supply equals the sum of independently modeled balances; every finite/infinite allowance matches its independent ledger after random transfers, approvals, revocations, and rejected calls. |
| `SwarmCatsAdditionalAdversarial.t.sol` | Partial receiver rejection, nested transfer rollback, callback data and operator identity, restored and revoked approvals, lazy ownership across public/reserve batch boundaries, pending owner replacement, and rollback of admin changes when a later payout fails. |
| `SwarmCatsStatefulInvariant.t.sol` | Ownership and pending-owner transitions, public/reserve mint accounting across owners, token and operator authorization, pause behavior, irreversible metadata state, immutable fee/royalty recipients, and exact payment conservation. |
| `SwarmCatsSupplyBoundary.t.sol` | Public/reserve mint competition for the final ten slots, failed-batch atomicity, supply remaining closed after sellout and transfers, and fee conservation in the presence of unsolicited ETH. |

The new fuzz properties run 1,000 examples each. Invariant settings are declared
inline: 256 sequences at depth 128 for the launch token, and 256 at depth 64 for
each new NFT campaign. Only explicitly listed handler selectors are targeted;
unexpected handler reverts fail the campaign. Expected reverts check the actual
error and are followed by the same invariant checks as successful calls.

Models update from known fixture allocations and successful input actions,
without copying contract balances, allowance counters, or ownership into their
expected state. The NFT stateful fixture seeds transferable tokens, and a
deterministic handler sequence exercises ownership rotation, revocation,
renunciation, zero-seed reveal, freezing, and rejected payments. Separate
deterministic boundary tests reach token 10,000 and exercise oversubscription.

The cap fixture mints its first 9,990 NFTs through the public API. Random
transfers touch token 9,990 and the newly minted tail; the other 9,989 tokens
remain with their fixture owners. Its unsolicited-ETH action uses `vm.deal`
solely to model a preexisting balance; NFT supply and counters are never written
through storage cheatcodes. ERC-20 recipients include the token contract itself
so custody there remains part of the supply identity.

Actors and fee recipients are disjoint in the invariant campaigns so fee receipts
can be measured independently of caller funding. The existing shared-recipient
unit test covers the release configuration where all three recipients equal the
owner. Receiver and fee callback behavior is exercised by the adversarial suites.
