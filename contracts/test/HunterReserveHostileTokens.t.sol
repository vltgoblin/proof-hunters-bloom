// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 vltgoblin
pragma solidity 0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {HunterNFT} from "../src/bloom/HunterNFT.sol";
import {HunterReserveVault} from "../src/bloom/HunterReserveVault.sol";
import {ReserveLifecycleFixture} from "./helpers/HunterReserveFixtures.sol";
import {ReserveVaultTestBase} from "./HunterReserveCore.t.sol";

/// @notice TEST-ONLY adversarial ERC20. NOT production and NOT a real-token
/// compatibility claim: switchable modes exist only to exercise the vault's
/// receipt/debit accounting against false returns, phantom receipt and hidden
/// sender-side fees. Default mode is a plain ERC20.
contract HostileTokenFixture is ERC20 {
    enum Mode {
        Normal,
        FalseReturn,
        BonusReceipt,
        ExtraSenderFee
    }

    address public vault;
    Mode public mode;

    constructor() ERC20("Hostile HUNTER", "xHUNT") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setVault(address newVault) external {
        vault = newVault;
    }

    function setMode(Mode newMode) external {
        mode = newMode;
    }

    /// @dev TEST-ONLY: in FalseReturn mode reports failure without moving any
    /// balance; every other mode is an ordinary ERC20 transfer.
    function transfer(address to, uint256 value) public override returns (bool) {
        if (mode == Mode.FalseReturn) return false;
        return super.transfer(to, value);
    }

    /// @dev TEST-ONLY: same false-return behavior as `transfer`.
    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (mode == Mode.FalseReturn) return false;
        return super.transferFrom(from, to, value);
    }

    /// @dev Mode effects run AFTER the honest super._update and re-enter the
    /// base implementation directly, so the adversarial clauses never recurse.
    /// BonusReceipt: inbound non-mint transfers into the vault conjure 1 extra
    /// unit inside the vault. ExtraSenderFee: outbound transfers from the vault
    /// burn 1 extra unit out of the vault (sender pays more than `value`).
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (mode == Mode.BonusReceipt && from != address(0) && to == vault) {
            super._update(address(0), to, 1); // phantom bonus lands in the vault
        } else if (mode == Mode.ExtraSenderFee && from == vault) {
            super._update(from, address(0), 1); // hidden fee skimmed off the vault
        }
    }
}

