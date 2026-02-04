// solhint-disable use-natspec
// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

contract ActorIdMock {
    bytes internal _getClaimsResult;

    error MethodNotFound();
    event Tutaj();
    receive() external payable {}

    function setGetClaimsResult(bytes memory d) public {
        _getClaimsResult = d;
    }

    function handleAddVerifiedClient() internal pure returns (bytes memory) {
        // Success send
        return abi.encode(0, 0x00, "");
    }

    // solhint-disable-next-line no-complex-fallback
    fallback(bytes calldata data) external payable returns (bytes memory) {
        (uint256 methodNum,,,,, uint64 target) = abi.decode(data, (uint64, uint256, uint64, uint64, bytes, uint64));
        if (methodNum == 3916220144) {
            return handleAddVerifiedClient();
        }
        if (methodNum == 3275365574) {
            return abi.encode(0, 0x51, hex"824400C2A101f6");
        }

        if (methodNum == 348244887) {
            return abi.encode(0, 0x51, hex"F5");
        }

        if (target == 6 && methodNum == 2199871187) {
            // verifreg get claims
            return abi.encode(0, 0x51, _getClaimsResult);
        }
        if (target == 7 && methodNum == 80475954) {
            // datacap transfer
            // return abi.encode(0, 0x51, hex"83808083410141024103");
            return abi.encode(0, 0x51, hex"834100410049838201808200808101");
        }
        if (target == 321 && methodNum == 3275365574) {
            return abi.encode(0, 0x51, hex"824300C10240");
        }
        revert MethodNotFound();
    }
}
