// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ItemType} from "seaport-types/src/lib/ConsiderationEnums.sol";
import {
    AdvancedOrder,
    ConsiderationItem,
    CriteriaResolver,
    Order,
    OrderParameters
} from "seaport-types/src/lib/ConsiderationStructs.sol";
import {Cocoon} from "../../src/Cocoon.sol";
import {SeatListing} from "../../src/cocoon/SeatListing.sol";
import {WorkerAuthorization} from "../../src/cocoon/WorkerAuthorization.sol";
import {MockERC721} from "../mocks/MockERC721.sol";
import {CocoonFixture} from "../utils/CocoonFixture.sol";

/// @dev A seller that pushes ETH back into Cocoon while being paid, the way a payout recipient or
/// a zone could during a purchase.
contract Bouncer {
    Cocoon immutable cocoon;
    uint8 public mode; // 1: call depositTax, 2: plain send

    constructor(Cocoon c) {
        cocoon = c;
    }

    function setMode(uint8 m) external {
        mode = m;
    }

    function approve(MockERC721 collection, address operator) external {
        collection.setApprovalForAll(operator, true);
    }

    receive() external payable {
        if (mode == 1) {
            cocoon.depositTax{value: msg.value}();
        } else if (mode == 2) {
            (bool ok,) = address(cocoon).call{value: msg.value}("");
            require(ok, "bounce refused");
        }
    }
}

