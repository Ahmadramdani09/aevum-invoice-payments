# Invoice Payments on Aevum Testnet

**Aevum Builder Challenge #1 — Stablecoin Payments track (Invoice Payments)**

A complete, minimal stablecoin payment flow on **Aevum Testnet**: an issuer
creates an on-chain invoice denominated in **tUSD8**, the named payer settles
it with one `transferFrom`, and anyone can verify the invoice's status —
Pending, Paid, or Cancelled — from the chain itself. No backend, no database,
no trusted intermediary: the contract is the record.

## Problem

Freelancers and small businesses billing in stablecoins today coordinate
payment over chat and screenshots: "please send 250 to this address, ref
INV-001." That is error-prone (wrong address, wrong amount, no proof of what
a payment was *for*) and disputes are unresolvable because nothing links the
payment request to the payment itself.

## Solution

Put the invoice itself on-chain. The invoice is a first-class object with an
issuer, a payer, an exact amount, a due date, and a memo. Settlement is bound
to it: only the named payer can pay, exactly the invoiced amount moves, and
the state transition is permanent and publicly auditable on the explorer.

## Architecture

```
┌────────────┐   createInvoice(payer, amount, due, memo)   ┌──────────────────┐
│   Issuer   │ ───────────────────────────────────────────▶│                  │
└────────────┘                                             │  InvoicePayments │
┌────────────┐   approve(tUSD8) + payInvoice(id)           │     (registry)   │
│   Payer    │ ───────────────────────────────────────────▶│                  │
└────────────┘            transferFrom(payer → issuer)     └────────┬─────────┘
                                                                    │ settles in
                                                           ┌────────▼─────────┐
                                                           │  tUSD8 (ERC-20)  │
                                                           │  Aevum Testnet   │
                                                           └──────────────────┘
Demo UI (demo/index.html, static) ── window.ethereum / ethers.js ──▶ contract
```

- **`src/InvoicePayments.sol`** — the whole product: an invoice registry with
  a three-state lifecycle (`Pending → Paid`, `Pending → Cancelled`). One
  immutable settlement token, set at construction.
- **`src/IERC20Minimal.sol`** — the four ERC-20 functions the contract needs.
  Declaring the interface locally keeps the project at **zero external
  dependencies** — nothing to download, nothing to audit beyond this repo.
- **`demo/index.html`** — a single self-contained page (ethers.js from CDN)
  that connects a wallet, switches/adds Aevum Testnet, creates and pays
  invoices, and lists recent invoice statuses. Serve it from any static host.
- **`test/`** — Foundry tests with a mock ERC-20, including a hostile
  re-entrant token. The test suite also declares its cheatcodes locally
  instead of depending on forge-std.
- **`script/Deploy.s.sol`** — one-command deployment against tUSD8.

## Core workflows

1. **Issue.** The issuer calls `createInvoice(payer, amount, dueDate, memo)`.
   Amounts are in the token's smallest unit (tUSD8 has 6 decimals, so
   250.00 tUSD8 = `250_000_000`). An `InvoiceCreated` event is emitted and a
   sequential id (starting at 1) identifies the invoice forever.
2. **Settle.** The payer approves the contract for the invoice amount, then
   calls `payInvoice(id)`. The contract pulls exactly that amount from payer
   to issuer and flips the status to `Paid`. Payment after the due date is
   accepted — real invoices get paid late — and flagged `late` in the
   `InvoicePaid` event so the issuer's books stay honest.
3. **Cancel.** The issuer may `cancelInvoice(id)` while the invoice is still
   unpaid (sent to the wrong payer? wrong amount? create a corrected one).
   A paid invoice can never be cancelled, and a cancelled invoice can never
   be paid.
4. **Verify.** `getInvoice(id)` returns the full record; `invoiceCount`
   bounds the id space. Every state change emits an event, so indexers and
   the demo UI can follow along without polling storage.

## Safety considerations (trust & controls)

- **Checks-Effects-Interactions** — `payInvoice` marks the invoice `Paid`
  *before* calling `transferFrom`, so a hostile token callback observes a
  settled invoice.
- **Reentrancy guard** — the only value-moving function is additionally
  protected by a hand-rolled guard; `testReentrantTokenCannotDoublePay`
  proves a token that re-enters from `transferFrom` cannot pay twice.
- **Exact-amount settlement** — the amount comes from the invoice, never from
  the caller, so a payer cannot underpay; an approval smaller than the
  invoice amount makes settlement revert and the invoice stays `Pending`.
- **Strict validation** — zero address, zero amount, self-invoicing, and
  past due dates all revert at creation; unknown ids revert on read instead
  of returning a plausible-looking empty record.
- **Return-value check** — a `transferFrom` that returns `false` reverts the
  payment instead of silently marking the invoice paid.
- **No unbounded work** — there are no loops; every call is O(1) regardless
  of how many invoices exist.
- **Keys stay out of the repo** — `.gitignore` excludes `.keys/`, `.env`,
  and `*.key`; the deployer key never touches git.

## Chain configuration

| Item                | Value                                       |
| ------------------- | ------------------------------------------- |
| Network             | Aevum Testnet                               |
| Chain ID            | 44005                                       |
| RPC                 | https://rpc-test.qday.info                  |
| Explorer            | https://explorer-test.qday.info             |
| Settlement token    | tUSD8 (ERC-20, 6 decimals)                  |
| tUSD8 address       | `0x456569838f1d43009A91ebA4263147Afd7233483` |
| InvoicePayments     | *pending deployment — see below*            |
| Deployer (testnet)  | `0x67223a889319A76C38DF7c78B3888E7d9FF08aA5` |

## Run the tests

Requires [Foundry](https://book.getfoundry.sh) (developed against 1.4.4,
solc 0.8.24):

```bash
forge test
```

Expected: **18 passed, 0 failed** — creation rules, happy-path payment,
wrong payer, under-approved ("wrong amount") settlement, insufficient
balance, double-pay rejection, late-payment flagging, cancel rules
(including "cannot cancel after payment"), and the reentrancy proof.

## Run the demo

Serve the folder statically and open it in a wallet-equipped browser:

```bash
python3 -m http.server --directory demo 8000
# → http://localhost:8000
```

The page adds/switches to Aevum Testnet automatically on connect. Until the
contract is deployed it shows a "not live yet" warning; after deployment,
set `CONFIG.invoiceContract` in `demo/index.html` to the deployed address.

## Deployment (pending)

The contract, tests, and demo are complete; deployment is a short final
step that needs testnet gas in the deployer wallet:

1. **Fund the deployer** — claim tQDAY from the Aevum testnet faucet to
   `0x67223a889319A76C38DF7c78B3888E7d9FF08aA5` (deployer key lives in
   `.keys/deployer.key`, gitignored, never shared).
2. **Deploy:**
   ```bash
   forge script script/Deploy.s.sol:Deploy \
     --rpc-url aevum_testnet --broadcast \
     --private-key $(cat .keys/deployer.key)
   ```
3. **Verify** — read state back (`cast call <address> "invoiceCount()"`)
   and check the contract on https://explorer-test.qday.info.
4. **Go live** — fill the deployed address into the table above and into
   `CONFIG.invoiceContract` in `demo/index.html`, then publish the demo
   (e.g. GitHub Pages from the `demo/` folder).

## Tech stack

Solidity 0.8.24 · Foundry (build/test/script) · ethers.js v6 (demo) ·
Aevum Testnet (EVM, chain 44005) · tUSD8

## License

MIT — see [LICENSE](LICENSE).
