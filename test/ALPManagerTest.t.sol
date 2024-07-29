// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import {ALPManager, IPoolAddressesProvider, IPool} from "src/ALPManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ALPManagerTest is Test {
    // system under test
    ALPManager public sut;

    address constant AAVE_POOL_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address constant WHALE = 0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503;

    IERC20 wethToken;
    IERC20 usdcToken;
    IERC20 daiToken;
    IERC20 aWethToken;

    uint256 constant INITIAL_COLLATERAL = 2 ether;
    uint256 constant LEVERAGE = 15000; // 1.5x leverage

    function setUp() public {
        vm.createSelectFork(vm.rpcUrl("mainnet"), 20409456);

        sut = new ALPManager(AAVE_POOL_ADDRESSES_PROVIDER, UNISWAP_V2_ROUTER);

        wethToken = IERC20(WETH);
        usdcToken = IERC20(USDC);
        daiToken = IERC20(DAI);

        aWethToken = IERC20(
            IPool(IPoolAddressesProvider(AAVE_POOL_ADDRESSES_PROVIDER).getPool()).getReserveData(WETH).aTokenAddress
        );

        deal(WETH, address(this), 10 ether);
        deal(USDC, address(this), 10000 * 1e6);
        deal(DAI, address(this), 10000 ether);

        wethToken.approve(address(sut), type(uint256).max);
        usdcToken.approve(address(sut), type(uint256).max);
        daiToken.approve(address(sut), type(uint256).max);
    }

    function testCreatePosition_ShouldCreatePosition() public {
        uint256 positionId = sut.createPosition(WETH, USDC, INITIAL_COLLATERAL, LEVERAGE);
        assertGt(positionId, 0, "Position not created");

        (address owner, address collateralAsset, address debtAsset, uint256 collateralAmount, uint256 debtAmount) =
            sut.positions(positionId);

        assertEq(owner, address(this), "Position owner should be this contract");
        assertEq(collateralAsset, WETH, "Collateral asset == WETH");
        assertEq(debtAsset, USDC, "Debt asset == USDC");
        assertGt(collateralAmount, INITIAL_COLLATERAL, "Final col. must be greater than initial");
        assertGt(debtAmount, 0, "Debt amount > 0");
    }

    function testMaxSafeLeverage_ShouldCreateSafePosition() public {
        uint256 maxSafeLeverage = sut.calculateMaxSafeLeverage(WETH);
        assertGt(maxSafeLeverage, 10000, "Max safe leverage > 1x");

        uint256 safeLeverageFactor = maxSafeLeverage * 99 / 100; // 99% of max safe leverage
        uint256 positionId = sut.createPosition(WETH, USDC, INITIAL_COLLATERAL, safeLeverageFactor);
        assertGt(positionId, 0, "position should be created");
    }

    function testMaxSafeLeverage_ShouldRevertOnUnsafeLeverage() public {
        uint256 maxSafeLeverage = sut.calculateMaxSafeLeverage(WETH);
        uint256 unsafeLeverageFactor = maxSafeLeverage * 101 / 100; // 101% of max safe leverage
        vm.expectRevert(ALPManager.LeverageExceedsMaxSafe.selector);
        sut.createPosition(WETH, USDC, INITIAL_COLLATERAL, unsafeLeverageFactor);
    }

    function testGetRate_ShouldReturnValidRate() public {
        uint256 amount = 1 ether;
        uint256 rate = sut.getRate(WETH, USDC, amount);
        assertGt(rate, 0, "Exchange rate should be greater than 0");

        rate = sut.getRate(WETH, WETH, amount);
        assertEq(rate, amount, "Exchange rate for same asset should be 1:1");
    }

    function testGetRate_ShouldRevertOnInvalidPriceData() public {
        uint256 amount = 1 ether;
        uint256[] memory prices = new uint256[](2);
        prices[0] = 0;
        prices[1] = 0;
        vm.mockCall(
            address(IPoolAddressesProvider(sut.ADDRESSES_PROVIDER()).getPriceOracle()),
            abi.encodeWithSignature("getAssetsPrices(address[])"),
            abi.encode(prices)
        );
        vm.expectRevert(ALPManager.InvalidPriceData.selector);
        sut.getRate(WETH, USDC, amount);
    }

    function testMultipleCollaterals_ShouldCreateUniquePositions() public {
        uint256 positionId1 = sut.createPosition(WETH, USDC, INITIAL_COLLATERAL, LEVERAGE);
        uint256 positionId2 = sut.createPosition(DAI, USDC, 1000 * 1e18, LEVERAGE);

        assertGt(positionId1, 0, "WETH position should be created");
        assertGt(positionId2, 0, "DAI position should be created");
        assertNotEq(positionId1, positionId2, "Position IDs should be unique");
    }

    function testInvalidLeverageFactor_ShouldRevert() public {
        vm.expectRevert(ALPManager.InvalidLeverageFactor.selector);
        sut.createPosition(WETH, USDC, INITIAL_COLLATERAL, 9999); // Less than 1x leverage
    }

    function testUnsupportedAssets_ShouldRevert() public {
        address UNSUPPORTED_TOKEN = address(0x1234);
        vm.expectRevert(ALPManager.UnsupportedCollateralAsset.selector);
        sut.createPosition(UNSUPPORTED_TOKEN, USDC, INITIAL_COLLATERAL, 10000);

        vm.expectRevert(ALPManager.UnsupportedDebtAsset.selector);
        sut.createPosition(WETH, UNSUPPORTED_TOKEN, INITIAL_COLLATERAL, 10000);
    }

    function testGetPositionHealth_ShouldReturnValidHealthFactor() public {
        uint256 positionId = sut.createPosition(WETH, USDC, INITIAL_COLLATERAL, LEVERAGE);
        uint256 healthFactor = sut.getPositionHealth(positionId);
        assertGt(healthFactor, 1e18, "Health factor should be greater than 1");
    }
}
