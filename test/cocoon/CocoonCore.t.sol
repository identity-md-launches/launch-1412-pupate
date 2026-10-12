// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {SeaportInterface} from "seaport-types/src/interfaces/SeaportInterface.sol";
import {Cocoon} from "../../src/Cocoon.sol";
import {FloorFeed} from "../../src/FloorFeed.sol";
import {IERC20Minimal} from "../../src/interfaces/IERC20Minimal.sol";
import {IERC721Minimal} from "../../src/interfaces/IERC721Minimal.sol";
import {CocoonFixture} from "../utils/CocoonFixture.sol";

contract CocoonCoreTest is CocoonFixture {
    // ------------------------------------------------------------------ construction

    function test_constructorRejectsZeroAddresses() public {
        IERC721Minimal c = IERC721Minimal(address(collection));
        SeaportInterface s = SeaportInterface(address(seaport));
        IERC20Minimal i = IERC20Minimal(address(imd));
        vm.expectRevert(Cocoon.ZeroAddress.selector);
        new Cocoon(address(0), developer, operator, c, s, manager, feed, i);
        vm.expectRevert(Cocoon.ZeroAddress.selector);
        new Cocoon(owner, address(0), operator, c, s, manager, feed, i);
        vm.expectRevert(Cocoon.ZeroAddress.selector);
        new Cocoon(owner, developer, operator, IERC721Minimal(address(0)), s, manager, feed, i);
        vm.expectRevert(Cocoon.ZeroAddress.selector);
        new Cocoon(owner, developer, operator, c, SeaportInterface(address(0)), manager, feed, i);
        vm.expectRevert(Cocoon.ZeroAddress.selector);
        new Cocoon(owner, developer, operator, c, s, IPoolManager(address(0)), feed, i);
        vm.expectRevert(Cocoon.ZeroAddress.selector);
        new Cocoon(owner, developer, operator, c, s, manager, FloorFeed(address(0)), i);
        vm.expectRevert(Cocoon.ZeroAddress.selector);
        new Cocoon(owner, developer, operator, c, s, manager, feed, IERC20Minimal(address(0)));
    }

    function test_defaults() public view {
        Cocoon.Params memory p = cocoon.getParams();
        assertEq(p.accumulateSeatBps, 7000);
        assertEq(p.listStartX, 15_000);
        assertEq(p.listEndX, 11_000);
        assertEq(p.listDecay, 14 days);
        assertEq(p.toleranceBps, 500);
        assertEq(p.callerRewardBps, 50);
        assertEq(p.burnImpactBps, 500);
        assertEq(p.burnSpacing, 5);
        assertEq(p.harvestStartWei, 100 ether);
        assertEq(p.imdStartPerEth, 20_000 ether);
        assertEq(cocoon.owner(), owner);
        assertEq(cocoon.developer(), developer);
        assertEq(cocoon.operator(), operator);
        assertTrue(
            collection.isApprovedForAll(address(cocoon), address(seaport)), "Seaport may move our seats"
        );
        assertTrue(cocoon.wired());
    }

    // ------------------------------------------------------------------ the split

    function test_depositSplitsEvenlyWhileTheFloorIsUnknown() public {
        (Cocoon.Mode m, uint256 seatBps) = cocoon.mode();
        assertEq(uint8(m), uint8(Cocoon.Mode.NEUTRAL));
        assertEq(seatBps, 5000);

        vm.expectEmit(false, false, false, true, address(cocoon));
        emit Cocoon.TaxDeposited(
            1 ether, 0.425 ether, 0.425 ether, 0.1 ether, 0.05 ether, Cocoon.Mode.NEUTRAL
        );
        _deposit(1 ether);

        (uint256 seat, uint256 burn, uint256 dev, uint256 imdBurn) = _pots();
        assertEq(seat, 0.425 ether);
        assertEq(burn, 0.425 ether);
        assertEq(dev, 0.1 ether);
        assertEq(imdBurn, 0.05 ether);
        _assertBalanceIdentity();
    }

    function test_depositAccumulatesWhileNoSeatIsHeld() public {
        _setFloor(2.74 ether);
        (Cocoon.Mode m, uint256 seatBps) = cocoon.mode();
        assertEq(uint8(m), uint8(Cocoon.Mode.ACCUMULATE));
        assertEq(seatBps, 7000);

        _deposit(1 ether);
        (uint256 seat, uint256 burn,,) = _pots();
        assertEq(seat, 0.595 ether);
        assertEq(burn, 0.255 ether);
    }

    function test_modeFollowsTheFloorAgainstTheAveragePurchasePrice() public {
        _setFloor(2.6 ether);
        _giveSeat(1);
        // A 15% rise needs about four hours under the feed's rise limit.
        vm.warp(block.timestamp + 4 hours);
        _setFloor(3 ether);
        _giveSeat(2);
        assertEq(cocoon.heldCount(), 2);
        assertEq(cocoon.heldCost(), 5.6 ether, "adopted at the floor of the moment");

        // Average is 2.8 ETH. At or below it: accumulate. Above it: burn.
        _setFloor(2.8 ether);
        (Cocoon.Mode m,) = cocoon.mode();
        assertEq(uint8(m), uint8(Cocoon.Mode.ACCUMULATE));

        _setFloor(2.8 ether + 1);
        uint256 seatBps;
        (m, seatBps) = cocoon.mode();
        assertEq(uint8(m), uint8(Cocoon.Mode.BURN));
        assertEq(seatBps, 3000);

        _deposit(1 ether);
        (uint256 seat, uint256 burn,,) = _pots();
        assertEq(seat, 0.255 ether);
        assertEq(burn, 0.595 ether);
    }

    function test_aStaleFloorMeansNeutralEvenWithSeats() public {
        _setFloor(2 ether);
        _giveSeat(1);
        _letTheFloorGoStale();
        (Cocoon.Mode m, uint256 seatBps) = cocoon.mode();
        assertEq(uint8(m), uint8(Cocoon.Mode.NEUTRAL));
        assertEq(seatBps, 5000);
    }

    function testFuzz_noWeiIsLostInTheSplit(uint96 amount) public {
        vm.deal(address(this), uint256(amount) + 1 ether);
        _deposit(amount);
        (uint256 seat, uint256 burn, uint256 dev, uint256 imdBurn) = _pots();
        assertEq(seat + burn + dev + imdBurn, amount);
        assertEq(dev, uint256(amount) * 1000 / 10_000);
        assertEq(imdBurn, uint256(amount) * 500 / 10_000);
        _assertBalanceIdentity();
    }

    function test_plainEthIsSaleProceedsAndGoesToTheBurnPot() public {
        vm.expectEmit(true, false, false, true, address(cocoon));
        emit Cocoon.ProceedsReceived(address(this), 3 ether);
        (bool ok,) = address(cocoon).call{value: 3 ether}("");
        assertTrue(ok);
        assertEq(cocoon.burnPot(), 3 ether);
        _assertBalanceIdentity();
    }

    // ------------------------------------------------------------------ developer

    function test_developerClaimsOnlyTheDeveloperBalance() public {
        _deposit(10 ether);
        vm.prank(makeAddr("anyone"));
        cocoon.claimDeveloper();
        assertEq(developer.balance, 1 ether);
        assertEq(cocoon.developerBalance(), 0);
        assertEq(address(cocoon).balance, 9 ether);
        _assertBalanceIdentity();

        cocoon.claimDeveloper();
        assertEq(developer.balance, 1 ether, "a second claim pays nothing");
    }

    function test_onlyTheDeveloperRotatesTheDeveloper() public {
        address next = makeAddr("next developer");
        vm.expectRevert(Cocoon.NotDeveloper.selector);
        cocoon.setDeveloper(next);
        vm.prank(developer);
        vm.expectRevert(Cocoon.ZeroAddress.selector);
        cocoon.setDeveloper(address(0));
        vm.prank(developer);
        cocoon.setDeveloper(next);
        assertEq(cocoon.developer(), next);

        _deposit(1 ether);
        cocoon.claimDeveloper();
        assertEq(next.balance, 0.1 ether);
    }

    // ------------------------------------------------------------------ owner

    function test_setParamsChecksEveryBound() public {
        Cocoon.Params memory p = cocoon.getParams();
        vm.startPrank(owner);

        p.accumulateSeatBps = 2999;
        _expectOutOfBounds(p);
        p.accumulateSeatBps = 7001;
        _expectOutOfBounds(p);
        p = cocoon.getParams();

        p.listStartX = 10_999;
        _expectOutOfBounds(p);
        p.listStartX = 30_001;
        _expectOutOfBounds(p);
        p = cocoon.getParams();

        p.listEndX = 9_999;
        _expectOutOfBounds(p);
        p.listEndX = 15_001;
        _expectOutOfBounds(p);
        p.listEndX = 15_000;
        p.listStartX = 14_999;
        _expectOutOfBounds(p);
        p = cocoon.getParams();

        p.listDecay = 1 days - 1;
        _expectOutOfBounds(p);
        p.listDecay = 60 days + 1;
        _expectOutOfBounds(p);
        p = cocoon.getParams();

        p.toleranceBps = 1001;
        _expectOutOfBounds(p);
        p = cocoon.getParams();

        p.callerRewardBps = 101;
        _expectOutOfBounds(p);
        p = cocoon.getParams();

        p.burnImpactBps = 99;
        _expectOutOfBounds(p);
        p.burnImpactBps = 1001;
        _expectOutOfBounds(p);
        p = cocoon.getParams();

        p.burnSpacing = 0;
        _expectOutOfBounds(p);
        p.burnSpacing = 301;
        _expectOutOfBounds(p);
        p = cocoon.getParams();

        p.harvestStartWei = 0.01 ether - 1;
        _expectOutOfBounds(p);
        p.harvestStartWei = 100 ether + 1;
        _expectOutOfBounds(p);
        p = cocoon.getParams();

        p.imdStartPerEth = 100 ether - 1;
        _expectOutOfBounds(p);
        p.imdStartPerEth = 10_000_000 ether + 1;
        _expectOutOfBounds(p);
        p = cocoon.getParams();

        p.accumulateSeatBps = 6000;
        p.toleranceBps = 0;
        p.callerRewardBps = 0;
        cocoon.setParams(p);
        vm.stopPrank();
        assertEq(cocoon.getParams().accumulateSeatBps, 6000);
        assertEq(cocoon.getParams().callerRewardBps, 0);
    }

    function _expectOutOfBounds(Cocoon.Params memory p) internal {
        vm.expectRevert(Cocoon.OutOfBounds.selector);
        cocoon.setParams(p);
    }

    function test_onlyTheOwnerAdministers() public {
        Cocoon.Params memory p = cocoon.getParams();
        vm.expectRevert(Cocoon.NotOwner.selector);
        cocoon.setParams(p);
        vm.expectRevert(Cocoon.NotOwner.selector);
        cocoon.setOperator(address(1));
        vm.expectRevert(Cocoon.NotOwner.selector);
        cocoon.transferOwnership(address(1));
        vm.expectRevert(Cocoon.NotOwner.selector);
        cocoon.wire(key);
    }

    function test_ownershipAndOperatorCanBeHandedOver() public {
        address next = makeAddr("next");
        vm.startPrank(owner);
        vm.expectRevert(Cocoon.ZeroAddress.selector);
        cocoon.setOperator(address(0));
        cocoon.setOperator(next);
        vm.expectRevert(Cocoon.ZeroAddress.selector);
        cocoon.transferOwnership(address(0));
        cocoon.transferOwnership(next);
        vm.stopPrank();
        assertEq(cocoon.operator(), next);
        assertEq(cocoon.owner(), next);
        vm.prank(owner);
        vm.expectRevert(Cocoon.NotOwner.selector);
        cocoon.setOperator(owner);
    }

    function test_wireHappensOnceAndOnlyToTheHooksLaunchPool() public {
        vm.startPrank(owner);
        vm.expectRevert(Cocoon.AlreadyWired.selector);
        cocoon.wire(key);
        vm.stopPrank();

        Cocoon fresh = new Cocoon(
            owner,
            developer,
            operator,
            IERC721Minimal(address(collection)),
            SeaportInterface(address(seaport)),
            manager,
            feed,
            IERC20Minimal(address(imd))
        );
        PoolKey memory other = PoolKey(
            CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(token)), 500, 10, IHooks(address(hook))
        );
        vm.startPrank(owner);
        vm.expectRevert(Cocoon.WrongPool.selector);
        fresh.wire(other);
        // The right pool, but a hook whose sink is another Cocoon.
        vm.expectRevert(Cocoon.WrongPool.selector);
        fresh.wire(key);
        vm.stopPrank();
        assertFalse(fresh.wired());
    }

    function test_burnAndAdoptNeedTheWire() public {
        Cocoon fresh = new Cocoon(
            owner,
            developer,
            operator,
            IERC721Minimal(address(collection)),
            SeaportInterface(address(seaport)),
            manager,
            feed,
            IERC20Minimal(address(imd))
        );
        vm.expectRevert(Cocoon.NotWired.selector);
        fresh.burn();
    }

    // ------------------------------------------------------------------ identity

    function testFuzz_theBalanceIdentityHoldsThroughDepositsClaimsAndProceeds(
        uint96[6] memory amounts,
        uint8 pattern
    ) public {
        vm.deal(address(this), 1_000_000 ether);
        _setFloor(2 ether);
        for (uint256 i; i < amounts.length; i++) {
            uint256 a = uint256(amounts[i]) % 50 ether;
            if ((pattern >> i) & 1 == 1) {
                _deposit(a);
            } else {
                (bool ok,) = address(cocoon).call{value: a}("");
                assertTrue(ok);
            }
            if (i == 3) cocoon.claimDeveloper();
            _assertBalanceIdentity();
        }
    }
}
