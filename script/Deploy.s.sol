// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {InvoicePayments} from "../src/InvoicePayments.sol";
import {IERC20Minimal} from "../src/IERC20Minimal.sol";

/// @notice Minimal broadcast cheatcodes, declared locally so the project has
///         zero external dependencies (no forge-std required).
interface BroadcastVm {
    function startBroadcast() external;
    function stopBroadcast() external;
}

/// @title Deploy
/// @notice Deploys InvoicePayments against the pre-deployed tUSD8 token on
///         Aevum Testnet (chain id 44005).
/// @dev NOT run yet — deployment is a separate, later step that first needs
///      the deployer wallet funded with tQDAY from the faucet.
///      When ready:
///        forge script script/Deploy.s.sol:Deploy \
///          --rpc-url aevum_testnet --broadcast \
///          --private-key $(cat .keys/deployer.key)
contract Deploy {
    BroadcastVm internal constant vm = BroadcastVm(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

    /// @notice tUSD8 on Aevum Testnet (pre-deployed ERC-20, 6 decimals).
    address internal constant TUSD8 = 0x456569838f1d43009A91ebA4263147Afd7233483;

    function run() external returns (InvoicePayments deployed) {
        vm.startBroadcast();
        deployed = new InvoicePayments(IERC20Minimal(TUSD8));
        vm.stopBroadcast();
    }
}