/// @notice Hostile-token reserve tests. Every case deploys a FRESH matched
/// lifecycle/vault/NFT wired to its own hostile token; only the shared
/// registry/basket/accounts of the base are reused. TEST-ONLY throughout.
contract HunterReserveHostileTokensTest is ReserveVaultTestBase {
    struct HostileSet {
        HostileTokenFixture token;
        HunterReserveVault vault;
        HunterNFT nft;
        ReserveLifecycleFixture lifecycle;
    }

    /// @dev Fresh matched wiring per hostile token. The token is deployed
    /// first, then the established prediction: lifecycle at nonce n, vault at
    /// n + 1, NFT at n + 2. This test contract is the fresh NFT's minter.
    function _freshSet() internal returns (HostileSet memory s) {
        s.token = new HostileTokenFixture();
        uint64 n = vm.getNonce(address(this));
        address wantNft = vm.computeCreateAddress(address(this), n + 2);
        address wantVault = vm.computeCreateAddress(address(this), n + 1);
        s.lifecycle = new ReserveLifecycleFixture(wantNft, wantVault);
        s.vault = new HunterReserveVault(wantNft, address(s.lifecycle), address(this));
        s.nft = new HunterNFT(address(registry), address(s.lifecycle), 1, ROYALTIES, "");
        s.vault.activateToken(address(s.token)); // this test contract is the launch authority
        assertEq(address(s.vault), wantVault);
        assertEq(address(s.nft), wantNft);
        s.token.setVault(address(s.vault));
        s.token.mint(ALICE, 1_000);
        vm.prank(ALICE);
        s.token.approve(address(s.vault), type(uint256).max);
    }

    /// @dev Mint on the FRESH nft (`_mintTo` targets the base set's nft).
    function _mintHostile(HostileSet memory s, address to) internal returns (uint256) {
        return s.nft.mint(to, bytes32(0), s.nft.mintedEver(), 1, basket);
    }

    function testFalseReturnBlocksDepositAndPayout() public {
        HostileSet memory s = _freshSet();
        uint256 id = _mintHostile(s, ALICE);
        bytes memory failedOp = abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(s.token));

        // Inbound false return: SafeERC20 wraps the false as a failed op.
        s.token.setMode(HostileTokenFixture.Mode.FalseReturn);
        vm.prank(ALICE);
        vm.expectRevert(failedOp);
        s.vault.deposit(id, 100);
        assertEq(s.token.balanceOf(ALICE), 1_000);
        assertEq(s.token.balanceOf(address(s.vault)), 0);
        assertEq(s.vault.reserveOf(id), 0);
        assertEq(s.vault.totalReserved(), 0);
        assertEq(s.vault.historyLength(id), 0);

        // Honest mode: the same deposit lands cleanly.
        s.token.setMode(HostileTokenFixture.Mode.Normal);
        vm.prank(ALICE);
        assertEq(s.vault.deposit(id, 100), 100);
        assertEq(s.vault.reserveOf(id), 100);

        // Outbound false return: payout fails and rolls back the NFT burn.
        s.token.setMode(HostileTokenFixture.Mode.FalseReturn);
        vm.prank(ALICE);
        vm.expectRevert(failedOp);
        s.nft.redeemAndDestroy(id);
        assertEq(s.nft.ownerOf(id), ALICE);
        assertEq(s.vault.reserveOf(id), 100);
        assertEq(s.token.balanceOf(address(s.vault)), 100);
        assertFalse(s.vault.settled(id));

        // Honest retry pays exactly once.
        s.token.setMode(HostileTokenFixture.Mode.Normal);
        vm.prank(ALICE);
        s.nft.redeemAndDestroy(id);
        assertEq(s.token.balanceOf(ALICE), 1_000);
        assertEq(s.vault.reserveOf(id), 0);
        assertEq(s.vault.totalReserved(), 0);
        assertTrue(s.vault.settled(id));
    }

    function testBonusReceiptRejectedAndRolledBack() public {
        HostileSet memory s = _freshSet();
        uint256 id = _mintHostile(s, ALICE);

        // Depositing 100 would credit the vault 101: over-receipt rejected.
        s.token.setMode(HostileTokenFixture.Mode.BonusReceipt);
        uint256 supplyBefore = s.token.totalSupply();
        vm.prank(ALICE);
        vm.expectRevert(HunterReserveVault.UnsupportedTokenReceipt.selector);
        s.vault.deposit(id, 100);
        assertEq(s.token.totalSupply(), supplyBefore); // phantom mint reverted
        assertEq(s.token.balanceOf(ALICE), 1_000);
        assertEq(s.token.balanceOf(address(s.vault)), 0);
        assertEq(s.vault.reserveOf(id), 0);
        assertEq(s.vault.totalReserved(), 0);
        assertEq(s.vault.historyLength(id), 0);

        // Honest retry credits exactly the requested amount, never the bonus.
        s.token.setMode(HostileTokenFixture.Mode.Normal);
        vm.prank(ALICE);
        assertEq(s.vault.deposit(id, 100), 100);
        assertEq(s.vault.reserveOf(id), 100);
        assertEq(s.vault.totalReserved(), 100);
        assertEq(s.token.balanceOf(address(s.vault)), 100);
        assertEq(s.vault.historyLength(id), 1);
    }

    function testSenderFeeTripsExactGrossDebitCheck() public {
        HostileSet memory s = _freshSet();
        uint256 idA = _mintHostile(s, ALICE);
        uint256 idB = _mintHostile(s, ALICE);
        vm.startPrank(ALICE);
        s.vault.deposit(idA, 100);
        s.vault.deposit(idB, 100);
        vm.stopPrank();
        s.token.mint(address(s.vault), 1); // direct donation: uncredited excess
        assertEq(s.token.balanceOf(address(s.vault)), 201);
        assertEq(s.vault.unreservedBalance(), 1);

        // Fee mode: paying out 100 debits the vault 101. The remaining reserve
        // of 100 is still solvent, so the SPECIFIC failure is the exact-gross
        // debit check, not insolvency — even though the excess could cover it.
        s.token.setMode(HostileTokenFixture.Mode.ExtraSenderFee);
        vm.prank(ALICE);
        vm.expectRevert(HunterReserveVault.DebitMismatch.selector);
        s.nft.redeemAndDestroy(idA);
        assertEq(s.nft.ownerOf(idA), ALICE); // whole burn rolled back
        assertEq(s.vault.reserveOf(idA), 100);
        assertEq(s.vault.reserveOf(idB), 100);
        assertEq(s.vault.totalReserved(), 200);
        assertEq(s.token.balanceOf(address(s.vault)), 201);
        assertEq(s.token.balanceOf(ALICE), 800);
        assertFalse(s.vault.settled(idA));

        // Honest mode: both burns pay out, only the donation stays behind.
        s.token.setMode(HostileTokenFixture.Mode.Normal);
        vm.startPrank(ALICE);
        s.nft.redeemAndDestroy(idA);
        s.nft.redeemAndDestroy(idB);
        vm.stopPrank();
        assertEq(s.token.balanceOf(ALICE), 1_000);
        assertEq(s.token.balanceOf(address(s.vault)), 1);
        assertEq(s.vault.totalReserved(), 0);
        assertTrue(s.vault.settled(idA));
        assertTrue(s.vault.settled(idB));
    }
}
