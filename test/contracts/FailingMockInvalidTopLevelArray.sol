// solhint-disable use-natspec
// SPDX-License-Identifier: MIT

pragma solidity 0.8.25;

contract FailingMockInvalidTopLevelArray {
    uint256 private constant VERIFREG_GET_CLAIMS = 2199871187;
    uint256 private constant ADD_VERIFIED_CLIENT = 3916220144;
    uint256 private constant DATACAP_TRANSFER = 80475954;
    uint256 private constant GET_OWNER = 3275365574;
    uint64 private constant VERIFREG_ACTOR_ID = 6;
    uint64 private constant DATACAP_ACTOR_ID = 7;
    uint8 private constant EXIT_CODE_ERROR = 1;
    uint8 private constant EXIT_CODE_SUCCESS = 0;
    error MethodNotFound(string mockName, uint256 methodNum, uint64 target);
    receive() external payable {}

    // solhint-disable-next-line no-complex-fallback
    fallback(bytes calldata data) external payable returns (bytes memory) {
        (uint256 methodNum,,,,, uint64 target) = abi.decode(data, (uint64, uint256, uint64, uint64, bytes, uint64));
        if (target == VERIFREG_ACTOR_ID) {
            if (methodNum == VERIFREG_GET_CLAIMS) return _handleVerifregGetClaims();
            if (methodNum == ADD_VERIFIED_CLIENT) return _handleAddVerifiedClient();
        }
        if (target == DATACAP_ACTOR_ID && methodNum == DATACAP_TRANSFER) return _handleDatacapTransfer();

        revert MethodNotFound("FailingMockInvalidTopLevelArray", methodNum, target);
    }

    function _handleVerifregGetClaims() internal pure returns (bytes memory) {
        return abi.encode(
            EXIT_CODE_SUCCESS,
            0x51,
            hex"8282018081881903E81866D82A5828000181E203922020071E414627E89D421B3BAFCCB24CBA13DDE9B6F388706AC8B1D48E58935C76381908001A003815911A005034D60000"
        );
    }

    function _handleAddVerifiedClient() internal pure returns (bytes memory) {
        return abi.encode(EXIT_CODE_SUCCESS, 0x00, "");
    }

    function _handleDatacapTransfer() internal pure returns (bytes memory) {
        return abi.encode(EXIT_CODE_SUCCESS, 0x51, hex"83410041004A84808201808200808101");
    }
}
