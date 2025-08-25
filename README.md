 # 🏨 Decentralized Hotel Smart Contract

## 📌 What

This smart contract enables **trustless hotel/hostel bookings** using Ethereum (or EVM-compatible chains).  
It removes the need for centralized platforms (Airbnb, Booking.com) by holding funds in **escrow** and releasing them only when stay conditions are met.

The booking process is **transparent, secure, and tamper-proof**, with refund guarantees for guests in case of cancellations or no-shows.

### ✅ Key Features  
 
- **Slot-based bookings:** Hosts create available stay slots (check-in, check-out, price, cancel deadline). 
- **Guest booking:** Guests pay directly into the contract to secure a slot.   
- **Escrow system:** Funds are held in the contract until conditions are met.   
- **Guest protection:**
  - Guest can cancel before the deadline for a full refund.  
  - If host cancels → full refund to guest.
  - If host fails to provide stay (no check-in confirmed), refund auto-available after grace period.
- **Host protection:**
  - If stay is completed (check-in confirmed + checkout passed), host can claim payout.
  - If host forgets to claim, anyone can trigger payout after a grace period.

---

## 🤔 Why

The current hotel/hostel booking ecosystem relies heavily on centralized intermediaries (Airbnb, Booking.com, Oyo, etc.) that:

- Charge **10–30% commission** from hosts.
- Require trust in opaque cancellation/refund policies.
- Delay host payouts (days or weeks).
- Create disputes with little guest/host transparency.

By moving the booking process **on-chain**, this contract ensures:

- **Trustless escrow:** Neither host nor guest controls funds until conditions are met.
- **Transparent cancellations/refunds:** Rules are written in immutable smart contract logic.
- **No middlemen fees:** Guests pay directly, hosts receive full amount (minus gas fees).
- **Protection for both sides:** Guest guaranteed refund if host fails; host guaranteed payout if stay is completed.
- **Global reach:** Anyone with crypto can book without bank intermediaries.

This creates a **fairer, more efficient public-stay ecosystem**.

---

## 🔄 Booking Flow

1. **Host creates a stay slot:**

   - Defines check-in, check-out, cancel-before deadline, and price.

2. **Guest books slot:**

   - Pays exact price into the contract.
   - Funds go into escrow.

3. **Possible scenarios:**
   - ✅ Guest cancels before cancel deadline → full refund.
   - ✅ Host cancels before check-in → full refund.
   - ✅ Guest & host confirm check-in → stay active.
   - ✅ If no check-in & noShowWindow passes → refund to guest.
   - ✅ After checkout → host can claim payout.
   - ✅ If host doesn’t claim after checkout + grace period → anyone can trigger payout to host.

---

## ⚙️ Functions Overview

- `createSlot(checkIn, checkOut, cancelBefore, price)` → Host creates stay slot.
- `book(slotId)` → Guest books by paying price.
- `cancelByGuest(bookingId)` → Guest cancels before cancel deadline → refund.
- `cancelByHost(bookingId)` → Host cancels before check-in → refund.
- `confirmCheckIn(bookingId)` → Either guest or host confirms check-in.
- `refundNoShow(bookingId)` → If no check-in after `noShowWindow` → refund guest.
- `releasePayout(bookingId)` → Host claims payout after stay ends.
- `finalizePayoutIfIdle(bookingId)` → Anyone finalizes payout if host forgets after `completionGrace`.

---

## ⏱️ Time Parameters

- `cancelBefore` → guest’s deadline to cancel with refund.
- `noShowWindow` (default 24h) → grace after check-in start; if no check-in → refund guest.
- `completionGrace` (default 12h) → grace after checkout; anyone can trigger payout if host forgets.

---

## 🛠️ Example Scenario

- Host Alice creates a room slot:

  - Check-in: Aug 25, 2PM
  - Check-out: Aug 28, 11AM
  - Cancel before: Aug 20, 12PM
  - Price: 0.5 ETH

- Guest Bob books by paying **0.5 ETH**.

- If Bob cancels on Aug 18 → auto refund **0.5 ETH**.
- If Alice cancels on Aug 24 → auto refund **0.5 ETH**.
- If Bob checks in & stays until Aug 28 → Alice can withdraw **0.5 ETH** immediately.
- If Bob never checked in, after Aug 26 (24h after check-in) → anyone can refund Bob automatically.

---

## 🌍 Use Cases

- **Hotels/Hostels** running independent of OTA platforms.
- **Decentralized Airbnb** alternative.
- **Event accommodations** (concerts, festivals, conferences).
- **DAO housing projects** with transparent booking.

---

## 📜 License

MIT
