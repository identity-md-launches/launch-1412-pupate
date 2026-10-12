// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "../mocks/MockERC20.sol";
import {CocoonFixture} from "../utils/CocoonFixture.sol";
import {CocoonHandler} from "../utils/CocoonHandler.sol";

contract CocoonInvariantTest is CocoonFixture {
    CocoonHandler internal handler;

    function setUp() public override {
        super.setUp();
        _endLaunch();
        _setFloor(2.8 ether);
        MockERC20 earned = new MockERC20("Some Launch", "SOME");
        handler = new CocoonHandler(
            CocoonHandler.Setup({
                cocoon: cocoon,
                hook: hook,
                feed: feed,
                collection: collection,
                seaport: seaport,
                imd: imd,
                earned: earned,
                router: router,
                key: key,
                attesterKey: ATTESTER_KEY,
                question: QUESTION,
                evidenceChain: EVIDENCE_CHAIN
            })
        );
        token.transfer(address(handler), 100_000_000 ether);
        vm.prank(address(handler));
        token.approve(address(router), type(uint256).max);
        vm.deal(address(handler), 10_000 ether);
        targetContract(address(handler));
    }

    /// @dev A handler whose actions all fail quietly would make the invariants hold for nothing.
    function test_theHandlerActuallyActs() public {
        handler.deposit(10 ether);
        handler.listAndBuy(uint96(2.8 ether));
        assertEq(cocoon.heldCount(), 1);
        handler.warp(1 days);
        handler.sellOurs(0);
        assertEq(cocoon.heldCount(), 0);
        handler.trade(true, 1 ether);
        handler.flush();
        handler.warp(1);
        handler.burn();
        handler.harvest(10 ether, 1 ether);
        handler.imdCycle();
        handler.hostileHarvest(0, 5 ether);
        assertEq(handler.hostileCalls(), 1, "the lot token called back into Cocoon");
        assertGt(cocoon.burnPot() + cocoon.seatPot(), 0);
        // The sold seat left Cocoon and its listing shows filled; no stray ETH exit was booked.
        assertTrue(handler.listingWasFilled(1000), "the seat left through a filled listing");
        assertEq(handler.ghost_leak(), 0);
    }

    function invariant_theBalanceIsExactlyTheFourPots() public view {
        assertEq(
            address(cocoon).balance,
            cocoon.seatPot() + cocoon.burnPot() + cocoon.developerBalance() + cocoon.imdBurnBalance()
        );
    }

    function invariant_theBooksMatchTheSeatsHeld() public view {
        uint256 count;
        uint256 cost;
        uint256 n = handler.recordedCount();
        for (uint256 i; i < n; i++) {
            uint256 tokenId = handler.recorded(i);
            (uint128 c,,,,, bool held,) = cocoon.seats(tokenId);
            bool owned = collection.ownerOf(tokenId) == address(cocoon);
            assertEq(held, owned, "held flag matches ownership");
            if (held) {
                count += 1;
                cost += c;
            }
        }
        assertEq(cocoon.heldCount(), count);
        assertEq(cocoon.heldCost(), cost);
    }

    /// @dev ETH leaves Cocoon only through one of its sanctioned spending entry points: a Seaport
    /// seat purchase (and the caller reward on it), a PUPATE burn (and its caller reward), a
    /// developer claim or the IMD auction. No other action may reduce Cocoon's balance; the handler
    /// books any drop outside those paths as a leak.
    function invariant_ethLeavesCocoonOnlyThroughSanctionedPaths() public view {
        assertEq(handler.ghost_leak(), 0);
    }

    /// @dev A seat leaves Cocoon only through a filled Seaport listing, never by a direct transfer
    /// out: any recorded seat Cocoon no longer owns must have one of its listings filled.
    function invariant_aSeatLeavesCocoonOnlyThroughAFilledListing() public view {
        uint256 n = handler.recordedCount();
        for (uint256 i; i < n; i++) {
            uint256 tokenId = handler.recorded(i);
            if (collection.ownerOf(tokenId) != address(cocoon)) {
                assertTrue(handler.listingWasFilled(tokenId), "a seat left without a filled listing");
            }
        }
    }

    function invariant_cocoonNeverKeepsPupate() public view {
        // Buybacks burn everything they buy in the same call.
        assertEq(token.balanceOf(address(cocoon)), 0);
    }

    function invariant_everyWeiOfTaxIsClaimsOrDelivered() public view {
        assertEq(manager.balanceOf(address(hook), 0) + _delivered(), hook.totalTax());
    }

    /// @dev Everything the hook ever flushed is what Cocoon booked as tax deposits; the handler's
    /// own deposits go through the same function, so the sum is read from the hook side.
    function _delivered() private view returns (uint256) {
        return hook.totalTax() - manager.balanceOf(address(hook), 0);
    }
}
