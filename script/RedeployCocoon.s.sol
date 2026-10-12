// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SeaportInterface} from "seaport-types/src/interfaces/SeaportInterface.sol";
import {Cocoon} from "../src/Cocoon.sol";
import {FloorFeed} from "../src/FloorFeed.sol";
import {IERC20Minimal} from "../src/interfaces/IERC20Minimal.sol";
import {IERC721Minimal} from "../src/interfaces/IERC721Minimal.sol";

/// @notice A new Cocoon beside a FloorFeed and a timelock that already exist. The hook is deployed by
/// the launch and takes the vault as a constructor argument, so until the launch a corrected vault
/// simply takes the place of the one `DeployPreLaunch` deployed; nothing else has to move. The vault
/// it replaces holds nothing and is left alone.
///
/// Environment, as for `DeployPreLaunch`: DEVELOPER, OPERATOR, COLLECTION, POOL_MANAGER, IMD, SEAPORT
/// (optional), and
///   FEED      the FloorFeed already deployed
///   EXPECTED  optional: the address the new Cocoon must land on. The launch manifest and the launch
///             request name the vault before it exists, as the deployer's next contract address. If
///             the deployer's nonce has moved since, the script stops in simulation and sends nothing.
contract RedeployCocoon is Script {
    error UnexpectedAddress(address next, address expected);

    function run() external {
        address developer = vm.envAddress("DEVELOPER");
        address operator = vm.envAddress("OPERATOR");
        address collection = vm.envAddress("COLLECTION");
        address poolManager = vm.envAddress("POOL_MANAGER");
        address imd = vm.envAddress("IMD");
        address feed = vm.envAddress("FEED");
        address seaport = vm.envOr("SEAPORT", address(0x0000000000000068F116a894984e2DB1123eB395));
        address expected = vm.envOr("EXPECTED", address(0));

        vm.startBroadcast();
        address deployer = msg.sender;
        if (expected != address(0)) {
            address next = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
            if (next != expected) revert UnexpectedAddress(next, expected);
        }
        Cocoon cocoon = new Cocoon(
            deployer,
            developer,
            operator,
            IERC721Minimal(collection),
            SeaportInterface(seaport),
            IPoolManager(poolManager),
            FloorFeed(feed),
            IERC20Minimal(imd)
        );
        vm.stopBroadcast();

        console2.log("Cocoon            ", address(cocoon));
        console2.log("FloorFeed (kept)  ", feed);
        console2.log("The launch manifest must name this Cocoon as the hook's sink.");
    }
}
