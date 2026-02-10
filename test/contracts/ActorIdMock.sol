// solhint-disable use-natspec
// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

contract ActorIdMock {
    bytes internal _getClaimsResult;
    uint256 internal constant VERIFREG_GET_CLAIMS = 2199871187;
    uint256 internal constant ADD_VERIFIED_CLIENT = 3916220144;
    uint256 internal constant IS_CONTROLLING_ADDRESS = 348244887;
    uint256 internal constant DATACAP_TRANSFER = 80475954;
    uint256 internal constant GET_OWNER = 3275365574;
    uint64 internal constant VERIFREG_ACTOR_ID = 6;
    uint64 internal constant DATACAP_ACTOR_ID = 7;

    error MethodNotFound(string mockName, uint256 methodNum, uint64 target);

    receive() external payable {}

    function setGetClaimsResult(bytes memory d) public {
        _getClaimsResult = d;
    }

    // solhint-disable-next-line no-complex-fallback
    fallback(bytes calldata data) external payable returns (bytes memory) {
        (uint256 methodNum,,,,, uint64 target) = abi.decode(data, (uint64, uint256, uint64, uint64, bytes, uint64));
        if (target == VERIFREG_ACTOR_ID) {
            if (methodNum == ADD_VERIFIED_CLIENT) return _handleAddVerifiedClient();
            if (methodNum == VERIFREG_GET_CLAIMS) return _handleVerifrefGetClaims();
        }

        if (target == DATACAP_ACTOR_ID) {
            if (methodNum == DATACAP_TRANSFER) return _handleDatacapTransfer();
        }

        if (methodNum == GET_OWNER) return _handleGetOwnerReturn(target);

        if (methodNum == IS_CONTROLLING_ADDRESS) return _handleIsControllingAddress();

        revert MethodNotFound("ActorIdMock", methodNum, target);
    }

    function _handleAddVerifiedClient() internal pure returns (bytes memory) {
        // Success send
        return abi.encode(0, 0x00, "");
    }

    function _handleVerifrefGetClaims() internal view returns (bytes memory) {
        return abi.encode(0, 0x51, _getClaimsResult);
    }

    function _handleDatacapTransfer() internal pure returns (bytes memory) {
        return abi.encode(0, 0x51, hex"834100410049838201808200808101");
    }

    function _handleGetOwnerReturn(uint64 target) internal pure returns (bytes memory) {
        if (target == 10000) return abi.encode(0, 0x51, hex"824400C2A101f6");
        // if (target == 321) return abi.encode(0, 0x51, hex"824300C10240");
        return abi.encode(0, 0x00, "");
    }

    function _handleIsControllingAddress() internal pure returns (bytes memory) {
        return abi.encode(0, 0x51, hex"F5");
    }
}
