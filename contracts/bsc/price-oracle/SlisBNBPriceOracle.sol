// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

import { SpotPriceOracleBase } from "../../price-oracle/SpotPriceOracleBase.sol";

import { IPriceOracle } from "../../price-oracle/interfaces/IPriceOracle.sol";
import { ITwapOracle } from "../../price-oracle/interfaces/ITwapOracle.sol";

contract SlisBNBPriceOracle is SpotPriceOracleBase, IPriceOracle {
  /*************
   * Constants *
   *************/

  /// @notice The Chainlink BNB/USD price feed.
  /// @dev See comments of `_readSpotPriceByChainlink` for more details.
  bytes32 public immutable Chainlink_BNB_USD_Spot;

  /// @notice The Chainlink slisBNB/BNB price feed.
  /// @dev See comments of `_readSpotPriceByChainlink` for more details.
  bytes32 public immutable Chainlink_slisBNB_BNB_Spot;

  /*************
   * Variables *
   *************/

  /// @dev The encodings for BNB/USD spot sources.
  bytes private onchainSpotEncodings_BNB_USD;

  /// @dev The encodings for slisBNB/BNB spot sources.
  bytes private onchainSpotEncodings_slisBNB_BNB;

  /// @dev The encodings for wstETH/USD spot sources.
  bytes private onchainSpotEncodings_slisBNB_USD;

  /// @notice The value of maximum price deviation, multiplied by 1e18.
  uint256 public maxPriceDeviation;

  /***************
   * Constructor *
   ***************/

  constructor(
    address _spotPriceOracle,
    bytes32 _Chainlink_BNB_USD_Spot,
    bytes32 _Chainlink_slisBNB_BNB_Spot
  ) SpotPriceOracleBase(_spotPriceOracle) {
    Chainlink_BNB_USD_Spot = _Chainlink_BNB_USD_Spot;
    Chainlink_slisBNB_BNB_Spot = _Chainlink_slisBNB_BNB_Spot;

    _updateMaxPriceDeviation(1e16); // 1%
  }

  /*************************
   * Public View Functions *
   *************************/

  /// @notice Return the slisBNB/USD spot price.
  /// @return chainlinkPrice The spot price from Chainlink price feed.
  /// @return minPrice The minimum spot price among all available sources.
  /// @return maxPrice The maximum spot price among all available sources.
  function getslisBNBUSDSpotPrice() external view returns (uint256 chainlinkPrice, uint256 minPrice, uint256 maxPrice) {
    (chainlinkPrice, minPrice, maxPrice) = _getslisBNBUSDSpotPrice();
  }

  /// @notice Return the slisBNB/BNB spot prices.
  /// @return prices The list of spot price among all available sources, multiplied by 1e18.
  function getslisBNBBNBSpotPrices() external view returns (uint256[] memory prices) {
    prices = _getSpotPriceByEncoding(onchainSpotEncodings_slisBNB_BNB);
  }

  /// @inheritdoc IPriceOracle
  /// @dev The price is valid iff |maxPrice-minPrice|/minPrice < maxPriceDeviation
  function getPrice() public view override returns (uint256 anchorPrice, uint256 minPrice, uint256 maxPrice) {
    (anchorPrice, minPrice, maxPrice) = _getslisBNBUSDSpotPrice();

    uint256 cachedMaxPriceDeviation = maxPriceDeviation; // gas saving
    // use anchor price when the price deviation between anchor price and min price exceed threshold
    if ((anchorPrice - minPrice) * PRECISION > cachedMaxPriceDeviation * minPrice) {
      minPrice = anchorPrice;
    }

    // use anchor price when the price deviation between anchor price and max price exceed threshold
    if ((maxPrice - anchorPrice) * PRECISION > cachedMaxPriceDeviation * anchorPrice) {
      maxPrice = anchorPrice;
    }
  }

  /// @inheritdoc IPriceOracle
  function getExchangePrice() public view returns (uint256) {
    (, uint256 price, ) = getPrice();
    return price;
  }

  /// @inheritdoc IPriceOracle
  function getLiquidatePrice() external view returns (uint256) {
    return getExchangePrice();
  }

  /// @inheritdoc IPriceOracle
  function getRedeemPrice() external view returns (uint256) {
    (, , uint256 price) = getPrice();
    return price;
  }

  /************************
   * Restricted Functions *
   ************************/

  /// @notice Update the on-chain spot encodings.
  /// @param encodings The encodings to update. See `_getSpotPriceByEncoding` for more details.
  /// @param spotType The type of the encodings.
  function updateOnchainSpotEncodings(bytes memory encodings, uint256 spotType) external onlyOwner {
    // validate encoding
    uint256[] memory prices = _getSpotPriceByEncoding(encodings);

    if (spotType == 0) {
      onchainSpotEncodings_BNB_USD = encodings;
      if (prices.length == 0) revert ErrorInvalidEncodings();
    } else if (spotType == 1) {
      onchainSpotEncodings_slisBNB_BNB = encodings;
    } else if (spotType == 2) {
      onchainSpotEncodings_slisBNB_USD = encodings;
    }
  }

  /// @notice Update the value of maximum price deviation.
  /// @param newMaxPriceDeviation The new value of maximum price deviation, multiplied by 1e18.
  function updateMaxPriceDeviation(uint256 newMaxPriceDeviation) external onlyOwner {
    _updateMaxPriceDeviation(newMaxPriceDeviation);
  }

  /**********************
   * Internal Functions *
   **********************/

  /// @dev Internal function to update the value of maximum price deviation.
  /// @param newMaxPriceDeviation The new value of maximum price deviation, multiplied by 1e18.
  function _updateMaxPriceDeviation(uint256 newMaxPriceDeviation) private {
    uint256 oldMaxPriceDeviation = maxPriceDeviation;
    if (oldMaxPriceDeviation == newMaxPriceDeviation) {
      revert ErrorParameterUnchanged();
    }

    maxPriceDeviation = newMaxPriceDeviation;

    emit UpdateMaxPriceDeviation(oldMaxPriceDeviation, newMaxPriceDeviation);
  }

  /// @dev Internal function to calculate the slisBNB/USD spot price.
  /// @return chainlinkPrice The spot price from Chainlink price feed, multiplied by 1e18.
  /// @return minPrice The minimum spot price among all available sources, multiplied by 1e18.
  /// @return maxPrice The maximum spot price among all available sources, multiplied by 1e18.
  function _getslisBNBUSDSpotPrice() internal view returns (uint256 chainlinkPrice, uint256 minPrice, uint256 maxPrice) {
    // compute chainlink price
    uint256 chainlinkPrice_BNB_USD = _readSpotPriceByChainlink(Chainlink_BNB_USD_Spot);
    uint256 chainlinkPrice_slisBNB_BNB = _readSpotPriceByChainlink(Chainlink_slisBNB_BNB_Spot);
    chainlinkPrice = (chainlinkPrice_BNB_USD * chainlinkPrice_slisBNB_BNB) / PRECISION;

    // consider slisBNB/USD
    uint256[] memory prices = _getSpotPriceByEncoding(onchainSpotEncodings_slisBNB_USD);
    minPrice = maxPrice = chainlinkPrice;
    for (uint256 i = 0; i < prices.length; i++) {
      if (prices[i] > maxPrice) maxPrice = prices[i];
      if (prices[i] < minPrice) minPrice = prices[i];
    }

    // consider slisBNB/BNB * BNB/USD
    uint256 minBNBPrice = chainlinkPrice_BNB_USD;
    uint256 maxBNBPrice = chainlinkPrice_BNB_USD;
    prices = _getSpotPriceByEncoding(onchainSpotEncodings_BNB_USD);
    for (uint256 i = 0; i < prices.length; i++) {
      if (prices[i] > maxBNBPrice) maxBNBPrice = prices[i];
      if (prices[i] < minBNBPrice) minBNBPrice = prices[i];
    }
    prices = _getSpotPriceByEncoding(onchainSpotEncodings_slisBNB_BNB);
    for (uint256 i = 0; i < prices.length; i++) {
      uint256 maxPrice_slisBNB_USD = (maxBNBPrice * prices[i]) / PRECISION;
      uint256 minPrice_slisBNB_USD = (minBNBPrice * prices[i]) / PRECISION;
      if (maxPrice_slisBNB_USD > maxPrice) maxPrice = maxPrice_slisBNB_USD;
      if (minPrice_slisBNB_USD < minPrice) minPrice = minPrice_slisBNB_USD;
    }
  }
}
