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

/// @title Aave Leveraged positions (ALP) contract
/// @notice A contract that represents a leverged position on Aave V3 pool

contract ALP is ReentrancyGuard {
    using SafeERC20 for IERC20Metadata;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;

    IPoolAddressesProvider public immutable ADDRESSES_PROVIDER =
        IPoolAddressesProvider(0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e);

    IPool public immutable POOL;

    IUniswapV2Router public immutable UNISWAP_ROUTER = IUniswapV2Router(0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D);

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

    uint256 private constant PRECISION = 1e4;

    struct Position {
        address owner;
        address[] collateralAssets;
        uint256[] collateralAmounts;
        address debtAsset;
        uint256 debtAmount;
    }

    // Struct for multi-asset input
    struct CollateralInput {
        address asset;
        uint256 amount;
    }

    Position public position;

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error InvalidLeverageFactor();
    error UnsupportedCollateralAsset();
    error UnsupportedDebtAsset();
    error LeverageExceedsMaxSafe();
    error PositionDoesNotExist();
    error InvalidPriceData();
    error IdenticalAssets();
    error InvalidCollateralCount(); // should be max 5
    error OnlyOwner();
    error InvalidCollateralAsset();
    error InsufficientCollateral();
    error ExcessRepayment();

    /*//////////////////////////////////////////////////////////////
                               EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new leveraged position is created
    event ALPCreated(
        address indexed owner,
        address[] collateralAssets,
        uint256[] collateralAmounts,
        address debtAsset,
        uint256 debtAmount
    );
    event CollateralAdded(address indexed asset, uint256 amount);
    event DebtRepaid(uint256 amount);
    event LeverageAdjusted(uint256 newLeverageFactor);

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(address owner, CollateralInput[] memory _collaterals, address _debtAsset, uint256 _leverageFactor) {
        if (_collaterals.length > 5) revert InvalidCollateralCount();
        if (_leverageFactor < PRECISION) revert InvalidLeverageFactor();
        POOL = IPool(ADDRESSES_PROVIDER.getPool());
        if (!_validateAssetInPool(_debtAsset)) revert UnsupportedDebtAsset();

        uint256 totalCollateralValueUSD = 0;
        uint256 totalBorrowCapacityUSD = 0;

        address[] memory collateralAssets = new address[](_collaterals.length);
        for (uint256 i = 0; i < _collaterals.length; i++) {
            collateralAssets[i] = _collaterals[i].asset;
        }
        uint256 maxSafeLeverage = calculateMaxSafeLeverage(collateralAssets);
        if (_leverageFactor > maxSafeLeverage) revert LeverageExceedsMaxSafe();

        for (uint256 i = 0; i < _collaterals.length; i++) {
            if (!_validateAssetInPool(_collaterals[i].asset)) revert UnsupportedCollateralAsset();

            uint256 collateralValueUSD = _getAssetValueInUsd(_collaterals[i].asset, _collaterals[i].amount);
            totalCollateralValueUSD += collateralValueUSD;

            uint256 ltv = POOL.getConfiguration(_collaterals[i].asset).getLtv();
            totalBorrowCapacityUSD += (collateralValueUSD * ltv) / PRECISION;

            IERC20Metadata(_collaterals[i].asset).safeTransferFrom(msg.sender, address(this), _collaterals[i].amount);
            IERC20Metadata(_collaterals[i].asset).safeIncreaseAllowance(address(POOL), _collaterals[i].amount);
            POOL.supply(_collaterals[i].asset, _collaterals[i].amount, address(this), 0);
        }

        uint256 borrowValueUSD = (totalCollateralValueUSD * (_leverageFactor - PRECISION)) / PRECISION;
        if (borrowValueUSD > totalBorrowCapacityUSD) revert LeverageExceedsMaxSafe();

        uint256 borrowAmount = _convertUsdToAsset(_debtAsset, borrowValueUSD);
        POOL.borrow(_debtAsset, borrowAmount, 2, 0, address(this));

        uint256[] memory additionalCollateral = new uint256[](_collaterals.length);
        {
            for (uint256 i = 0; i < _collaterals.length; i++) {
                if (_debtAsset == _collaterals[i].asset) revert IdenticalAssets();
                uint256 swapValueUSD = (
                    borrowValueUSD * _getAssetValueInUsd(_collaterals[i].asset, _collaterals[i].amount)
                ) / totalCollateralValueUSD;
                uint256 swapAmount = _convertUsdToAsset(_debtAsset, swapValueUSD);
                additionalCollateral[i] = _swapAssetsUniswap(_debtAsset, _collaterals[i].asset, swapAmount);

                IERC20Metadata(_collaterals[i].asset).safeIncreaseAllowance(address(POOL), additionalCollateral[i]);
                POOL.supply(_collaterals[i].asset, additionalCollateral[i], address(this), 0);
            }
        }

        _createPosition(owner, _collaterals, additionalCollateral, _debtAsset, borrowAmount);
    }

    /// @notice Allows the position owner to add more collateral
    /// @param asset Address of the collateral asset to add
    /// @param amount Amount of collateral to add
    function addCollateral(address asset, uint256 amount) external nonReentrant {
        if (msg.sender != position.owner) revert OnlyOwner();
        if (!_isValidCollateralAsset(asset)) revert InvalidCollateralAsset();

        IERC20Metadata(asset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20Metadata(asset).safeIncreaseAllowance(address(POOL), amount);
        POOL.supply(asset, amount, address(this), 0);

        // Update position state
        bool assetExists = false;
        for (uint256 i = 0; i < position.collateralAssets.length; i++) {
            if (position.collateralAssets[i] == asset) {
                position.collateralAmounts[i] += amount;
                assetExists = true;
                break;
            }
        }

        if (!assetExists) {
            if (position.collateralAssets.length > 3) {
                revert InvalidCollateralCount();
            }
            position.collateralAssets.push(asset);
            position.collateralAmounts.push(amount);
        }

        emit CollateralAdded(asset, amount);
    }

    /// @notice Allows the position owner to repay part of the debt
    /// @param amount The amount of debt to repay
    function repayDebt(uint256 amount) external nonReentrant {
        if (msg.sender != position.owner) revert OnlyOwner();
        if (amount > position.debtAmount) revert ExcessRepayment();

        IERC20Metadata(position.debtAsset).safeTransferFrom(msg.sender, address(this), amount);
        IERC20Metadata(position.debtAsset).safeIncreaseAllowance(address(POOL), amount);
        POOL.repay(position.debtAsset, amount, 2, address(this));

        position.debtAmount -= amount;

        emit DebtRepaid(amount);
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
        (,,,,, uint256 healthFactor) = POOL.getUserAccountData(address(this));
        return healthFactor;
    }

    /// @notice Gets the details of a position
    /// @return owner The owner of the position
    /// @return collateralAssets Array of collateral asset addresses
    /// @return collateralAmounts Array of collateral amounts
    /// @return debtAsset The debt asset address
    /// @return debtAmount The debt amount
    function getPosition()
        public
        view
        returns (
            address owner,
            address[] memory collateralAssets,
            uint256[] memory collateralAmounts,
            address debtAsset,
            uint256 debtAmount
        )
    {
        return (
            position.owner,
            position.collateralAssets,
            position.collateralAmounts,
            position.debtAsset,
            position.debtAmount
        );
    }

    function getDetailedPositionData()
        public
        view
        returns (
            uint256 totalCollateral,
            uint256 totalDebt,
            uint256 availableBorrows,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        )
    {
        return POOL.getUserAccountData(address(this));
    }

    /// @notice Calculates the maximum safe leverage for multiple collateral assets
    /// @param collateralAssets Array of collateral asset addresses
    /// @return The maximum safe leverage factor considering all assets
    function calculateMaxSafeLeverage(address[] memory collateralAssets) public view returns (uint256) {
        uint256 lowestLtv = type(uint256).max;
        for (uint256 i = 0; i < collateralAssets.length; i++) {
            DataTypes.ReserveConfigurationMap memory config = POOL.getConfiguration(collateralAssets[i]);
            uint256 ltv = config.getLtv();
            if (ltv < lowestLtv) {
                lowestLtv = ltv;
            }
        }
        uint256 ltvAdjusted = (lowestLtv * PRECISION) / 10000;

        return PRECISION + ltvAdjusted;
    }

    /// @notice Calculates the USD value of a given amount of an asset
    /// @param asset The address of the asset
    /// @param amount The amount of the asset
    /// @return The USD value of the asset amount, expressed with 8 decimal places
    function _getAssetValueInUsd(address asset, uint256 amount) internal view returns (uint256) {
        IAaveOracle oracle = IAaveOracle(ADDRESSES_PROVIDER.getPriceOracle());
        uint256 priceInUsd = oracle.getAssetPrice(asset); // Price in USD with 8 decimals
        uint256 assetDecimals = IERC20Metadata(asset).decimals();
        //console.log("_getAssetValueInUsd", priceInUsd, amount, (amount * priceInUsd) / (10 ** assetDecimals));
        return (amount * priceInUsd) / (10 ** assetDecimals);
    }

    /// @notice Converts a USD amount to the equivalent amount of a specific asset
    /// @param asset The address of the asset to convert to
    /// @param amountInUsd The amount in USD, expressed with 8 decimal places
    /// @return The equivalent amount of the asset, expressed in the asset's native decimals
    function _convertUsdToAsset(address asset, uint256 amountInUsd) internal view returns (uint256) {
        IAaveOracle oracle = IAaveOracle(ADDRESSES_PROVIDER.getPriceOracle());
        uint256 priceInUsd = oracle.getAssetPrice(asset); // Price in USD with 8 decimals
        uint256 assetDecimals = IERC20Metadata(asset).decimals();
        // console.log("_convertUsdToAsset", priceInUsd, amountInUsd, (amountInUsd * (10 ** assetDecimals)) / priceInUsd);

        return (amountInUsd * (10 ** assetDecimals)) / priceInUsd;
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

        // TODO: add minOut to avoid sandwich attack
        uint256[] memory amounts =
            UNISWAP_ROUTER.swapExactTokensForTokens(_amountIn, 0, path, address(this), block.timestamp);

        return amounts[1];
    }

    /// @notice Creates a new position with multiple collateral assets
    /// @param user Address of the position owner
    /// @param collaterals Array of CollateralInput structs
    /// @param additionalCollateral Array of additional collateral amounts
    /// @param debtAsset Address of the debt asset
    /// @param debtAmount Amount of debt
    /// @return The unique identifier of the created position
    function _createPosition(
        address user,
        CollateralInput[] memory collaterals,
        uint256[] memory additionalCollateral,
        address debtAsset,
        uint256 debtAmount
    ) internal returns (uint256) {
        address[] memory collateralAssets = new address[](collaterals.length);
        uint256[] memory collateralAmounts = new uint256[](collaterals.length);

        for (uint256 i = 0; i < collaterals.length; i++) {
            collateralAssets[i] = collaterals[i].asset;
            collateralAmounts[i] = collaterals[i].amount + additionalCollateral[i];
        }

        position = Position({
            owner: user,
            collateralAssets: collateralAssets,
            collateralAmounts: collateralAmounts,
            debtAsset: debtAsset,
            debtAmount: debtAmount
        });

        emit ALPCreated(user, collateralAssets, collateralAmounts, debtAsset, debtAmount);
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
    /// @notice Checks if an asset is a valid collateral in the Aave pool
    /// @param asset The address of the asset to check
    /// @return bool True if the asset is a valid collateral, false otherwise

    function _isValidCollateralAsset(address asset) internal view returns (bool) {
        DataTypes.ReserveConfigurationMap memory config = POOL.getConfiguration(asset);
        return config.getActive() && config.getReserveFactor() > 0;
    }
}
