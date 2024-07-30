// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol";
import "../src/ALP.sol";
import "../src/ALPFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ALPForkTest is Test {
    ALPFactory public factory;
    ALP public alp;
    address public constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address public constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    address public constant POOL_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;

    address public user = address(1);
    uint256 public constant INITIAL_BALANCE = 1000 * 1e18; // 1000 ETH
    uint256 public constant INITIAL_COLLATERAL = 10 * 1e18; // 10 ETH
    uint256 public constant LEVERAGE_FACTOR = 15000; // 1.5x leverage

    function setUp() public {
        // Fork Ethereum mainnet
        vm.createSelectFork(vm.rpcUrl("mainnet"), 20409456);

        // Deploy ALPFactory
        factory = new ALPFactory();

        // Setup user with initial balance
        deal(WETH, user, INITIAL_BALANCE);
        deal(USDC, user, INITIAL_BALANCE);
        deal(DAI, user, INITIAL_BALANCE);

        // Approve ALPFactory to spend user's tokens
        vm.startPrank(user);
        IERC20(WETH).approve(address(factory), type(uint256).max);
        IERC20(USDC).approve(address(factory), type(uint256).max);
        IERC20(DAI).approve(address(factory), type(uint256).max);

        // Create ALP using factory
        ALPFactory.CollateralInput[] memory collaterals = new ALPFactory.CollateralInput[](1);
        collaterals[0] = ALPFactory.CollateralInput({asset: WETH, amount: INITIAL_COLLATERAL});

        address alpAddress = factory.createALP(collaterals, USDC, LEVERAGE_FACTOR, false);
        alp = ALP(alpAddress);

        vm.stopPrank();
    }

    function test_addCollateral_WETH() public {
        uint256 additionalCollateral = 5 * 1e18; // 5 WETH

        vm.startPrank(user);
        IERC20(WETH).approve(address(alp), additionalCollateral);

        uint256 userBalanceBefore = IERC20(WETH).balanceOf(user);
        (uint256 totalCollateralBefore,,,,,) = alp.getDetailedPositionData();

        alp.addCollateral(WETH, additionalCollateral);

        uint256 userBalanceAfter = IERC20(WETH).balanceOf(user);
        (uint256 totalCollateralAfter,,,,,) = alp.getDetailedPositionData();

        assertEq(userBalanceBefore - userBalanceAfter, additionalCollateral, "User balance ~ decrease");
        assertGt(totalCollateralAfter, totalCollateralBefore, "Total collateral ~ increase");

        vm.stopPrank();
    }

    function test_addCollateral_NewAsset() public {
        uint256 additionalCollateral = 1000 * 1e18; // 1000 DAI

        vm.startPrank(user);
        IERC20(DAI).approve(address(alp), additionalCollateral);

        uint256 userBalanceBefore = IERC20(DAI).balanceOf(user);
        (uint256 totalCollateralBefore,,,,,) = alp.getDetailedPositionData();

        alp.addCollateral(DAI, additionalCollateral);

        uint256 userBalanceAfter = IERC20(DAI).balanceOf(user);
        (uint256 totalCollateralAfter,,,,,) = alp.getDetailedPositionData();

        assertEq(userBalanceBefore - userBalanceAfter, additionalCollateral, "User balance ~ decrease");
        assertGt(totalCollateralAfter, totalCollateralBefore, "Total collateral ~ increase");

        vm.stopPrank();
    }

    function test_addCollateral_FailInvalidAsset() public {
        address invalidAsset = address(0x123); // Some random address
        uint256 additionalCollateral = 1 * 1e18;

        vm.startPrank(user);

        vm.expectRevert(ALP.InvalidCollateralAsset.selector);
        alp.addCollateral(invalidAsset, additionalCollateral);

        vm.stopPrank();
    }

    function test_addCollateral_FailNotOwner() public {
        address notOwner = address(0x456);
        uint256 additionalCollateral = 1 * 1e18;

        vm.startPrank(notOwner);

        vm.expectRevert(ALP.OnlyOwner.selector);
        alp.addCollateral(WETH, additionalCollateral);

        vm.stopPrank();
    }

    function test_addCollateral_EmitEvent() public {
        uint256 additionalCollateral = 5 * 1e18; // 5 WETH

        vm.startPrank(user);
        IERC20(WETH).approve(address(alp), additionalCollateral);

        vm.expectEmit(true, false, false, true);
        emit ALP.CollateralAdded(WETH, additionalCollateral);

        alp.addCollateral(WETH, additionalCollateral);

        vm.stopPrank();
    }

    function test_repayDebt() public {
        vm.startPrank(user);

        (,,, address debtAsset, uint256 initialDebtAmount) = alp.getPosition();

        uint256 repaymentAmount = initialDebtAmount / 2;

        deal(USDC, user, repaymentAmount);
        IERC20(USDC).approve(address(alp), repaymentAmount);

        // Get initial balances and position data
        uint256 userBalanceBefore = IERC20(USDC).balanceOf(user);
        (uint256 totalCollateralBefore, uint256 totalDebtBefore,,,,) = alp.getDetailedPositionData();

        // Repay debt
        alp.repayDebt(repaymentAmount);

        uint256 userBalanceAfter = IERC20(USDC).balanceOf(user);
        (uint256 totalCollateralAfter, uint256 totalDebtAfter,,,,) = alp.getDetailedPositionData();
        (,,, address finalDebtAsset, uint256 finalDebtAmount) = alp.getPosition();

        assertEq(
            userBalanceBefore - userBalanceAfter, repaymentAmount, "User balance should decrease by repayment amount"
        );
        assertEq(
            initialDebtAmount - finalDebtAmount, repaymentAmount, "Debt amount should decrease by repayment amount"
        );
        assertEq(totalCollateralBefore, totalCollateralAfter, "Total collateral should not change");
        assertLt(totalDebtAfter, totalDebtBefore, "Total debt should decrease");

        vm.stopPrank();
    }

    function testRepayDebt_ExcessiveRepayment() public {
        vm.startPrank(user);

        (,,,, uint256 debtAmount) = alp.getPosition();
        uint256 excessiveRepaymentAmount = debtAmount + 1 ether;

        deal(USDC, user, excessiveRepaymentAmount);
        IERC20(USDC).approve(address(alp), excessiveRepaymentAmount);

        vm.expectRevert(ALP.ExcessRepayment.selector);
        alp.repayDebt(excessiveRepaymentAmount);

        vm.stopPrank();
    }

    function testRepayDebt_NotOwner() public {
        address notOwner = address(0x456);
        vm.startPrank(notOwner);

        (,,,, uint256 debtAmount) = alp.getPosition();
        uint256 repaymentAmount = debtAmount / 2;

        vm.expectRevert(ALP.OnlyOwner.selector);
        alp.repayDebt(repaymentAmount);

        vm.stopPrank();
    }
}
