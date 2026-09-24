# Contributing

Bloom is development software. Small, reproducible contributions are welcome.

1. Explain the behavior, risk or missing test before proposing a broad redesign.
2. Follow the commands in the README and use the pinned compiler/dependencies.
3. Add focused tests for changed behavior, including authorization, repayment/default boundaries, callback/reentrancy behavior and asset-accounting effects where relevant.
4. State which tests ran and which checks remain unverified. Do not describe local tests as deployed or audited evidence.
5. Keep unrelated formatting and dependency upgrades out of the change. Apart from their licensing headers, imported files preserve their original formatting for source comparison.

Never commit environment files, credentials, wallet backups, private keys, local user paths, production deployment logs, screenshots of accounts or private infrastructure details. Use generated test identities and mock assets. Configure a public Git author name and GitHub noreply email before committing.

`node scripts/check-publication.mjs` checks indexed publication files, the Apache license text, project attribution, source hashes and dependency pins. This initial package is anchored to a source snapshot with licensing-only changes. Substantive source changes require an explicit provenance-policy and manifest update, not silently rewriting the original snapshot hashes. Newly added files require an explicit policy update. Passing these checks does not replace code review.

Run a secret scan before publication. Report exploitable issues privately as described in [SECURITY.md](SECURITY.md), not in a public issue or pull request.

By contributing, you confirm that you have the rights to submit your contribution under the repository's Apache License 2.0. Preserve applicable copyright and attribution notices, document your modifications, and retain dependency licenses. See LICENSE and NOTICE.
