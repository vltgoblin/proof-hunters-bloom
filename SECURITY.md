# Security policy

This is an experimental development-source release. No production-safe version, audit certification, funded bug bounty or response-time commitment is implied.

## Report privately

Use this repository's **Report a vulnerability** feature if private vulnerability reporting is enabled. If it is unavailable, contact **social@proofhunter.fun** with a short request for a private security-reporting channel. Do not send private keys, seed phrases, passwords or personal information. Do not post an unpatched exploit in a public issue.

Include the affected source revision, relevant contract/function, impact, assumptions and a local Forge reproduction using mock assets. Do not attack live contracts, spend other people's funds, or probe private infrastructure to demonstrate an issue.

## Important boundaries

- A defaulted whole-NFT loan can transfer the NFT and its attached rights to the lender.
- Loan asset behavior, custody wiring, deployment parameters and role holders affect safety. Unit tests with mock tokens do not approve arbitrary real assets.
- The DirectLoan stop authority can permanently stop new entry. Existing settlement paths remain separate; do not claim there are no privileged roles.
- Basket admission and round recording/funding have explicit trust and configuration boundaries. A basket entry or nominal budget is not proof of available collateral.
- External basket-asset lending, market funding, oracle selection and liquidation integration are not provided by this package.

Before any deployment, obtain an independent review of the exact build, bytecode sizes, constructor values, permissions, token behaviors and full end-to-end custody flows. This source release grants no deployment approval.