/// @dev Pins the fixes from the independent review of Cocoon (docs/REVIEW.md, Plan 3).
contract CocoonReviewTest is CocoonFixture {
    uint256 constant SEAT = 7;
    CriteriaResolver[] internal noResolvers;
    address buyer = makeAddr("buyer");

    function setUp() public override {
        super.setUp();
        collection.mint(seller, SEAT);
        vm.prank(seller);
        collection.setApprovalForAll(address(seaport), true);
        _setFloor(2.8 ether);
        _deposit(10 ether); // seat pot 5.95 ETH
        vm.deal(buyer, 20 ether);
    }

    // ------------------------------------------------------------------ helpers

    function _params(address offerer, uint256 tokenId, uint256 price)
        internal
        view
        returns (OrderParameters memory)
    {
        return SeatListing.parameters(
            offerer,
            address(collection),
            tokenId,
            SeatListing.Terms(price, 10_000, 10_000, 7 days, uint40(block.timestamp), uint16(block.number)),
            0
        );
    }

    function _validate(OrderParameters memory p) internal {
        Order[] memory orders = new Order[](1);
        orders[0] = Order(p, "");
        vm.prank(p.offerer);
        seaport.validate(orders);
    }

    function _item(uint256 amount, address to) internal pure returns (ConsiderationItem memory) {
        return ConsiderationItem(ItemType.NATIVE, address(0), 0, amount, amount, payable(to));
    }

    function _buy(OrderParameters memory p) internal {
        vm.prank(keeper);
        cocoon.buySeat(AdvancedOrder(p, 1, 1, "", ""), noResolvers);
    }

    function _expectBad(OrderParameters memory p, bytes4 err) internal {
        vm.prank(keeper);
        vm.expectRevert(err);
        cocoon.buySeat(AdvancedOrder(p, 1, 1, "", ""), noResolvers);
    }

    function _ourOrders(uint256 tokenId) internal view returns (Order[] memory) {
        (uint128 cost, uint40 boughtAt, uint16 startX, uint16 endX, uint32 decay,, uint16 round) =
            cocoon.seats(tokenId);
        return SeatListing.orders(
            address(cocoon),
            address(collection),
            tokenId,
            SeatListing.Terms(cost, startX, endX, decay, boughtAt, round)
        );
    }

    // ------------------------------------------------------------------ finding 1: payments back to Cocoon

    function test_rejectsOrdersThatPayCocoon() public {
        OrderParameters memory p = _params(seller, SEAT, 2.94 ether);
        ConsiderationItem[] memory c = new ConsiderationItem[](2);
        c[0] = _item(2.94 ether - 1, address(cocoon));
        c[1] = _item(1, seller);
        p.consideration = c;
        p.totalOriginalConsiderationItems = 2;
        _validate(p);
        _expectBad(p, Cocoon.BadOrder.selector);
    }

    function test_rejectsZeroAmountItems() public {
        OrderParameters memory p = _params(seller, SEAT, 2.8 ether);
        p.consideration[0].startAmount = 0;
        _validate(p);
        _expectBad(p, Cocoon.BadOrder.selector);
    }

    function test_ethFromAnyoneButSeaportDuringAPurchaseRevertsThePurchase() public {
        Bouncer bouncer = new Bouncer(cocoon);
        bouncer.approve(collection, address(seaport));
        collection.mint(address(bouncer), SEAT + 1);
        vm.deal(address(bouncer), 5 ether);
        OrderParameters memory p = _params(address(bouncer), SEAT + 1, 2.8 ether);
        _validate(p);

        bouncer.setMode(1); // a recipient that calls depositTax mid-purchase
        vm.prank(keeper);
        vm.expectRevert();
        cocoon.buySeat(AdvancedOrder(p, 1, 1, "", ""), noResolvers);

        bouncer.setMode(2); // a recipient that sends the ETH straight back
        vm.prank(keeper);
        vm.expectRevert();
        cocoon.buySeat(AdvancedOrder(p, 1, 1, "", ""), noResolvers);

        assertEq(collection.ownerOf(SEAT + 1), address(bouncer));
        _assertBalanceIdentity();

        bouncer.setMode(0); // a plain recipient works
        _buy(p);
        assertEq(collection.ownerOf(SEAT + 1), address(cocoon));
    }

    // ------------------------------------------------------------------ finding 2: tips

    function test_rejectsConsiderationThatIsNotTheOriginal() public {
        OrderParameters memory p = _params(seller, SEAT, 2 ether);
        ConsiderationItem[] memory c = new ConsiderationItem[](2);
        c[0] = _item(2 ether, seller);
        c[1] = _item(0.94 ether, keeper); // a tip the fulfiller appended
        p.consideration = c; // totalOriginalConsiderationItems stays 1
        _expectBad(p, Cocoon.BadOrder.selector);

        p = _params(seller, SEAT, 2 ether);
        p.totalOriginalConsiderationItems = 2; // or an order that claims more items than it carries
        _expectBad(p, Cocoon.BadOrder.selector);
    }

    function test_aLegitimateSplitPaymentIsAccepted() public {
        OrderParameters memory p = _params(seller, SEAT, 2.8 ether);
        ConsiderationItem[] memory c = new ConsiderationItem[](2);
        c[0] = _item(2.73 ether, seller);
        c[1] = _item(0.07 ether, makeAddr("marketplace fee")); // 2.5%, as a marketplace adds
        p.consideration = c;
        p.totalOriginalConsiderationItems = 2;
        _validate(p);
        _buy(p);
        (uint128 cost,,,,,,) = cocoon.seats(SEAT);
        assertEq(cost, 2.8 ether);
        assertEq(makeAddr("marketplace fee").balance, 0.07 ether);
    }

    // ------------------------------------------------------------------ findings 3 and 7: accounting

    function test_costIsWhatSeaportPaidOutAndTheRewardIsOnIt() public {
        OrderParameters memory p = SeatListing.parameters(
            seller,
            address(collection),
            SEAT,
            SeatListing.Terms(2.4 ether, 12_000, 10_000, 7 days, uint40(block.timestamp), 1),
            0
        );
        _validate(p);
        vm.warp(block.timestamp + 3.5 days);
        _setFloor(2.8 ether);
        uint256 current = seaport.currentAmount(2.88 ether, 2.4 ether, p.startTime, p.endTime, true);
        uint256 potBefore = cocoon.seatPot();
        uint256 burnBefore = cocoon.burnPot();

        _buy(p);

        uint256 reward = current * 50 / 10_000;
        (uint128 cost,,,,,,) = cocoon.seats(SEAT);
        assertEq(cost, current);
        assertEq(keeper.balance, 100 ether + reward);
        assertEq(cocoon.seatPot(), potBefore - current - reward);
        assertEq(cocoon.burnPot(), burnBefore);
        _assertBalanceIdentity();
    }

    function test_skimBooksForcedEthAsProceeds() public {
        vm.expectRevert(Cocoon.NothingToSkim.selector);
        cocoon.skim();

        vm.deal(address(cocoon), address(cocoon).balance + 1 ether);
        uint256 burnBefore = cocoon.burnPot();
        cocoon.skim();
        assertEq(cocoon.burnPot(), burnBefore + 1 ether);
        _assertBalanceIdentity();
    }

    // ------------------------------------------------------------------ finding 4: what can be auctioned

    function test_auctionsRejectTheCollectionAndNeedTheWire() public {
        vm.expectRevert(Cocoon.NotForAuction.selector);
        cocoon.startAuction(address(collection));

        Cocoon unwired = new Cocoon(
            owner, developer, operator, cocoon.COLLECTION(), cocoon.SEAPORT(), manager, feed, cocoon.IMD()
        );
        vm.expectRevert(Cocoon.NotWired.selector);
        unwired.startAuction(address(imd));
    }

    // ------------------------------------------------------------------ finding 5: pairing approvals

    function test_pairingApprovalDoesNotReviveWhenTheSeatComesBack() public {
        _validate(_params(seller, SEAT, 2.8 ether));
        _buy(_params(seller, SEAT, 2.8 ether));
        WorkerAuthorization.Auth memory a;
        a.deviceKey = keccak256("device");
        a.wallet = address(cocoon);
        a.tokenId = SEAT;
        a.nonce = keccak256("nonce");
        a.expiresAt = uint64(block.timestamp + 30 days);
        a.relayOrigin = "https://api.imd.fun";
        vm.prank(operator);
        bytes32 digest = cocoon.authorizeWorker(a);
        assertEq(cocoon.isValidSignature(digest, ""), bytes4(0x1626ba7e));

        // Sold through the falling order, settled, then sent straight back and adopted again.
        Order[] memory ours = _ourOrders(SEAT);
        vm.warp(block.timestamp + 1 days);
        uint256 price = seaport.currentAmount(
            4.2 ether, 3.08 ether, ours[0].parameters.startTime, ours[0].parameters.endTime, true
        );
        vm.prank(buyer);
        seaport.fulfillAdvancedOrder{value: price}(
            AdvancedOrder(ours[0].parameters, 1, 1, "", ""), noResolvers, bytes32(0), buyer
        );
        cocoon.settleSeat(SEAT);
        assertEq(cocoon.isValidSignature(digest, ""), bytes4(0xffffffff));

        vm.prank(buyer);
        collection.transferFrom(buyer, address(cocoon), SEAT);
        assertEq(cocoon.isValidSignature(digest, ""), bytes4(0xffffffff), "held again, but off the books");
        _setFloor(2.8 ether);
        cocoon.adopt(SEAT);
        assertEq(cocoon.isValidSignature(digest, ""), bytes4(0xffffffff), "a new round needs a new approval");
    }

    // ------------------------------------------------------------------ operator cannot move value

    function test_theOperatorCannotMoveValueSeatsOrParameters() public {
        _validate(_params(seller, SEAT, 2.8 ether));
        _buy(_params(seller, SEAT, 2.8 ether));
        uint256 potBefore = cocoon.seatPot();
        uint256 balBefore = address(cocoon).balance;
        imd.mint(address(cocoon), 1000 ether); // some tokens the operator must not be able to move
        uint256 imdBefore = imd.balanceOf(address(cocoon));

        Cocoon.Params memory p = cocoon.getParams();
        vm.startPrank(operator);

        // The operator holds no owner power: no parameter, role or wiring change.
        vm.expectRevert(Cocoon.NotOwner.selector);
        cocoon.setParams(p);
        vm.expectRevert(Cocoon.NotOwner.selector);
        cocoon.setOperator(operator);
        vm.expectRevert(Cocoon.NotOwner.selector);
        cocoon.transferOwnership(operator);
        vm.expectRevert(Cocoon.NotOwner.selector);
        cocoon.wire(key);

        // The only thing the operator may do is bless a pairing, which moves nothing.
        WorkerAuthorization.Auth memory a;
        a.deviceKey = keccak256("device");
        a.wallet = address(cocoon);
        a.tokenId = SEAT;
        a.nonce = keccak256("nonce");
        a.expiresAt = uint64(block.timestamp + 1 hours);
        a.relayOrigin = "https://api.imd.fun";
        bytes32 digest = cocoon.authorizeWorker(a);
        vm.stopPrank();

        // The seat, the ETH and the tokens are exactly as before.
        assertEq(collection.ownerOf(SEAT), address(cocoon), "the seat did not move");
        assertEq(cocoon.seatPot(), potBefore, "the seat pot is untouched");
        assertEq(address(cocoon).balance, balBefore, "no ETH left");
        assertEq(imd.balanceOf(address(cocoon)), imdBefore, "no tokens left");

        // The approval validates only its own pairing digest, never a would-be Seaport approval.
        assertEq(cocoon.isValidSignature(digest, ""), bytes4(0x1626ba7e));
        assertEq(cocoon.isValidSignature(keccak256("a seaport order hash"), ""), bytes4(0xffffffff));
    }

    // ------------------------------------------------------------------ finding 6: a seat sent back before settle

    function test_aSeatSentBackBeforeSettleCanBeSettledAndAdopted() public {
        _validate(_params(seller, SEAT, 2.8 ether));
        _buy(_params(seller, SEAT, 2.8 ether));
        Order[] memory first = _ourOrders(SEAT);

        vm.warp(block.timestamp + 1 days);
        uint256 price = seaport.currentAmount(
            4.2 ether, 3.08 ether, first[0].parameters.startTime, first[0].parameters.endTime, true
        );
        vm.prank(buyer);
        seaport.fulfillAdvancedOrder{value: price}(
            AdvancedOrder(first[0].parameters, 1, 1, "", ""), noResolvers, bytes32(0), buyer
        );
        vm.prank(buyer);
        collection.transferFrom(buyer, address(cocoon), SEAT);
        assertEq(collection.ownerOf(SEAT), address(cocoon));

        cocoon.settleSeat(SEAT);
        assertEq(cocoon.heldCount(), 0);
        assertTrue(seaport.cancelled(seaport.hashOf(first[1].parameters)), "the old tail is dead");

        _setFloor(2.8 ether);
        cocoon.adopt(SEAT);
        (uint128 cost,,,,, bool held, uint16 round) = cocoon.seats(SEAT);
        assertEq(cost, 2.8 ether);
        assertTrue(held);
        assertEq(round, 1);
        assertEq(cocoon.heldCount(), 1);
    }

    // ------------------------------------------------------------------ from the audit of launch #1400: a cost the books cannot hold

    /// @dev A seat's cost is kept in 128 bits and the total in 256. A floor that does not fit was cut
    /// in the one and not in the other, and settling the seat left the difference in the total for good.
    function test_aFloorTooLargeForTheBooksCannotBeAdopted() public {
        vm.prank(owner);
        feed.setQuestion(QUESTION); // forgets the stored floor, so the next report is not rate-limited
        _setFloor(uint256(type(uint128).max) + 1);
        collection.mint(address(cocoon), 8);

        vm.expectRevert(Cocoon.OutOfBounds.selector);
        cocoon.adopt(8);
        assertEq(cocoon.heldCost(), 0);
        assertEq(cocoon.heldCount(), 0);
    }

    function test_theLargestCostTheBooksHoldIsRecordedWhole() public {
        vm.prank(owner);
        feed.setQuestion(QUESTION);
        _setFloor(type(uint128).max);
        _giveSeat(8);

        (uint128 cost,,,,,,) = cocoon.seats(8);
        assertEq(cost, type(uint128).max);
        assertEq(cocoon.heldCost(), type(uint128).max, "the total moves by exactly the seat's cost");
    }
}
