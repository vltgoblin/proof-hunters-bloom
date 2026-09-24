# Status and intended use

This package is prepared for code inspection and local development. It is not a launch announcement.

## Included implementation

- Whole-NFT DirectLoan request/fund/repay/cancel/default/claim contracts and local tests.
- NFT, reserve, lifecycle, backing and weighted allocation modules required to inspect the custody model.
- Mining Power, mining and Live Hunt integration tests relevant to shared NFT state.

## Not established by this release

- Deployment of Bloom, live lenders, loan liquidity, approved production fees or supported real loan assets.
- Production compatibility with every existing NFT/contract deployment.
- A completed independent security audit or an economic guarantee.
- External basket-asset borrowing, automatic repayment from backing or a liquidation/oracle integration.
- Implementation of the separate proposed new-token companion reserve/rewards system.

The public product currently distinguishes live mining from Bloom borrowing in development. Backing funding is a separate operational decision, not something this code publication turns on. Check the [project guide](https://doc.proofhunter.fun/guides/bloom/) for product updates; do not infer a live market from source availability.

## Risks to understand

Default can cost the borrower their NFT or, for any future basket-collateral route, pledged assets. Collateral values, lender availability and market liquidity are uncertain. Real ERC-20 behavior can differ from mocks. Privileged roles, immutable bindings, one-time configuration, callback behavior and deployment size limits need review before funds are placed at risk.

No production addresses, wallet instructions or transaction-broadcast scripts are bundled.
