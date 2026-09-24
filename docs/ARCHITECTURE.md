# Architecture

The package keeps the original file layout so imports and source hashes remain comparable.

| Component | Responsibility | Important boundary |
| --- | --- | --- |
| `DirectLoan` | Fixed-term whole-NFT loan requests, funding, repayment, default and claims | Escrows the NFT; does not move its basket backing into an external lending market |
| `HunterNFT` | NFT ownership, immutable birth data and custody/encumbrance rules | Sale, burn, switch and credit state must not permit conflicting claims |
| `HunterLifecycle` | Connects NFT, reserve and backing actions; fixes the final burn beneficiary | Wiring and caller authentication are part of the security model |
| `HunterReserveVault` | HUNTER reserve custody attached to a token ID | Separate from Mining Power and from basket-asset backing |
| `HunterBackingVault` | Received basket-asset custody, owner deposits and burn/late-share payouts | Nominal round budgets are not token balances |
| `WeightedRoundLedger`, `WeightedRoundFunding`, `WeightedRoundMaterialisation` | Historical allocation, funding receipts and per-NFT materialisation | Historical cutoffs, actual receipts and one-time consumption must agree |
| `BasketRegistry`, `IBasketConverter` | Asset/route admission and conversion interface | Admission is policy, not independent proof of liquidity or economic safety |
| `WeightedHistory`, weighted math libraries | Checkpoint history and integer allocation arithmetic | Rounding, timing and large-value behavior are tested separately |
| `HunterMiningCore`, `MiningPowerCustody` | Mining and separate optional power custody | Included for integration context; not a token or NFT relaunch |
| `LiveHunt`, `ILiveHuntNFT` | Offer/fulfillment integration | Included to test interactions with loan custody and ownership |

## Whole-Hunter loan sequence

1. The owner escrows the NFT through `HunterNFT.escrowTo`, encoding versioned loan terms. `DirectLoan` validates the callback and records the request.
2. A lender funds an eligible request within its funding window. The borrower receives the principal net of the configured origination fee.
3. The borrower deposits repayment before the deadline. Full repayment changes the state to repaid; the borrower can claim the NFT, and the lender separately claims repayment.
4. Cancelling an unfunded request returns the NFT to the borrower in the same transaction. For a funded loan that defaults, the default-resolution rules determine when resolution is allowed; the lender then becomes the NFT claimant. Partial deposits follow the contract's borrower-refund accounting.

After repayment or default resolution, the NFT claim is a separate transaction. Attached reserve/backing is not an automatic debt payment source. Test fees and duration bounds are fixtures, not selected public loan terms.

## Basket-asset lending is a separate future integration

Credit-lock hooks and custody exclusions are not a lending adapter. A complete external route still needs market acceptance, real loan funding, eligible asset rules, price/oracle design, liquidation behavior and tested release/default paths. This repository does not announce any external protocol partnership.
