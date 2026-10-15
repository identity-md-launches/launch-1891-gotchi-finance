# Gotchi Finance (GOTCHI)

An immutable, fixed-supply ERC-20. Its constructor mints **1,000,000,000 GOTCHI**
with **18 decimals** to the immediate deployer in one mint operation. The token
uses the vendored OpenZeppelin Contracts v5.0.2 ERC-20 implementation.

## Contract and deployment parameters

| Parameter | Value |
| --- | --- |
| Source | `src/GotchiToken.sol` |
| Solidity contract identifier | `GotchiToken` |
| Token name | `Gotchi Finance` |
| Token symbol | `GOTCHI` |
| Decimals | `18` |
| Whole-token supply | `1000000000` |
| Supply in smallest units | `1000000000000000000000000000` (`10^27`) |
| Constructor arguments | None; empty argument list `[]` |
| Constructor ETH value | `0`; constructor is nonpayable |
| Initial supply recipient | `msg.sender`, the immediate deployer |
| Launch chain | Ethereum, chain ID `1` |
| Solidity compiler | `0.8.26` |
| EVM target | `cancun` |
| Optimizer | Enabled, 200 runs |
| Metadata bytecode hash | `none` |

The supply is the named constant `INITIAL_SUPPLY`. There are no external
addresses, runtime services, constructor choices, linked libraries, or
initialization calls to configure. The constructor makes no external calls.

Deploy the creation bytecode for `src/GotchiToken.sol:GotchiToken` directly.
The artifact is `out/GotchiToken.sol/GotchiToken.json`; creation bytecode can
also be obtained locally with:

```sh
forge inspect src/GotchiToken.sol:GotchiToken bytecode
```

For the IdentityMD launch, the factory is the immediate deployer and receives
the **entire** supply. An EOA calling a factory does not receive the mint;
neither the transaction origin nor a configured owner is used. The factory
performs the subsequent distribution and pool operations. No token amounts
are allocated elsewhere by this constructor.

## Behavior and assumptions

The brief specifies a fixed-supply token without special transfer rules, so
GOTCHI uses ordinary ERC-20 transfers and approvals:

- Successful `transfer`, `approve`, and `transferFrom` return `true`.
  Invalid operations revert with OpenZeppelin's ERC-6093 custom errors.
- Transfers deliver the exact amount. There are no taxes, fees, rebases,
  transfer limits, exemptions, receiver callbacks, or timing restrictions.
- Zero-amount transfers between valid addresses succeed and emit `Transfer`.
  Self-transfers preserve balances and still require sufficient balance.
- Transfers to the zero address and approvals to the zero spender revert.
- `approve` replaces an allowance. `transferFrom` consumes finite allowances;
  `type(uint256).max` is the conventional unlimited allowance and is not reduced.
  Even an account using `transferFrom` on its own tokens needs an allowance.
- Minting and transfers emit `Transfer`; `approve` emits `Approval`.
  This OpenZeppelin version does not emit an additional `Approval` when
  `transferFrom` spends an allowance. Integrations should read `allowance`.
- There is no callable mint or burn function, ownership, pause, blacklist,
  seizure, upgrade path, proxy, or privileged recovery function. The deployed
  contract's supply remains exactly `10^27` smallest units.

