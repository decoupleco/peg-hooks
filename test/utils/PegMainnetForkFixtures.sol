// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {BaseTest} from "./BaseTest.sol";
import {IPegCore} from "./peg/IPegCore.sol";
import {IPegModel} from "./peg/IPegModel.sol";
import {IPegStateView} from "./peg/IPegStateView.sol";
import {Id, MarketParams, PegMarketParamsLib} from "./peg/PegTypes.sol";
import {IMorphoChainlinkOracleFactory} from "./peg/IMorphoChainlinkOracleFactory.sol";

abstract contract PegMainnetForkFixtures is BaseTest {
    using PegMarketParamsLib for MarketParams;

    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    uint256 internal constant MAINNET_FORK_BLOCK = 24_688_680;
    uint256 internal constant FORK_LLTV_WAD = 0.75e18;
    uint256 internal constant FORK_SWAP_FEE_BPS = 10;
    uint112 internal constant FORK_MARKET_BORROW_CAP = 1_000_000 ether;
    uint256 internal constant FORK_USER_BALANCE = 10_000 ether;

    address internal constant MORPHO_ORACLE_FACTORY = 0x3A7bB36Ee3f3eE32A60e9f2b33c1e5f2E83ad766;
    address internal constant BASE_VAULT = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;
    address internal constant BASE_FEED = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;
    address internal constant QUOTE_FEED = 0xc0053f3FBcCD593758258334Dfce24C2A9A673aD;

    bytes32 internal constant FIXED_PEG_USD_ORACLE_SALT =
        0x0000000000000000000000000000000000000000000000000000000000000001;
    bytes32 internal constant FIXED_PEG_ETH_ORACLE_SALT =
        0x0000000000000000000000000000000000000000000000000000000000000002;

    string internal constant PEG_STATE_VIEW_ARTIFACT =
        "test/fixtures/peg-core-artifacts/contracts/view/PegStateView.sol/PegStateView.json";

    struct MainnetForkFixture {
        address owner;
        address user;
        address user2;
        MockERC20 susds;
        address pegUsd;
        address pegEth;
        IPegCore pegCore;
        IPegModel model;
        IPegStateView pegStateView;
        address pegUsdOracleAddress;
        address pegEthOracleAddress;
        MarketParams pegUsdMarketParams;
        Id pegUsdMarketId;
        MarketParams pegEthMarketParams;
        Id pegEthMarketId;
    }

    function createMainnetForkOrSkip() internal {
        string memory rpcUrl = VM.envOr("MAINNET_QUICKNODE_HTTPS_URL", string(""));
        if (bytes(rpcUrl).length == 0) {
            rpcUrl = VM.envOr("MAINNET_RPC_URL", string(""));
        }
        if (bytes(rpcUrl).length == 0) {
            VM.skip(true, "MAINNET_QUICKNODE_HTTPS_URL or MAINNET_RPC_URL is required for fork tests");
        }

        VM.createSelectFork(rpcUrl, MAINNET_FORK_BLOCK);
    }

    function deployMainnetForkFixture() internal returns (MainnetForkFixture memory fixture) {
        fixture.owner = address(this);
        fixture.user = _makeAddr("peg-fork-user");
        fixture.user2 = _makeAddr("peg-fork-user-2");

        fixture.susds = new MockERC20("Savings USDS", "sUSDS", 18);

        deployPegCore();
        deployPegModel();
        deployPegAssetFactory();
        pegCore.setModel(address(pegModel), true);

        fixture.pegCore = pegCore;
        fixture.model = pegModel;
        fixture.pegStateView = IPegStateView(_deployArtifact(PEG_STATE_VIEW_ARTIFACT, abi.encode(address(pegCore))));

        fixture.pegUsd = deployPegAsset("Peg USD", "pegUSD");
        fixture.pegEth = deployPegAsset("Peg ETH", "pegETH");

        fixture.pegUsdOracleAddress = _createMorphoChainlinkOracle(
            BASE_VAULT,
            1 ether,
            BASE_FEED,
            address(0),
            18,
            address(0),
            1,
            address(0),
            address(0),
            18,
            FIXED_PEG_USD_ORACLE_SALT
        );

        fixture.pegEthOracleAddress = _createMorphoChainlinkOracle(
            BASE_VAULT,
            1 ether,
            BASE_FEED,
            address(0),
            18,
            address(0),
            1,
            QUOTE_FEED,
            address(0),
            18,
            FIXED_PEG_ETH_ORACLE_SALT
        );

        pegModel.setCollateralToken(address(fixture.susds));

        fixture.pegUsdMarketParams = MarketParams({
            collateralToken: address(fixture.susds),
            loanToken: fixture.pegUsd,
            oracle: fixture.pegUsdOracleAddress,
            model: address(pegModel)
        });
        fixture.pegUsdMarketId = fixture.pegUsdMarketParams.id();
        pegModel.setLltv(fixture.pegUsdMarketId, FORK_LLTV_WAD);
        pegCore.createMarket(fixture.pegUsdMarketParams);
        pegModel.setSwapFee(fixture.pegUsdMarketId, FORK_SWAP_FEE_BPS);
        pegCore.setBorrowCap(fixture.pegUsdMarketId, FORK_MARKET_BORROW_CAP);

        fixture.pegEthMarketParams = MarketParams({
            collateralToken: address(fixture.susds),
            loanToken: fixture.pegEth,
            oracle: fixture.pegEthOracleAddress,
            model: address(pegModel)
        });
        fixture.pegEthMarketId = fixture.pegEthMarketParams.id();
        pegModel.setLltv(fixture.pegEthMarketId, FORK_LLTV_WAD);
        pegCore.createMarket(fixture.pegEthMarketParams);
        pegModel.setSwapFee(fixture.pegEthMarketId, FORK_SWAP_FEE_BPS);
        pegCore.setBorrowCap(fixture.pegEthMarketId, FORK_MARKET_BORROW_CAP);

        fixture.susds.mint(fixture.user, FORK_USER_BALANCE);
        fixture.susds.mint(fixture.user2, FORK_USER_BALANCE);

        VM.prank(fixture.user);
        fixture.susds.approve(address(pegCore), FORK_USER_BALANCE);

        VM.prank(fixture.user2);
        fixture.susds.approve(address(pegCore), FORK_USER_BALANCE);
    }

    function _makeAddr(string memory label) internal pure returns (address addr) {
        addr = address(uint160(uint256(keccak256(bytes(label)))));
    }

    function _createMorphoChainlinkOracle(
        address baseVault,
        uint256 baseVaultConversionSample,
        address baseFeed1,
        address baseFeed2,
        uint256 baseTokenDecimals,
        address quoteVault,
        uint256 quoteVaultConversionSample,
        address quoteFeed1,
        address quoteFeed2,
        uint256 quoteTokenDecimals,
        bytes32 salt
    ) internal returns (address oracle) {
        oracle = IMorphoChainlinkOracleFactory(MORPHO_ORACLE_FACTORY)
            .createMorphoChainlinkOracleV2(
                baseVault,
                baseVaultConversionSample,
                baseFeed1,
                baseFeed2,
                baseTokenDecimals,
                quoteVault,
                quoteVaultConversionSample,
                quoteFeed1,
                quoteFeed2,
                quoteTokenDecimals,
                salt
            );
    }
}
