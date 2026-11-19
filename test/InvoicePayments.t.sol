// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {InvoicePayments} from "../src/InvoicePayments.sol";
import {IERC20Minimal} from "../src/IERC20Minimal.sol";
import {MockERC20, ReentrantToken} from "./mocks/MockERC20.sol";

/// @notice Minimal cheatcode interface, declared locally so the project has
///         zero external dependencies (no forge-std download required).
interface Vm {
    function prank(address msgSender) external;
    function warp(uint256 newTimestamp) external;
    function expectRevert() external;
    function expectRevert(bytes4 revertData) external;
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData) external;
}

/// @notice Dependency-free test suite for InvoicePayments. Assertions revert
///         with a message on failure, which forge reports as a failed test.
contract InvoicePaymentsTest {
    Vm internal constant vm = Vm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    // Events re-declared so tests can emit the expected log for expectEmit.
    event InvoiceCreated(
        uint256 indexed id, address indexed issuer, address indexed payer, uint256 amount, uint64 dueDate, string memo
    );
    event InvoicePaid(uint256 indexed id, address indexed payer, uint256 amount, bool late);
    event InvoiceCancelled(uint256 indexed id, address indexed issuer);

    address internal issuer = address(0x1559E1);
    address internal payer = address(0x9A9E12);
    address internal stranger = address(0x57A6E12);

    uint256 internal constant AMOUNT = 250 * 1e6; // 250.00 tUSD8 (6 decimals)

    MockERC20 internal token;
    InvoicePayments internal invoices;

    function setUp() public {
        token = new MockERC20(6);
        invoices = new InvoicePayments(IERC20Minimal(address(token)));
        token.mint(payer, 1_000 * 1e6);
    }

    // ---------- helpers ----------

    function _due() internal view returns (uint64) {
        return uint64(block.timestamp + 7 days);
    }

    function _create() internal returns (uint256 id) {
        vm.prank(issuer);
        id = invoices.createInvoice(payer, AMOUNT, _due(), "INV-001");
    }

    function _approve(uint256 amount) internal {
        vm.prank(payer);
        token.approve(address(invoices), amount);
    }

    function assertEq(uint256 a, uint256 b, string memory what) internal pure {
        if (a != b) revert(string.concat("assertEq failed: ", what));
    }

    function assertEq(address a, address b, string memory what) internal pure {
        if (a != b) revert(string.concat("assertEq failed: ", what));
    }

    function assertTrue(bool cond, string memory what) internal pure {
        if (!cond) revert(string.concat("assertTrue failed: ", what));
    }

    // ---------- creation ----------

    function testCreateInvoiceStoresFieldsAndEmits() public {
        uint64 due = _due();
        vm.expectEmit(true, true, true, true);
        emit InvoiceCreated(1, issuer, payer, AMOUNT, due, "INV-001");

        vm.prank(issuer);
        uint256 id = invoices.createInvoice(payer, AMOUNT, due, "INV-001");

        assertEq(id, 1, "first id is 1");
        assertEq(invoices.invoiceCount(), 1, "count");

        InvoicePayments.Invoice memory inv = invoices.getInvoice(id);
        assertEq(inv.issuer, issuer, "issuer");
        assertEq(inv.payer, payer, "payer");
        assertEq(inv.amount, AMOUNT, "amount");
        assertEq(uint256(inv.dueDate), uint256(due), "dueDate");
        assertTrue(inv.status == InvoicePayments.Status.Pending, "status pending");
    }

    function testCreateInvoiceRejectsZeroPayer() public {
        vm.prank(issuer);
        vm.expectRevert(InvoicePayments.ZeroAddress.selector);
        invoices.createInvoice(address(0), AMOUNT, _due(), "x");
    }

    function testCreateInvoiceRejectsZeroAmount() public {
        vm.prank(issuer);
        vm.expectRevert(InvoicePayments.ZeroAmount.selector);
        invoices.createInvoice(payer, 0, _due(), "x");
    }

    function testCreateInvoiceRejectsSelfInvoice() public {
        vm.prank(issuer);
        vm.expectRevert(InvoicePayments.SelfInvoice.selector);
        invoices.createInvoice(issuer, AMOUNT, _due(), "x");
    }

    function testCreateInvoiceRejectsPastDueDate() public {
        vm.prank(issuer);
        vm.expectRevert(InvoicePayments.DueDateInPast.selector);
        invoices.createInvoice(payer, AMOUNT, uint64(block.timestamp), "x");
    }

    function testGetInvoiceRevertsForUnknownId() public {
        vm.expectRevert();
        invoices.getInvoice(42);
    }

    // ---------- payment ----------

    function testPayInvoiceHappyPath() public {
        uint256 id = _create();
        _approve(AMOUNT);

        vm.expectEmit(true, true, false, true);
        emit InvoicePaid(id, payer, AMOUNT, false);

        vm.prank(payer);
        invoices.payInvoice(id);

        assertEq(token.balanceOf(issuer), AMOUNT, "issuer received amount");
        assertEq(token.balanceOf(payer), 1_000 * 1e6 - AMOUNT, "payer balance reduced");
        InvoicePayments.Invoice memory inv = invoices.getInvoice(id);
        assertTrue(inv.status == InvoicePayments.Status.Paid, "status paid");
    }

    function testPayInvoiceWrongPayerReverts() public {
        uint256 id = _create();
        _approve(AMOUNT);

        vm.prank(stranger);
        vm.expectRevert();
        invoices.payInvoice(id);
    }

    function testPayInvoiceWithTooSmallApprovalReverts() public {
        // "Wrong amount" coverage: the payer approved less than the invoice
        // amount, so settlement must fail and the invoice stays pending.
        uint256 id = _create();
        _approve(AMOUNT - 1);

        vm.prank(payer);
        vm.expectRevert();
        invoices.payInvoice(id);

        InvoicePayments.Invoice memory inv = invoices.getInvoice(id);
        assertTrue(inv.status == InvoicePayments.Status.Pending, "still pending after failed pay");
    }

    function testPayInvoiceWithInsufficientBalanceReverts() public {
        uint256 id = _create();
        _approve(AMOUNT);

        // Drain the payer below the invoice amount.
        vm.prank(payer);
        token.transfer(stranger, 900 * 1e6);

        vm.prank(payer);
        vm.expectRevert();
        invoices.payInvoice(id);
    }

    function testPayInvoiceTwiceReverts() public {
        uint256 id = _create();
        _approve(AMOUNT * 2);

        vm.prank(payer);
        invoices.payInvoice(id);

        vm.prank(payer);
        vm.expectRevert();
        invoices.payInvoice(id);

        assertEq(token.balanceOf(issuer), AMOUNT, "issuer paid exactly once");
    }

    function testPayInvoiceLatePaymentIsFlagged() public {
        uint256 id = _create();
        _approve(AMOUNT);

        vm.warp(block.timestamp + 8 days); // one day past the 7-day due date

        vm.expectEmit(true, true, false, true);
        emit InvoicePaid(id, payer, AMOUNT, true);

        vm.prank(payer);
        invoices.payInvoice(id);
    }

    function testPayCancelledInvoiceReverts() public {
        uint256 id = _create();
        _approve(AMOUNT);

        vm.prank(issuer);
        invoices.cancelInvoice(id);

        vm.prank(payer);
        vm.expectRevert();
        invoices.payInvoice(id);
    }

    function testPayUnknownInvoiceReverts() public {
        vm.prank(payer);
        vm.expectRevert();
        invoices.payInvoice(99);
    }

    // ---------- cancellation ----------

    function testCancelInvoiceByIssuer() public {
        uint256 id = _create();

        vm.expectEmit(true, true, false, true);
        emit InvoiceCancelled(id, issuer);

        vm.prank(issuer);
        invoices.cancelInvoice(id);

        InvoicePayments.Invoice memory inv = invoices.getInvoice(id);
        assertTrue(inv.status == InvoicePayments.Status.Cancelled, "status cancelled");
    }

    function testCancelInvoiceByNonIssuerReverts() public {
        uint256 id = _create();

        vm.prank(payer);
        vm.expectRevert();
        invoices.cancelInvoice(id);
    }

    function testCancelInvoiceAfterPaymentReverts() public {
        uint256 id = _create();
        _approve(AMOUNT);

        vm.prank(payer);
        invoices.payInvoice(id);

        vm.prank(issuer);
        vm.expectRevert();
        invoices.cancelInvoice(id);
    }

    // ---------- reentrancy ----------

    function testReentrantTokenCannotDoublePay() public {
        ReentrantToken evil = new ReentrantToken();
        InvoicePayments guarded = new InvoicePayments(IERC20Minimal(address(evil)));
        evil.mint(payer, 1_000 * 1e6);

        vm.prank(issuer);
        uint256 id = guarded.createInvoice(payer, AMOUNT, _due(), "INV-EVIL");
        evil.arm(address(guarded), id);

        vm.prank(payer);
        evil.approve(address(guarded), AMOUNT);

        vm.prank(payer);
        guarded.payInvoice(id);

        assertTrue(evil.reentryAttempted(), "reentry was attempted");
        assertTrue(!evil.reentrySucceeded(), "reentry was blocked");
        assertEq(evil.balanceOf(issuer), AMOUNT, "issuer paid exactly once");
        InvoicePayments.Invoice memory inv = guarded.getInvoice(id);
        assertTrue(inv.status == InvoicePayments.Status.Paid, "status paid once");
    }
}
