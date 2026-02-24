# PoRep Market

## Executive Summary: PoRep Market

### 1. Overview
The **PoRep Market** is a set of smart contracts and off-chain actors designed to automate, manage, and settle storage deals on the Filecoin network. It serves as a middleware that connects **Clients** (data owners) with **Storage Providers** (miners), ensuring that data is not only stored but maintained according to explicitly defined minimum values for selected performance indicators.

### 2. Key Value Propositions
* **Automated Matchmaking:** Removes the need for manual negotiation by automatically selecting the best-fit Storage Provider (SP) based on capacity and and predefined minimum values for selected performance indicators.
* **Performance-Based Payments:** Unlike standard deals, this system uses "Smart Validators" to release payments only when performance metrics (SLIs) are met.
* **Trustless Quality Assurance:** Integrates off-chain Oracles to verify real-world data on-chain.

### 3. System Architecture & Roles

The ecosystem is divided into three functional pillars:

- **PoRep Market & Provider Selection**
  * **PoRep Market:** The core orchestrator. It handles deal proposals, prices, and deal lifecycle updates.
  * **SPRegistry:** A dynamic directory of active Storage Providers. It filters providers to ensure they have the capacity and technical capability to fulfill a client's request.

- **Quality Control (SLA)**
  * **SLIScorer:** Defines the rules of the deal by evaluating Storage Providers based on selected indicators and calculating their overall score.
  * **OracleSLI:** It feeds off-chain performance data into the blockchain so the SLC contract can evaluate the provider.

- **Financial Settlement & Operations**
  * **Validator:** A specific Validator is deployed for each deal. It validates the provider's performance score before approving any payout.
  * **FilecoinPay:** The underlying payment rail that executes the transfers once validated.
  * **Client Smart Contract:** managing DataCap and tracking allocation metrics.

### 4. Operational Workflow

The lifecycle of a deal follows this high-level logic:

1.  **Proposal:** A Client proposes a deal (size, price, service level). The **PoRep Market** consults the **SPRegistry** to reserve a suitable Provider.
2.  **Setup:** A **Validator** contract is created to secure the funds and link to **FilecoinPay**.
3.  **Execution:** The Client transfers data, and the Provider seals the data (Mining).
4.  **Verification:** A **SettlementBot** periodically triggers a check. The Validator asks the **SLIScorer** for a performance score based on **Oracle** data.
5.  **Settlement:**
    * **High Score:** Funds are released to the Provider.
    * **Low Score:** Payouts are reduced or withheld based on the penalty logic.
6.  **Deal Termination:** Once the agreed deal duration expires, the deal is automatically terminated. Any remaining locked funds are settled according to the contract logic, and the Validator is finalized.

### 5. Conclusion
The PoRep Market turns Filecoin storage from a simple yes/no deal into a practical service marketplace. Payments are released only when real performance requirements are met, which protects Clients from bad service and motivates Storage Providers to keep their infrastructure reliable and well-maintained.