The standard interface is described in [ERC-20](https://eips.ethereum.org/EIPS/eip-20).
The implementation is in the vendored
[ERC20.sol](lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol).

## Build and test

Run from this repository's root with Foundry and Solidity 0.8.26 available:

```sh
forge build
FOUNDRY_FUZZ_SEED=0x27a99cdbd479e7d3e86f582074a562279a854dc72a7d17d47557d4efe9fb70a5 forge test
forge fmt --check
```

All Solidity dependencies are ordinary files under `lib/`. A fresh checkout
does not need dependency downloads, submodules, npm, RPC access, keys, or
environment configuration. An offline worker must provide the pinned compiler
and Foundry; no compiler binary is included. Tests never read or set environment
variables and use isolated fixtures. The command above provides the verifier's
fuzz seed to Foundry itself.

The suite includes:

- Metadata, exact initial supply, constructor mint event, direct deployment,
  factory deployment with a different transaction origin, and fuzzed CREATE2
  deployment predictions.
- Exact transfers, full-supply transfers, zero amounts, self-transfers,
  contract recipients, round trips, and balance failures.
- Approval events, replacement and revocation; finite and unlimited allowances;
  unauthorized spending; allowance exhaustion; and rollback of allowance and
  balances on failed transfers.
- Factory distribution, distributor claims, and transfers in both directions
  between an ordinary holder and a pool address, all without deductions.
- Rejection of common mint, burn, ownership, upgrade, and holder-control calls;
  deployer inability to spend unapproved holder funds; fixed supply over time;
  runtime size and forbidden opcode checks.
- Three stateful invariants comparing balances and allowances to an independent
  ledger across randomized transfers, approvals, delegated spending, and rejected
  actions. These also check that all supply stays with the tracked holders.

Default fuzzing runs each of the seven fuzz tests 1,024 times. Stateful testing
uses 128 sequences of depth 64 (8,192 handler calls) and fails on unexpected
handler reverts. The deterministic success and failure cases cover the boundary
conditions independently of the fuzz seed.

The supplied protected tests were read as acceptance definitions. Their full
launch harness imports external factory/Uniswap infrastructure and obtains
launch parameters from the later manifest step. That harness is not part of this
standalone project and was not run locally. The local launch-flow test checks
token movement only; it does not claim to simulate liquidity seeding or swaps.

## Operational responsibilities

The launch operator must deploy the reviewed bytecode using the pinned build
settings, verify the deployed source and metadata, and confirm that the factory
holds the entire initial supply before distribution. The factory and launch
process handle the swarm distribution, pool creation/seeding, and requester
remainder according to the launch's terms. This repository supplies the token;
the separate launch step supplies its manifest and performs transactions.

Recipients and integrations are responsible for address correctness, wallet
security, and the permissions they grant spenders. Prefer exact allowances.
When replacing a live allowance, revoke it first and wait for confirmation
before granting a new amount to reduce the standard ERC-20 approval race risk.
GOTCHI performs no recipient capability check; tokens sent to the token itself
or an incompatible contract cannot be recovered by an administrator. The token
does not accept ordinary ETH payments or expose an asset rescue function.

### After launch

There are **no owner settings, setup calls, keepers, or maintenance transactions**
for this token. The deployer retains only the rights of an ordinary holder or
an explicitly approved spender. Holders can transfer immediately.

## Security review and verification limits

The local review used the supplied security reference. The production change is
limited to fixed metadata and one constructor mint on the standard ERC-20 base.
Supply-changing internal functions have no post-construction external entrypoint.
There are no external calls, oracle reads, signatures, randomness, proxies, or
administrative roles. Transfer authorization is enforced through caller balances
and holder-granted allowances. Integer accounting and failed-operation rollback
are exercised by unit, fuzz, and stateful tests.

`forge build`, the seeded `forge test`, and `forge fmt --check` are the local
verification tools. Slither and Mythril were not run. Local tests and this review
are not an independent security audit; the launch's independent review and
factory/PoolManager integration checks remain the launch process's responsibility.
No on-chain transactions were submitted by this project.

## Vendored dependencies

- [OpenZeppelin Contracts v5.0.2](https://github.com/OpenZeppelin/openzeppelin-contracts/tree/v5.0.2):
  only the ERC-20 dependency closure, with its MIT license.
- [forge-std v1.9.7](https://github.com/foundry-rs/forge-std/tree/v1.9.7):
  Solidity sources used for testing, with its MIT and Apache-2.0 licenses.

[DEPENDENCIES.json](DEPENDENCIES.json) records the release archives, SHA-256
archive digests, and per-file digests. Vendored source files are unmodified.
