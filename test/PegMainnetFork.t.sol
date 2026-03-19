// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PegMainnetForkFixtures} from "./utils/PegMainnetForkFixtures.sol";
import {IOracle} from "./utils/peg/IOracle.sol";
import {IChainlinkAggregator} from "./utils/peg/IChainlinkAggregator.sol";
import {IERC4626Like} from "./utils/peg/IERC4626Like.sol";

contract PegMainnetForkTest is PegMainnetForkFixtures {
    uint256 internal constant ORACLE_PRICE_SCALE = 1e36;
    uint256 internal constant SUPPLIED_COLLATERAL = 1_200 ether;
    uint256 internal constant MINTED_PEG_USD = 100 ether;

    MainnetForkFixture internal fixture;

    function setUp() public {
        createMainnetForkOrSkip();
        fixture = deployMainnetForkFixture();
    }

    function testDeployMainnetForkFixtureSetsMarketsAndView() public view {
        (address collateralToken, address pegUsdLoanToken, address pegUsdOracle, address pegUsdModel) =
            fixture.pegCore.idToMarketParams(fixture.pegUsdMarketId);
        (address pegEthCollateralToken, address pegEthLoanToken, address pegEthOracle, address pegEthModel) =
            fixture.pegCore.idToMarketParams(fixture.pegEthMarketId);
        (uint32 pegUsdTimestamp,,,,,,, uint112 pegUsdBorrowCap) = fixture.pegCore.market(fixture.pegUsdMarketId);
        (uint32 pegEthTimestamp,,,,,,, uint112 pegEthBorrowCap) = fixture.pegCore.market(fixture.pegEthMarketId);

        assertEq(collateralToken, fixture.pegUsdMarketParams.collateralToken);
        assertEq(pegUsdLoanToken, fixture.pegUsdMarketParams.loanToken);
        assertEq(pegUsdOracle, fixture.pegUsdMarketParams.oracle);
        assertEq(pegUsdModel, fixture.pegUsdMarketParams.model);
        assertEq(pegEthCollateralToken, fixture.pegEthMarketParams.collateralToken);
        assertEq(pegEthLoanToken, fixture.pegEthMarketParams.loanToken);
        assertEq(pegEthOracle, fixture.pegEthMarketParams.oracle);
        assertEq(pegEthModel, fixture.pegEthMarketParams.model);
        assertEq(pegUsdTimestamp, 0);
        assertEq(pegEthTimestamp, 0);
        assertEq(pegUsdBorrowCap, FORK_MARKET_BORROW_CAP);
        assertEq(pegEthBorrowCap, FORK_MARKET_BORROW_CAP);
        assertEq(fixture.pegStateView.pegCore(), address(fixture.pegCore));
        assertEq(fixture.model.lltv(fixture.pegUsdMarketId), FORK_LLTV_WAD);
        assertEq(fixture.model.lltv(fixture.pegEthMarketId), FORK_LLTV_WAD);
    }

    function testForkOraclePricesMatchMainnetFeeds() public view {
        (uint256 baseUsdPrice, uint8 baseUsdDecimals) = _readChainlinkUsdPrice(BASE_FEED);
        (uint256 quoteUsdPrice, uint8 quoteUsdDecimals) = _readChainlinkUsdPrice(QUOTE_FEED);
        uint256 baseVaultPrice = IERC4626Like(BASE_VAULT).convertToAssets(1 ether);

        uint256 susdsPegUsdPrice = IOracle(fixture.pegUsdOracleAddress).price();
        uint256 computedSusdsPegUsdPrice = (baseVaultPrice * baseUsdPrice * ORACLE_PRICE_SCALE) /
            (1 ether * (10 ** uint256(baseUsdDecimals)));

        uint256 susdsWethPrice = IOracle(fixture.pegEthOracleAddress).price();
        uint256 computedSusdsWethPrice =
            (baseVaultPrice * baseUsdPrice * ORACLE_PRICE_SCALE * (10 ** uint256(quoteUsdDecimals))) /
            (1 ether * quoteUsdPrice * (10 ** uint256(baseUsdDecimals)));

        assertGt(baseVaultPrice, 0);
        assertEq(susdsPegUsdPrice, computedSusdsPegUsdPrice);
        assertEq(susdsWethPrice, computedSusdsWethPrice);
    }

    function testForkFixtureFundsUsersAndSupportsSupplyMint() public {
        assertEq(fixture.susds.balanceOf(fixture.user), FORK_USER_BALANCE);
        assertEq(fixture.susds.allowance(fixture.user, address(fixture.pegCore)), FORK_USER_BALANCE);

        vm.startPrank(fixture.user);
        fixture.pegCore.supply(fixture.pegUsdMarketId, SUPPLIED_COLLATERAL, fixture.user);
        fixture.pegCore.mint(fixture.pegUsdMarketId, MINTED_PEG_USD, 0, fixture.user, fixture.user);
        vm.stopPrank();

        (uint128 collateral, uint128 borrowShares,,, uint128 lockCollateral) =
            fixture.pegCore.position(fixture.pegUsdMarketId, fixture.user);

        assertEq(uint256(collateral), SUPPLIED_COLLATERAL);
        assertGt(uint256(borrowShares), MINTED_PEG_USD);
        assertGt(uint256(lockCollateral), 0);
        assertEq(IERC20(fixture.pegUsd).balanceOf(fixture.user), MINTED_PEG_USD);
    }

    function _readChainlinkUsdPrice(address feedAddress) internal view returns (uint256 price, uint8 decimals) {
        (, int256 answer,,,) = IChainlinkAggregator(feedAddress).latestRoundData();
        require(answer > 0, "invalid chainlink price");

        price = uint256(answer);
        decimals = IChainlinkAggregator(feedAddress).decimals();
    }
}
