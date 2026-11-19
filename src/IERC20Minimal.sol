// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Minimal ERC-20 interface
/// @notice Only the functions the invoice contract needs. Using a local
///         interface keeps the project free of external dependencies.
interface IERC20Minimal {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function decimals() external view returns (uint8);
}
