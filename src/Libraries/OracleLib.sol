// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title OracleLib
 * @author Sid
 * @notice This Library is used to check the Chainlink Oracle for stale data
 * If the price is stale the function will revert, and render the DSCEngine unsuable - this is by design
 * We want the DSCEngine to freeze if prices become stale
 *
 * So if the Chainlnk network explodes and you have a lot of money licked in the protocol... TOO BAD!
 *
 */

library OracleLib {
    error OracleLib__PriceIsStale();
    uint256 private constant TIMEOUT = 3 hours; // 3x60x60 = 10800 seconds

    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();
        uint256 secondsSince = block.timestamp - updatedAt;
        if (secondsSince > TIMEOUT) {
            revert OracleLib__PriceIsStale();
        }
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
