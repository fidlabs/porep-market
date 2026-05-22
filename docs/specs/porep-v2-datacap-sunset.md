# PoRep V2 DataCap Sunset and Storage Evidence Transition

Status: draft for review.

`DataCapEvidenceAdapter` has a finite operational lifetime. This document
covers the transition plan, on-chain evidence requirements, and replacement
adapter paths.

## Table of Contents

- [Context](#context)
- [FIP-1249 Impact By Deal State](#fip-1249-impact-by-deal-state)
- [On-Chain Evidence After DataCap](#on-chain-evidence-after-datacap)
- [Sector Data Pinning](#sector-data-pinning)
- [Recommended On-Chain Requirements](#recommended-on-chain-requirements)
- [Replacement Adapter: PieceEvidenceAdapter](#replacement-adapter-pieceevidenceadapter)
- [Fallback: OracleEvidenceAdapter](#fallback-oracleevidenceadapter)
- [Transition Strategy](#transition-strategy)
- [Open Design Questions](#open-design-questions)

## Context

FIP-1249 proposes deprecating Filecoin Plus and removing the DataCap token and
VerifReg allocation/claim system. The PR (filecoin-project/builtin-actors#1744)
is not final. The timeline, exact scope, and what on-chain primitives replace
VerifReg are still being designed. We may have influence over what goes on-chain
before DataCap removal.

This is an opportunity. The V2 adapter abstraction was designed for this
transition. The question is not whether to support post-DataCap evidence, but
what on-chain primitives the replacement adapter needs.

### What FIP-1249 blocks

When FIP-1249 activates:

| Capability | Status |
| --- | --- |
| `UniversalReceiverHook` (new allocations) | Blocked (`USR_FORBIDDEN`) |
| `ClaimAllocations` (new claims) | Blocked (`USR_FORBIDDEN`) |
| `ExtendClaimTerms` | Blocked (`USR_FORBIDDEN`) |
| `GetClaims` (read existing claims) | Still works |
| `RemoveExpiredAllocations/Claims` | Still works |
| Market `SectorContentChanged` | Still works (events only) |
| Market `GetDealSector` | Still works |

### What FIP-1249 does not block

`GetClaims` remains available for reading existing claims. Existing claims are
not deleted; they drain naturally via expiration. This means evidence for deals
that already have claims can still be verified after FIP-1249 activates.

## FIP-1249 Impact By Deal State

### ACTIVE deals (already activated, payment flowing)

No impact. Settlement is deterministic from frozen deal state:
`pricePer32GiBPerMonth`, `billed32GiBUnits`, `serviceStartEpoch`,
`serviceEndEpoch`. None of these depend on VerifReg. These deals continue to
completion with no action needed.

If ongoing claim health monitoring is added later, `GetClaims` still works for
existing claims.

### ACCEPTED deals with verified claims (evidence batches submitted)

`GetClaims` still works. Any remaining evidence batches can still be submitted
and activation can proceed. These deals can activate normally after FIP-1249.

### ACCEPTED deals with allocations but no claims

The SP needs `ClaimAllocations` to turn allocations into claims. This is blocked
post-FIP-1249. These deals are stuck.

Resolution: if FIP-1249 is imminent, SP tooling must race to claim all posted
allocations before activation. If the deadline passes, the adapter reports
`isOperational() == false` and the market admin rejects stuck deals. Clients
re-propose with the replacement adapter.

### ACCEPTED deals with no allocations

`DataCapAPI.transfer()` triggers `UniversalReceiverHook` which is blocked
post-FIP-1249. No new allocations can be posted.

Resolution: same as above. Admin rejection, client re-proposes with replacement
adapter.

### PROPOSED deals

If the selected adapter is `DataCapEvidenceAdapter`, the deal cannot progress.
These deals should be rejected or expired normally.

## On-Chain Evidence After DataCap

The core question: how does a smart contract verify "provider X stores data Y"
without VerifReg claims?

### What exists today

1. **VerifReg claims** (finite lifetime): `GetClaims` returns `{provider,
   client, data_cid, size, sector, term_min, term_max, term_start}`. This is the
   strongest evidence, but only for existing pre-sunset claims.

2. **Market actor `SectorContentChanged`**: When a miner activates a sector
   with pieces, the miner calls this hook on the market actor. The market records
   the piece-to-sector binding. However, this is currently driven by deal-based
   piece activation; its behavior post-DataCap-removal depends on FIP-1249's
   scope.

3. **Market actor `GetDealSector`**: Returns the sector number for a deal ID.
   Works post-FIP-1249 for existing deals.

4. **Miner sector info**: `SectorOnChainInfo` contains `sealed_cid` (CommR) and
   power/expiration data, but does NOT contain individual piece CIDs. Piece
   granularity comes from the market actor or VerifReg, not from the miner state
   directly.

### Relevant network changes and proposals

Two in-progress Filecoin changes are directly relevant to the post-DataCap
evidence path:

**NV28 (network upgrade)**: Exposes sector status to smart contracts. After
NV28, an FEVM contract can check whether a sector is active, its expiration,
and its power. This is necessary but not sufficient: sector status tells you
the sector exists, but not which pieces are in it. The data-to-sector mapping
is still missing from sector status alone.

**FIP-0109 (DDO sector content notifications)**: Proposes a smart-contract-based
sector content notification mechanism. When a miner activates a sector containing
pieces, a notification can be sent to a registered smart contract. This is
conceptually similar to `SectorContentChanged` but designed for FEVM contracts
rather than exclusively for the built-in market actor.

The trust model for FIP-0109 notifications is not fully resolved: whether they
are protocol-enforced (miner must call), tool-enforced (tooling triggers the
call), or SP-claimable (the provider decides to notify) affects how much the
adapter can rely on them as evidence. If notifications are not protocol-enforced,
a provider could seal data and never notify, leaving the adapter with no
evidence.

These changes affect the replacement adapter design:

| Mechanism | What it provides | What it lacks |
| --- | --- | --- |
| NV28 sector status | Sector liveness, expiration, power | Piece-level data; no mapping from CID to sector |
| FIP-0109 notifications | Piece-to-sector binding at activation time | Uncertain trust model; no persistent queryable state (event-only); no unpin/removal notification |
| Data pinning (planned) | Pin/unpin as on-chain state changes | Timeline uncertain; design not finalized |

The ideal post-DataCap evidence path combines NV28 sector status (is the sector
alive?) with either persistent FIP-0109-derived state or data pinning state (is
piece X in that sector?). Neither alone is sufficient.

These mechanisms are not final. The timeline, exact scope, and trust properties
are still being designed. V2's adapter abstraction is positioned to consume
whichever combination ships first.

### What is missing

There is no general-purpose on-chain query: "is piece CID X currently in an
active sector of provider Y?" outside of VerifReg claims and market deals. This
is the gap that a replacement adapter needs filled.

### Critical gap: `SectorContentChanged` and V2 deals

The built-in market actor's `provider_sectors` HAMT tracks piece-to-sector
bindings, but only for deals created through the built-in market actor. V2 deals
are created on PoRepMarket (an FEVM contract), not the built-in market. The
miner actor calls `SectorContentChanged` on the built-in market, not on
PoRepMarket.

This means: even existing `SectorContentChanged` state will not be populated
for V2 deals unless the miner actor is modified to report piece membership
independently of built-in market deals. This gap must be addressed either by:

- modifying the miner actor to call a configurable hook (not just the built-in
  market) when sector content changes, or
- introducing a separate piece-membership actor that the miner reports to, or
- the data pinning feature providing queryable piece state that is independent
  of the built-in market actor.

This is a key requirement for the FIP proposal (see separate FIP document).

## Sector Data Pinning

A planned Filecoin feature will allow sectors and data to become independent
entities. Miners will be able to create sectors and then pin/unpin data
independently, similar to SnapDeals but bidirectional. Data can be pinned into a
sector and later unpinned (removed) without terminating the sector.

This feature is planned but not finalized. It is expected to arrive around or
after DataCap removal.

### Why this matters for V2

If pinning is an explicit on-chain action with queryable state, it becomes the
natural replacement for VerifReg claims as storage evidence. A pin event proves
the provider committed to storing specific data in a specific sector.

### Requirements for V2 compatibility

For data pinning to work as V2 storage evidence, the following must be true:

1. **Pin state must be queryable**: a smart contract must be able to call
   something like `isPinned(provider, pieceCID) returns (bool, sectorId)` or
   enumerate pinned pieces for a provider. Without this, the adapter cannot
   verify storage.

2. **Unpin must be detectable**: if a provider silently unpins data, the market
   continues paying for unstored data. Either unpinning must emit a queryable
   state change, or periodic verification must be possible.

3. **Pin must be provider-committed**: pinning should involve provider-side
   proof of data inclusion (PoRep or equivalent). If pinning is a cheap metadata
   operation without proof, the evidence model weakens.

4. **Pin history should not be required for settlement**: normal settlement
   must work from current pin state (or aggregated state), not by iterating pin
   history. This matches V2's settlement design.

### Risks

- If unpin is silent (no on-chain state change), the market cannot detect data
  removal during settlement. The adapter would need an external challenge
  mechanism or periodic verification.
- If pinning is cheap (no sealing cost), the incentive to actually store data
  weakens. A provider could pin, collect payment, and unpin after each check.
- If the market relies on pin state and a provider temporarily unpins to
  reorganize sectors, it could trigger false termination.
- If pin/unpin state is per-sector (not per-piece), the adapter needs to map
  pieces to sectors, adding complexity.

## Recommended On-Chain Requirements

These are requirements for the Filecoin core network that V2 needs to function
post-DataCap. They may be suitable for a FIP or a formal request to the Filecoin
Foundation.

### Must-have for replacement adapter

1. **Piece membership query**: an on-chain method to check whether a specific
   piece CID is currently stored by a specific provider. This could be:
   - A new actor method: `hasPiece(provider, pieceCID) returns (bool)`
   - Queryable pin state from the data pinning feature
   - A persistent, queryable form of `SectorContentChanged` data

2. **Piece lifecycle events with on-chain state**: `SectorContentChanged`
   currently produces events, but the piece-to-sector bindings must persist as
   queryable state (not just historical events). A smart contract cannot read
   historical events.

3. **Provider-scoped piece enumeration** (optional but useful): the ability to
   enumerate or count pieces stored by a provider, or at minimum to query total
   stored bytes for a provider. This supports aggregate checks without iterating
   every piece.

### Nice-to-have

4. **Piece change notifications**: a hook or callback when piece membership
   changes (pin/unpin/sector termination). This would let the adapter react to
   storage changes rather than poll.

5. **Batch piece query**: check multiple piece CIDs in one call for gas
   efficiency on large deals.

### What exists that is close

- `SectorContentChanged` in the market actor already tracks piece activation.
  Making this data persist as queryable state (not just events) would satisfy
  requirements 1 and 2.
- The data pinning feature, if it includes queryable pin state, would satisfy
  requirements 1 and 2 directly.
- VerifReg `GetClaims` satisfies all requirements for existing claims, but only
  for pre-sunset allocations.

## Replacement Adapter: PieceEvidenceAdapter

This is the preferred long-term path assuming on-chain piece membership queries
become available.

### Interface (same as IStorageEvidenceAdapter)

The adapter implements the same `submitEvidenceBatch` / `activateEvidence`
interface. What changes is the evidence format and validation logic.

### Evidence flow

1. Client proposes deal with `PieceEvidenceAdapter` as selected adapter
2. Client submits piece manifest off-chain to the SP
3. SP stores data in sectors (pin operation or standard sealing)
4. Tooling calls `submitEvidenceBatch` with piece CIDs from the manifest
5. Adapter calls the on-chain piece membership query for each piece CID,
   verifying the provider has it in an active sector
6. Adapter accumulates covered bytes from verified pieces
7. When enough bytes are covered, `activateEvidence` activates the deal

### What the adapter stores per deal

```
PieceDealEvidence {
    uint256 verifiedPieceCount;
    uint256 coveredBytes;
    bool activationReady;
}
```

No allocation IDs or claim IDs. Simpler than `DataCapEvidenceAdapter`.

### Advantages over DataCap path

- No DataCap token transfer ceremony
- No allocation/claim lifecycle to manage
- No `finishDataCapPosting` step (no posting phase at all)
- Simpler deal flow: propose → accept → prepare rail → SP stores data →
  submit evidence → activate
- The `submitDataCapBatch` + `finishDataCapPosting` steps disappear entirely
  from the deal flow

### Dependencies

Requires on-chain piece membership query (see recommended requirements above).
Cannot be built until that primitive exists.

## Fallback: OracleEvidenceAdapter

If on-chain piece membership queries are not available when DataCap is removed,
this is the last-resort fallback to keep the market functional.

A trusted oracle network attests that a provider has committed sectors
containing specific piece CIDs. The oracle uses existing off-chain
infrastructure (BMS retrievability testing, SLI measurements) as evidence.

### Trust model

The oracle is operated by market administrators. This is weaker than on-chain
evidence because the oracle can attest falsely (or be compromised). This path
is acceptable only for a transition period with known, trusted market
participants.

### Evidence format

```
OracleAttestation {
    uint256 dealId;
    FilActorId provider;
    bytes32 pieceSetCommitment;
    uint256 coveredBytes;
    ChainEpoch attestationEpoch;
    bytes signature;
}
```

The adapter verifies the oracle signature, checks `pieceSetCommitment` matches
the frozen deal, and accumulates covered bytes.

### Why this is a last resort

- Trust is centralized in the oracle operator
- No on-chain verification of actual storage
- Oracle downtime blocks deal activation
- Regulatory and decentralization concerns

This adapter should be deployed only if the on-chain path is not ready when
DataCap removal activates, and should be replaced as soon as on-chain piece
queries are available.

## Transition Strategy

### Preferred path (on-chain evidence available before DataCap removal)

1. Deploy V2 with `DataCapEvidenceAdapter` for initial deals
2. Propose on-chain piece membership requirements to Filecoin Foundation (FIP or
   formal request)
3. When piece membership queries ship (via data pinning or persistent
   `SectorContentChanged` state), deploy `PieceEvidenceAdapter` and allowlist it
4. New deals use `PieceEvidenceAdapter`; existing DataCap deals continue on
   their frozen adapter
5. When FIP-1249 activates, `DataCapEvidenceAdapter.isOperational()` returns
   false
6. Admin rejects any stuck ACCEPTED deals on the dead adapter; clients
   re-propose with `PieceEvidenceAdapter`
7. ACTIVE DataCap deals run to completion on frozen settlement math

### Fallback path (DataCap removed before on-chain evidence is ready)

1. Deploy `OracleEvidenceAdapter` before FIP-1249 activation
2. New deals use oracle adapter with trusted attestation
3. Race to claim all ACCEPTED deals with posted allocations before FIP-1249
4. Admin-reject stuck deals after FIP-1249
5. When on-chain piece queries ship, deploy `PieceEvidenceAdapter` and
   transition new deals to it
6. Oracle-backed deals continue on their frozen adapter until completion

### Timeline considerations

FIP-1249 is not final. The exact activation date is unknown. This gives us time
to:

- Influence what on-chain primitives are available post-DataCap
- Propose piece membership requirements before the removal is finalized
- Ensure the replacement adapter is ready before the old one dies

The worst outcome is DataCap removal activating before any replacement evidence
primitive exists. The oracle fallback exists for this scenario but should not be
the plan.

## Open Design Questions

1. **Piece query granularity**: does the on-chain query need per-piece CID
   resolution, or is "total bytes stored by provider" sufficient? Per-piece is
   stronger (matches manifest), but aggregate bytes is simpler and cheaper.

2. **Ongoing verification**: should the replacement adapter support periodic
   re-verification (check that data is still stored), or is initial activation
   evidence sufficient for the paid service duration?

3. **Data pinning timing**: if data pinning arrives after DataCap removal, there
   is a gap where neither VerifReg claims nor pin state is available. The oracle
   fallback covers this gap, but the gap duration matters for planning.

4. **Existing claims post-sunset**: should the `PieceEvidenceAdapter` also
   accept existing VerifReg claims as evidence (via `GetClaims`, which survives
   FIP-1249)? This would let deals use claims that were created pre-sunset
   without needing the DataCap adapter.

5. **FIP proposal scope**: should the piece membership requirement be a
   standalone FIP, or part of the data pinning FIP, or a formal request to the
   Filecoin Foundation outside the FIP process?

## Related Documents

- FIP proposal draft: see vault document `knowledge/filecoin/2026-05-22-fip-piece-membership-query.md`
