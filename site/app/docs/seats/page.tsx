import type { Metadata } from "next";
import Link from "next/link";
import { Aside, Doc } from "@/components/docs/Doc";

export const metadata: Metadata = { title: "Seats" };

export default function Seats() {
  return (
    <Doc slug="seats">
      <h2>What a seat is</h2>
      <p>
        An Identity MD seat is one token of the identity.md collection on Ethereum (
        <code className="num">0x0000eC93…38ec1D</code>). Holding one lets a device join the IMD swarm as a worker: it
        answers oracle questions on panels, reviews and builds launches, and earns from them. Pupate’s vault holds seats
        the way a strategy holds inventory, except that the inventory works.
      </p>

      <h2>Buying</h2>
      <p>
        <code>buySeat(order)</code> fulfils a Seaport 1.6 listing of one seat. Anyone can call it with any listing; the
        vault pays from the seat pot. It goes through only when all of these hold:
      </p>
      <ul>
        <li>a fresh oracle report exists;</li>
        <li>the order’s price is at most 105% of the reference price;</li>
        <li>the seat pot covers the price plus the caller reward;</li>
        <li>
          the order is one seat of the collection, in full, for native ETH, with every consideration item paid to someone
          other than the vault and no tip appended by the caller;
        </li>
        <li>the vault does not already hold that seat.</li>
      </ul>
      <p>
        The vault sends the highest price the order can ask and Seaport returns what the order did not need. During a
        purchase the vault accepts ETH from Seaport only, so the seat’s cost is exactly what Seaport paid out to others
        and a refund stays in the pot. The caller receives 0.5% of what was actually spent.
      </p>

      <h2>Listing</h2>
      <p>
        On purchase the vault publishes two signature-free Seaport orders for the seat and validates them on-chain. No key
        signs anything.
      </p>
      <table>
        <thead>
          <tr>
            <th>Order</th>
            <th>Price</th>
            <th>Runs</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td>The fall</td>
            <td className="num">1.5× cost falling in a straight line to 1.1× cost</td>
            <td className="num">14 days from purchase</td>
          </tr>
          <tr>
            <td>The tail</td>
            <td className="num">1.1× cost, flat</td>
            <td className="num">from day 14, for ten years</td>
          </tr>
        </tbody>
      </table>
      <p>
        The terms are fixed at purchase; a later change of parameters applies to new purchases only. The orders carry a
        per-seat round number, so the orders of an earlier purchase of the same seat can never collide with a later one’s.
      </p>

      <h2>Working</h2>
      <p>
        IMD pairs a device to a seat by checking a <code>WorkerAuthorization</code> message signed by the seat’s holder,
        and accepts ERC-1271 when the holder is a contract. The vault’s <b>operator</b> approves a specific authorisation
        on-chain with <code>authorizeWorker</code>; the vault’s <code>isValidSignature</code> then returns valid for that
        message and nothing else. An approval is tied to the purchase it was made under: it dies when the seat sells and
        does not revive if the seat comes back.
      </p>
      <p>
        That is all the operator can do. It cannot transfer seats, move ETH, sign anything else, or change parameters.
        In this phase the operator is the developer, who also runs the machines behind the seats.
      </p>
      <p>
        Tokens a working seat earns, launch allocations and IMD, arrive in the vault. <code>startAuction(token)</code>{" "}
        opens a falling-price auction for the vault’s whole balance of that token: the price starts at 100 ETH, far above anything a lot can be worth, halves every
        2 hours, falls in a straight line inside each half-life, and is zero from 48 hours on. The first taker gets the
        lot and the ETH goes to the seat pot. PUPATE is never auctioned; any PUPATE the vault holds is burned.
      </p>

      <h2>Proof of work</h2>
      <p>
        IMD keeps a public record for every paired seat: whether it is online, what runs it, how many submissions it has
        made and how many were accepted by other seats, the jobs themselves and who it worked with. The{" "}
        <Link href="/work/">Work</Link> page shows that record for the seats the vault holds, job by job, each linked to
        IMD&apos;s explorer; the keeper publishes it as <code>work.json</code> next to <code>status.json</code>. Other projects
        prove hashes. Pupate&apos;s seats prove work.
      </p>

      <h2>Selling</h2>
      <p>
        When a listing fills, the ETH goes to the burn pot. <code>settleSeat(tokenId)</code>, callable by anyone, takes
        the sold seat off the books and cancels its other order on Seaport, so the seat cannot be sold at a stale price if
        the vault ever buys it back. A seat that is sent to the vault directly can be taken onto the books by{" "}
        <code>adopt(tokenId)</code>, at the current reference price, and listed like a purchase.
      </p>
      <p>
        A seat leaves the vault only through a filled listing. There is no function that transfers a seat out.
      </p>

      <Aside>
        Every seat the vault holds has its own page with its listing curve, its work in the swarm and a card drawn from
        its number. Open one from the <Link href="/cocoon/">Cocoon</Link> page; sold seats stay reachable from{" "}
        <Link href="/emerge/">Emerge</Link>.
      </Aside>
    </Doc>
  );
}
