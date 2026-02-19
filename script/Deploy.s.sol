// SPDX-License-Identifier: MIT
// solhint-disable use-natspec
pragma solidity =0.8.25;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {PoRepMarket} from "../src/PoRepMarket.sol";
import {Validator} from "../src/Validator.sol";
import {ValidatorFactory} from "../src/ValidatorFactory.sol";
import {Client} from "../src/Client.sol";

contract Deploy is Script {
    address public porepMarket;
    address public validatorFactory;
    address public clientSmartContract;
    address public spRegistry;
    address public filecoinPay;
    address public admin;
    address public allocator;
    address public terminationOracle;

    error InvalidEnv();

    function run() external {
        _ensureEnvsExist();

        admin = vm.addr(vm.envUint("ADMIN_PRIVATE_KEY"));
        allocator = vm.envAddress("ALLOCATOR");
        terminationOracle = vm.envAddress("TERMINATION_ORACLE");
        filecoinPay = vm.envAddress("FILECOIN_PAY");
        spRegistry = vm.envAddress("SP_REGISTRY");

        vm.startBroadcast(vm.envUint("ADMIN_PRIVATE_KEY"));

        validatorFactory = _deployValidatorFactory(admin);
        porepMarket = _deployPoRepMarket(admin, validatorFactory, spRegistry);
        clientSmartContract = _deployClientSmartContract(admin, allocator, terminationOracle, porepMarket);

        // circular dependencies
        PoRepMarket(porepMarket).setClientSmartContract(clientSmartContract);
        ValidatorFactory(validatorFactory).initialize2(porepMarket, clientSmartContract, filecoinPay);

        vm.stopBroadcast();

        _print();
    }

    function _ensureEnvsExist() internal view {
        if (
            !vm.envExists("RPC_TEST") || !vm.envExists("ADMIN_PRIVATE_KEY") || !vm.envExists("FILECOIN_PAY")
                || !vm.envExists("SP_REGISTRY") || !vm.envExists("ALLOCATOR") || !vm.envExists("TERMINATION_ORACLE")
        ) {
            revert InvalidEnv();
        }
    }

    function _deployValidatorFactory(address _admin) internal returns (address proxy) {
        Validator validatorImpl = new Validator();
        ValidatorFactory impl = new ValidatorFactory();
        bytes memory init = abi.encodeCall(ValidatorFactory.initialize, (_admin, address(validatorImpl)));
        proxy = _createProxy(init, address(impl));
    }

    function _deployPoRepMarket(address _admin, address _validatorFactory, address _spRegistry)
        internal
        returns (address proxy)
    {
        PoRepMarket impl = new PoRepMarket();
        bytes memory init = abi.encodeCall(PoRepMarket.initialize, (_admin, _validatorFactory, _spRegistry));
        proxy = _createProxy(init, address(impl));
    }

    function _deployClientSmartContract(
        address _admin,
        address _allocator,
        address _terminationOracle,
        address _porepMarket
    ) internal returns (address proxy) {
        Client impl = new Client();
        bytes memory init = abi.encodeCall(Client.initialize, (_admin, _allocator, _terminationOracle, _porepMarket));
        proxy = _createProxy(init, address(impl));
    }

    function _createProxy(bytes memory init, address impl) internal returns (address proxy) {
        proxy = address(new ERC1967Proxy(address(impl), init));
    }

    // solhint-disable no-console
    /**
     * @notice Prints the addresses of the deployed contracts
     * @dev Prints the addresses of the deployed contracts
     */
    function _print() internal view {
        console.log("Admin: %s", admin);
        console.log("PoRepMarket: %s", porepMarket);
        console.log("ValidatorFactory: %s", validatorFactory);
        console.log("ClientSmartContract: %s", clientSmartContract);
        console.log("FilecoinPay: %s", filecoinPay);
    }
    // solhint-enable no-console
}
