# S1 (VLT-52): live facts from Robinhood Chain mainnet (chain id 4663)

This was read-only. No transactions were sent and no keys were used. The work used `cast call/code/storage/logs/rpc eth_call` (pinned tools forge/cast 1.7.1) and `forge test --fork-url` on local forks. Every state change in the fork test happened only in the local fork.
Artifacts: `s1/` in the scratchpad: raw code (`code/*.hex`), `codehashes.txt`, `bytecode-compare.txt`, `core.txt`, `cust.txt`, `nft-lc-res.txt`, `lc-probe.txt`, `token.txt`, `evm-env.txt`, `blocktimes.txt`, `facts-B2.txt` and `forktest-B2.log`.
Test file: `contracts/test/fork/PrefundedForkFacts.t.sol`. It is new and uncommitted.

## Pinned blocks

| pin | L2 block | L2 timestamp | parent (L1) block = on-chain `block.number` | L2 hash |
|---|---|---|---|---|
| A (code + most facts) | 71892749 | 1790305530 (2026-09-25 03:05:30 UTC) | 26051667 | 0xbb0f4448…23dc |
| B2 (fork test + state re-read) | 71901986 | 1790306466 (2026-09-25 03:21:06 UTC) | 26051745 | 0xc5aea4f5…1fec |

**The public RPC is not an archive node.** After roughly 20–30 min, pin A failed with `historical state … is not available`. For that reason the fork test and the state re-read ran at a second pin, B2. Code is identical across the two pins because every contract is immutable and non-proxy. The only state that changed between A and B2 was one accepted proof (449 → 450). **Tables below give B2 values** unless marked otherwise.
Run the fork test with: `FORK_RPC_URL=https://rpc.mainnet.chain.robinhood.com FORK_BLOCK=<recent> forge test --match-path 'test/fork/*' -j 1`. Leave `FORK_BLOCK` unset to use the latest block. A pin older than about 20 minutes fails.

## 1. Code: extcodehash, size, and comparison with the public source (release profile: solc 0.8.24, cancun, optimizer 200)

The local build used `FOUNDRY_PROFILE=release forge build --skip test --skip script` against this repo's sources. `src/bloom` differs from b5a6bc0 only by the new PrefundedMiningPower.sol. For each contract I compared the runtime from `deployedBytecode`. The comparison stripped the trailing CBOR metadata (its length is in the last 2 bytes) and masked the `immutableReferences` byte ranges in both the local and the live copy.

| contract | address | size | extcodehash (= keccak(runtime)) | vs public source |
|---|---|---|---|---|
| HunterMiningCore | 0xf213…4c2c | 10370 | 0x0fd8b83da061b5581d3bb4e3b906b80ee60c68130ddf787586324a2b966bfd95 | equal modulo metadata and immutables |
| HunterNFT | 0x924a…e273 | 9729 | 0x137ff387ef44fd8ea05afdd4524b6414de21988c7ab140042a211c0f0c43ae03 | equal modulo metadata and immutables |
| HunterLifecycle | 0x3eed…ef7d | 17670 | 0x5333163fd17e2d230298a949453df9d8ecaf353c454ff7d7ac69366dbe0959bb | equal modulo metadata and immutables |
| HunterReserveVault | 0x681e…bb82 | 6788 | 0x028e63d9c55a0a7a775b8ec261b90ad65fbcf56c7edcdddee40a895fd43eed40 | equal modulo metadata and immutables |
| HunterBackingVault | 0x7cb8…347d | 15273 | 0x2699ac25a2afa5f6de7b2ca96d57d6a684fa7b543ddd090b20de077d1f40fc87 | equal modulo metadata and immutables |
| WeightedRoundLedger | 0x3c53…37d9 | 6398 | 0xa6a03f46d62f7b226ccc20fd040fbcf462fb7e9dd9bd742560dc498b03402ff1 | equal modulo metadata and immutables |
| BasketRegistry | 0x0487…c703 | 2873 | 0xfc1b48a2a68119fc4429523d77a8ff70db0242aeacad8e3b9bcdaf0d2893abc1 | equal modulo metadata (no immutables) |
| LiveHunt | 0x0621…7bf6 | 8219 | 0xf921eaeeda81dbac3c3a6da0e278fe0c6d862595062e66999d916418c43ddd3f | equal modulo metadata and immutables |
| MiningPowerCustody (old) | 0x73a9…F306 | 6690 | 0xcadf5e8acc363626a1841cffb5adb8da1d7024eb6a659fd074cbc44cb839bcd2 | equal modulo metadata and immutables |
| HUNTER token | 0xBBDD…7960 | 3248 | 0x5cbed682efd35d15e5d2f2cdc88b3fc80176145c6a9aba06fac3553a0943c90c | not in this repo (solc 0.8.35 per CBOR) |

