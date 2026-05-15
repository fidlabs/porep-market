# PoRep Market V2 Open Questions

Status: draft for PR review.

Close these before implementation starts.

## Contract Shape

1. Should V2 be a fresh deployment with canonical contract names, or an in-place upgrade with V2 sidecar namespaces?
2. Should `Expired` become a real deal state, or should expired proposals reuse `Rejected` plus an event?
3. Should `proposeDealAuto` be the first V2 entrypoint, or should the first slice require direct `offerId` selection?
4. Should the external proposal API keep `durationDays` only, or expose both `durationDays` and `durationEpochs`?

## Provider And Offer Semantics

1. Is provider identity always `FilActorId`, with no synthetic `providerId`?
2. Is payee provider-level for the starting scope?
3. Should offer token deactivation preserve the token in getter enumeration?
4. Do offer terms need both min/max piece size and min/max duration in the first slice?

## Payment Semantics

1. Are active offer prices always monthly token units per 32 GiB?
2. Does `billed32GiBUnits` round up from actual completed bytes, requested bytes, or Filecoin claim size?
3. Is `railMaxRatePerEpoch` frozen only after completion/rail creation, or already at proposal time using requested size?
4. Should SLI penalties apply after cumulative exact payment calculation?

## Duration And Filecoin Terms

1. What exact epoch anchors define `paymentStartEpoch` and `serviceStartEpoch`?
2. Should `serviceEndEpoch` be stored immediately when payment starts, or derived from stored start plus `durationEpochs`?
3. For verified allocation rescue, should replacement allocation `termMin` use remaining service duration only?
4. What slack policy should produce `termMax` without letting it become paid service duration?

## Indexing And Tooling

1. Does indexing remain a core SLI field in V2?
2. Which deal indexes must stay on chain for SP/operator workflows?
3. Which getters need pagination before implementation starts?
4. Which events must be stable enough for external clients and indexers?
