// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../src/ALP.sol";
import "../src/ALPFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ALPMaxLeverageTest is Test {
    ALPFactory public factory;
    ALP public alp;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant POOL_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;

    address public user = address(1);
    uint256 public constant INITIAL_BALANCE = 1000 ether; // 1000 ETH
    uint256 public constant INITIAL_COLLATERAL = 1 ether; // 1 ETH
    uint256 public constant LEVERAGE_FACTOR = 40000; // 4x :O

    function setUp() public {
        // Fork Ethereum mainnet
        vm.createSelectFork(vm.rpcUrl("mainnet"), 20409456);

        // Deploy ALPFactory
        factory = new ALPFactory();

        // Setup user with initial balance
        deal(WETH, user, INITIAL_BALANCE);
        deal(USDC, user, INITIAL_BALANCE);

        // Approve ALPFactory to spend user's tokens
        vm.startPrank(user);
        IERC20(WETH).approve(address(factory), type(uint256).max);
        IERC20(USDC).approve(address(factory), type(uint256).max);
        vm.stopPrank();
    }

    function test_createMaxLeveragePosition() public {
        vm.startPrank(user);

        ALPFactory.CollateralInput[] memory collaterals = new ALPFactory.CollateralInput[](1);
        collaterals[0] = ALPFactory.CollateralInput({asset: WETH, amount: INITIAL_COLLATERAL});

        address alpAddress = factory.createALP(collaterals, USDC, LEVERAGE_FACTOR, true);
        alp = ALP(alpAddress);

        (
            address owner,
            address[] memory collateralAssets,
            uint256[] memory collateralAmounts,
            address debtAsset,
            uint256 debtAmount
        ) = alp.getPosition();

        assertEq(collateralAssets.length, 1, "assets.length = 1");
        assertEq(collateralAssets[0], WETH, "Collateral is WETH");
        assertGt(collateralAmounts[0], INITIAL_COLLATERAL, "Collateral > initial");
        assertEq(debtAsset, USDC, "Debt is USDC");
        assertGt(debtAmount, 0, "Debt > 0");

        // Check detailed position data
        (uint256 totalCollateral, uint256 totalDebt,,,, uint256 healthFactor) = alp.getDetailedPositionData();

        assertGt(healthFactor, 1.05e18, "Health > 1.05");

        // Calculate actual leverage
        uint256 actualLeverage = (totalCollateral * 1e4) / (totalCollateral - totalDebt);

        assertApproxEqAbs(actualLeverage, LEVERAGE_FACTOR, 5000, "Leverage == Expected");

        vm.stopPrank();
    }

    // use -vvv flag to see the actual revert reason
    // verified manually

    function testFail_createMaxLeveragePosition_FailMultipleCollaterals() public {
        vm.startPrank(user);

        ALPFactory.CollateralInput[] memory collaterals = new ALPFactory.CollateralInput[](2);
        collaterals[0] = ALPFactory.CollateralInput({asset: WETH, amount: INITIAL_COLLATERAL});
        collaterals[1] = ALPFactory.CollateralInput({asset: USDC, amount: INITIAL_COLLATERAL});

        vm.expectRevert(ALP.InvalidCollateralCount.selector);
        factory.createALP(collaterals, USDC, LEVERAGE_FACTOR, true);

        vm.stopPrank();
    }

    function testFail_createMaxLeveragePosition_FailIdenticalAssets() public {
        vm.startPrank(user);

        ALPFactory.CollateralInput[] memory collaterals = new ALPFactory.CollateralInput[](1);
        collaterals[0] = ALPFactory.CollateralInput({asset: WETH, amount: INITIAL_COLLATERAL});

        vm.expectRevert(ALP.IdenticalAssets.selector);
        factory.createALP(collaterals, WETH, LEVERAGE_FACTOR, true);

        vm.stopPrank();
    }

    function test_closePosition_Degen() public {
        vm.startPrank(user);

        ALPFactory.CollateralInput[] memory collaterals = new ALPFactory.CollateralInput[](1);
        collaterals[0] = ALPFactory.CollateralInput({asset: WETH, amount: INITIAL_COLLATERAL});

        address alpAddress = factory.createALP(collaterals, USDC, LEVERAGE_FACTOR, true);
        alp = ALP(alpAddress);
        // Get initial position data and user balances
        (, address[] memory collateralAssets,, address debtAsset,) = alp.getPosition();

        uint256[] memory userBalancesBefore = new uint256[](collateralAssets.length);
        for (uint256 i = 0; i < collateralAssets.length; i++) {
            userBalancesBefore[i] = IERC20(collateralAssets[i]).balanceOf(user);
            console.log("Initial balance of", collateralAssets[i], ":", userBalancesBefore[i]);
        }
        uint256 userDebtAssetBalanceBefore = IERC20(debtAsset).balanceOf(user);
        console.log("Initial debt asset balance:", userDebtAssetBalanceBefore);

        (uint256 totalCollateralBefore, uint256 totalDebtBefore,,,,) = alp.getDetailedPositionData();
        console.log("Total collateral before:", totalCollateralBefore);
        console.log("Total debt before:", totalDebtBefore);

        // Close the position
        IERC20(USDC).approve(address(alp), 20000e6);
        console.log("Approved USDC for closing position");

        alp.closePosition();
        console.log("Position closed");

        // Check user balances after closing position
        for (uint256 i = 0; i < collateralAssets.length; i++) {
            uint256 userBalanceAfter = IERC20(collateralAssets[i]).balanceOf(user);
            console.log("Final balance of", collateralAssets[i], ":", userBalanceAfter);
            assertGt(userBalanceAfter, userBalancesBefore[i], "Collateral not returned");
        }

        // Check that the position is closed
        (
            address newOwner,
            address[] memory newCollateralAssets,
            uint256[] memory newCollateralAmounts,
            address newDebtAsset,
            uint256 newDebtAmount
        ) = alp.getPosition();

        assertEq(newOwner, address(0), "Owner not zero");
        assertEq(newCollateralAssets.length, 0, "Collateral assets not empty");
        assertEq(newCollateralAmounts.length, 0, "Collateral amounts not empty");
        assertEq(newDebtAsset, address(0), "Debt asset not zero");
        assertEq(newDebtAmount, 0, "Debt amount not zero");

        // Check detailed position data
        (uint256 totalCollateralAfter, uint256 totalDebtAfter,,,,) = alp.getDetailedPositionData();
        console.log("Total collateral after:", totalCollateralAfter);
        console.log("Total debt after:", totalDebtAfter);

        assertEq(totalCollateralAfter, 0, "Collateral not zero");
        assertEq(totalDebtAfter, 0, "Debt not zero");

        // Verify that the debt has been repaid
        uint256 userDebtAssetBalanceAfter = IERC20(debtAsset).balanceOf(user);
        assertLe(userDebtAssetBalanceAfter, userDebtAssetBalanceBefore, "Debt not repaid");

        vm.stopPrank();
    }
}
