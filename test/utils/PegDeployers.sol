// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.30;

import {stdJson} from "forge-std/StdJson.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Deployers} from "./Deployers.sol";
import {IPegCore} from "./peg/IPegCore.sol";
import {IPegModel} from "./peg/IPegModel.sol";
import {IPegAssetFactory} from "./peg/IPegAssetFactory.sol";
import {Id, MarketParams, PegMarketParamsLib} from "./peg/PegTypes.sol";

abstract contract PegDeployers is Deployers {
    using stdJson for string;
    using PegMarketParamsLib for MarketParams;

    Vm private constant CHEATS = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    string internal constant PEG_CORE_ARTIFACT =
        "test/fixtures/peg-core-artifacts/contracts/core/PegCore.sol/PegCore.json";
    string internal constant PEG_MODEL_ARTIFACT =
        "test/fixtures/peg-core-artifacts/contracts/core/PegModel.sol/PegModel.json";
    string internal constant PEG_ASSET_FACTORY_ARTIFACT =
        "test/fixtures/peg-core-artifacts/contracts/core/PegAssetFactory.sol/PegAssetFactory.json";

    uint256 internal constant DEFAULT_PEG_LLTV = 0.8e18;
    uint112 internal constant DEFAULT_PEG_BORROW_CAP = type(uint112).max;

    IPegCore pegCore;
    IPegModel pegModel;
    IPegAssetFactory pegAssetFactory;

    function deployPegArtifacts() internal {
        deployPegCore();
        deployPegModel();
        pegCore.setModel(address(pegModel), true);
        deployPegAssetFactory();
    }

    function deployPegCore() internal returns (IPegCore deployedPegCore) {
        deployedPegCore = IPegCore(_deployArtifact(PEG_CORE_ARTIFACT, bytes("")));
        pegCore = deployedPegCore;
    }

    function deployPegModel() internal returns (IPegModel deployedPegModel) {
        deployedPegModel = IPegModel(_deployArtifact(PEG_MODEL_ARTIFACT, bytes("")));
        pegModel = deployedPegModel;
    }

    function deployPegAssetFactory() internal returns (IPegAssetFactory deployedPegAssetFactory) {
        deployedPegAssetFactory =
            IPegAssetFactory(_deployArtifact(PEG_ASSET_FACTORY_ARTIFACT, abi.encode(address(pegCore))));
        pegAssetFactory = deployedPegAssetFactory;
    }

    function deployPegCollateralToken() internal returns (MockERC20 token) {
        token = new MockERC20("Peg Collateral", "PCOL", 18);
        token.mint(address(this), 10_000_000 ether);
    }

    function deployPegAsset(string memory name, string memory symbol) internal returns (address pegAsset) {
        pegAsset = pegAssetFactory.createPegAsset(name, symbol);
    }

    function createPegMarket(address collateralToken, address loanToken, address oracle)
        internal
        returns (Id marketId, MarketParams memory marketParams)
    {
        pegModel.setCollateralToken(collateralToken);

        marketParams = MarketParams({
            collateralToken: collateralToken, loanToken: loanToken, oracle: oracle, model: address(pegModel)
        });

        marketId = marketParams.id();
        pegModel.setLltv(marketId, DEFAULT_PEG_LLTV);
        pegCore.createMarket(marketParams);
        pegCore.setBorrowCap(marketId, DEFAULT_PEG_BORROW_CAP);
    }

    function _deployArtifact(string memory artifactPath, bytes memory constructorArgs)
        internal
        returns (address deployed)
    {
        bytes memory artifactBytecode = _artifactBytecode(artifactPath);
        bytes memory creationCode = abi.encodePacked(artifactBytecode, constructorArgs);

        assembly ("memory-safe") {
            deployed := create(0, add(creationCode, 0x20), mload(creationCode))
        }

        require(deployed != address(0), "artifact deploy failed");
    }

    function _artifactBytecode(string memory artifactPath) internal view returns (bytes memory bytecode) {
        string memory artifactJson = CHEATS.readFile(artifactPath);
        bytecode = artifactJson.readBytes(".bytecode");

        require(bytecode.length != 0, "empty artifact bytecode");
    }
}
