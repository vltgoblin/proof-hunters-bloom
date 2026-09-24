# Hunter Bloom

Borrowing research and Solidity building blocks for Proof Hunters.

Maintained by [vltgoblin](https://github.com/vltgoblin).

Mining is how a Hunter is discovered. Bloom explores what its owner can do next: borrow against the whole NFT, or eventually use eligible, actually funded basket assets as collateral.

**Development source, not a live lending launch. Do not send funds to addresses in tests.** This repository is not an audit, deployment attestation, offer of credit, or promise of yield. A passing test does not establish production safety.

## What is here

- **Whole-Hunter loans:** `DirectLoan` implements a request, lender funding, repayment, cancellation, default and collateral-claim lifecycle. Test configurations use mock assets and placeholder fees.
- **NFT ownership and custody:** Hunter NFT, lifecycle, reserve, backing and weighted-round accounting modules used by the loan integration tests.
- **Integration context:** mining and Mining Power code, plus Live Hunt contracts needed to test that lending cannot conflict with a sale or other encumbrance.
- **Local tests:** unit, fuzz, invariant and cross-module tests, plus independent arithmetic fixture vectors.

## What is not here

- A deployed Bloom lending market, funded lenders, approved loan assets or production loan terms.
- An implemented external basket-token lending adapter, oracle or liquidation integration. Morpho is not an included integration or announced partnership.
- The proposed new-token companion reserve, a token migration, or permission to change existing NFT/token contracts.
- Private operational records, production wallet configuration, deployment scripts, private repository history or the web application.

Existing Hunter NFTs are the product context. Publishing this source does not migrate them or change their rights. Future integration with deployed contracts needs its own compatibility review and approval.

## Run locally

Requirements: Git, Node.js 22 or newer, and [Foundry](https://getfoundry.sh/) **v1.7.1**. Solidity **0.8.24** and EVM **Cancun** are pinned in the configuration. The first build may download the compiler; no wallet, RPC credential or real funds are needed.

From the repository root:

```sh
git submodule update --init --recursive
node scripts/check-publication.mjs
forge build --root contracts
forge test --root contracts
FOUNDRY_PROFILE=release forge test --root contracts
forge test --root contracts/specs/hunter-bloom
```

All tests use the local Forge EVM. They do not broadcast transactions or require a network fork.

The default contract profile preserves the source configuration: optimizer off, 200 optimizer runs, via-IR off. The `release` profile enables the optimizer at 200 runs with via-IR still off. Its name is inherited; it does **not** confer release approval. The default unoptimized lifecycle exceeds the EIP-170 runtime size limit and must not be treated as a deployable build. Arithmetic-spec tests retain their separate optimized profile and 128 fuzz runs.

## Start reading

- [Architecture and custody boundaries](docs/ARCHITECTURE.md)
- [Development status and risks](docs/STATUS.md)
- [Contributing](CONTRIBUTING.md)
- [Security reporting](SECURITY.md)
- [Project attribution](NOTICE) and [source/dependency notices](NOTICE.md)
- [Verification scope](docs/VERIFICATION.md)

[Project website](https://proofhunter.fun/) · [Bloom product guide](https://doc.proofhunter.fun/guides/bloom/)

## License

[Apache License 2.0](LICENSE) for this project's code and documentation. Copyright (c) 2026 vltgoblin. See [NOTICE](NOTICE) for project attribution.

Redistributions must comply with the license, including its applicable copyright, attribution, NOTICE and modification-notice requirements. This does not add a mandatory advertising credit, website badge or social mention. Dependencies retain their own licenses and notices. No NFT artwork, project trademark or branding rights are granted by the code license.

This release changes first-party licensing headers from the earlier MIT-marked source snapshot. It does not revoke MIT permissions already granted for earlier copies. The manifest retains original and current hashes; contract logic is unchanged by the licensing update.
