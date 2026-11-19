// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20Minimal} from "./IERC20Minimal.sol";

/// @title InvoicePayments
/// @notice A minimal on-chain invoice registry settled in a single ERC-20
///         (on Aevum Testnet: tUSD8). An issuer creates an invoice naming a
///         payer and an amount; the payer settles it with `transferFrom`;
///         the issuer may cancel an invoice while it is still unpaid.
/// @dev Safety properties:
///      - Checks-Effects-Interactions: state is updated before the token
///        transfer in `payInvoice`, so a hostile token cannot observe or
///        exploit a half-settled invoice.
///      - A hand-rolled reentrancy guard protects the only function that
///        moves value (no external dependencies are used anywhere).
///      - Every state-changing input is validated (zero address, zero
///        amount, past due date, self-invoicing) and unknown invoice ids
///        revert instead of returning a misleading empty record.
///      - No loops at all: storage access is O(1) per call, so gas cost
///        never grows with the number of invoices.
contract InvoicePayments {
    enum Status {
        Pending,
        Paid,
        Cancelled
    }

    struct Invoice {
        address issuer;
        address payer;
        uint256 amount; // in the token's smallest unit (tUSD8: 6 decimals)
        uint64 dueDate; // unix timestamp; payment is still accepted after it (flagged late)
        Status status;
        string memo;
    }

    /// @notice The ERC-20 all invoices are denominated and settled in.
    IERC20Minimal public immutable token;

    /// @notice Total number of invoices ever created. Ids start at 1.
    uint256 public invoiceCount;

    mapping(uint256 => Invoice) private _invoices;

    // --- reentrancy guard (1 = unlocked, 2 = locked) ---
    uint256 private _guard = 1;

    modifier nonReentrant() {
        if (_guard != 1) revert ReentrantCall();
        _guard = 2;
        _;
        _guard = 1;
    }

    // --- events (one per state change) ---
    event InvoiceCreated(
        uint256 indexed id, address indexed issuer, address indexed payer, uint256 amount, uint64 dueDate, string memo
    );
    event InvoicePaid(uint256 indexed id, address indexed payer, uint256 amount, bool late);
    event InvoiceCancelled(uint256 indexed id, address indexed issuer);

    // --- errors ---
    error ZeroAddress();
    error ZeroAmount();
    error SelfInvoice();
    error DueDateInPast();
    error InvoiceNotFound(uint256 id);
    error NotPending(uint256 id);
    error NotPayer(uint256 id, address caller);
    error NotIssuer(uint256 id, address caller);
    error TransferFailed();
    error ReentrantCall();

    /// @param token_ The settlement token (tUSD8 on Aevum Testnet).
    constructor(IERC20Minimal token_) {
        if (address(token_) == address(0)) revert ZeroAddress();
        token = token_;
    }

    /// @notice Create an invoice for `payer` to settle in the token.
    /// @param payer Address that must pay the invoice.
    /// @param amount Amount in the token's smallest unit; must be > 0.
    /// @param dueDate Unix timestamp the invoice is due; must be in the future.
    /// @param memo Free-text reference (invoice number, description, ...).
    /// @return id The new invoice id (ids are sequential, starting at 1).
    function createInvoice(address payer, uint256 amount, uint64 dueDate, string calldata memo)
        external
        returns (uint256 id)
    {
        if (payer == address(0)) revert ZeroAddress();
        if (payer == msg.sender) revert SelfInvoice();
        if (amount == 0) revert ZeroAmount();
        if (dueDate <= block.timestamp) revert DueDateInPast();

        id = ++invoiceCount;
        _invoices[id] = Invoice({
            issuer: msg.sender,
            payer: payer,
            amount: amount,
            dueDate: dueDate,
            status: Status.Pending,
            memo: memo
        });

        emit InvoiceCreated(id, msg.sender, payer, amount, dueDate, memo);
    }

    /// @notice Pay a pending invoice. The caller must be the invoice's payer
    ///         and must have approved this contract for at least the invoice
    ///         amount. Payment after the due date is accepted and flagged
    ///         as late in the event.
    /// @param id The invoice to pay.
    function payInvoice(uint256 id) external nonReentrant {
        Invoice storage inv = _invoiceOrRevert(id);
        if (inv.status != Status.Pending) revert NotPending(id);
        if (msg.sender != inv.payer) revert NotPayer(id, msg.sender);

        // Effects before interactions: mark paid *before* moving tokens so a
        // malicious token re-entering sees a settled invoice (and the guard
        // blocks the re-entry outright anyway).
        inv.status = Status.Paid;
        bool late = block.timestamp > inv.dueDate;

        // Interaction last. If the transfer fails the whole call reverts,
        // which also rolls back the status change above.
        if (!token.transferFrom(inv.payer, inv.issuer, inv.amount)) {
            revert TransferFailed();
        }

        emit InvoicePaid(id, inv.payer, inv.amount, late);
    }

    /// @notice Cancel a pending invoice. Only the issuer, and only while the
    ///         invoice has not been paid yet.
    /// @param id The invoice to cancel.
    function cancelInvoice(uint256 id) external {
        Invoice storage inv = _invoiceOrRevert(id);
        if (msg.sender != inv.issuer) revert NotIssuer(id, msg.sender);
        if (inv.status != Status.Pending) revert NotPending(id);

        inv.status = Status.Cancelled;

        emit InvoiceCancelled(id, inv.issuer);
    }

    /// @notice Read an invoice by id. Reverts for ids that were never created
    ///         (including 0), so callers never mistake an empty record for a
    ///         real zero-amount invoice.
    function getInvoice(uint256 id) external view returns (Invoice memory) {
        return _invoiceOrRevert(id);
    }

    function _invoiceOrRevert(uint256 id) internal view returns (Invoice storage inv) {
        if (id == 0 || id > invoiceCount) revert InvoiceNotFound(id);
        inv = _invoices[id];
    }
}
