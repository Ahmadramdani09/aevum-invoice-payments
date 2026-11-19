// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockERC20
/// @notice Test-only ERC-20 with configurable decimals and a public mint.
///         Mirrors tUSD8's shape (6 decimals) without any network dependency.
contract MockERC20 {
    string public name = "Mock USD8";
    string public symbol = "mUSD8";
    uint8 public immutable decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external virtual returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "MockERC20: allowance too low");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "MockERC20: balance too low");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @title ReentrantToken
/// @notice Test-only token that tries to re-enter `payInvoice` from inside
///         `transferFrom`. Records whether the re-entry succeeded so the test
///         can prove the invoice contract's guard blocked it.
contract ReentrantToken is MockERC20 {
    address public target;
    uint256 public targetInvoiceId;
    bool public reentryAttempted;
    bool public reentrySucceeded;

    constructor() MockERC20(6) {}

    function arm(address target_, uint256 invoiceId) external {
        target = target_;
        targetInvoiceId = invoiceId;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        if (target != address(0) && !reentryAttempted) {
            reentryAttempted = true;
            // Low-level call so a revert inside does not bubble up.
            (bool ok,) = target.call(abi.encodeWithSignature("payInvoice(uint256)", targetInvoiceId));
            reentrySucceeded = ok;
        }
        // Settle the outer transfer like a normal token.
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "ReentrantToken: allowance too low");
        allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }
}
