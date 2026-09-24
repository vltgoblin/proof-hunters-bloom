# Source and dependency notices

This standalone package contains an allowlisted snapshot of Proof Hunters contract source and relevant tests. The source revision is `256d82309c478624ac014763f416305dfa3789f1`. The owner selected Apache-2.0 for this release, with project attribution in [NOTICE](NOTICE) to `vltgoblin`.

The 75 first-party Solidity files have Apache-2.0 SPDX headers and a `vltgoblin` copyright line. Beyond that header change, their original contents are preserved. Two JSON arithmetic fixtures are unchanged. `SOURCE-MANIFEST.json` records both the original snapshot hashes (`sourceSha256`) and current publication hashes (`sha256`). Packaging, documentation and CI files are new. Prior MIT permissions granted for earlier copies are not revoked by this release.

This is a clean-history extraction, not the complete application or development history. Old milestone identifiers and comments referring to other documents describe the original development context. They are not claims of independent audit or current production readiness.

## Dependencies

Dependencies are public upstream Git submodules pinned to exact revisions, not copies from an operator's working tree:

| Dependency | Pinned revision | License |
| --- | --- | --- |
| [OpenZeppelin Contracts](https://github.com/OpenZeppelin/openzeppelin-contracts) | `cab19933c33c2ad1d4c7a84864a3601dddfd16f3` | MIT; see `contracts/lib/openzeppelin-contracts/LICENSE` |
| [Forge Standard Library](https://github.com/foundry-rs/forge-std) | `bf647bd6046f2f7da30d0c2bf435e5c76a780c1b` | MIT or Apache-2.0; see the library's `LICENSE-MIT` and `LICENSE-APACHE` |

Keep dependency license and attribution files intact when redistributing them. The project's Apache-2.0 license does not replace upstream terms. No dependency source headers, copyright holders, licenses or pinned revisions were changed by this licensing update.

## Scope decisions

The import closure adds `LiveHunt.sol` and `ILiveHuntNFT.sol` because NFT and DirectLoan mutual-exclusion tests import them. It does not include the separate legacy mining/token implementation.

Excluded test areas include deployment/launch preflight, the old token/miner, the operational income-bridge fixture, composition/deployment scripts and the unrelated bounded-accounting prototype. Public tests therefore do not claim coverage of every private application or deployment path.

The current publication guard verifies that reversing the first-party header update restores the original source hashes. Future substantive source changes require an explicit provenance-policy update; do not silently overwrite the original snapshot hashes. The manifest is an extraction-integrity check, not a signature, audit or security guarantee.
