// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {IPool} from "@aave/core-v3/contracts/interfaces/IPool.sol";
import {IPoolAddressesProvider} from "@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {DataTypes} from "@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol";
import {IUniswapV2Router} from "src/interfaces/IUniswapV2Router.sol";
import {ReserveConfiguration} from "@aave/core-v3/contracts/protocol/libraries/configuration/ReserveConfiguration.sol";
import {IAaveOracle} from "@aave/core-v3/contracts/interfaces/IAaveOracle.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title Aave Leveraged positions (ALP) Manager
/// @notice A contract for creating and managing leverged positions on Aave V3 pools

contract ALPManager is ReentrancyGuard {
    using SafeERC20 for IERC20Metadata;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    IPoolAddressesProvider public immutable ADDRESSES_PROVIDER;
    IPool public immutable POOL;
    IUniswapV2Router public immutable UNISWAP_ROUTER;

    uint256 private constant PRECISION = 1e4;

    struct Position {
        address owner;
        address collateralAsset;
        address debtAsset;
        uint256 collateralAmount;
        uint256 debtAmount;
    }

    mapping(uint256 => Position) public positions;
    uint256 public nextPositionId = 1;

    // Errors
    error InvalidLeverageFactor();
    error UnsupportedCollateralAsset();
    error UnsupportedDebtAsset();
    error LeverageExceedsMaxSafe();
    error PositionDoesNotExist();
    error InvalidPriceData();

    /// @notice Emitted when a new leveraged position is created
    event PositionCreated(
        uint256 indexed positionId,
        address indexed owner,
        address collateralAsset,
        address debtAsset,
        uint256 collateralAmount,
        uint256 debtAmount
    );

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address _addressesProvider, address _uniswapRouter) {
        ADDRESSES_PROVIDER = IPoolAddressesProvider(_addressesProvider);
        POOL = IPool(ADDRESSES_PROVIDER.getPool());
        UNISWAP_ROUTER = IUniswapV2Router(_uniswapRouter);
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL METHODS
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a leveraged position
    /// @param _collateralAsset Address of the collateral asset
    /// @param _debtAsset Address of the debt asset
    /// @param _collateralAmount Amount of collateral to supply
    /// @param _leverageFactor Desired leverage factor (e.g., 15000 for 1.5x)
    /// @return positionId Unique identifier for the created position
    function createPosition(
        address _collateralAsset,
        address _debtAsset,
        uint256 _collateralAmount,
        uint256 _leverageFactor
    ) external nonReentrant returns (uint256 positionId) {
        if (_leverageFactor < PRECISION) revert InvalidLeverageFactor();
        if (!_validateAssetInPool(_collateralAsset)) revert UnsupportedCollateralAsset();
        if (!_validateAssetInPool(_debtAsset)) revert UnsupportedDebtAsset();

        uint256 maxSafeLeverage = calculateMaxSafeLeverage(_collateralAsset);
        if (_leverageFactor > maxSafeLeverage) revert LeverageExceedsMaxSafe();

        IERC20Metadata(_collateralAsset).safeTransferFrom(msg.sender, address(this), _collateralAmount);
        IERC20Metadata(_collateralAsset).safeIncreaseAllowance(address(POOL), _collateralAmount);
        POOL.supply(_collateralAsset, _collateralAmount, address(this), 0);

        uint256 collateralDecimals = IERC20Metadata(_collateralAsset).decimals();
        uint256 debtDecimals = IERC20Metadata(_debtAsset).decimals();

        // Calculate the amount to borrow in collateral asset terms
        uint256 amountToBorrow = (_collateralAmount * (_leverageFactor - PRECISION)) / PRECISION;

        // Convert the borrow amount from collateral asset to debt asset, considering decimals
        uint256 amountToBorrowInDebtAsset = getRate(_collateralAsset, _debtAsset, amountToBorrow);

        // Adjust for decimal differences
        if (collateralDecimals > debtDecimals) {
            amountToBorrowInDebtAsset = amountToBorrowInDebtAsset / 10 ** (collateralDecimals - debtDecimals);
        } else if (collateralDecimals < debtDecimals) {
            amountToBorrowInDebtAsset = amountToBorrowInDebtAsset * 10 ** (debtDecimals - collateralDecimals);
        }

        POOL.borrow(_debtAsset, amountToBorrowInDebtAsset, 2, 0, address(this));

        IERC20Metadata(_debtAsset).safeIncreaseAllowance(address(UNISWAP_ROUTER), amountToBorrowInDebtAsset);
        uint256 additionalCollateral = _swapAssetsUniswap(_debtAsset, _collateralAsset, amountToBorrowInDebtAsset);

        IERC20Metadata(_collateralAsset).safeIncreaseAllowance(address(POOL), additionalCollateral);
        POOL.supply(_collateralAsset, additionalCollateral, address(this), 0);

        uint256 finalCollateral = _collateralAmount + additionalCollateral;
        positionId =
            _createPosition(msg.sender, _collateralAsset, _debtAsset, finalCollateral, amountToBorrowInDebtAsset);

        return positionId;
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW METHODS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculates exchange rate of the given asset using their price feeds
    /// @param _assetBase Address of the base asset
    /// @param _amount Address of the quote asset
    /// @param _amount Amount to convert
    /// @return The exchange rate
    function getRate(address _assetBase, address _assetQuote, uint256 _amount) public view returns (uint256) {
        if (_assetBase == _assetQuote) {
            return _amount;
        }

        IAaveOracle priceFeed = IAaveOracle(ADDRESSES_PROVIDER.getPriceOracle());

        address[] memory assets = new address[](2);
        assets[0] = _assetBase;
        assets[1] = _assetQuote;

        uint256[] memory prices = priceFeed.getAssetsPrices(assets);

        if (prices[0] <= 0 || prices[1] <= 0) revert InvalidPriceData();

        return (_amount * prices[0]) / prices[1];
    }

    /// @notice Gets the health factor of a position
    /// @param positionId Unique identifier of the position
    /// @return The health factor of the position
    function getPositionHealth(uint256 positionId) public view returns (uint256) {
        Position memory position = positions[positionId];
        if (position.owner == address(0)) revert PositionDoesNotExist();

        (,,,,, uint256 healthFactor) = POOL.getUserAccountData(address(this));
        return healthFactor;
    }

    /// @notice Gets detailed data about a position
    /// @param positionId Unique identifier of the position
    /// @return totalCollateralETH Total collateral in ETH
    /// @return totalDebtETH Total debt in ETH
    /// @return availableBorrowsETH Available borrows in ETH
    /// @return currentLiquidationThreshold Current liquidation threshold
    /// @return ltv Loan-to-Value ratio
    /// @return healthFactor Health factor of the position
    function getDetailedPositionData(uint256 positionId)
        public
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        Position memory position = positions[positionId];
        if (position.owner == address(0)) revert PositionDoesNotExist();

        return POOL.getUserAccountData(address(this));
    }

    /// @notice Calculates the maximum safe leverage for a given asset
    /// @param collateralAsset Address of the collateral asset
    /// @return The maximum safe leverage factor
    function calculateMaxSafeLeverage(address collateralAsset) public view returns (uint256) {
        DataTypes.ReserveConfigurationMap memory config = POOL.getConfiguration(collateralAsset);
        uint256 ltv = config.getLtv();
        uint256 ltvAdjusted = (ltv * PRECISION) / 10000;
        return PRECISION + ltvAdjusted;
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL METHODS
    //////////////////////////////////////////////////////////////*/

    /// @notice Swaps assets using UniswapV2
    /// @param _fromAsset Address of the asset to swap from
    /// @param _toAsset Address of the asset to swap to
    /// @param _amountIn Amount to swap
    /// @return The amount of _toAsset received
    function _swapAssetsUniswap(address _fromAsset, address _toAsset, uint256 _amountIn) internal returns (uint256) {
        IERC20Metadata(_fromAsset).safeIncreaseAllowance(address(UNISWAP_ROUTER), _amountIn);

        address[] memory path = new address[](2);
        path[0] = _fromAsset;
        path[1] = _toAsset;

        uint256[] memory amounts =
            UNISWAP_ROUTER.swapExactTokensForTokens(_amountIn, 0, path, address(this), block.timestamp);

        return amounts[1];
    }

    /// @notice Creates a new position
    /// @param user Address of the position owner
    /// @param collateralAsset Address of the collateral asset
    /// @param debtAsset Address of the debt asset
    /// @param collateralAmount Amount of collateral
    /// @param debtAmount Amount of debt
    /// @return The unique identifier of the created position
    function _createPosition(
        address user,
        address collateralAsset,
        address debtAsset,
        uint256 collateralAmount,
        uint256 debtAmount
    ) internal returns (uint256) {
        uint256 positionId = nextPositionId++;

        positions[positionId] = Position({
            owner: user,
            collateralAsset: collateralAsset,
            debtAsset: debtAsset,
            collateralAmount: collateralAmount,
            debtAmount: debtAmount
        });

        emit PositionCreated(positionId, user, collateralAsset, debtAsset, collateralAmount, debtAmount);

        return positionId;
    }

    /// @notice Validates if an asset exists in the Aave pool
    /// @param _asset Address of the asset to validate
    /// @return bool True if the asset exists in the pool, false otherwise
    function _validateAssetInPool(address _asset) internal view returns (bool) {
        try POOL.getReserveData(_asset) returns (DataTypes.ReserveData memory reserveData) {
            // Check if the asset is active in the pool
            return reserveData.aTokenAddress != address(0);
        } catch {
            return false;
        }
    }
}