## Glossary
We expect following actors and contracts in the system:
1. **Client** - person that has data and wants to store it 
2. **SP** - person that runs a miner that can store data and mine blocks
3. **Gov** - Filecoin governance team
4. **SettlementBot** - off-chain service that triggers settlement-related transaction
5. **SPRegistry** - smart contract that tracks registered Storage Providers participating in the PoRep Market
6. **OracleSLI** -  smart contract that stores off-chain data regarding SLIs for providers
7. **SLIScorer** - smart contract that evaluates Storage Providers by calculating a score based on predefined minimum values for selected Service Level Indicators (SLIs).8. **PoRepMarket** - smart contract coordinating deals
9. **Client Smart Contract** - singleton smart contract that helps **Clients** to make allocation and helps track metrics
10. **ValidatorFactory** - smart contract that deploys and registers Validator contracts
11. **Validator** - smart contract that validate payments during settlement
12. [**FilecoinPay**](https://github.com/FilOzone/filecoin-pay) - smart contract enables automated payment channels between payers and recipient
13. **Miner** - instance of the [Miner Actor](https://github.com/filecoin-project/builtin-actors/tree/master/actors/miner)


## PoRep Market

**PoRep Market** is a smart contract responsible for managing deal proposals and updates. It allows clients to propose new deals, automatically selects a Storage Provider (SP) via an external registry, and stores deal proposals on-chain. 

There will be following roles in this contract:
* `ADMIN`, who can upgrade the contract
* `UPGRADER_ROLE`, who can upgrade the contract

Expected interface:
```
interface PoRepMarket {
    function proposeDeal(uint256 expectedDealSize, uint256 priceForDeal, address SLC) external;
    function updateValidatorAndRailId(uint256 dealId, uint256 railId) external;
    function getDealProposal(uint256 dealId) external view returns (DealProposal memory);
    function getCompletedDeals() external returns (DealProposal[] memory);
    function acceptDeal(uint256 dealId) external;
    function rejectDeal(uint256 dealId) external;
    function completeDeal(uint256 dealId) external;
    function terminateDeal(uint256 dealId, address terminator, uint256 endEpoch) external;
}
```

Expected storage items:
```
struct DealProposal {
    uint256 dealId;
    address client;
    CommonTypes.FilActorId provider;
    SLIThresholds slis;
    address validator;
    DealState state;
    uint256 railId;
    uint256 price;
    uint256 totalDealSize;
}

enum DealState {
    Proposed,
    Accepted,
    Completed,
    Rejected,
    Terminated
}

mapping(uint256 => DealProposal) dealProposals;
address SPRegistry;
address ValidatorRegistry;
address ClientContract;
uint256 dealIdCounter;
```
// and items inherited from OpenZeppelin's AccessControl, UUPSUpgradeable and Multicall

## Client Smart Contract

**Client Smart Contract** acts as a Verified Registry Client. It has an allowance and may mint DataCap to transfer it to Verifreg create Allocations.

The main function it will implement is `transfer`, which copies the interface of DataCap and expects a transfer of DC to Verifreg with Verifreg-compatible operator data. See [FIDL Client Smart Contract](https://github.com/fidlabs/contract-metaallocator/blob/main/src/Client.sol#L71) for reference. It will mint and  transfer the DataCap and create allocations under following conditions:
1. **Client Smart Contract** has enough allowance

It will also track how much a given **Client** allocated with a given **SP** for a given deal, so that the Validator can check the size of allocations made by the client and compare it with the actual size of **SP** data.

There will be following role in this contract:
* `ADMIN`, who can upgrade the contract
* `TERMINATION_ORACLE`, external service that updates the contract about early terminated sectors

Expected interface:
```
interface Client {
    function transfer(DataCapTypes.TransferParams calldata params, uint256 dealID, bool completed) external;
    function isDataSizeMatching(uint256 dealId) external;
}
```

Expected storage items:
```
  struct Deal {
      address client;
      address validator;
      CommonTypes.FilActorId provider;
      uint256 dealId;
      uint256 railId;
      uint256 sizeOfAllocations;
      CommonTypes.ChainEpoch longestDealTerm;
      CommonTypes.FilActorId[] allocationIds;
  }

address PoRepMarket;
// and items inherited from OpenZeppelin's AccessControl, UUPSUpgradeable and Multicall
```

## OracleSLI

**OracleSLI** is a contract that provides information about off-chain world.

**FIDLOracle** is a reference **Oracle** provided by FIDL that uses data from DataCapStats for SLIs. It will be upgradeable and implement a following interface:

There will be following role in this contract:
* `UPGRADER`, who can upgrade the contract
* `ORACLE`, which allows to update SLI values

```
interface OracleSLI {
  struct SLIThresholds {
      uint8 retrievabilityPct;
      uint16 bandwidthMbps;
      uint16 latencyMs;
      uint8 indexingPct;
  }

  struct Attestation {
      uint256 lastUpdate;
      SLIThresholds slis;
  }

  function setSLI(CommonTypes.FilActorId provider, SLIThresholds calldata slis) external onlyRole(ORACLE_ROLE);
}
```

Expected storage items:
```
mapping(address provider => Attestation attestation) public attestations;
```

## SLIScorer

**SLIScorer** is a smart contract responsible for calculating a score for a given provider based on the required Service Level Indicators (SLIs) and the actual SLIs reported by the **OracleSLI** contract.

```
interface ServiceLevelClass {
  struct SLIThresholds {
      uint8 retrievabilityPct;
      uint16 bandwidthMbps;
      uint16 latencyMs;
      uint8 indexingPct;
  }
  function calculateScore(address provider, SLIThresholds calldata required) external view returns (uint256 score);
}
```

Expected storage items:
```
  address OracleSLI;
```

## SPRegistry

**SPRegistry** is a smart contract responsible for storing available Storage Providers (SPs) together with their service parameters. The contract participates in the selection of a Storage Provider based on required deal parameters provided by **PoRep Market**.

The selection logic verifies whether a given SP supports the **ServiceLevelClass (SLC)** chosen by the client and whether its declared capacity is sufficient to handle the deal.

> **Note:** Function definitions may change after the contract is created.

Expected interface:
```
interface SPRegistry {
    function createStorageEntity(address entityOwner, uint64[] calldata storageProviders) external;
    function addStorageProviders(address entityOwner, uint64[] calldata storageProviders) external;
    function removeStorageProviders(address entityOwner, uint64[] calldata storageProviders) external;
    function setStorageEntityActiveStatus(address entityOwner, bool isActive) external;
    function setStorageProviderDetails(address entityOwner, uint64 storageProvider, ProviderDetails calldata details) external;
    function isStorageProviderUsed(uint64 storageProvider) external;
    function getStorageEntity(address entityOwner) external;
    function getStorageEntities() external;
    function selectSp(uint256 dealSize, address SLC) external;
}
```
Expected storage items:
```
struct StorageEntity {
    bool isActive;
    address owner;
    uint64[] storageProviders;
    mapping(uint64 => ProviderDetails) providerDetails;
}

struct ProviderDetails {
    bool isActive;
    uint256 spaceLeft;
}

mapping(address entityOwner => StorageEntity entity) public storageEntities;
mapping(uint64 storageProvider => bool isUsed) public usedStorageProviders;
address[] public entityAddresses;
// and items inherited from OpenZeppelin's AccessControl, UUPSUpgradeable
```

## ValidatorFactory

**ValidatorFactory** is a smart contract responsible for creating new validator instances with a specified admin, **SLIs**, and Storage Provider Actor ID.

The contract stores the addresses of all validator contracts it creates and provides a function to verify whether a given address is a validator instance created by the factory.

Expected interface:
```
interface ValidatorFactory {
    function create(address admin, SLIThresholds slis, CommonTypes.FilActorId provider, Validator.DepositWithRailParams) external;
    function isValidatorContract(address contractAddress) external view returns (bool);
}
```

// and items inherited from OpenZeppelin's AccessControl and the Beacon Proxy Factory upgradeable pattern

## Validator

**Validator** is a smart contract responsible for validating storage deals and managing payments for a specific Storage Provider under defined **Service Level Indicators** (SLIs) requirements.
It interacts with **ClientSC** to verify DataCap allocations, computes a score based on the required **SLIs**, and manages deposits and payouts.  
The contract separates **Validator** and **Operator** responsibilities by inheriting from abstract contracts and maintains a lockup period for funds.

Expected interface:
```
interface Validator {
    function validatePayment(uint256 railId, uint256 proposedAmount, uint256 fromEpoch, uint256 toEpoch, uint256 rate) external view returns (ValidationResult memory result);
    function updateLockupPeriod(uint256 railId, uint256 newLockupPeriod) external;
    function railTerminated(uint256 railId, address terminator, uint256 endEpoch) external;
}
```
Expected storage items:
```
struct ValidationResult {
    uint256 modifiedAmount;
    uint256 settleUpto;
    string note;
}

struct DepositWithRailInputParams {
    IERC20 token;
    uint8 v;
    uint256 amount;
    uint256 deadline;
    bytes32 r;
    bytes32 s;
    uint256 dealId;
}

address ClientSmartContract
address PoRepMarket
```

## Diagrams

A typical full flow from proposing a deal to withdrawing rewards will look as follows:

```mermaid
sequenceDiagram
  actor Client
  actor SP
  actor Gov
  actor SettlementBot
  participant SPRegistry
  participant OracleSLI@{ "type" : "collections" }
  participant SLIScorer
  participant PoRepMarket
  participant ClientSC as Client Smart Contract
  participant ValidatorFactory
  participant Validator@{ "type" : "collections" }
  participant FilecoinPay
  participant DataCap
  participant Verifreg
  participant Miner
  

note over Gov,ClientSC: Tx 1: Assign Allowance
    Gov->>ClientSC: Assign allowance to contract

note over SP,SPRegistry: Tx 2: Register SP
    SP->>SPRegistry: Register as SP

note over Client, PoRepMarket: Tx 3: Propose a Deal
    Client->>PoRepMarket: Propose deal with expected deal size, price and SLIThresholds 
    activate PoRepMarket
    PoRepMarket->>SPRegistry: Ask for SP
    activate SPRegistry
    SPRegistry->>SPRegistry: Filter available SPs matching criteria
    SPRegistry->>SPRegistry: Reserve SP capacity on proposal creation
    SPRegistry-->> PoRepMarket: Return selected SP
    deactivate SPRegistry
    PoRepMarket->>PoRepMarket: Create deal proposal
    deactivate PoRepMarket

note over SP, PoRepMarket: Tx 4: Accept deal
    SP->>PoRepMarket: Accept proposed deal

note over Client, FilecoinPay: Tx 5: Register Validator And Initialize FilecoinPay
    Client->>ValidatorFactory: Trigger creation of Validator contract with SLIThresholds, , dealID and permit for token transfer
    activate ValidatorFactory
    ValidatorFactory->>Validator: Deploy new Validator
    deactivate ValidatorFactory
    activate Validator
    Validator->>Validator: Initialize SLIThresholds
    Validator->>Validator: Initialize provider address
    Validator->>FilecoinPay: Deposit with permit and approve operator
    Validator->>FilecoinPay: Rail Creation with Validator address
    Validator->>PoRepMarket: Update deal
    deactivate Validator
  
note over Client,DataCap: Tx 6: Make DDO Allocation
    Client->>ClientSC: Make DDO Allocation with dealID and information if completed
    activate ClientSC
    ClientSC->>DataCap: Make DDO Allocation
    activate DataCap
    DataCap->>Verifreg: Receive Allocations
    activate Verifreg
    Verifreg-->>DataCap: Return Allocation IDs
    deactivate Verifreg
    DataCap-->>ClientSC: Return Allocation IDs
    ClientSC->>ClientSC: Store client's AllocationIDs
    ClientSC->>ClientSC: Store max term of alloation with the longest duration
    ClientSC->>PoRepMarket: Update information about deal if completed 
    ClientSC->>PoRepMarket: Get validator address for lockup period update if the new value of max term exceeds the current maximum term
    ClientSC->> Validator: Trigger update of the lockup period
    activate Validator
    Validator->>FilecoinPay: Update the lockup period
    deactivate ClientSC
    deactivate Validator 
  
note over SP,DataCap: Tx 7: Start mining
  SP->>Miner: Claim DC allocations 

loop
note over Client, FilecoinPay: Tx 8: Calculate withdrawal
    SettlementBot->>FilecoinPay: Trigger settle rail  
    FilecoinPay->>Validator: Validate payment
    activate Validator
    Validator->>Validator: Check if one month has passed since the last payout
    Validator->>SLIScorer: Get score
    activate SLIScorer
    SLIScorer->>OracleSLI: Get attestations
    SLIScorer-->>Validator: Return score
    deactivate SLIScorer
    Validator ->>PoRepMarket: Get DealID
    Validator->>ClientSC: Get info about actual size of the deal
    activate ClientSC
    ClientSC->>ClientSC: Check terminated sectors
    ClientSC-->>Validator: Return the actual total size of all deals
    deactivate ClientSC 
    Validator->>Validator: Calculate modified amount to withdrawal
    Validator-->>FilecoinPay: Return modified amount to withdrawal
    deactivate Validator
  end

note over SP, FilecoinPay: Tx 9: Withdraw payments
  SP->>FilecoinPay: Withdraw funds to recipient
  activate FilecoinPay
  FilecoinPay-->>SP: Transfer funds to recipient
  deactivate FilecoinPay

note over SettlementBot, Validator: Tx 10: Rail termination
    SettlementBot->>Validator: Trigger rail termination
    activate Validator
    Validator->>FilecoinPay: Terminate Rail
    activate FilecoinPay
    FilecoinPay->>Validator: Notify about rail termination 
    deactivate FilecoinPay
    Validator->>PoRepMarket: Terminate deal
    activate PoRepMarket
    PoRepMarket->>SPRegistry: Release SP capacity
    deactivate PoRepMarket
    deactivate Validator
    
```