- In every case, sizes are byte-identical and the executable bytes match after masking immutables. None matches exactly, because the CBOR metadata hash differs in all of them. All of them carry solc `0.8.24` (`…64736f6c6343000818`) in the CBOR.
- **The manifest hash `0x0fd8b8…bfd95` equals the core's `extcodehash`, which is keccak256 of the deployed runtime bytecode including immutables and metadata.** Both `cast keccak (cast code)` and `address(CORE).codehash` in the fork test confirm this. It is not a hash of the creation code or of the metadata-stripped code.
- Immutables recovered from the live runtime:
  - Core: MIN_TARGET, MAX_TARGET, GENESIS_TARGET (see §2); GENESIS_SEED_PARENT_BLOCK = 26036530; GENESIS_SEED_MINIMUM_DELAY = 3; MINING_STOP_MULTISIG = 0xEE95…6C15; MINING_STOP_SUNSET = 0x6b000f91 = 1795166097; PROOF_NFT = 0x924a…e273.
  - Custody: HUNTER = 0xBBDD…7960, miningCore = core, curveUnit = 1e24 (1,000,000 HUNTER).
  - NFT: MINER = core, REGISTRY, LIFECYCLE, ART_VERSION = 1, ROYALTY_RECIPIENT = 0xEE95…6C15 (the stop account).
  - Reserve, Backing and Ledger: TOKEN_AUTHORITY = 0xAC11D1d09f171FE48F2f30BF76466A217c85C00f. This is also the token's `deployer()`.

## 2. Mining Core state (B2; pin A in brackets)

| getter | value |
|---|---|
| miningPower() | 0x73a9796768F69f9089A03B0eEDd8F0D41EE6F306 (old custody) |
| miningPowerWasAttached() | true |
| MINING_STOP_MULTISIG() | 0xEE951AA16F261B31B921E54FCA6bA2074b496C15 |
| MINING_STOP_SUNSET() | 1795166097 = 2026-11-20 09:14:57 UTC (about 56 days after B2) |
| miningStopped() | false |
| nftsMintedEver() / acceptedProofs() | 450 / 450 [449 / 449]; NFT.mintedEver() = 450 |
| activeChallengeId() | 464 [463] (13 seed refreshes so far: 464 − 1 − 450) |
| activeSeedParentBlock() | 26051701 [26051604] |
| previousAcceptedDigest (A) | 0x0000000004a7fc3c…ac31 |
| currentTarget() | 1842604861898166636326147918635834951085774054732756321866642557592 = **0.150749 × GENESIS_TARGET** (about 1 in 6.28e10 hashes) |
| retargetWindowProofs() | 18 [17] |
| retargetWindowStartBlock() | 26048785 |
| lastProofBlock() | 26051698 [26051601] |
| lastEaseBlock() | 26036466 (= deployment parent block; **no ease has ever happened**) |
| challengeState() | 1 = ACTIVE (on-chain eth_call) |
| PROOF_NFT() | 0x924a65312cd535bc8787acECdfa5F71609B4e273 |
| MIN_TARGET | 1222300462931713417584073808721893676106053654785799575224840304290 (= GENESIS/10 − 1) |
| GENESIS_TARGET | 12223004629317134175840738087218936761060536547857995752248403042914 (about 1 in 9.47e9) |
| MAX_TARGET | 122230046293171341758407380872189367610605365478579957522484030429154 (= 10·GENESIS + 14) |
| SEED_READABLE_PARENT_BLOCKS | 256 |

Of the 450 proofs, 432 went through 3 completed retarget windows, and 18 are in the current window. Together those three retargets took the target to 0.1507× genesis, which is close to MIN (0.1×). The current window has 18 proofs in 2960 parent blocks, about 164 per proof against the 50 target. If that pace continues, the next retarget makes mining easier.

## 3. Stop "multisig": **it is not a multisig. It is an EOA with an EIP-7702 delegation.**

