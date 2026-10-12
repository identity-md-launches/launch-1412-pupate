// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SeaportInterface} from "seaport-types/src/interfaces/SeaportInterface.sol";
import {AdvancedOrder, CriteriaResolver} from "seaport-types/src/lib/ConsiderationStructs.sol";
import {Cocoon} from "../../src/Cocoon.sol";
import {IERC20Minimal} from "../../src/interfaces/IERC20Minimal.sol";
import {IERC721Minimal} from "../../src/interfaces/IERC721Minimal.sol";
import {ReenteringToken} from "../mocks/ReenteringToken.sol";
import {CocoonFixture} from "../utils/CocoonFixture.sol";

/// @dev What a hostile token can reach while Cocoon is calling it. Found by the audit of launch
/// #1400: `takeAuction` called the lot token while the taker's excess ETH was still in the balance,
/// and `skim`, which was not under the reentrancy lock, booked that excess into the burn pot before
/// it was refunded. The pots then claimed ETH that had left, and later burns spent the other pots.
contract CocoonReentrancyTest is CocoonFixture {
    ReenteringToken bad;
    address attacker = makeAddr("attacker");
    bytes reentrancy = abi.encodeWithSelector(Cocoon.Reentrancy.selector);

    function setUp() public override {
        super.setUp();
        _endLaunch();
        bad = new ReenteringToken();
        vm.deal(attacker, 1000 ether);
        // Real income: 10 ETH of tax in the four pots (no floor yet, so the split is the neutral one).
        _deposit(10 ether);
        _assertBalanceIdentity();
    }

    /// @dev Anyone can put a token up for auction, and after the cutoff the lot costs nothing.
    function _openAFreeAuction() internal {
        cocoon.startAuction(address(bad));
        vm.warp(block.timestamp + 48 hours);
        assertEq(cocoon.auctionPrice(address(bad)), 0);
    }

    // ------------------------------------------------------------------ the finding

    function test_skimCannotBookATakersExcessFromInsideTheLotTransfer() public {
        bad.arm(address(cocoon), abi.encodeCall(Cocoon.skim, ()), 0);
        _openAFreeAuction();
        (, uint256 burnPotBefore,,) = _pots();

        // The whole 50 ETH is excess: the lot is free.
        vm.prank(attacker);
        cocoon.takeAuction{value: 50 ether}(address(bad));

        assertTrue(bad.called(), "the lot token was called");
        assertFalse(bad.succeeded(), "skim ran inside the auction");
        assertEq(bad.refusal(), reentrancy);
        assertEq(attacker.balance, 1000 ether, "the excess came back");
        assertEq(cocoon.burnPot(), burnPotBefore, "the burn pot was credited with ETH that left again");
        _assertBalanceIdentity();
    }

    function test_theExcessIsRefundedBeforeTheLotTokenIsCalled() public {
        bad.arm(address(0), "", 0);
        cocoon.startAuction(address(bad));
        vm.warp(block.timestamp + 2 hours);
        uint256 price = cocoon.auctionPrice(address(bad));
        assertGt(price, 0);
        uint256 held = address(cocoon).balance;

        vm.prank(attacker);
        cocoon.takeAuction{value: price + 50 ether}(address(bad));

        assertEq(bad.callerBalanceSeen(), held + price, "the excess was still in Cocoon during the transfer");
        assertEq(attacker.balance, 1000 ether - price);
        _assertBalanceIdentity();
    }

    function test_taxCannotBeDepositedFromInsideTheLotTransfer() public {
        vm.deal(address(bad), 1 ether);
        bad.arm(address(cocoon), abi.encodeCall(Cocoon.depositTax, ()), 1 ether);
        _openAFreeAuction();
        (uint256 seat, uint256 burn, uint256 dev, uint256 imdBurn) = _pots();

        vm.prank(attacker);
        cocoon.takeAuction{value: 50 ether}(address(bad));

        assertFalse(bad.succeeded(), "depositTax ran inside the auction");
        assertEq(bad.refusal(), reentrancy);
        assertEq(address(bad).balance, 1 ether, "the refused deposit stayed with its sender");
        (uint256 seatAfter, uint256 burnAfter, uint256 devAfter, uint256 imdAfter) = _pots();
        assertEq(seatAfter + burnAfter + devAfter + imdAfter, seat + burn + dev + imdBurn);
        _assertBalanceIdentity();
    }

    function test_plainEthSentFromInsideTheLotTransferIsBookedOnce() public {
        vm.deal(address(bad), 1 ether);
        bad.arm(address(cocoon), "", 1 ether);
        _openAFreeAuction();
        (, uint256 burnPotBefore,,) = _pots();

        vm.prank(attacker);
        cocoon.takeAuction{value: 50 ether}(address(bad));

        assertTrue(bad.succeeded(), "a gift is taken at any time outside a purchase");
        assertEq(cocoon.burnPot(), burnPotBefore + 1 ether);
        assertEq(attacker.balance, 1000 ether);
        _assertBalanceIdentity();
    }

    /// @dev Every entry point that moves ETH or reads the balance against the pots is under the one
    /// lock, so none of them can run while another is half done.
    function test_noGuardedEntryPointRunsFromInsideTheLotTransfer() public {
        AdvancedOrder memory order;
        CriteriaResolver[] memory none;
        bytes[8] memory calls = [
            abi.encodeCall(Cocoon.skim, ()),
            abi.encodeCall(Cocoon.depositTax, ()),
            abi.encodeCall(Cocoon.burn, ()),
            abi.encodeCall(Cocoon.claimDeveloper, ()),
            abi.encodeCall(Cocoon.takeAuction, (address(bad))),
            abi.encodeCall(Cocoon.takeImdAuction, ()),
            abi.encodeCall(Cocoon.adopt, (1)),
            abi.encodeCall(Cocoon.buySeat, (order, none))
        ];
        for (uint256 i; i < calls.length; i++) {
            bad.arm(address(cocoon), calls[i], 0);
            _openAFreeAuction();
            vm.prank(attacker);
            cocoon.takeAuction{value: 1 ether}(address(bad));
            assertTrue(bad.called());
            assertFalse(bad.succeeded(), "a guarded entry point ran inside the auction");
            assertEq(bad.refusal(), reentrancy);
            _assertBalanceIdentity();
        }
        // settleSeat is under the same lock; it has its own test because its argument must name a seat.
        bad.arm(address(cocoon), abi.encodeCall(Cocoon.settleSeat, (1)), 0);
        _openAFreeAuction();
        vm.prank(attacker);
        cocoon.takeAuction(address(bad));
        assertEq(bad.refusal(), reentrancy);
    }

    // ------------------------------------------------------------------ the IMD auction

    /// @dev The same window from the other auction: the ETH lot has left the IMD pot and has not yet
    /// been paid out while the IMD token is called. The real IMD token does not call back; a vault
    /// built on a token that does must still keep its books.
    function test_skimCannotBookTheImdLotFromInsideTheImdTransfer() public {
        Cocoon other = new Cocoon(
            owner,
            developer,
            operator,
            IERC721Minimal(address(collection)),
            SeaportInterface(address(seaport)),
            manager,
            feed,
            IERC20Minimal(address(bad))
        );
        other.depositTax{value: 10 ether}();
        other.startImdAuction();
        assertEq(other.imdBurnBalance(), 0.5 ether);
        uint256 burnPotBefore = other.burnPot();
        bad.arm(address(other), abi.encodeCall(Cocoon.skim, ()), 0);

        vm.prank(attacker);
        other.takeImdAuction();

        assertTrue(bad.called(), "the IMD token was called");
        assertFalse(bad.succeeded(), "skim ran inside the IMD auction");
        assertEq(bad.refusal(), reentrancy);
        assertEq(attacker.balance, 1000.5 ether, "the taker has the lot");
        assertEq(other.burnPot(), burnPotBefore);
        assertEq(
            address(other).balance,
            other.seatPot() + other.burnPot() + other.developerBalance() + other.imdBurnBalance(),
            "balance identity"
        );
    }

    // ------------------------------------------------------------------ what skim is for

    function test_skimStillBooksEthThatWasForcedIn() public {
        vm.deal(address(cocoon), address(cocoon).balance + 3 ether);
        (, uint256 burnPotBefore,,) = _pots();

        cocoon.skim();

        assertEq(cocoon.burnPot(), burnPotBefore + 3 ether);
        _assertBalanceIdentity();
        vm.expectRevert(Cocoon.NothingToSkim.selector);
        cocoon.skim();
    }
}
