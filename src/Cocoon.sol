// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {SeaportInterface} from "seaport-types/src/interfaces/SeaportInterface.sol";
import {ItemType, OrderType} from "seaport-types/src/lib/ConsiderationEnums.sol";
import {
    AdvancedOrder,
    ConsiderationItem,
    CriteriaResolver,
    OfferItem,
    OrderComponents,
    OrderParameters
} from "seaport-types/src/lib/ConsiderationStructs.sol";
import {Decay} from "./cocoon/Decay.sol";
import {SeatListing} from "./cocoon/SeatListing.sol";
import {WorkerAuthorization} from "./cocoon/WorkerAuthorization.sol";
import {FloorFeed} from "./FloorFeed.sol";
import {IERC20Minimal} from "./interfaces/IERC20Minimal.sol";
import {IERC721Minimal} from "./interfaces/IERC721Minimal.sol";
import {ILaunchHook} from "./interfaces/ILaunchHook.sol";
import {PupateToken} from "./PupateToken.sol";

/// @notice The Pupate vault. Receives the tax, buys Identity MD seats on Seaport at or under the
/// reference price, lists each seat at a falling price, burns PUPATE with what the seats sell for,
/// auctions what the seats earn, and lets an operator pair the seats to IMD workers.
/// @dev ETH leaves this contract only to: Seaport (a seat purchase), the PoolManager (a buyback),
/// a caller reward of at most 1%, the developer, an auction taker's own excess, and the taker of
/// the IMD auction (the ETH lot). Every function that moves value is callable by anyone and
/// bounded by parameters the owner can change only within hard-coded limits. Between calls the
/// balance always equals the four pots added together; `skim` books ETH that was forced in. Every
/// entry point that moves ETH or measures the balance against the pots holds one lock, so none of
/// them runs while another has ETH in flight.
contract Cocoon is IUnlockCallback {
    using StateLibrary for IPoolManager;

    // ------------------------------------------------------------------ errors and events

    error ZeroAddress();
    error NotOwner();
    error NotDeveloper();
    error NotOperator();
    error OnlyPoolManager();
    error UnexpectedCallback();
    error Reentrancy();
    error UnexpectedPayment();
    error OutOfBounds();
    error AlreadyWired();
    error NotWired();
    error WrongPool();
    error BadOrder();
    error FloorNotFresh();
    error PriceAboveFloor();
    error PotTooSmall();
    error PurchaseFailed();
    error UnexpectedToken();
    error NotHeld();
    error StillHeld();
    error AlreadyHeld();
    error TooSoon();
    error NothingToBurn();
    error NothingBought();
    error NotForAuction();
    error AuctionRunning();
    error NoAuction();
    error NothingToAuction();
    error Underpaid();
    error NothingToSkim();
    error WrongWallet();
    error Expired();
    error TransferFailed();

    event TaxDeposited(
        uint256 amount,
        uint256 toSeatPot,
        uint256 toBurnPot,
        uint256 toDeveloper,
        uint256 toImdBurn,
        Mode mode
    );
    event ProceedsReceived(address indexed from, uint256 amount);
    event SeatBought(uint256 indexed tokenId, uint256 cost, address indexed caller, uint256 reward);
    event SeatAdopted(uint256 indexed tokenId, uint256 cost);
    event SeatListed(
        uint256 indexed tokenId, uint256 startPrice, uint256 endPrice, uint256 startTime, uint256 decayEnd
    );
    event SeatSold(uint256 indexed tokenId, uint256 cost);
    event Burned(uint256 ethSpent, uint256 pupateBurned, address indexed caller, uint256 reward);
    event AuctionStarted(address indexed token, uint256 lot, uint256 startPrice);
    event AuctionTaken(address indexed token, address indexed taker, uint256 lot, uint256 price);
    event ImdAuctionStarted(uint256 lotWei, uint256 startDemand);
    event ImdBurned(address indexed taker, uint256 imdBurned, uint256 ethPaid);
    event DeveloperPaid(uint256 amount);
    event DeveloperSet(address developer);
    event OperatorSet(address operator);
    event OwnershipTransferred(address indexed from, address indexed to);
    event ParamsSet(Params params);
    event Wired(PoolId indexed poolId);
    event WorkerAuthorized(uint256 indexed tokenId, bytes32 indexed digest);
    event WorkerRevoked(bytes32 indexed digest);

    // ------------------------------------------------------------------ types

    enum Mode {
        NEUTRAL,
        ACCUMULATE,
        BURN
    }

    /// @notice Everything the owner can tune, each within the bounds in `_checkParams`.
    struct Params {
        uint16 accumulateSeatBps; // seat-pot share of the strategy share while accumulating
        uint16 listStartX; // listing starts at cost * listStartX / 1e4
        uint16 listEndX; // and falls to cost * listEndX / 1e4
        uint32 listDecay; // over this long
        uint16 toleranceBps; // buy up to floor * (1e4 + toleranceBps) / 1e4
        uint16 callerRewardBps; // paid to whoever runs a purchase or a burn, on the ETH spent
        uint16 burnImpactBps; // one burn may move the pool price by at most this
        uint16 burnSpacing; // blocks between burns
        uint128 harvestStartWei; // where a harvest auction starts
        uint128 imdStartPerEth; // IMD demanded per ETH at the start of the IMD auction
    }

    struct Seat {
        uint128 cost;
        uint40 boughtAt;
        uint16 startX;
        uint16 endX;
        uint32 decay;
        bool held;
        uint16 round; // purchases of this seat before this one
    }

    struct Auction {
        uint128 lot;
        uint128 start;
        uint40 startedAt;
    }

    struct WorkerApproval {
        uint232 tokenId;
        uint16 round;
        bool approved;
    }

    // ------------------------------------------------------------------ constants

    uint256 public constant BPS = 10_000;
    uint256 public constant DEVELOPER_BPS = 1000;
    uint256 public constant IMD_BURN_BPS = 500;
    uint256 public constant NEUTRAL_SEAT_BPS = 5000;
    address public constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes4 private constant ERC1271_VALID = 0x1626ba7e;
    bytes4 private constant ERC1271_INVALID = 0xffffffff;
    bytes4 private constant ERC721_RECEIVED = 0x150b7a02;
    /// @dev Transient slots: 1 the reentrancy lock, 2 set while a Seaport purchase is in flight,
    /// 3 the ETH Seaport returned during that purchase.
    uint256 private constant LOCK_SLOT = 1;
    uint256 private constant PURCHASE_SLOT = 2;
    uint256 private constant REFUND_SLOT = 3;

    IERC721Minimal public immutable COLLECTION;
    SeaportInterface public immutable SEAPORT;
    IPoolManager public immutable POOL_MANAGER;
    FloorFeed public immutable FLOOR;
    IERC20Minimal public immutable IMD;

    // ------------------------------------------------------------------ storage

    address public owner;
    address public developer;
    address public operator;
    Params internal params;

    uint256 public seatPot;
    uint256 public burnPot;
    uint256 public developerBalance;
    uint256 public imdBurnBalance;

    mapping(uint256 tokenId => Seat) public seats;
    uint256 public heldCount;
    uint256 public heldCost;

    PoolKey public launchKey;
    bool public wired;
    uint256 public lastBurnBlock;

    mapping(address token => Auction) public auctions;
    Auction public imdAuction;

    mapping(bytes32 digest => WorkerApproval) private _workerApprovals;

    // ------------------------------------------------------------------ modifiers

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev One lock for every entry point that moves ETH or measures the balance against the pots.
    /// While it is held, ETH may be in flight (the price of a purchase, a taker's excess, a lot on
    /// its way out), and no other such entry point may run until the books are whole again.
    modifier nonReentrant() {
        if (_tload(LOCK_SLOT) != 0) revert Reentrancy();
        _tstore(LOCK_SLOT, 1);
        _;
        _tstore(LOCK_SLOT, 0);
    }

    constructor(
        address owner_,
        address developer_,
        address operator_,
        IERC721Minimal collection,
        SeaportInterface seaport,
        IPoolManager poolManager,
        FloorFeed floor,
        IERC20Minimal imd
    ) {
        if (
            owner_ == address(0) || developer_ == address(0) || operator_ == address(0)
                || address(collection) == address(0) || address(seaport) == address(0)
                || address(poolManager) == address(0) || address(floor) == address(0)
                || address(imd) == address(0)
        ) revert ZeroAddress();
        owner = owner_;
        developer = developer_;
        operator = operator_;
        COLLECTION = collection;
        SEAPORT = seaport;
        POOL_MANAGER = poolManager;
        FLOOR = floor;
        IMD = imd;
        params = Params({
            accumulateSeatBps: 7000,
            listStartX: 15_000,
            listEndX: 11_000,
            listDecay: 14 days,
            toleranceBps: 500,
            callerRewardBps: 50,
            burnImpactBps: 500,
            burnSpacing: 5,
            // Nothing prices a harvest lot, so its auction starts at the highest price the bounds
            // allow and the curve finds the lot's worth on the way down.
            harvestStartWei: 100 ether,
            imdStartPerEth: 20_000 ether
        });
        lastBurnBlock = block.number;
        collection.setApprovalForAll(address(seaport), true);
        emit OwnershipTransferred(address(0), owner_);
        emit DeveloperSet(developer_);
        emit OperatorSet(operator_);
    }

    /// @dev Outside a purchase, plain ETH is a filled listing or a gift: it buys and burns PUPATE.
    /// Inside one, only Seaport may send ETH, and what it sends is the refund of the price.
    receive() external payable {
        if (_tload(PURCHASE_SLOT) != 0) {
            if (msg.sender != address(SEAPORT)) revert UnexpectedPayment();
            _tstore(REFUND_SLOT, _tload(REFUND_SLOT) + msg.value);
            return;
        }
        burnPot += msg.value;
        emit ProceedsReceived(msg.sender, msg.value);
    }

    // ------------------------------------------------------------------ tax

    /// @notice Accept tax: 10% to the developer, 5% to the IMD burn, 85% to the strategy, split
    /// between the seat pot and the burn pot by the current mode.
    function depositTax() external payable nonReentrant {
        uint256 amount = msg.value;
        uint256 dev = amount * DEVELOPER_BPS / BPS;
        uint256 toImd = amount * IMD_BURN_BPS / BPS;
        uint256 strategy = amount - dev - toImd;
        (Mode m, uint256 seatBps) = mode();
        uint256 toSeat = strategy * seatBps / BPS;
        uint256 toBurn = strategy - toSeat;
        developerBalance += dev;
        imdBurnBalance += toImd;
        seatPot += toSeat;
        burnPot += toBurn;
        emit TaxDeposited(amount, toSeat, toBurn, dev, toImd, m);
    }

    /// @notice Book ETH that arrived without a call (forced in) as sale proceeds, so the balance
    /// identity holds again. Anyone may call.
    /// @dev Under the lock: inside another guarded call the balance can run ahead of the pots by ETH
    /// that is only passing through, and booking it would credit the burn pot with ETH that leaves.
    function skim() external nonReentrant {
        uint256 surplus = address(this).balance - (seatPot + burnPot + developerBalance + imdBurnBalance);
        if (surplus == 0) revert NothingToSkim();
        burnPot += surplus;
        emit ProceedsReceived(address(0), surplus);
    }

    /// @notice The mode and the seat pot's share of the strategy share, in basis points.
    function mode() public view returns (Mode, uint256 seatBps) {
        (uint256 floor, bool fresh) = FLOOR.latest();
        if (!fresh) return (Mode.NEUTRAL, NEUTRAL_SEAT_BPS);
        uint256 n = heldCount;
        // Accumulate while no seat is held, or while the floor is at or under the average cost.
        if (n == 0 || floor * n <= heldCost) return (Mode.ACCUMULATE, params.accumulateSeatBps);
        return (Mode.BURN, BPS - params.accumulateSeatBps);
    }

    function getParams() external view returns (Params memory) {
        return params;
    }

    // ------------------------------------------------------------------ buying and listing

    /// @notice Fulfil a Seaport listing of one seat for ETH at or under the reference price plus
    /// tolerance, list the seat, and pay the caller the reward on what was spent.
    function buySeat(AdvancedOrder calldata order, CriteriaResolver[] calldata resolvers)
        external
        nonReentrant
    {
        (uint256 tokenId, uint256 price) = _checkOrder(order);
        if (seatPot < price + price * params.callerRewardBps / BPS) revert PotTooSmall();

        // Cocoon sends the highest price the order can ask. Seaport returns the part the order did
        // not need, and `receive` counts only Seaport's ETH during the purchase, so the cost is
        // exactly what Seaport paid out to others.
        _tstore(PURCHASE_SLOT, 1);
        _tstore(REFUND_SLOT, 0);
        bool fulfilled =
            SEAPORT.fulfillAdvancedOrder{value: price}(order, resolvers, bytes32(0), address(this));
        uint256 refund = _tload(REFUND_SLOT);
        _tstore(PURCHASE_SLOT, 0);
        _tstore(REFUND_SLOT, 0);
        if (!fulfilled || refund >= price || !_holds(tokenId)) revert PurchaseFailed();

        uint256 spent = price - refund;
        uint256 reward = spent * params.callerRewardBps / BPS;
        seatPot -= spent + reward;
        _record(tokenId, spent);
        emit SeatBought(tokenId, spent, msg.sender, reward);
        if (reward != 0) _pay(msg.sender, reward);
    }

    /// @notice Take in a seat that was sent to Cocoon directly, at the current floor, and list it.
    function adopt(uint256 tokenId) external nonReentrant {
        if (seats[tokenId].held) revert AlreadyHeld();
        if (!_holds(tokenId)) revert NotHeld();
        (uint256 floor, bool fresh) = FLOOR.latest();
        if (!fresh) revert FloorNotFresh();
        _record(tokenId, floor);
        emit SeatAdopted(tokenId, floor);
    }

    /// @notice Once a listing has filled, take the seat off the books and cancel its other order.
    /// Works whether the seat is gone or was sent straight back; `adopt` can then take it in again.
    function settleSeat(uint256 tokenId) external nonReentrant {
        Seat memory s = seats[tokenId];
        if (!s.held) revert NotHeld();
        OrderComponents[] memory orders = SeatListing.components(
            address(this), address(COLLECTION), tokenId, _terms(s), SEAPORT.getCounter(address(this))
        );
        if (_holds(tokenId) && !_anyFilled(orders)) revert StillHeld();
        seats[tokenId].held = false;
        heldCount -= 1;
        heldCost -= s.cost;
        SEAPORT.cancel(orders);
        emit SeatSold(tokenId, s.cost);
    }

    /// @dev Seats arrive only from the collection and only while a purchase is in flight.
    function onERC721Received(address, address, uint256, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(COLLECTION) || _tload(PURCHASE_SLOT) == 0) revert UnexpectedToken();
        return ERC721_RECEIVED;
    }

    /// @dev The order must be one seat of the collection for native ETH, in full, paid to others:
    /// every consideration item is ETH to someone other than Cocoon with a non-zero amount, and the
    /// array is exactly the original one, so a fulfiller cannot append tips paid from the price.
    function _checkOrder(AdvancedOrder calldata order) private view returns (uint256 tokenId, uint256 price) {
        OrderParameters calldata p = order.parameters;
        if (p.offer.length != 1 || p.consideration.length == 0) revert BadOrder();
        if (p.consideration.length != p.totalOriginalConsiderationItems) revert BadOrder();
        if (order.numerator != 1 || order.denominator != 1) revert BadOrder();
        if (p.orderType != OrderType.FULL_OPEN && p.orderType != OrderType.FULL_RESTRICTED) {
            revert BadOrder();
        }
        OfferItem calldata item = p.offer[0];
        if (
            item.itemType != ItemType.ERC721 || item.token != address(COLLECTION) || item.startAmount != 1
                || item.endAmount != 1
        ) revert BadOrder();
        tokenId = item.identifierOrCriteria;
        if (seats[tokenId].held) revert AlreadyHeld();
        for (uint256 i; i < p.consideration.length; i++) {
            ConsiderationItem calldata c = p.consideration[i];
            if (c.itemType != ItemType.NATIVE || c.recipient == address(this)) revert BadOrder();
            if (c.startAmount == 0 || c.endAmount == 0) revert BadOrder();
            price += c.startAmount > c.endAmount ? c.startAmount : c.endAmount;
        }
        (uint256 floor, bool fresh) = FLOOR.latest();
        if (!fresh) revert FloorNotFresh();
        if (price > floor * (BPS + params.toleranceBps) / BPS) revert PriceAboveFloor();
    }

    function _record(uint256 tokenId, uint256 cost) private {
        // The seat's cost is kept in 128 bits and the total in 256: a cost that does not fit would be
        // cut in one and not in the other, and the difference would stay in `heldCost` for good.
        if (cost > type(uint128).max) revert OutOfBounds();
        Params storage p = params;
        Seat storage previous = seats[tokenId];
        uint16 round = previous.boughtAt == 0 ? 0 : previous.round + 1;
        Seat memory s = Seat({
            cost: uint128(cost),
            boughtAt: uint40(block.timestamp),
            startX: p.listStartX,
            endX: p.listEndX,
            decay: p.listDecay,
            held: true,
            round: round
        });
        seats[tokenId] = s;
        heldCount += 1;
        heldCost += cost;
        SeatListing.Terms memory t = _terms(s);
        SEAPORT.validate(SeatListing.orders(address(this), address(COLLECTION), tokenId, t));
        emit SeatListed(
            tokenId,
            SeatListing.startPrice(t),
            SeatListing.endPrice(t),
            block.timestamp,
            block.timestamp + p.listDecay
        );
    }

    function _terms(Seat memory s) private pure returns (SeatListing.Terms memory) {
        return SeatListing.Terms(s.cost, s.startX, s.endX, s.decay, s.boughtAt, s.round);
    }

    function _holds(uint256 tokenId) private view returns (bool) {
        try COLLECTION.ownerOf(tokenId) returns (address holder) {
            return holder == address(this);
        } catch {
            return false;
        }
    }

    function _anyFilled(OrderComponents[] memory orders) private view returns (bool) {
        for (uint256 i; i < orders.length; i++) {
            (,, uint256 totalFilled,) = SEAPORT.getOrderStatus(SEAPORT.getOrderHash(orders[i]));
            if (totalFilled != 0) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------ burning

    /// @notice Spend the burn pot on PUPATE in the launch pool, within the price-impact limit, and
    /// burn what it buys. Pays the caller the reward on the ETH spent.
    function burn() external nonReentrant {
        if (!wired) revert NotWired();
        Params storage p = params;
        if (block.number < lastBurnBlock + p.burnSpacing) revert TooSoon();
        uint256 budget = burnPot;
        // Hold back the reward so the pot covers it however much of the budget the pool takes.
        uint256 swapBudget = budget * (BPS - p.callerRewardBps) / BPS;
        if (swapBudget == 0) revert NothingToBurn();

        (uint160 sqrtPrice,,,) = POOL_MANAGER.getSlot0(launchKey.toId());
        uint256 limit = uint256(sqrtPrice) * _sqrt((BPS - p.burnImpactBps) * BPS) / BPS;
        if (limit <= TickMath.MIN_SQRT_PRICE) limit = TickMath.MIN_SQRT_PRICE + 1;

        bytes memory result = POOL_MANAGER.unlock(abi.encode(swapBudget, uint160(limit)));
        (uint256 spent, uint256 bought) = abi.decode(result, (uint256, uint256));
        if (bought == 0) revert NothingBought();

        uint256 reward = spent * p.callerRewardBps / BPS;
        burnPot -= spent + reward;
        lastBurnBlock = block.number;
        PupateToken(Currency.unwrap(launchKey.currency1)).burn(bought);
        emit Burned(spent, bought, msg.sender, reward);
        if (reward != 0) _pay(msg.sender, reward);
    }

    /// @notice Burn any PUPATE Cocoon holds. Harvest lots never include PUPATE.
    function burnPupate() external {
        if (!wired) revert NotWired();
        PupateToken pupate = PupateToken(Currency.unwrap(launchKey.currency1));
        uint256 amount = pupate.balanceOf(address(this));
        if (amount == 0) revert NothingToBurn();
        pupate.burn(amount);
        emit Burned(0, amount, msg.sender, 0);
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Reached only from `burn`. Buys with exact ETH in up to the price limit, pays the pool
    /// exactly what it took, and takes the PUPATE.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert OnlyPoolManager();
        if (_tload(LOCK_SLOT) == 0) revert UnexpectedCallback();
        (uint256 budget, uint160 limit) = abi.decode(data, (uint256, uint160));
        BalanceDelta delta = POOL_MANAGER.swap(launchKey, SwapParams(true, -int256(budget), limit), "");
        uint256 spent = uint256(uint128(-delta.amount0()));
        uint256 bought = uint256(uint128(delta.amount1()));
        if (spent != 0) POOL_MANAGER.settle{value: spent}();
        if (bought != 0) POOL_MANAGER.take(launchKey.currency1, address(this), bought);
        return abi.encode(spent, bought);
    }

    // ------------------------------------------------------------------ harvest auctions

    /// @notice Put Cocoon's whole balance of `token` up for a falling-price auction. Not PUPATE,
    /// not the collection.
    function startAuction(address token) external {
        if (!wired) revert NotWired();
        if (
            token == address(0) || token == address(COLLECTION)
                || token == Currency.unwrap(launchKey.currency1)
        ) {
            revert NotForAuction();
        }
        if (auctions[token].lot != 0) revert AuctionRunning();
        uint256 balance = IERC20Minimal(token).balanceOf(address(this));
        if (balance == 0) revert NothingToAuction();
        uint128 lot = balance > type(uint128).max ? type(uint128).max : uint128(balance);
        auctions[token] = Auction(lot, params.harvestStartWei, uint40(block.timestamp));
        emit AuctionStarted(token, lot, params.harvestStartWei);
    }

    function auctionPrice(address token) public view returns (uint256) {
        Auction memory a = auctions[token];
        if (a.lot == 0) revert NoAuction();
        return Decay.price(a.start, block.timestamp - a.startedAt);
    }

    /// @notice Take the lot at the current price. The ETH goes to the seat pot; the excess comes back.
    function takeAuction(address token) external payable nonReentrant {
        Auction memory a = auctions[token];
        if (a.lot == 0) revert NoAuction();
        uint256 price = Decay.price(a.start, block.timestamp - a.startedAt);
        if (msg.value < price) revert Underpaid();
        delete auctions[token];
        seatPot += price;
        emit AuctionTaken(token, msg.sender, a.lot, price);
        // The excess goes back before the lot token is called. Any contract can be put up as a lot,
        // so from here on the balance and the pots agree, whatever that token does with the call.
        if (msg.value > price) _pay(msg.sender, msg.value - price);
        _safeTransfer(token, msg.sender, a.lot);
    }

    // ------------------------------------------------------------------ the IMD auction

    /// @notice Offer the IMD-burn ETH for IMD: the IMD demanded falls over time, the first taker
    /// gets the ETH, and the IMD they deliver goes to the dead address.
    function startImdAuction() external {
        if (imdAuction.lot != 0) revert AuctionRunning();
        uint256 lot = imdBurnBalance;
        if (lot == 0) revert NothingToAuction();
        uint256 demand = uint256(params.imdStartPerEth) * lot / 1 ether;
        imdAuction = Auction(uint128(lot), uint128(demand), uint40(block.timestamp));
        emit ImdAuctionStarted(lot, demand);
    }

    function imdDemand() public view returns (uint256) {
        Auction memory a = imdAuction;
        if (a.lot == 0) revert NoAuction();
        return Decay.price(a.start, block.timestamp - a.startedAt);
    }

    function takeImdAuction() external nonReentrant {
        Auction memory a = imdAuction;
        if (a.lot == 0) revert NoAuction();
        uint256 demand = Decay.price(a.start, block.timestamp - a.startedAt);
        delete imdAuction;
        imdBurnBalance -= a.lot;
        if (demand != 0) _safeTransferFrom(address(IMD), msg.sender, DEAD, demand);
        emit ImdBurned(msg.sender, demand, a.lot);
        _pay(msg.sender, a.lot);
    }

    // ------------------------------------------------------------------ pairing

    /// @notice Approve IMD's pairing message for a held seat, so `isValidSignature` accepts it. The
    /// approval is tied to this purchase of the seat and dies when the seat sells.
    /// @dev Send the same message to IMD's pairing endpoint with any signature bytes.
    function authorizeWorker(WorkerAuthorization.Auth calldata a) external returns (bytes32 digest) {
        if (msg.sender != operator) revert NotOperator();
        if (a.wallet != address(this)) revert WrongWallet();
        if (a.expiresAt <= block.timestamp) revert Expired();
        Seat storage s = seats[a.tokenId];
        if (!s.held || !_holds(a.tokenId)) revert NotHeld();
        digest = WorkerAuthorization.digest(address(COLLECTION), a);
        if (a.tokenId > type(uint232).max) revert NotHeld();
        _workerApprovals[digest] = WorkerApproval(uint232(a.tokenId), s.round, true);
        emit WorkerAuthorized(a.tokenId, digest);
    }

    function revokeWorker(bytes32 digest) external {
        if (msg.sender != operator) revert NotOperator();
        delete _workerApprovals[digest];
        emit WorkerRevoked(digest);
    }

    /// @notice ERC-1271. Valid only for an approved pairing digest of a seat Cocoon still holds
    /// from the same purchase; never for anything else.
    function isValidSignature(bytes32 hash, bytes calldata) external view returns (bytes4) {
        WorkerApproval memory w = _workerApprovals[hash];
        if (!w.approved) return ERC1271_INVALID;
        Seat storage s = seats[w.tokenId];
        if (!s.held || s.round != w.round) return ERC1271_INVALID;
        return _holds(w.tokenId) ? ERC1271_VALID : ERC1271_INVALID;
    }

    // ------------------------------------------------------------------ developer, owner

    /// @notice Pay the developer whatever has accrued. Anyone may call.
    function claimDeveloper() external nonReentrant {
        uint256 amount = developerBalance;
        if (amount == 0) return;
        developerBalance = 0;
        emit DeveloperPaid(amount);
        _pay(developer, amount);
    }

    function setDeveloper(address to) external {
        if (msg.sender != developer) revert NotDeveloper();
        if (to == address(0)) revert ZeroAddress();
        developer = to;
        emit DeveloperSet(to);
    }

    function setOperator(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        operator = to;
        emit OperatorSet(to);
    }

    function transferOwnership(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, to);
        owner = to;
    }

    function setParams(Params calldata p) external onlyOwner {
        _checkParams(p);
        params = p;
        emit ParamsSet(p);
    }

    /// @notice Point Cocoon at the launch pool, once. The pool's hook must have opened it, name it
    /// as its launch pool, and name this contract as its sink.
    function wire(PoolKey calldata key) external onlyOwner {
        if (wired) revert AlreadyWired();
        ILaunchHook hook = ILaunchHook(address(key.hooks));
        if (
            !key.currency0.isAddressZero() || Currency.unwrap(key.currency1) == address(0)
                || hook.openedAt() == 0 || PoolId.unwrap(hook.launchPool()) != PoolId.unwrap(key.toId())
                || hook.sink() != address(this)
        ) revert WrongPool();
        launchKey = key;
        wired = true;
        emit Wired(key.toId());
    }

    function _checkParams(Params calldata p) private pure {
        if (p.accumulateSeatBps < 3000 || p.accumulateSeatBps > 7000) revert OutOfBounds();
        if (p.listStartX < 11_000 || p.listStartX > 30_000) revert OutOfBounds();
        if (p.listEndX < 10_000 || p.listEndX > 15_000 || p.listEndX > p.listStartX) revert OutOfBounds();
        if (p.listDecay < 1 days || p.listDecay > 60 days) revert OutOfBounds();
        if (p.toleranceBps > 1000) revert OutOfBounds();
        if (p.callerRewardBps > 100) revert OutOfBounds();
        if (p.burnImpactBps < 100 || p.burnImpactBps > 1000) revert OutOfBounds();
        if (p.burnSpacing < 1 || p.burnSpacing > 300) revert OutOfBounds();
        if (p.harvestStartWei < 0.01 ether || p.harvestStartWei > 100 ether) revert OutOfBounds();
        if (p.imdStartPerEth < 100 ether || p.imdStartPerEth > 10_000_000 ether) revert OutOfBounds();
    }

    // ------------------------------------------------------------------ internals

    function _pay(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }

    /// @dev Works for tokens that return nothing as well as for those that return a bool.
    function _safeTransfer(address token, address to, uint256 amount) private {
        _tokenCall(token, abi.encodeCall(IERC20Minimal.transfer, (to, amount)));
    }

    function _safeTransferFrom(address token, address from, address to, uint256 amount) private {
        _tokenCall(token, abi.encodeCall(IERC20Minimal.transferFrom, (from, to, amount)));
    }

    function _tokenCall(address token, bytes memory data) private {
        (bool ok, bytes memory ret) = token.call(data);
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _tload(uint256 slot) private view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    function _tstore(uint256 slot, uint256 value) private {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }
}
