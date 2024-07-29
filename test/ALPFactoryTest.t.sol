// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {ALPFactory} from "src/ALPFactory.sol";
import {ALP} from "src/ALP.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ALPFactoryTest is Test {
    ALPFactory public factory;

    address constant AAVE_POOL_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    IERC20 wethToken;
    IERC20 usdcToken;
    IERC20 daiToken;

    uint256 constant LEVERAGE = 15000; // 1.5x leverage
    uint256 constant PRECISION = 1e4;

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 20409456);

        factory = new ALPFactory();

        wethToken = IERC20(WETH);
        usdcToken = IERC20(USDC);
        daiToken = IERC20(DAI);

        deal(WETH, address(this), 10 ether);
        deal(USDC, address(this), 10000 * 1e6);
        deal(DAI, address(this), 10000 ether);

        wethToken.approve(address(factory), type(uint256).max);
        usdcToken.approve(address(factory), type(uint256).max);
        daiToken.approve(address(factory), type(uint256).max);
    }

    function testCreateALP_ShouldCreateALP() public {
        ALPFactory.CollateralInput[] memory collaterals = new ALPFactory.CollateralInput[](2);
        collaterals[0] = ALPFactory.CollateralInput(WETH, 1 ether);
        collaterals[1] = ALPFactory.CollateralInput(DAI, 1000 ether);

        address alp = factory.createALP(collaterals, USDC, LEVERAGE);
        assertNotEq(alp, address(0), "ALP not created");

        assertEq(factory.getALPOwner(alp), address(this), "ALP owner == address(this)");

        address[] memory userALPs = factory.getUserALPs(address(this));
        assertEq(userALPs.length, 1, "Should have 1 ALP");
        assertEq(userALPs[0], alp, "ALP address should match");

        (
            address owner,
            address[] memory retCollateralAssets,
            uint256[] memory retCollateralAmounts,
            address debtAsset,
            uint256 debtAmount
        ) = factory.getALPLoanDetails(alp);

        assertEq(owner, address(this), "Owner should match");
        assertEq(retCollateralAssets.length, 2, "Should have 2 collateral assets");
        assertEq(retCollateralAssets[0], WETH, "1st collateral asset == WETH");
        assertEq(retCollateralAssets[1], DAI, "2nd collateral asset == DAI");
        assertGt(retCollateralAmounts[0], 1 ether, "WETH collateral++");
        assertGt(retCollateralAmounts[1], 1000 ether, "DAI collateral++");
        assertEq(debtAsset, USDC, "Debt asset == USDC");
        assertGt(debtAmount, 0, "Debt > 0");
    }

    function testCreate_MultipleALPs() public {
        ALPFactory.CollateralInput[] memory collaterals1 = new ALPFactory.CollateralInput[](1);
        collaterals1[0] = ALPFactory.CollateralInput(WETH, 1 ether);

        ALPFactory.CollateralInput[] memory collaterals2 = new ALPFactory.CollateralInput[](1);
        collaterals2[0] = ALPFactory.CollateralInput(DAI, 1000 ether);

        address alp1 = factory.createALP(collaterals1, USDC, LEVERAGE);
        address alp2 = factory.createALP(collaterals2, USDC, LEVERAGE);

        assertNotEq(alp1, alp2, "ALPs should be different");

        address[] memory userALPs = factory.getUserALPs(address(this));
        assertEq(userALPs.length, 2, "Should have 2 ALPs");
        assertEq(userALPs[0], alp1, "First ALP should match");
        assertEq(userALPs[1], alp2, "Second ALP should match");
    }

    function testCreateALP_Details() public {
        ALPFactory.CollateralInput[] memory collaterals = new ALPFactory.CollateralInput[](2);
        collaterals[0] = ALPFactory.CollateralInput(WETH, 1 ether);
        collaterals[1] = ALPFactory.CollateralInput(DAI, 1000 ether);

        address alp = factory.createALP(collaterals, USDC, LEVERAGE);

        (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        ) = ALP(alp).getDetailedPositionData();

        assertGt(totalCollateralETH, 0, "Total collateral > 0");
        assertGt(totalDebtETH, 0, "Total debt > 0");
        assertGt(availableBorrowsETH, 0, "Available borrows > 0");
        assertGt(currentLiquidationThreshold, 0, "Liquidation threshold > 0");
        assertGt(ltv, 0, "LTV > 0");
        assertGt(healthFactor, 1e18, "Health factor > 1");
    }

    // Since the default error code will be `Create2FailedDeployment()` adding a generic revert
    // Run test with -vvvv to see the actual revert reason
    function testFail_InvalidLeverageFactor() public {
        ALPFactory.CollateralInput[] memory collaterals = new ALPFactory.CollateralInput[](1);
        collaterals[0] = ALPFactory.CollateralInput(WETH, 1 ether);

        factory.createALP(collaterals, USDC, 9999); // Less than 1x leverage
    }

    // Since the default error code will be `Create2FailedDeployment()` adding a generic revert
    // Run test with -vvvv to see the actual revert reason
    function testFail_UnsupportedCollateralAsset() public {
        ALPFactory.CollateralInput[] memory collaterals = new ALPFactory.CollateralInput[](1);

        address UNSUPPORTED_TOKEN = address(0x1234);
        collaterals[0] = ALPFactory.CollateralInput(UNSUPPORTED_TOKEN, 1 ether);
        vm.expectRevert(ALP.UnsupportedCollateralAsset.selector);
        factory.createALP(collaterals, USDC, 10000);
    }

    function testFail_UnsupportedDebtAsset() public {
        ALPFactory.CollateralInput[] memory collaterals = new ALPFactory.CollateralInput[](1);

        address UNSUPPORTED_TOKEN = address(0x1234);

        collaterals[0] = ALPFactory.CollateralInput(WETH, 1 ether);
        vm.expectRevert(ALP.UnsupportedDebtAsset.selector);
        factory.createALP(collaterals, UNSUPPORTED_TOKEN, 10000);
    }

    function testFail_MaxSafeLeverage() public {
        ALPFactory.CollateralInput[] memory collaterals = new ALPFactory.CollateralInput[](2);
        collaterals[0] = ALPFactory.CollateralInput(WETH, 1 ether);
        collaterals[1] = ALPFactory.CollateralInput(DAI, 1000 ether);

        address alp = factory.createALP(collaterals, USDC, LEVERAGE);

        address[] memory assets = new address[](2);
        assets[0] = WETH;
        assets[1] = DAI;
        uint256 maxSafeLeverage = ALP(alp).calculateMaxSafeLeverage(assets);

        uint256 unsafeLeverageFactor = maxSafeLeverage + 1;
        vm.expectRevert(ALP.LeverageExceedsMaxSafe.selector);
        factory.createALP(collaterals, USDC, unsafeLeverageFactor);
    }

    function testCreateALP_ValidateLeverage() public {
        // Test different leverage values
        uint256[] memory leverageValues = new uint256[](3);
        leverageValues[0] = 12000; // 1.2x leverage
        leverageValues[1] = 15000; // 1.5x leverage
        leverageValues[2] = 16250; // 1.625x leverage

        for (uint256 i = 0; i < leverageValues.length; i++) {
            uint256 targetLeverage = leverageValues[i];

            ALPFactory.CollateralInput[] memory collaterals = new ALPFactory.CollateralInput[](2);
            collaterals[0] = ALPFactory.CollateralInput(WETH, 1 ether);
            collaterals[1] = ALPFactory.CollateralInput(DAI, 1000 ether);

            address alpAddress = factory.createALP(collaterals, USDC, targetLeverage);
            ALP alp = ALP(alpAddress);

            (uint256 totalCollateralETH, uint256 totalDebtETH,,,, uint256 healthFactor) = alp.getDetailedPositionData();

            // Calculate actual leverage
            uint256 actualLeverage = (totalCollateralETH * PRECISION) / (totalCollateralETH - totalDebtETH);

            // Check if actual leverage is close to target leverage
            assertApproxEqRel(actualLeverage, targetLeverage, 0.01e18, "Leverage should be close to target");

            // Additional checks
            assertGt(healthFactor, 1e18, "Health factor should be above 1");

            // Validate position details
            (, address[] memory posCollateralAssets,,,) = alp.getPosition();

            // Calculate and check LTV
            uint256 currentLTV = (totalDebtETH * PRECISION) / totalCollateralETH;
            uint256 maxLTV = alp.calculateMaxSafeLeverage(posCollateralAssets) - PRECISION;
            assertLt(currentLTV, maxLTV, "Current LTV should be below max LTV");

            console.log("Target Leverage:", targetLeverage);
            console.log("Actual Leverage:", actualLeverage);
            console.log("Health Factor:", healthFactor / 1e14);
            console.log("Current LTV:", currentLTV);
            console.log("Max LTV:", maxLTV);
            console.log("");
        }
    }
}
