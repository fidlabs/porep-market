// SPDX-License-Identifier: MIT
// solhint-disable use-natspec, one-contract-per-file, gas-small-strings
pragma solidity =0.8.30;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {PieceSetCommitment} from "../../src/lib/PieceSetCommitment.sol";

contract PieceSetCommitmentHarness {
    function domains()
        external
        pure
        returns (bytes32 leafDomain, bytes32 nodeDomain, bytes32 emptyDomain, bytes32 commitmentDomain)
    {
        return (
            PieceSetCommitment.LEAF_DOMAIN,
            PieceSetCommitment.NODE_DOMAIN,
            PieceSetCommitment.EMPTY_DOMAIN,
            PieceSetCommitment.COMMITMENT_DOMAIN
        );
    }

    function leaf(uint32 pieceIndex, bytes32 pieceCidDigest, uint64 paddedSize) external pure returns (bytes32) {
        return PieceSetCommitment.leaf(pieceIndex, pieceCidDigest, paddedSize);
    }

    function emptyLeaf() external pure returns (bytes32) {
        return PieceSetCommitment.emptyLeaf();
    }

    function proofDepth(uint32 pieceCount) external pure returns (uint256) {
        return PieceSetCommitment.proofDepth(pieceCount);
    }

    function root(
        uint32 pieceIndex,
        uint32 pieceCount,
        bytes32 pieceCidDigest,
        uint64 paddedSize,
        bytes32[] calldata proof
    ) external pure returns (bytes32) {
        return PieceSetCommitment.root(pieceIndex, pieceCount, pieceCidDigest, paddedSize, proof);
    }

    function commitment(uint32 pieceCount, uint256 requestedSizeBytes, bytes32 merkleRoot)
        external
        pure
        returns (bytes32)
    {
        return PieceSetCommitment.commitment(pieceCount, requestedSizeBytes, merkleRoot);
    }
}