- Code at 0xEE95…6C15 is 23 bytes: `0xef0100 63c0c19a282a1b52b07dd5a65b58948a07dae32b`. That is an EIP-7702 delegation designator. The account nonce is 14, and it holds 0.0361 ETH.
- The delegate 0x63c0C19a282a1B52b07dD5a65b58948A07DAE32B is 11185 bytes (keccak 0xa06befcb…e6b0). It reports:
  - `NAME()` = "EIP7702StatelessDeleGator"
  - `VERSION()` = "1.3.0"
  - `DOMAIN_VERSION()` = "1"
  - `entryPoint()` = 0x0000000071727De22E5E9d8BAf0edAc6f37da032 (ERC-4337 v0.7)
  - `delegationManager()` = 0xdb9B1e94B5b69Df7e401DDbedE43491141047dB3
  - `eip712Domain` verifyingContract = the stop account itself
  
  This is MetaMask Delegation Framework's stateless 7702 smart account, where the signer is the EOA's own key. It exposes `execute(bytes32,bytes)` (ERC-7579 modes, including batch), `executeFromExecutor` and `isValidSignature`.
- The Safe getters fail: `getOwners()`, `getThreshold()` and `nonce()` revert. Storage slot 0 (masterCopy) is 0, and the EIP-1967 slot on the delegate is 0. **The `VERSION()` = "1.3.0" reply belongs to the DeleGator. It does not mean this is a Safe 1.3.0.**
- Safe infrastructure does exist on 4663, by code size:
  - MultiSendCallOnly v1.3.0 canonical 0x40A2…130D: 410 bytes. v1.3.0 eip155 0xA1da…102B: 410. v1.4.1 0x9641…02e2: 410.
  - Safe singletons 0x3E5c… (23800), 0x4167… (23579), 0x29fc… (24421).
  - Proxy factories 0xa6B7… (3774), 0x4e1D… (3054).
  
  None of this helps here. MultiSend `CALL`s would present MultiSend as `msg.sender`, and the core requires `msg.sender == 0xEE95…6C15`.
- **What this means for the cutover method:** the cutover is signed by **one private key**, the stop EOA, in one of two ways:
  - two plain transactions sent directly from the EOA, `setMiningPower(0)` then `setMiningPower(new)`; or
  - one atomic self-call to the account's own `execute(batchMode, [detach, attach])`, which runs as the EOA so `msg.sender` is correct. The DeleGator allows the call when it comes from the account itself or from the EntryPoint.
  
  The fork test has not rehearsed the batched path. The fork runs under the cancun spec, which does not execute 7702 delegations. It needs a Prague-spec fork test in a later slice.
- The same EOA is also the NFT `ROYALTY_RECIPIENT` and appears twice in LiveHunt's immutables.

## 4. Old custody 0x73a9…F306

| getter | value |
|---|---|
| HUNTER() | 0xBBDD439FD49ADE6Ff3C96f748867de4356647960 |
| miningCore() | 0xF213854c6D5D4334D23D452574556bD53CA24c2C |
| curveUnit() | 1e24 |
| wired() / retired() | true / false |
| totalLocked() = totalAssigned() | 6,014,424 HUNTER (6.014424e24). **All locked stake is assigned.** |
| HUNTER.balanceOf(custody) | 6.014424e24 (exactly totalLocked, no surplus) |
| lastAcceptedProofs() | 450 (= core) |
| latestChallengeId() | 464 (= core.activeChallengeId) |
| UNLOCK_DELAY_PROOFS() | 12 |

- The live runtime is the public `MiningPowerCustody` modulo metadata and immutables. It contains `PUSH4 0x4d680190` (acceptedProofs()) and `PUSH4 0x843d5a5c` (challengeState()).
- The fork test `test_fork_custodyUnassignReadsLiveCoreAfterDetach` rehearsed the full sequence, and it passes:
  1. A fresh depositor deposits and assigns 1000 HUNTER.
  2. The stop account runs a non-terminal `setMiningPower(0)`. Afterwards custody has wired = false and retired = false.
  3. `unassign` reverts with `UnlockDelayNotMet(462, 450)`.
  4. Core `acceptedProofs` is bumped by `vm.store` (slot 5) to +11, and unassign still reverts `(462, 461)`.
  5. At +12, unassign succeeds while `custody.lastAcceptedProofs` stays frozen at 450. The live-core read is the only way the call can succeed.
  6. After a fork-local `stopMining()` on the detached core, custody was never notified (retired = false). `challengeState` = STOPPED waives the delay, and `unassign` and `withdraw` succeed.

