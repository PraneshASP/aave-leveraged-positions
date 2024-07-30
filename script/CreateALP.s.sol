// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import "forge-std/Script.sol";
import {ALPFactory} from "../src/ALPFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CreateALP is Script {
    // Replace with your deployed ALPFactory address
    address constant ALP_FACTORY_ADDRESS = 0x8896Dce0E60a706244553ADA1aAc5CDCc40a0428;

    // Example parameters (replace with actual values)
    address constant COLLATERAL_TOKEN = address(0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2); // WETH
    address constant DEBT_TOKEN = address(0x6B175474E89094C44Da98b954EedeAC495271d0F); // DAI
    uint256 constant COLLATERAL_AMOUNT = 1 ether;
    uint256 constant LEVERAGE_FACTOR = 1.35 * 1e4; // 1.35x leverage
    bool constant IS_DEGEN_MODE = false;

    function setUp() public {}

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        ALPFactory alpFactory = ALPFactory(ALP_FACTORY_ADDRESS);

        // Approve tokens
        IERC20(COLLATERAL_TOKEN).approve(ALP_FACTORY_ADDRESS, COLLATERAL_AMOUNT);

        // Create collateral input array
        ALPFactory.CollateralInput[] memory collateralInputs = new ALPFactory.CollateralInput[](1);
        collateralInputs[0] = ALPFactory.CollateralInput({asset: COLLATERAL_TOKEN, amount: COLLATERAL_AMOUNT});

        // Create ALP
        address alp = alpFactory.createALP(collateralInputs, DEBT_TOKEN, LEVERAGE_FACTOR, IS_DEGEN_MODE);

        console.log("ALP created at:", alp);

        vm.stopBroadcast();
    }
}
