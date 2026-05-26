// solhint-disable use-natspec
// SPDX-License-Identifier: MIT

pragma solidity =0.8.30;

import {CBORDecoder} from "filecoin-solidity/v0.8/utils/CborDecode.sol";

contract ActorIdMock {
    bytes internal _getClaimsResult;
    bytes internal _dataCapTransferResult;
    int256 internal _dataCapTransferExitCode;
    bytes internal _lastDataCapTransferOperatorData;
    uint256 internal constant VERIFREG_GET_CLAIMS = 2199871187;
    uint256 internal constant ADD_VERIFIED_CLIENT = 3916220144;
    uint256 internal constant IS_CONTROLLING_ADDRESS = 348244887;
    uint256 internal constant DATACAP_TRANSFER = 80475954;
    uint256 internal constant GET_OWNER = 3275365574;
    uint64 internal constant VERIFREG_ACTOR_ID = 6;
    uint64 internal constant DATACAP_ACTOR_ID = 7;

    error MethodNotFound(string mockName, uint256 methodNum, uint64 target);
    error InvalidOperatorData();
    error AllocationMissing();
    error InvalidAllocationRequest();
    error InvalidTransferParams();

    receive() external payable {}

    function setGetClaimsResult(bytes memory d) public {
        _getClaimsResult = d;
    }

    function setDataCapTransferResult(bytes memory d) public {
        _dataCapTransferResult = d;
    }

    function setDataCapTransferExitCode(int256 exitCode) public {
        _dataCapTransferExitCode = exitCode;
    }

    function lastDataCapTransferOperatorData() public view returns (bytes memory) {
        return _lastDataCapTransferOperatorData;
    }

    function lastDataCapTransferAllocation(uint256 targetIndex)
        public
        view
        returns (uint64 provider, bytes memory data, uint64 size, int64 termMin, int64 termMax, int64 expiration)
    {
        uint256 byteIdx = 0;
        uint256 resultLength;
        (resultLength, byteIdx) = CBORDecoder.readFixedArray(_lastDataCapTransferOperatorData, byteIdx);
        if (resultLength != 2) revert InvalidOperatorData();

        uint256 allocationCount;
        (allocationCount, byteIdx) = CBORDecoder.readFixedArray(_lastDataCapTransferOperatorData, byteIdx);
        if (allocationCount == 0 || targetIndex > allocationCount - 1) revert AllocationMissing();

        uint256 targetCount = targetIndex + 1;
        for (uint256 i = 0; i < targetCount; i++) {
            uint256 allocationRequestLength;
            (allocationRequestLength, byteIdx) = CBORDecoder.readFixedArray(_lastDataCapTransferOperatorData, byteIdx);
            if (allocationRequestLength != 6) revert InvalidAllocationRequest();

            (provider, byteIdx) = CBORDecoder.readUInt64(_lastDataCapTransferOperatorData, byteIdx);
            (data, byteIdx) = CBORDecoder.readBytes(_lastDataCapTransferOperatorData, byteIdx);
            (size, byteIdx) = CBORDecoder.readUInt64(_lastDataCapTransferOperatorData, byteIdx);
            (termMin, byteIdx) = CBORDecoder.readInt64(_lastDataCapTransferOperatorData, byteIdx);
            (termMax, byteIdx) = CBORDecoder.readInt64(_lastDataCapTransferOperatorData, byteIdx);
            (expiration, byteIdx) = CBORDecoder.readInt64(_lastDataCapTransferOperatorData, byteIdx);
        }
    }

    // solhint-disable-next-line no-complex-fallback
    fallback(bytes calldata data) external payable returns (bytes memory) {
        (uint256 methodNum,,,,, uint64 target) = abi.decode(data, (uint64, uint256, uint64, uint64, bytes, uint64));
        if (target == VERIFREG_ACTOR_ID) {
            if (methodNum == ADD_VERIFIED_CLIENT) return _handleAddVerifiedClient();
            if (methodNum == VERIFREG_GET_CLAIMS) return _handleVerifrefGetClaims();
        }

        if (target == DATACAP_ACTOR_ID) {
            if (methodNum == DATACAP_TRANSFER) return _handleDatacapTransfer(data);
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

    function _handleDatacapTransfer(bytes calldata data) internal returns (bytes memory) {
        (,,,, bytes memory rawRequest,) = abi.decode(data, (uint64, uint256, uint64, uint64, bytes, uint64));
        _lastDataCapTransferOperatorData = _decodeDataCapTransferOperatorData(rawRequest);
        return abi.encode(_dataCapTransferExitCode, 0x51, _dataCapTransferResult);
    }

    function _decodeDataCapTransferOperatorData(bytes memory rawRequest)
        internal
        pure
        returns (bytes memory operatorData)
    {
        uint256 byteIdx = 0;
        uint256 paramsLength;
        (paramsLength, byteIdx) = CBORDecoder.readFixedArray(rawRequest, byteIdx);
        if (paramsLength != 3) revert InvalidTransferParams();

        (, byteIdx) = CBORDecoder.readBytes(rawRequest, byteIdx); // to
        (, byteIdx) = CBORDecoder.readBytes(rawRequest, byteIdx); // amount
        (operatorData, byteIdx) = CBORDecoder.readBytes(rawRequest, byteIdx);
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