## 5. NFT / Lifecycle / Reserve

- NFT:
  - `MINER()` = core ✓, `LIFECYCLE()` = 0x3eed…ef7d ✓, `REGISTRY()` = 0x0487…c703.
  - `mintedEver()` = 450 [449], `MAX_NFTS_EVER()` = 5000.
  - `totalSupply()` does not exist (it reverts).
- Lifecycle:
  - `nft()` = NFT ✓, `reserve()` = 0x681e…bb82 ✓, `backing()` = 0x7cb8…347d ✓.
  - Selectors `finalBeneficiary(uint256)` 0xafad39eb and `currentMember(uint256)` 0xd9adacb7 are both present in the runtime.
  - Pin A:
    - `finalBeneficiary(1)` = 0 and `currentMember(1)` = (basket 0xd0601CE1…9EEC, rarity 125, hunter 0, alive = true, eligible = true).
    - `currentMember(449)` = (same basket, 110, 0, true, true).
    - For id 450, then not minted: `finalBeneficiary` = 0, and `currentMember` reverts `UnknownId()` (0x48e73c8e).
  - **No token has ever been burned.** There are 0 `Transfer(…, 0x0, …)` logs from the first mint (L2 block 70139953) to pin A, against 449 mints. The fork test burns the first owner-held token by its real owner (`redeemAndDestroy`). Afterwards `currentMember.alive` = false, `eligible` = false, `finalBeneficiary` = owner, and `reserve.settled` = true.
  - Unknown ids revert `UnknownId`. Code that uses `currentMember` for ids that may be unminted needs try/catch.
- Reserve:
  - `NFT()` ✓, `LIFECYCLE()` ✓, `HUNTER()` = 0xBBDD…7960.
  - `TOKEN_AUTHORITY()` = 0xAC11D1d09f171FE48F2f30BF76466A217c85C00f.
  - `tokenActivated()` = true.
  - `totalReserved()` = 0 and HUNTER balance = 0: nobody has deposited a reserve yet. Token 1 has `reserveOf` = 0.

## 6. HUNTER token 0xBBDD…7960

- `name` "Proof Hunter", `symbol` "HUNTER", `decimals` 18.
- `totalSupply` = 999,846,398.227005015601984051. That is 1e9 minus about 153,602 burned; the token has `burn` and `burnFrom`.
- The code is 3248 bytes, compiled with solc 0.8.35. It is **not a proxy**:
  - the EIP-1967 implementation, admin and beacon slots are all 0;
  - `implementation()` reverts;
  - there is no DELEGATECALL, CALLCODE or SELFDESTRUCT in the code.
- The dispatcher contains only standard ERC-20 selectors plus `burn`, `burnFrom`, `launchFactory()` (0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e), `curve()` (0x994108D6C160b628F33110aC09154ecd8dAE4684, 10229 bytes of code, holds 0 HUNTER), `deployer()` (= TOKEN_AUTHORITY 0xAC11…C00f), `getTokenInfo()`, `description()`, `logo()` and `socials()`. It is a launchpad token.
- `owner()`, `paused()`, `isBlacklisted(address)`, `isBlackListed(address)`, `blacklisted(address)` and `blacklist(address)` do not exist; all revert with empty data. Four other selectors in the code (0x391434e3, 0x4a1406b1, 0x4b637e8f, 0x7dc7a0d9) revert when called with no arguments. They are probably custom errors.
- **Measured on the fork at B2, the token takes no transfer tax.** Balances were set with `deal` (standard storage works). A `transfer` of 1e18 gave the recipient +1e18 and the sender −1e18, with totalSupply unchanged. `transferFrom` of 1e18 gave the recipient +1e18. The custody `deposit` inside the detach test also received the full amount (it checks the balance difference).

## 7. Chain

