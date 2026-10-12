// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {StdUtils} from "forge-std/StdUtils.sol";
import {Vm} from "forge-std/Vm.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {
    AdvancedOrder,
    CriteriaResolver,
    Order,
    OrderParameters
} from "seaport-types/src/lib/ConsiderationStructs.sol";
import {Cocoon} from "../../src/Cocoon.sol";
import {FloorFeed} from "../../src/FloorFeed.sol";
import {PupateHook} from "../../src/PupateHook.sol";
import {SeatListing} from "../../src/cocoon/SeatListing.sol";
import {OracleAttestation} from "../../src/oracle/OracleAttestation.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockERC721} from "../mocks/MockERC721.sol";
import {MockSeaport} from "../mocks/MockSeaport.sol";
import {ReenteringToken} from "../mocks/ReenteringToken.sol";
import {PoolRouter} from "./PoolRouter.sol";

/// @dev Invariant handler. Plays every role around Cocoon: trader, keeper, seller, buyer of our
/// listings, auction taker, oracle, and the author of a lot token that calls back into Cocoon while
/// it is being paid out. Nothing here reverts; failed actions are swallowed, and the invariants read
/// the resulting state.
contract CocoonHandler is StdUtils {
    struct Setup {
        Cocoon cocoon;
        PupateHook hook;
        FloorFeed feed;
        MockERC721 collection;
        MockSeaport seaport;
        MockERC20 imd;
        MockERC20 earned;
        PoolRouter router;
        PoolKey key;
        uint256 attesterKey;
        bytes32 question;
        uint256 evidenceChain;
    }

    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    Setup private s;
    CriteriaResolver[] private noResolvers;
    /// @dev Anyone can put any contract up as a harvest lot; this one calls back from its transfer.
    ReenteringToken public hostile;
    uint256 public hostileCalls;

    uint256[] public recorded;
    mapping(uint256 => bool) private isRecorded;
    uint256 private nextSeat = 1000;
    uint64 private lastIssuedAt;

    /// @dev Any wei Cocoon's balance loses during an action that is not one of its sanctioned
    /// ETH-spending entry points (a seat purchase, a burn, a developer claim or the IMD auction).
    /// Must stay zero: ETH must never leave Cocoon through any other path.
    uint256 public ghost_leak;

    constructor(Setup memory setup) {
        s = setup;
        setup.collection.setApprovalForAll(address(setup.seaport), true);
        hostile = new ReenteringToken();
    }

    receive() external payable {}

    /// @dev Marks an action that must never reduce Cocoon's ETH balance. Books any drop as a leak.
    modifier noEthExit() {
        uint256 before = address(s.cocoon).balance;
        _;
        uint256 remaining = address(s.cocoon).balance;
        if (remaining < before) ghost_leak += before - remaining;
    }

    function recordedCount() external view returns (uint256) {
        return recorded.length;
    }

    // ------------------------------------------------------------------ actions

    function deposit(uint96 amount) external noEthExit {
        s.cocoon.depositTax{value: bound(amount, 0, 20 ether)}();
    }

    function donate(uint96 amount) external noEthExit {
        (bool ok,) = address(s.cocoon).call{value: bound(amount, 0, 5 ether)}("");
        ok;
    }

    function trade(bool buy, uint96 amount) external noEthExit {
        int256 specified =
            buy ? -int256(bound(amount, 1e9, 20 ether)) : -int256(bound(amount, 1 ether, 2_000_000 ether));
        uint160 limit = buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        try s.router.swap{value: buy ? address(this).balance / 2 : 0}(
            s.key, SwapParams(buy, specified, limit)
        ) {}
            catch {}
    }

    function flush() external noEthExit {
        try s.hook.flush() {} catch {}
    }

    function warp(uint32 by) external noEthExit {
        vm.warp(block.timestamp + bound(by, 1, 2 days));
        vm.roll(block.number + 1 + bound(by, 0, 100));
    }

    function reportFloor(uint96 floorWei) external noEthExit {
        uint256 floor = bound(floorWei, 0.5 ether, 10 ether);
        if (block.timestamp <= lastIssuedAt) vm.warp(lastIssuedAt + 1);
        OracleAttestation.Attestation memory a;
        a.requestId = bytes32(block.timestamp);
        a.chainId = s.evidenceChain;
        a.questionHash = s.question;
        a.answerType = OracleAttestation.ANSWER_TYPE_UINT256;
        a.answer = abi.encode(floor);
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 4;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 24 hours);
        bytes32 sep = OracleAttestation.domainSeparator(block.chainid, address(s.feed));
        (uint8 v, bytes32 r, bytes32 sig) = vm.sign(s.attesterKey, OracleAttestation.digest(sep, a));
        try s.feed.report(a, abi.encodePacked(r, sig, v)) {
            lastIssuedAt = a.issuedAt;
        } catch {}
    }

    /// @dev A seller lists a fresh seat near the floor and the handler, as keeper, tries to buy it.
    function listAndBuy(uint96 priceSeed) external {
        (uint256 floor, bool fresh) = s.feed.latest();
        if (!fresh) return;
        uint256 tokenId = nextSeat++;
        s.collection.mint(address(this), tokenId);
        Order[] memory orders = new Order[](1);
        orders[0] = Order(
            SeatListing.parameters(
                address(this),
                address(s.collection),
                tokenId,
                SeatListing.Terms(
                    bound(priceSeed, floor / 2, floor * 12 / 10),
                    10_000,
                    10_000,
                    7 days,
                    uint40(block.timestamp),
                    0
                ),
                0
            ),
            ""
        );
        s.seaport.validate(orders);
        try s.cocoon.buySeat(AdvancedOrder(orders[0].parameters, 1, 1, "", ""), noResolvers) {
            if (!isRecorded[tokenId]) {
                isRecorded[tokenId] = true;
                recorded.push(tokenId);
            }
        } catch {}
    }

    /// @dev A buyer takes one of our listings at its current price, and the handler settles it.
    function sellOurs(uint256 pick) external noEthExit {
        if (recorded.length == 0) return;
        uint256 tokenId = recorded[bound(pick, 0, recorded.length - 1)];
        (OrderParameters memory p, bool live) = _ourLiveOrder(tokenId);
        if (!live) return;
        uint256 price = s.seaport
            .currentAmount(
                p.consideration[0].startAmount, p.consideration[0].endAmount, p.startTime, p.endTime, true
            );
        if (address(this).balance < price) return;
        try s.seaport.fulfillAdvancedOrder{value: price}(
            AdvancedOrder(p, 1, 1, "", ""), noResolvers, bytes32(0), address(this)
        ) {
            s.cocoon.settleSeat(tokenId);
        } catch {}
    }

    function burn() external {
        try s.cocoon.burn() {} catch {}
    }

    function claimDeveloper() external {
        try s.cocoon.claimDeveloper() {} catch {}
    }

    function harvest(uint96 mintAmount, uint96 payment) external noEthExit {
        s.earned.mint(address(s.cocoon), bound(mintAmount, 1, 1000 ether));
        try s.cocoon.startAuction(address(s.earned)) {} catch {}
        uint256 price;
        try s.cocoon.auctionPrice(address(s.earned)) returns (uint256 p) {
            price = p;
        } catch {
            return;
        }
        uint256 pay = bound(payment, price, price + 0.1 ether);
        if (address(this).balance < pay) return;
        try s.cocoon.takeAuction{value: pay}(address(s.earned)) {} catch {}
    }

    /// @dev A lot nobody vetted. From inside the transfer that pays the lot out, the token makes one
    /// call back into Cocoon, chosen by `pick`, while the taker has sent `excess` on top of the price.
    /// Whatever the token tries, the action as a whole must not take ETH out of Cocoon, and the pots
    /// must still add up to the balance afterwards.
    function hostileHarvest(uint8 pick, uint96 excess) external noEthExit {
        bytes memory data;
        uint256 value;
        uint256 which = pick % 7;
        if (which == 0) {
            data = abi.encodeCall(Cocoon.skim, ());
        } else if (which == 1) {
            data = abi.encodeCall(Cocoon.depositTax, ());
            value = 0.1 ether;
        } else if (which == 2) {
            value = 0.1 ether; // a plain payment, which Cocoon books as proceeds
        } else if (which == 3) {
            data = abi.encodeCall(Cocoon.burn, ());
        } else if (which == 4) {
            data = abi.encodeCall(Cocoon.claimDeveloper, ());
        } else if (which == 5) {
            data = abi.encodeCall(Cocoon.takeImdAuction, ());
        } else {
            data = abi.encodeCall(Cocoon.startImdAuction, ());
        }
        if (value != 0) {
            (bool funded,) = address(hostile).call{value: value}("");
            if (!funded) return;
        }
        hostile.arm(address(s.cocoon), data, value);
        try s.cocoon.startAuction(address(hostile)) {} catch {}
        uint256 price;
        try s.cocoon.auctionPrice(address(hostile)) returns (uint256 p) {
            price = p;
        } catch {
            return;
        }
        uint256 pay = price + bound(excess, 0, 50 ether);
        if (address(this).balance < pay) return;
        try s.cocoon.takeAuction{value: pay}(address(hostile)) {
            if (hostile.called()) hostileCalls += 1;
        } catch {}
    }

    function imdCycle() external {
        try s.cocoon.startImdAuction() {} catch {}
        uint256 demand;
        try s.cocoon.imdDemand() returns (uint256 d) {
            demand = d;
        } catch {
            return;
        }
        s.imd.mint(address(this), demand);
        s.imd.approve(address(s.cocoon), demand);
        try s.cocoon.takeImdAuction() {} catch {}
    }

    // ------------------------------------------------------------------ helpers

    /// @dev Whether either of Cocoon's two listings for `tokenId` has been filled on Seaport. A seat
    /// may leave Cocoon only this way, so a seat Cocoon no longer holds must show a filled listing.
    function listingWasFilled(uint256 tokenId) external view returns (bool) {
        (uint128 cost, uint40 boughtAt, uint16 startX, uint16 endX, uint32 decay,, uint16 round) =
            s.cocoon.seats(tokenId);
        Order[] memory orders = SeatListing.orders(
            address(s.cocoon),
            address(s.collection),
            tokenId,
            SeatListing.Terms(cost, startX, endX, decay, boughtAt, round)
        );
        return s.seaport.filled(s.seaport.hashOf(orders[0].parameters))
            || s.seaport.filled(s.seaport.hashOf(orders[1].parameters));
    }

    /// @dev The order of ours that is live right now for `tokenId`: the falling one during the
    /// decay, the flat tail after it. `live` is false when the seat is not held or no window is open.
    function _ourLiveOrder(uint256 tokenId) private view returns (OrderParameters memory p, bool live) {
        (uint128 cost, uint40 boughtAt, uint16 startX, uint16 endX, uint32 decay, bool held, uint16 round) =
            s.cocoon.seats(tokenId);
        if (!held) return (p, false);
        uint256 index = block.timestamp < uint256(boughtAt) + decay ? 0 : 1;
        p = SeatListing.parameters(
            address(s.cocoon),
            address(s.collection),
            tokenId,
            SeatListing.Terms(cost, startX, endX, decay, boughtAt, round),
            index
        );
        live = block.timestamp >= p.startTime && block.timestamp < p.endTime;
    }
}
