// SPDX-License-Identifier: MIT
pragma solidity =0.8.30;

/**
 * @title Piece-set commitment v1
 * @notice Reconstructs an ordered Merkle root and its versioned PoRep Market commitment.
 */
library PieceSetCommitment {
    uint8 internal constant VERSION = 1;
    bytes32 internal constant LEAF_DOMAIN = keccak256("PoRepMarket.PieceSet.Leaf");
    bytes32 internal constant NODE_DOMAIN = keccak256("PoRepMarket.PieceSet.Node");
    bytes32 internal constant EMPTY_DOMAIN = keccak256("PoRepMarket.PieceSet.Empty");
    bytes32 internal constant COMMITMENT_DOMAIN = keccak256("PoRepMarket.PieceSet.Commitment");

    /**
     * @dev 0x12e03a46
     */
    error ZeroPieceCount();
    /**
     * @dev 0x266da4b9
     */
    error PieceIndexOutOfBounds(uint32 pieceIndex, uint32 pieceCount);
    /**
     * @dev 0x301b70fa
     */
    error InvalidProofLength(uint256 expected, uint256 actual);

    /**
     * @notice Hashes one canonical piece row at its zero-based index.
     * @param pieceIndex Zero-based index in canonical row order.
     * @param pieceCidDigest CommP multihash digest.
     * @param paddedSize Padded piece size in bytes.
     * @return hash Domain-separated leaf hash.
     */
    function leaf(uint32 pieceIndex, bytes32 pieceCidDigest, uint64 paddedSize) internal pure returns (bytes32 hash) {
        return keccak256(abi.encode(LEAF_DOMAIN, VERSION, pieceIndex, pieceCidDigest, paddedSize));
    }

    /**
     * @notice Returns the leaf used to pad a non-power-of-two tree.
     * @return hash Domain-separated empty leaf hash.
     */
    function emptyLeaf() internal pure returns (bytes32 hash) {
        return keccak256(abi.encode(EMPTY_DOMAIN, VERSION));
    }

    /**
     * @notice Returns the exact proof depth for a complete padded tree.
     * @param pieceCount Non-zero number of committed rows.
     * @return depth Number of proof siblings required for any row.
     */
    function proofDepth(uint32 pieceCount) internal pure returns (uint256 depth) {
        if (pieceCount == 0) revert ZeroPieceCount();
        uint256 remaining = uint256(pieceCount) - 1;
        while (remaining != 0) {
            unchecked {
                ++depth;
            }
            remaining >>= 1;
        }
    }

    /**
     * @notice Reconstructs the ordered Merkle root for one committed row.
     * @param pieceIndex Zero-based index in canonical row order.
     * @param pieceCount Non-zero number of committed rows.
     * @param pieceCidDigest CommP multihash digest.
     * @param paddedSize Padded piece size in bytes.
     * @param proof Siblings ordered from leaf level to root.
     * @return current Reconstructed Merkle root.
     */
    function root(
        uint32 pieceIndex,
        uint32 pieceCount,
        bytes32 pieceCidDigest,
        uint64 paddedSize,
        bytes32[] memory proof
    ) internal pure returns (bytes32 current) {
        if (pieceCount == 0) revert ZeroPieceCount();
        if (!(pieceIndex < pieceCount)) revert PieceIndexOutOfBounds(pieceIndex, pieceCount);

        uint256 expectedDepth = proofDepth(pieceCount);
        if (proof.length != expectedDepth) revert InvalidProofLength(expectedDepth, proof.length);

        current = leaf(pieceIndex, pieceCidDigest, paddedSize);
        for (uint256 level = 0; level < expectedDepth; level++) {
            bytes32 sibling = proof[level];
            if ((uint256(pieceIndex) & (uint256(1) << level)) == 0) {
                current = keccak256(abi.encode(NODE_DOMAIN, current, sibling));
            } else {
                current = keccak256(abi.encode(NODE_DOMAIN, sibling, current));
            }
        }
    }

    /**
     * @notice Wraps a Merkle root with the exact count and requested byte total.
     * @param pieceCount Non-zero number of committed rows.
     * @param requestedSizeBytes Exact byte total committed by the deal.
     * @param merkleRoot Ordered padded-tree root.
     * @return hash Versioned piece-set commitment stored in `manifestHash`.
     */
    function commitment(uint32 pieceCount, uint256 requestedSizeBytes, bytes32 merkleRoot)
        internal
        pure
        returns (bytes32 hash)
    {
        if (pieceCount == 0) revert ZeroPieceCount();
        return keccak256(abi.encode(COMMITMENT_DOMAIN, VERSION, pieceCount, requestedSizeBytes, merkleRoot));
    }
}