- Chain id 4663 (eth_chainId, `CHAINID`, and ArbSys `arbChainID()`). It is an Arbitrum Orbit chain: ArbSys `arbBlockNumber()` = L2 number.
- **L2 block time is about 0.1 s.** The L2 timestamp advanced 10 s over 100 blocks, 999 s over 10,000 blocks and 100,839 s over 1,000,000 blocks.
- **Parent block cadence (what the core's `block.number` measures) is about 12.1 s per block.** It advanced 83 over 999 s and 8,333 over 100,839 s.
- An on-chain EVM probe (eth_call of init code, pin A) returned:
  - `NUMBER` = 26051667 (**the parent/L1 block number**, not the L2 number);
  - `BLOCKHASH(n−1)` and `BLOCKHASH(n−256)` both nonzero, `BLOCKHASH(n−257)` = 0, so exactly 256 are readable;
  - `BASEFEE` = 0 and `GASPRICE` = 0 inside eth_call.
- The on-chain `BLOCKHASH(26051666)` = 0xdae7639c…e3d3, while Ethereum mainnet block 26051666's hash is 0x961241d7…b3e1. **The seed hash is ArbOS's recorded value, not the L1 block hash.** Miners must read it from the chain, not from L1.
- Gas price: eth_gasPrice about 0.041 gwei; header baseFee 0x27afab0 = 0.0416 gwei.
- **The fork differs from the chain:** in the Foundry fork, `block.number` is the **L2** number (71,901,986), and `blockhash(n−1)` and `blockhash(n−256)` are nonzero L2 hashes. So the core's `challengeState()` on a fork reads EXPIRED (2), while the chain reads ACTIVE (1). Any fork test that depends on the parent-block clock (seed, ease, retarget, submitProof) must first `vm.roll(<parent block>)`, and seed hashes will not match the chain.

## 8. Seed and cadence at B2

- The parent block at B2 is 26051745. `activeSeedParentBlock` = 26051701, which is `lastProofBlock` 26051698 + SEED_DELAY 3 ✓.
- The seed is 44 parent blocks old. It turns EXPIRED when `block.number − seed > 256`, so from parent block 26051958. That is 213 parent blocks away, about **43 min** at 12.1 s. (At pin A: seed 26051604, age 63, 194 left, about 39 min.)
- A challenge is readable for exactly 256 parent blocks ≈ **51.6 min**. This matches SEED_READABLE_PARENT_BLOCKS = 256, and the probe confirms blockhash depth 256.
- The last two proofs were 97 parent blocks apart (about 19.6 min). The stall interval is 250 parent blocks (about 50 min). The ease path has never fired.

## Stop conditions

| | condition | result | evidence |
|---|---|---|---|
| (a) | code hashes match the manifest and the public source modulo metadata | **PASS** | The core's extcodehash equals the manifest hash exactly. All 9 project contracts equal the release-profile compile after stripping CBOR metadata and masking immutables. Sizes match exactly. |
| (b) | the live old custody's unassign reads the live core after detach | **PASS** | Both selectors are present in the live runtime. The fork rehearsal passes: the delay is enforced against live `acceptedProofs`, and the terminal waiver comes from live `challengeState`. |
| (c) | the live lifecycle exposes finalBeneficiary and currentMember with the expected behaviour | **PASS** | Both selectors are present. Live reads show live members as alive/eligible and `finalBeneficiary` = 0. A fork-simulated burn gives alive = false and `finalBeneficiary` = burner. Unminted ids revert `UnknownId`. No real burn exists on-chain yet. |
| (d) | the core's miningPower is the old custody, miningPowerWasAttached is true, and sunset == 1795166097 | **PASS** | All three hold at both pins. |

## Surprises / follow-ups

1. **The "stop multisig" is a single-key EOA** with an EIP-7702 MetaMask DeleGator delegation, not a Safe. The cutover is one-key-signed. For atomic detach + attach, use a self-call to `execute(batch)`; otherwise send two transactions, which leaves a window with no module. That batch path should be rehearsed on a Prague-spec fork. The EOA key also controls royalties.
2. The core's clock is the **Ethereum L1 block number (about 12 s)**, not L2 blocks. BLOCKHASH is ArbOS's value, not the L1 hash. Foundry forks use the L2 number, so the fork test must `vm.roll`.
3. The public RPC keeps only about 20–30 min of historical state, so pinned fork tests must run promptly after pinning.
4. All 6,014,424 locked HUNTER are assigned. Every depositor must unassign after detach, and the 12-proof delay runs on the live core clock (about 97–164 parent blocks per proof lately, so roughly 4–7 h). The reserve holds 0 HUNTER, and there have been no burns.
5. The token is a non-proxy, tax-free launchpad ERC-20 with public burn. No pause or blacklist.
