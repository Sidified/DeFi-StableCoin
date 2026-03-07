// SPDX-License-Identifier: MIT

// Layout of Contract:
// version
// imports
// interfaces, libraries, contracts
// errors
// Type declarations
// State variables
// Events
// Modifiers
// Functions

// Layout of Functions:
// constructor
// receive function (if exists)
// fallback function (if exists)
// external
// public
// internal
// private
// view & pure functions

pragma solidity ^0.8.18;
import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {OracleLib} from "./Libraries/OracleLib.sol";

/**
 * @title DSCEngine
 * @author Sid
 *
 * This system is designed to be as minimal as possible, and have the token maintains a 1 token == $1 pegged
 * This stablecoin has the properties:
 * - Exogenous Collateral
 * - Dollar Pegged
 * - Algorithmically Stable
 *
 * It is similar to DAI if DAI had no governance, no fees and was only backed by WETH and WBTC
 *
 * Our DSC system should always be "overcollateralized" (more collateral than needed). At no point should the value of the collateral be <= the $ backed value of the DSC.
 * @notice This contract is the core of the DSC system. It handels all the logic for mining and redeeming DSC, as well as depositing and withdrawing collateral
 * @notice  This contract is very loosely based inn the MakerDAO DSS (DAI) system
 */

contract DSCEngine is ReentrancyGuard {
    ///////////////
    //  ERRORS   //
    ///////////////
    error DSCEngine__NeedsMoreThanZero();
    error DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine__NotAllowedToken();
    error DSCEngine__TransferFailed();
    error DSCEngine__BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine__MintFailed();
    error DSCEngine__HealthFactorIsOk();
    error DSCEngine__HealthFactorNotImproved();

    ///////////////
    //  Types    //
    ///////////////
    using OracleLib for AggregatorV3Interface;

    /////////////////////
    // STATE VARIABLES //
    /////////////////////
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10; // Chainlink price feeds have 8 decimals, we want to convert it to 18 decimals to be consistent with the rest of the system
    uint256 private constant PRECISION = 1e18; // 1e18 = 1.0 in our system, we use 18 decimals for precision
    uint256 private constant LIQUIDATION_THRESHOLD = 50; // 200% overcollateralized
    uint256 private constant LIQUIDATION_PRECISION = 100;
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10; // 10% bonus for liquidators

    mapping(address token => address priceFeed) private s_priceFeeds; // tokenToPriceFeed
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;

    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;

    ////////////
    // EVENTS //
    ////////////
    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(address indexed redeemedFrom, address indexed to, address indexed token, uint256 amount);

    ///////////////
    // MODIFIERS //
    ///////////////
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine__NeedsMoreThanZero();
        }
        _;
    }

    modifier isAllowedToken(address token) {
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine__NotAllowedToken();
        }
        _;
    }

    ///////////////
    // FUNCTIONS //
    ///////////////
    constructor(address[] memory tokenAddress, address[] memory priceFeedAddresses, address dscAddress) {
        // USD Price Feeds
        if (tokenAddress.length != priceFeedAddresses.length) {
            revert DSCEngine__TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        // For Ex ETH/USD, BTC/USD, MKR/USD etc
        for (uint256 i = 0; i < tokenAddress.length; i++) {
            s_priceFeeds[tokenAddress[i]] = priceFeedAddresses[i];
            s_collateralTokens.push(tokenAddress[i]);
        }

        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    ////////////////////////
    // EXTERNAL FUNCTIONS //
    ////////////////////////

    /**
     * @param tokenCollateralAddress The address of the token to depposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     * @param amountDscToMint The amount of decentralized stable coin to mint
     * @notice This function is a combination of depositCollateral and mintDsc. This function will deposit the collateral and mint the DSC in one transaction.
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * @notice Follows CEI
     * @param tokenCollateralAddress The address of the token to depposit as collateral
     * @param amountCollateral The amount of collateral to deposit
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    /**
     * @param tokenCollateralAddress The address of the token to redeem as collateral
     * @param amountCollateral The amount of collateral to redeem
     * @param amountDscToBurn The amount of DSC to burn
     * @notice This function is a combination of burnDsc and redeemCollateral. This function will burn the DSC and redeem the collateral in one transaction.
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        burnDsc(amountDscToBurn);
        redeemCollateral(tokenCollateralAddress, amountCollateral);
        // redeemCollateral already checks the health factor
    }
    // In order to redeem collateral
    // 1. Health factor must be above the minimum threshold after redeeming collateral

    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(tokenCollateralAddress, amountCollateral, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * @notice follows CEI
     * @param amountDscToMint THe amunt of decentralized stable coin to mint
     * @notice they must have more collateral than the minimum required
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        s_DSCMinted[msg.sender] += amountDscToMint;
        // if they minted too much, their health factor would drop below the minimum threshold and the transaction would revert
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine__MintFailed();
        }
    }

    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        _revertIfHealthFactorIsBroken(msg.sender); // it is highly unlikely that burning DSC would break the health factor, but we can still check just in case
    }

    // If we do start nearing undercollateralization, we want to allow people to liquidate the system and make a profit, while also bringing the system back to a healthy state

    // For example, $100 worth of collateral backing $50 worth of DSC

    // Now if ETH drops and the collateral is only worth $75 which is still backing $50 worh of DSC

    // This is undercollateralized, so someone can come in and say, I want to pay back that $50 worth of DSC and in return I want that $75 worth of collateral

    // Liquidator now can take $75 backing and burns off the 50$ worth of DSC

    /**
     * @param collateral The ERC20 token address of the collateral token to liquidate from the user
     * @param user The address of the user to liquidate. The user who has broken the health factor and is undercollateralized.(Their health factor must be below MIN_HEALTH_FACTOR)
     * @param debtToCover The amount of DSC the liquidator wants to burn to cover
     * @notice You can partially liquidate a user
     * @notice You will get a liquidation bonus for taking the user's funds.
     * @notice This function working assumes the protocol will be roughly 200% overcollateralized in order for this to work
     * @notice A known bug would be if the protocol were 100% or less collateralized, then we would'nt be able to incetivize the liquidators.
     * For example, the price of the collateral plummited before anyone could be liquidated
     * Folloes CEI: Checks, Effects, Interactions
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        external
        moreThanZero(debtToCover)
        nonReentrant
    {
        // need to check if the user is actually undercollateralized and can be liquidated(health factor)
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine__HealthFactorIsOk();
        }
        // We want to burn their DSC "debt" and take their collateral
        // for ex they have $140 woth of ETH and $100 worth of DSC
        // $100 worth of debt to cover
        // Now we have to check that $100 worth of DSC is how much ETH????
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        // Now we have to give the liquidator a liquidation bonus for taking the user's funds
        // If the liquidation bonus is 10%, then we give them 10% more collateral than the amount of debt they covered
        // So we are giving them $110 worth of WETH for covering 100 DSC
        // We should implement a feature to liquidate in the event the protocol is insolvent (LATER)
        // And sweep extra amount to the treasury (LATER)

        // 0.05*0.1 = 0.0005, -->> example, 0.05 ETH times 0.1 which is 10% liquidation bonus = 0.005 ETH worth of bonus for the liquidator
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(collateral, totalCollateralToRedeem, user, msg.sender);
        _burnDsc(debtToCover, user, msg.sender);

        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine__HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender); // check if the liquidator broke the health factor, they could have been close to the edge and then by redeeming collateral, they broke their own health factor so we want to make sure that they are still above the minimum threshold after liquidating
    }

    function getHealthFactor() external view {}

    /////////////////////////////////////////
    // PRIVATE AND INTERNAL VIEW FUNCTIONS //
    /////////////////////////////////////////

    /**
     * @dev Low-Level Internal Function, do not call unless the function calling it is checking for the health factors being broken
     */
    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
        i_dsc.burn(amountDscToBurn);
    }

    function _redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral, address from, address to)
        private
    {
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);

        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine__TransferFailed();
        }
    }

    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValueInUsd)
    {
        totalDscMinted = s_DSCMinted[user];
        totalCollateralValueInUsd = getAccountCollateralValue(user);
    }

    /**
     * Returns how close to liquidation the user is
     * If the user goes below 1, they can get liquidated
     */
    /* function _healthFactor(address user) private view returns (uint256) {
        // total DSC minted
        // total value of collateral
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = _getAccountInformation(user);
        uint256 collateralAdjustedForThreshold =
            (totalCollateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
        // $1000 worth of collateral deposited
        // 100 DSC minted
        // 1000 * 50  = 50,000
        // 50,000 / 100 = 500
        // Health factor = 500 / 100 = 5, which is > 1 (500% overcollateralized)
    } */
    // The following function is the modified version of the above function with a check to return max uint256 if the user has no debt, this is to prevent division by zero errors and also to make sure that we are not underflowing when we calculate the health factor for users with no debt
    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 totalCollateralValueInUsd) = _getAccountInformation(user);

        if (totalDscMinted == 0) {
            return type(uint256).max;
        }

        uint256 collateralAdjustedForThreshold =
            (totalCollateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;

        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    // 1. Check health factor (do they have enough collateral?)
    // 2. Revert if they don't
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 userHealthFactor = _healthFactor(user);
        if (userHealthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine__BreaksHealthFactor(userHealthFactor);
        }
    }

    /////////////////////////////////////////
    // PUBLIC AND EXTERNAL VIEW FUNCTIONS ///
    /////////////////////////////////////////

    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        // Get the price feed address for the token
        // Get the latest price from the price feed
        // Convert the price to 18 decimals and return the amount of tokens that is worth the usdAmountInWei
        // We have to convert here -->> $X is equal to how many ETH???
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = OracleLib.staleCheckLatestRoundData(priceFeed);
        // lets say that 1eth = $1000, then the price feed would return 1000 * 10^8 (because Chainlink price feeds have 8 decimals)
        return (usdAmountInWei * PRECISION) / ((uint256(price) * ADDITIONAL_FEED_PRECISION)); // (1000*1e8*(1e10))*1000*1e18
    }

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        // Loop through all the collateral tokens, get the amount they have deposited and map it to the price feed to get the value in USD
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            uint256 amount = s_collateralDeposited[user][token];
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        // Get the price feed address for the token
        // Get the latest price from the price feed
        // Convert the price to 18 decimals and return the value in USD
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = OracleLib.staleCheckLatestRoundData(priceFeed);
        // lets say that 1eth = $1000, then the price feed would return 1000 * 10^8 (because Chainlink price feeds have 8 decimals)
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION * amount)) / PRECISION; // (1000*1e8*(1e10))*1000*1e18
    }

    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 totalCollateralValueInUsd)
    {
        (totalDscMinted, totalCollateralValueInUsd) = _getAccountInformation(user);
    }

    ///////////////////////
    // GETTER FUNCTIONS ///
    ///////////////////////
    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    function getCollateralTokenPriceFeed(address token) external view returns (address) {
        return s_priceFeeds[token];
    }
}
