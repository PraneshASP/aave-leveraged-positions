// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import {ALPFactory} from "../src/ALPFactory.sol";

contract DeployALPFactory is Script {
    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        ALPFactory alpFactory = new ALPFactory();

        console.log("ALPFactory deployed to:", address(alpFactory));

        vm.stopBroadcast();
    }
}
