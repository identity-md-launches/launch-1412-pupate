// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Cocoon} from "../../src/Cocoon.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {CocoonFixture} from "../utils/CocoonFixture.sol";

contract CocoonAuctionsTest is CocoonFixture {
    MockERC20 earned;
    address taker = makeAddr("taker");

    function setUp() public override {
        super.setUp();
        earned = new MockERC20("Some Launch", "SOME");
        earned.mint(address(cocoon), 1000 ether);
        vm.deal(taker, 1000 ether);
    }

    // ------------------------------------------------------------------ harvest

    function test_harvestAuctionFallsAndTheTakerGetsTheLot() public {
        vm.expectEmit(true, false, false, true, address(cocoon));
        emit Cocoon.AuctionStarted(address(earned), 1000 ether, 100 ether);
        cocoon.startAuction(address(earned));
        assertEq(cocoon.auctionPrice(address(earned)), 100 ether);

        vm.warp(block.timestamp + 2 hours);
        assertEq(cocoon.auctionPrice(address(earned)), 50 ether);
        vm.warp(block.timestamp + 2 hours);
        assertEq(cocoon.auctionPrice(address(earned)), 25 ether);

        vm.prank(taker);
        vm.expectRevert(Cocoon.Underpaid.selector);
        cocoon.takeAuction{value: 25 ether - 1}(address(earned));

        uint256 potBefore = cocoon.seatPot();
        vm.expectEmit(true, true, false, true, address(cocoon));
        emit Cocoon.AuctionTaken(address(earned), taker, 1000 ether, 25 ether);
        vm.prank(taker);
        cocoon.takeAuction{value: 30 ether}(address(earned));

        assertEq(earned.balanceOf(taker), 1000 ether);
        assertEq(taker.balance, 1000 ether - 25 ether, "the excess came back");
        assertEq(cocoon.seatPot(), potBefore + 25 ether);
        _assertBalanceIdentity();

        vm.expectRevert(Cocoon.NoAuction.selector);
        cocoon.auctionPrice(address(earned));
        vm.expectRevert(Cocoon.NoAuction.selector);
        cocoon.takeAuction(address(earned));
    }

    /// @dev Nothing prices a lot, so whoever opens an auction could also take it at once. At the
    /// default start that costs 100 ETH, more than any lot the vault can come to hold is worth.
    function test_openingAndTakingAtOnceCostsTheWholeStartPrice() public {
        cocoon.startAuction(address(earned));
        vm.prank(taker);
        vm.expectRevert(Cocoon.Underpaid.selector);
        cocoon.takeAuction{value: 100 ether - 1}(address(earned));

        uint256 potBefore = cocoon.seatPot();
        vm.prank(taker);
        cocoon.takeAuction{value: 100 ether}(address(earned));
        assertEq(cocoon.seatPot(), potBefore + 100 ether);
        _assertBalanceIdentity();
    }

    function test_afterTheCutoffTheLotIsFree() public {
        cocoon.startAuction(address(earned));
        vm.warp(block.timestamp + 48 hours);
        assertEq(cocoon.auctionPrice(address(earned)), 0);
        vm.prank(taker);
        cocoon.takeAuction(address(earned));
        assertEq(earned.balanceOf(taker), 1000 ether);
    }

    function test_whatArrivesDuringAnAuctionGoesToTheNextLot() public {
        cocoon.startAuction(address(earned));
        earned.mint(address(cocoon), 500 ether);
        vm.expectRevert(Cocoon.AuctionRunning.selector);
        cocoon.startAuction(address(earned));

        vm.prank(taker);
        cocoon.takeAuction{value: 100 ether}(address(earned));
        assertEq(earned.balanceOf(taker), 1000 ether);
        assertEq(earned.balanceOf(address(cocoon)), 500 ether);

        cocoon.startAuction(address(earned));
        (uint128 lot,,) = cocoon.auctions(address(earned));
        assertEq(lot, 500 ether);
    }

    function test_whatCannotBeAuctioned() public {
        vm.expectRevert(Cocoon.NotForAuction.selector);
        cocoon.startAuction(address(0));
        vm.expectRevert(Cocoon.NotForAuction.selector);
        cocoon.startAuction(address(token));
        MockERC20 empty = new MockERC20("Empty", "NONE");
        vm.expectRevert(Cocoon.NothingToAuction.selector);
        cocoon.startAuction(address(empty));
    }

    function test_theStartPriceIsFixedWhenTheAuctionStarts() public {
        cocoon.startAuction(address(earned));
        Cocoon.Params memory p = cocoon.getParams();
        p.harvestStartWei = 10 ether;
        vm.prank(owner);
        cocoon.setParams(p);
        assertEq(
            cocoon.auctionPrice(address(earned)),
            100 ether,
            "a parameter change does not move a running auction"
        );
    }

    // ------------------------------------------------------------------ the IMD auction

    function test_imdAuctionBurnsTheDemandedImdAndPaysTheLot() public {
        vm.expectRevert(Cocoon.NothingToAuction.selector);
        cocoon.startImdAuction();

        _deposit(2 ether); // IMD burn balance 0.1 ETH
        vm.expectEmit(false, false, false, true, address(cocoon));
        emit Cocoon.ImdAuctionStarted(0.1 ether, 2000 ether);
        cocoon.startImdAuction();
        assertEq(cocoon.imdDemand(), 2000 ether);
        vm.expectRevert(Cocoon.AuctionRunning.selector);
        cocoon.startImdAuction();

        vm.warp(block.timestamp + 2 hours);
        assertEq(cocoon.imdDemand(), 1000 ether);

        imd.mint(taker, 5000 ether);
        vm.prank(taker);
        imd.approve(address(cocoon), type(uint256).max);

        vm.expectEmit(true, false, false, true, address(cocoon));
        emit Cocoon.ImdBurned(taker, 1000 ether, 0.1 ether);
        vm.prank(taker);
        cocoon.takeImdAuction();

        assertEq(imd.balanceOf(cocoon.DEAD()), 1000 ether);
        assertEq(imd.balanceOf(taker), 4000 ether);
        assertEq(taker.balance, 1000.1 ether);
        assertEq(cocoon.imdBurnBalance(), 0);
        _assertBalanceIdentity();

        vm.expectRevert(Cocoon.NoAuction.selector);
        cocoon.takeImdAuction();
    }

    function test_imdAuctionTakerWithoutImdFails() public {
        _deposit(2 ether);
        cocoon.startImdAuction();
        vm.prank(taker);
        vm.expectRevert(Cocoon.TransferFailed.selector);
        cocoon.takeImdAuction();
    }

    function test_imdThatArrivesDuringTheAuctionWaitsForTheNext() public {
        _deposit(2 ether);
        cocoon.startImdAuction();
        _deposit(2 ether);
        assertEq(cocoon.imdBurnBalance(), 0.2 ether);
        imd.mint(taker, 5000 ether);
        vm.prank(taker);
        imd.approve(address(cocoon), type(uint256).max);
        vm.prank(taker);
        cocoon.takeImdAuction();
        assertEq(taker.balance, 1000.1 ether);
        assertEq(cocoon.imdBurnBalance(), 0.1 ether);
        _assertBalanceIdentity();
    }
}