contract PieceSetCommitmentTest is Test {
    using stdJson for string;

    bytes32 internal constant LEAF_DOMAIN = 0xde24299ea19a4e461e31a0be02e5c601b2f66c1f3786214aa46f553fde6f7179;
    bytes32 internal constant NODE_DOMAIN = 0xaedbcc7b5d2c40692870fd30607e9e30315a8153c6b3a368ef838aec7de83b5d;
    bytes32 internal constant EMPTY_LEAF = 0x784f6484cd3db69cd3d40f6148c228e3ef179ced49d461ca765d98c6ac8fc45e;
    bytes32 internal constant COMMITMENT_DOMAIN = 0x30999723613fc3c0c783e4cfe2d089b89c98f5f609e29f18d0c8eefcc99be0b6;
    bytes32 internal constant DIGEST_0 = 0x1111111111111111111111111111111111111111111111111111111111111111;
    bytes32 internal constant DIGEST_1 = 0x2222222222222222222222222222222222222222222222222222222222222222;
    bytes32 internal constant DIGEST_2 = 0x3333333333333333333333333333333333333333333333333333333333333333;

    PieceSetCommitmentHarness internal harness;

    function setUp() public {
        harness = new PieceSetCommitmentHarness();
    }

    function testFixedThreePieceVector() public view {
        (bytes32 leafDomain, bytes32 nodeDomain, bytes32 emptyDomain, bytes32 commitmentDomain) = harness.domains();
        assertEq(leafDomain, 0xde24299ea19a4e461e31a0be02e5c601b2f66c1f3786214aa46f553fde6f7179);
        assertEq(nodeDomain, 0xaedbcc7b5d2c40692870fd30607e9e30315a8153c6b3a368ef838aec7de83b5d);
        assertEq(emptyDomain, 0x678499e9bc60f37870b6a17ee59af33c4f4b303a121e0769acd22450b495ed08);
        assertEq(commitmentDomain, 0x30999723613fc3c0c783e4cfe2d089b89c98f5f609e29f18d0c8eefcc99be0b6);

        assertEq(harness.leaf(0, DIGEST_0, 128), 0x7b3f821ecaf580689a1225ed5be95f9c22621f15ee6a361928610240c223ca2d);
        assertEq(harness.leaf(1, DIGEST_1, 256), 0xedc035b821e84e0482006816069b1cc6b5a20171ac9d5ff1d5252e91e40f6d2f);
        assertEq(harness.leaf(2, DIGEST_2, 512), 0x558e19c7b594efff94ac0115d7f4a9583c918d4fffdd21d0939843946b607801);
        assertEq(harness.emptyLeaf(), 0x784f6484cd3db69cd3d40f6148c228e3ef179ced49d461ca765d98c6ac8fc45e);

        bytes32[] memory proof = new bytes32[](2);
        proof[0] = 0xedc035b821e84e0482006816069b1cc6b5a20171ac9d5ff1d5252e91e40f6d2f;
        proof[1] = 0x35b44e36ef6aeec3f6ebd0ab06c70a88b73225ffe2ae6b70dcd48814503711dc;
        bytes32 root = harness.root(0, 3, DIGEST_0, 128, proof);
        assertEq(root, 0x0ffe7f5a9fbfc28df65d7609707390a500c2f54a04f07d31632fcb20d86729a1);
        assertEq(harness.commitment(3, 896, root), 0x9b09a902598a2e1320b33cebf3c66f4fc6c4afe230ec4550a8053bbef66673c9);
        assertEq(harness.proofDepth(3), 2);
    }

    function testCanonicalJsonFixtureMatchesImplementation() public view {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/piece-set-commitment-v1.json"));
        (bytes32 leafDomain, bytes32 nodeDomain, bytes32 emptyDomain, bytes32 commitmentDomain) = harness.domains();
        assertEq(json.readUint(".version"), 1);
        assertEq(json.readBytes32(".domains.leaf"), leafDomain);
        assertEq(json.readBytes32(".domains.node"), nodeDomain);
        assertEq(json.readBytes32(".domains.empty"), emptyDomain);
        assertEq(json.readBytes32(".domains.commitment"), commitmentDomain);
        assertEq(json.readBytes32(".emptyLeaf"), harness.emptyLeaf());

        bytes32[] memory proof = json.readBytes32Array(".vectors[2].rows[0].proof");
        bytes32 root = harness.root(
            uint32(json.readUint(".vectors[2].rows[0].index")),
            uint32(json.readUint(".vectors[2].pieceCount")),
            json.readBytes32(".vectors[2].rows[0].digest"),
            uint64(vm.parseUint(json.readString(".vectors[2].rows[0].paddedSize"))),
            proof
        );
        assertEq(root, json.readBytes32(".vectors[2].root"));
        assertEq(
            harness.commitment(
                uint32(json.readUint(".vectors[2].pieceCount")),
                vm.parseUint(json.readString(".vectors[2].requestedSizeBytes")),
                root
            ),
            json.readBytes32(".vectors[2].commitment")
        );
    }

    function testFixedOneAndTwoPieceVectors() public view {
        bytes32[] memory emptyProof = new bytes32[](0);
        bytes32 singleRoot = harness.root(0, 1, DIGEST_0, 128, emptyProof);
        assertEq(singleRoot, 0x7b3f821ecaf580689a1225ed5be95f9c22621f15ee6a361928610240c223ca2d);
        assertEq(
            harness.commitment(1, 128, singleRoot), 0xb61dd264461b3cdd244113ac78b02b1e851b311909242cc15230e4a88c0e75b3
        );

        bytes32[] memory proof0 = new bytes32[](1);
        proof0[0] = 0xedc035b821e84e0482006816069b1cc6b5a20171ac9d5ff1d5252e91e40f6d2f;
        bytes32[] memory proof1 = new bytes32[](1);
        proof1[0] = 0x7b3f821ecaf580689a1225ed5be95f9c22621f15ee6a361928610240c223ca2d;
        bytes32 root0 = harness.root(0, 2, DIGEST_0, 128, proof0);
        bytes32 root1 = harness.root(1, 2, DIGEST_1, 256, proof1);
        assertEq(root0, 0x05613c7fe68a92c02e6921b5ff6fb851c700b4daf9acd85e583c6d073213aec9);
        assertEq(root1, root0);
        assertEq(harness.commitment(2, 384, root0), 0xf4ee2025495c6097306d770bbcdb4141ad797344b7cbad0d51681addbd887699);
    }

    function testEveryProofForThreeAndTenPieces() public view {
        bytes32 expectedThree = 0x0ffe7f5a9fbfc28df65d7609707390a500c2f54a04f07d31632fcb20d86729a1;
        bytes32[] memory proof0 = new bytes32[](2);
        proof0[0] = 0xedc035b821e84e0482006816069b1cc6b5a20171ac9d5ff1d5252e91e40f6d2f;
        proof0[1] = 0x35b44e36ef6aeec3f6ebd0ab06c70a88b73225ffe2ae6b70dcd48814503711dc;
        bytes32[] memory proof1 = new bytes32[](2);
        proof1[0] = 0x7b3f821ecaf580689a1225ed5be95f9c22621f15ee6a361928610240c223ca2d;
        proof1[1] = 0x35b44e36ef6aeec3f6ebd0ab06c70a88b73225ffe2ae6b70dcd48814503711dc;
        bytes32[] memory proof2 = new bytes32[](2);
        proof2[0] = 0x784f6484cd3db69cd3d40f6148c228e3ef179ced49d461ca765d98c6ac8fc45e;
        proof2[1] = 0x05613c7fe68a92c02e6921b5ff6fb851c700b4daf9acd85e583c6d073213aec9;
        assertEq(harness.root(0, 3, DIGEST_0, 128, proof0), expectedThree);
        assertEq(harness.root(1, 3, DIGEST_1, 256, proof1), expectedThree);
        assertEq(harness.root(2, 3, DIGEST_2, 512, proof2), expectedThree);

        bytes32 expectedTen = 0xc04c1106153dd536ff6434ee8c87bbd70ed1a0f7eedb6f3b8ad922ce166da459;
        for (uint32 i = 0; i < 10; i++) {
            (bytes32[] memory proof,,) = _generatedVector(10, i);
            bytes32 digest = bytes32(uint256(i) + 1);
            assertEq(harness.root(i, 10, digest, 128, proof), expectedTen);
        }
    }

    function testGeneratedScaleRootsAndCommitmentsAreFixed() public view {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/test/fixtures/piece-set-commitment-v1.json"));
        _assertGeneratedFixtureVector(json, 10);
        _assertGeneratedFixtureVector(json, 64);
        _assertGeneratedFixtureVector(json, 305);
        _assertGeneratedFixtureVector(json, 945);
        _assertGeneratedFixtureVector(json, 1393);
    }

    function testProofDepthBoundaries() public view {
        assertEq(harness.proofDepth(1), 0);
        assertEq(harness.proofDepth(2), 1);
        assertEq(harness.proofDepth(3), 2);
        assertEq(harness.proofDepth(10), 4);
        assertEq(harness.proofDepth(64), 6);
        assertEq(harness.proofDepth(305), 9);
        assertEq(harness.proofDepth(945), 10);
        assertEq(harness.proofDepth(1393), 11);
        assertEq(harness.proofDepth(type(uint32).max), 32);
    }

    function testInvalidCountIndexAndProofLengthRevert() public {
        bytes32[] memory proof = new bytes32[](0);
        vm.expectRevert(PieceSetCommitment.ZeroPieceCount.selector);
        harness.proofDepth(0);
        vm.expectRevert(PieceSetCommitment.ZeroPieceCount.selector);
        harness.root(0, 0, DIGEST_0, 128, proof);
        vm.expectRevert(abi.encodeWithSelector(PieceSetCommitment.PieceIndexOutOfBounds.selector, 1, 1));
        harness.root(1, 1, DIGEST_0, 128, proof);
        vm.expectRevert(abi.encodeWithSelector(PieceSetCommitment.InvalidProofLength.selector, 2, 0));
        harness.root(0, 3, DIGEST_0, 128, proof);
        vm.expectRevert(PieceSetCommitment.ZeroPieceCount.selector);
        harness.commitment(0, 0, bytes32(0));
    }

    function testChangedIndexCidSizeSiblingCountRequestedBytesAndRootDoNotMatchVector() public view {
        bytes32 expectedRoot = 0x0ffe7f5a9fbfc28df65d7609707390a500c2f54a04f07d31632fcb20d86729a1;
        bytes32 expectedCommitment = 0x9b09a902598a2e1320b33cebf3c66f4fc6c4afe230ec4550a8053bbef66673c9;
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = 0xedc035b821e84e0482006816069b1cc6b5a20171ac9d5ff1d5252e91e40f6d2f;
        proof[1] = 0x35b44e36ef6aeec3f6ebd0ab06c70a88b73225ffe2ae6b70dcd48814503711dc;
        assertNotEq(harness.root(1, 3, DIGEST_0, 128, proof), expectedRoot);
        assertNotEq(harness.root(0, 3, DIGEST_1, 128, proof), expectedRoot);
        assertNotEq(harness.root(0, 3, DIGEST_0, 256, proof), expectedRoot);
        proof[0] = bytes32(uint256(123));
        assertNotEq(harness.root(0, 3, DIGEST_0, 128, proof), expectedRoot);
        assertNotEq(harness.commitment(2, 896, expectedRoot), expectedCommitment);
        assertNotEq(harness.commitment(3, 897, expectedRoot), expectedCommitment);
        assertNotEq(harness.commitment(3, 896, bytes32(uint256(123))), expectedCommitment);
    }

    function _assertGeneratedVector(uint32 pieceCount, bytes32 expectedRoot, bytes32 expectedCommitment) private view {
        (bytes32[] memory proof, bytes32 root, bytes32 commitment) = _generatedVector(pieceCount, 0);
        assertEq(root, expectedRoot);
        assertEq(commitment, expectedCommitment);
        assertEq(harness.root(0, pieceCount, bytes32(uint256(1)), 128, proof), expectedRoot);
        assertEq(harness.commitment(pieceCount, uint256(pieceCount) * 128, root), expectedCommitment);
    }

    function _assertGeneratedFixtureVector(string memory json, uint32 pieceCount) private view {
        string memory prefix = string.concat(".generatedScaleVectors.", vm.toString(pieceCount));
        assertEq(json.readUint(string.concat(prefix, ".depth")), harness.proofDepth(pieceCount));
        _assertGeneratedVector(
            pieceCount,
            json.readBytes32(string.concat(prefix, ".root")),
            json.readBytes32(string.concat(prefix, ".commitment"))
        );
    }

    function _generatedVector(uint32 pieceCount, uint32 targetIndex)
        private
        pure
        returns (bytes32[] memory proof, bytes32 root, bytes32 commitment)
    {
        uint64 paddedSize = 128;
        uint256 width = 1;
        uint256 depth;
        while (width < pieceCount) {
            width <<= 1;
            ++depth;
        }
        bytes32[] memory level = new bytes32[](width);
        for (uint256 i = 0; i < pieceCount; i++) {
            bytes32 digest = bytes32(i + 1);
            // `i` is bounded by the uint32 `pieceCount`.
            // forge-lint: disable-next-line(unsafe-typecast)
            level[i] = keccak256(abi.encode(LEAF_DOMAIN, uint8(1), uint32(i), digest, paddedSize));
        }
        for (uint256 i = pieceCount; i < width; i++) {
            level[i] = EMPTY_LEAF;
        }

        proof = new bytes32[](depth);
        uint256 target = targetIndex;
        uint256 activeWidth = width;
        for (uint256 height = 0; height < depth; height++) {
            proof[height] = level[target ^ 1];
            for (uint256 i = 0; i < activeWidth; i += 2) {
                level[i >> 1] = keccak256(abi.encode(NODE_DOMAIN, level[i], level[i + 1]));
            }
            target >>= 1;
            activeWidth >>= 1;
        }
        root = level[0];
        commitment =
            keccak256(abi.encode(COMMITMENT_DOMAIN, uint8(1), pieceCount, uint256(pieceCount) * paddedSize, root));
    }
}
