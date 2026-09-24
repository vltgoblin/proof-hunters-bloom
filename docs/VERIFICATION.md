# Verification scope

This document records local package checks, not a security audit or live deployment test.

Prepared from source revision `256d82309c478624ac014763f416305dfa3789f1` with Foundry v1.7.1 and Solidity 0.8.24. `SOURCE-MANIFEST.json` records both original and current hashes for all 77 imported source/test/fixture files. The current package uses Apache-2.0 for first-party files, with `vltgoblin` attribution in NOTICE.

## Apache-2.0 packaging update

The 75 first-party Solidity headers were changed from MIT to Apache-2.0 with a copyright line for `vltgoblin`. Reversing only those headers reproduces all original source hashes; contract and test bodies were not edited. Two JSON fixtures and both dependency pins are unchanged. The source-license update can change compiler metadata hashes; it is not a bytecode-identity claim.

The complete LICENSE text matches the canonical Apache 2.0 text, with SHA-256 `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30`. NOTICE credits `vltgoblin`; dependency license and copyright notices are preserved. New publication checks reject altered license text, missing project attribution, stale Solidity headers and source-body drift even if a current-file hash is updated.

Post-update validation:

- Default profile compilation and unit/fuzz suite: 339 passed, zero failures or skips.
- Optimized `release` profile compilation and unit/fuzz suite: 339 passed, zero failures or skips.
- Arithmetic vector/fuzz suite: 12 passed, zero failures or skips.
- Publication guard regression suite: 8 passed, including licensing and original-source-body checks.
- Indexed publication guard: 97 entries, 77 source/fixture records, two pinned dependencies and zero privacy-pattern findings.

Both contract runs used `--no-match-test '^invariant_'`. Full invariant campaigns were not repeated for this licensing-only update: all executable contract/test bodies are verified unchanged. The full invariant results in the next section are from the pre-license-change extraction, not a new campaign. No live deployment or hosted CI run is claimed.

## Pre-license-change standalone checks

The clean-room export had no private history, prebuilt artifacts or private configuration. It fetched its dependencies from the pinned public upstream repositories.

| Check | Result |
| --- | --- |
| Publication guard | 96 indexed entries at that revision; 77 imported files matched their original source hashes; two dependency pins verified; zero privacy-pattern findings |
| Publication guard regression tests | 8 passed, including rejected extra files, modified source, missing files and changed dependency pins |
| Gitleaks v8.30.1, exported publication files | Zero findings; full value redaction and no allow-comment suppression |
| Full standalone suite, default profile | 351 passed; zero failures or skips, including all 12 invariant tests |
| Full standalone suite, optimized `release` profile | 351 passed; zero failures or skips, including all 12 invariant tests |
| Clean-room unit/fuzz suite, default profile | 339 passed; zero failures |
| Clean-room unit/fuzz suite, optimized `release` profile | 339 passed; zero failures |
| Clean-room arithmetic vector/fuzz suite | 12 passed; zero failures; 128 runs for fuzz tests |
| Workflow static validation | Passed with actionlint v1.7.7 |
| Clean-room optimized contract-size check | Passed; DirectLoan runtime 10,130 bytes; HunterLifecycle runtime 17,670 bytes |

The clean-room unit/fuzz runs used `--no-match-test '^invariant_'` to isolate portability checks. The full standalone suite additionally ran all invariant campaigns under each compiler profile, retaining Foundry v1.7.1 defaults of 256 runs and depth 500, with no reduced campaign sizes. Default fuzz tests used 256 runs. Hosted CI is configured but has not run before repository publication.

### Known size-check failure

The default **unoptimized** `forge build --sizes` check fails because HunterLifecycle is 27,208 bytes, above the EIP-170 limit of 24,576 bytes. This is an existing source/profile limitation, not a failure to compile or a reason to silently change the default build. The optimized profile passing a size check is not deployment or security approval.

Inherited compiler/lint warnings remain, including declaration-name, mutability and test-token-transfer warnings. No executable contract logic was rewritten for this extraction or its licensing update.

The publication guard checks the Git index, including dependency pins and the source manifest. It rejects unlisted files, non-regular files, binaries, files above 3 MiB, common personal paths, unexpected email addresses, private-network references and credential-shaped URLs. Gitleaks adds pattern-based secret detection. Neither check proves the absence of every possible secret or personal detail.

Dependency source is fetched from pinned public upstream commits with upstream license notices retained. Dependencies' public Git histories are separate from this project's clean-history source release.

Not covered: a new independent contract-security audit, economic safety, external market/oracle integration, production parameter selection, deployment, real fund movement or end-to-end website behavior.
