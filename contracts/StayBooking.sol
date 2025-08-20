// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/**
 * Decentralized Hotel/Hostel Booking Contract
 *
 * Model (slot-based):
 * - Host creates a StaySlot for a specific check-in/check-out window, price, and free-cancel deadline.
 * - Guest books the slot by paying exactly the price => funds held in escrow.
 * - If guest cancels before `cancelBefore` => full refund to guest.
 * - If host cancels before check-in => full refund to guest.
 * - If host fails to provide stay (no check-in confirmation), anyone can trigger auto-refund to guest
 *   after `checkIn + noShowWindow`.
 * - If stay completes (checked-in and after check-out), host can claim payout; or anyone can finalize
 *   payout after a small `completionGrace` if still not claimed.
 *
 * Notes:
 * - "Automatic" on-chain actions still require *someone* to call the relevant function;
 *   in production, use an automation/keeper service.
 * - No platform fee baked-in; easy to add later.
 */

contract StayBooking {
    // ========= Errors =========
    error NotHost();
    error NotGuest();
    error AlreadyBooked();
    error SlotInactive();
    error InvalidTimes();
    error InvalidValue();
    error TooLateToCancel();
    error TooEarly();
    error AlreadySettled();
    error NotBooked();
    error Reentrancy();

    // ========= Events =========
    event SlotCreated(
        uint256 indexed slotId,
        address indexed host,
        uint64 checkIn,
        uint64 checkOut,
        uint256 price,
        uint64 cancelBefore
    );
    event SlotDeactivated(uint256 indexed slotId, address indexed host);

    event Booked(
        uint256 indexed bookingId,
        uint256 indexed slotId,
        address indexed guest,
        uint256 price
    );
    event GuestCanceled(
        uint256 indexed bookingId,
        address indexed guest,
        uint256 refund
    );
    event HostCanceled(
        uint256 indexed bookingId,
        address indexed host,
        uint256 refund
    );
    event CheckInConfirmed(uint256 indexed bookingId, address indexed by);
    event RefundedNoShow(uint256 indexed bookingId, uint256 refund);
    event PayoutReleased(
        uint256 indexed bookingId,
        address indexed host,
        uint256 amount
    );

    // ========= Reentrancy Guard (lightweight) =========
    uint256 private _locked = 1;
    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    // ========= Types =========
    struct StaySlot {
        address host;
        uint64 checkIn; // unix timestamp (seconds)
        uint64 checkOut; // must be > checkIn
        uint64 cancelBefore; // guest free-cancel deadline
        uint256 price; // total price for the whole stay (wei)
        bool active; // host can deactivate before booking
        bool booked; // becomes true when booked once
    }

    enum BookingStatus {
        None, // 0
        Booked, // 1
        GuestCanceled,
        HostCanceled,
        RefundedNoShow,
        CompletedPaid
    }

    struct Booking {
        uint256 slotId;
        address host;
        address guest;
        uint256 amount; // escrowed wei
        bool checkedIn; // confirmed check-in
        BookingStatus status;
    }

    // ========= Storage =========
    uint256 public nextSlotId = 1;
    uint256 public nextBookingId = 1;

    // windows (seconds)
    uint64 public noShowWindow = 24 hours; // after check-in, if not checked in => refundable to guest
    uint64 public completionGrace = 12 hours; // after checkout, if checked in => anyone can trigger payout

    mapping(uint256 => StaySlot) public slots; // slotId => StaySlot
    mapping(uint256 => Booking) public bookings; // bookingId => Booking

    // ========= Admin (optional) =========
    address public immutable owner;

    constructor() {
        owner = msg.sender;
    }

    function setNoShowWindow(uint64 newWindow) external {
        require(msg.sender == owner, "Only owner");
        require(
            newWindow >= 1 hours && newWindow <= 7 days,
            "Unreasonable window"
        );
        noShowWindow = newWindow;
    }

    function setCompletionGrace(uint64 newGrace) external {
        require(msg.sender == owner, "Only owner");
        require(
            newGrace >= 1 hours && newGrace <= 7 days,
            "Unreasonable grace"
        );
        completionGrace = newGrace;
    }

    // ========= Host Flow =========

    /**
     * Host creates a slot for a specific stay window and fixed price.
     * cancelBefore is the timestamp until which the guest can freely cancel.
     */
    function createSlot(
        uint64 checkIn,
        uint64 checkOut,
        uint64 cancelBefore,
        uint256 price
    ) external returns (uint256 slotId) {
        if (checkOut <= checkIn) revert InvalidTimes();
        if (cancelBefore > checkIn) revert InvalidTimes();
        require(price > 0, "Price must be > 0");

        slotId = nextSlotId++;
        slots[slotId] = StaySlot({
            host: msg.sender,
            checkIn: checkIn,
            checkOut: checkOut,
            cancelBefore: cancelBefore,
            price: price,
            active: true,
            booked: false
        });

        emit SlotCreated(
            slotId,
            msg.sender,
            checkIn,
            checkOut,
            price,
            cancelBefore
        );
    }

    function deactivateSlot(uint256 slotId) external {
        StaySlot storage s = slots[slotId];
        if (s.host != msg.sender) revert NotHost();
        if (!s.active) revert SlotInactive();
        require(!s.booked, "Already booked");
        s.active = false;
        emit SlotDeactivated(slotId, msg.sender);
    }

    // ========= Guest Flow =========

    /**
     * Book an active slot by paying exact price. Funds go to escrow.
     */
    function book(
        uint256 slotId
    ) external payable nonReentrant returns (uint256 bookingId) {
        StaySlot storage s = slots[slotId];
        if (!s.active) revert SlotInactive();
        if (s.booked) revert AlreadyBooked();
        if (msg.value != s.price) revert InvalidValue();

        s.booked = true;

        bookingId = nextBookingId++;
        bookings[bookingId] = Booking({
            slotId: slotId,
            host: s.host,
            guest: msg.sender,
            amount: msg.value,
            checkedIn: false,
            status: BookingStatus.Booked
        });

        emit Booked(bookingId, slotId, msg.sender, msg.value);
    }

    /**
     * Guest can cancel before `cancelBefore` => full refund.
     */
    function cancelByGuest(uint256 bookingId) external nonReentrant {
        Booking storage b = bookings[bookingId];
        if (b.status != BookingStatus.Booked) revert NotBooked();
        if (b.guest != msg.sender) revert NotGuest();

        StaySlot storage s = slots[b.slotId];
        if (block.timestamp > s.cancelBefore) revert TooLateToCancel();

        uint256 refund = b.amount;
        _markRefund(b, BookingStatus.GuestCanceled);
        _safeTransfer(payable(b.guest), refund);

        emit GuestCanceled(bookingId, b.guest, refund);
    }

    /**
     * Host can cancel before check-in => full refund to guest.
     */
    function cancelByHost(uint256 bookingId) external nonReentrant {
        Booking storage b = bookings[bookingId];
        if (b.status != BookingStatus.Booked) revert NotBooked();
        if (b.host != msg.sender) revert NotHost();

        StaySlot storage s = slots[b.slotId];
        if (block.timestamp >= s.checkIn) revert TooEarly(); // too late to host-cancel once check-in starts

        uint256 refund = b.amount;
        _markRefund(b, BookingStatus.HostCanceled);
        _safeTransfer(payable(b.guest), refund);

        emit HostCanceled(bookingId, b.host, refund);
    }

    // ========= Check-in / No-Show =========

    /**
     * Either party can confirm check-in after the check-in time starts.
     * If not confirmed and noShowWindow passes, anyone can refund to guest.
     */
    function confirmCheckIn(uint256 bookingId) external {
        Booking storage b = bookings[bookingId];
        if (b.status != BookingStatus.Booked) revert NotBooked();
        if (msg.sender != b.guest && msg.sender != b.host) revert();

        StaySlot storage s = slots[b.slotId];
        if (block.timestamp < s.checkIn) revert TooEarly();
        b.checkedIn = true;

        emit CheckInConfirmed(bookingId, msg.sender);
    }

    /**
     * If host failed to provide stay (no check-in confirmation),
     * after checkIn + noShowWindow anyone can trigger a refund to guest.
     */
    function refundNoShow(uint256 bookingId) external nonReentrant {
        Booking storage b = bookings[bookingId];
        if (b.status != BookingStatus.Booked) revert NotBooked();

        StaySlot storage s = slots[b.slotId];
        if (b.checkedIn) revert AlreadySettled();
        if (block.timestamp < uint256(s.checkIn) + uint256(noShowWindow))
            revert TooEarly();

        uint256 refund = b.amount;
        _markRefund(b, BookingStatus.RefundedNoShow);
        _safeTransfer(payable(b.guest), refund);

        emit RefundedNoShow(bookingId, refund);
    }

    // ========= Completion / Payout =========

    /**
     * Host can claim payout after checkout if check-in was confirmed.
     */
    function releasePayout(uint256 bookingId) external nonReentrant {
        Booking storage b = bookings[bookingId];
        if (b.status != BookingStatus.Booked) revert NotBooked();
        if (!b.checkedIn) revert TooEarly();
        if (msg.sender != b.host) revert NotHost();

        StaySlot storage s = slots[b.slotId];
        if (block.timestamp < s.checkOut) revert TooEarly();

        uint256 amount = b.amount;
        b.status = BookingStatus.CompletedPaid;
        b.amount = 0;

        _safeTransfer(payable(b.host), amount);
        emit PayoutReleased(bookingId, b.host, amount);
    }

    /**
     * Anyone can finalize payout after checkout + completionGrace if host hasn't claimed yet.
     * Useful for tidy state; sends funds to host.
     */
    function finalizePayoutIfIdle(uint256 bookingId) external nonReentrant {
        Booking storage b = bookings[bookingId];
        if (b.status != BookingStatus.Booked) revert NotBooked();
        if (!b.checkedIn) revert TooEarly();

        StaySlot storage s = slots[b.slotId];
        if (block.timestamp < uint256(s.checkOut) + uint256(completionGrace))
            revert TooEarly();

        uint256 amount = b.amount;
        b.status = BookingStatus.CompletedPaid;
        b.amount = 0;

        _safeTransfer(payable(b.host), amount);
        emit PayoutReleased(bookingId, b.host, amount);
    }

    // ========= Internal helpers =========
    function _markRefund(Booking storage b, BookingStatus newStatus) internal {
        if (b.status != BookingStatus.Booked) revert AlreadySettled();
        b.status = newStatus;
        b.amount = 0;
    }

    function _safeTransfer(address payable to, uint256 value) internal {
        (bool ok, ) = to.call{value: value}("");
        require(ok, "ETH transfer failed");
    }

    // ========= View helpers =========
    function getSlot(uint256 slotId) external view returns (StaySlot memory) {
        return slots[slotId];
    }

    function getBooking(
        uint256 bookingId
    ) external view returns (Booking memory) {
        return bookings[bookingId];
    }
}
