#!/usr/bin/env python3
import argparse
import base64
import datetime as dt
import json
import re
import subprocess
import urllib.request
from pathlib import Path
from typing import Any, Optional

MIN_CLAIM_WINDOW_EPOCHS = 11_520
INT64_MAX = 9_223_372_036_854_775_807
VERIFREG_ACTOR_FIL_ADDRESS_HEX = "0x0006"

DEAL_SIG = (
    "((uint256,address,uint64,(uint16,uint16,uint16,uint8),"
    "(uint256,uint256,uint32),address,uint8,uint256,uint256,string))"
)
STATE_NAMES = {
    0: "Proposed",
    1: "Accepted",
    2: "Completed",
    3: "Rejected",
    4: "Terminated",
}


def die(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def run(cmd: list[str]) -> str:
    try:
        return subprocess.check_output(cmd, text=True, stderr=subprocess.PIPE).strip()
    except subprocess.CalledProcessError as exc:
        stderr = exc.stderr.strip()
        details = f": {stderr}" if stderr else ""
        raise RuntimeError(f"command failed ({' '.join(cmd)}){details}") from exc


def rpc(url: str, method: str, params: list[Any]) -> Any:
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        raw = resp.read().decode()
    data, _ = json.JSONDecoder().raw_decode(raw)
    if data.get("error"):
        raise RuntimeError(f"{method} failed: {data['error']}")
    return data["result"]


def require_address(name: str, value: str) -> None:
    if not re.fullmatch(r"0x[0-9a-fA-F]{40}", value):
        die(f"{name} must be an EVM address, got {value!r}")


def require_epoch(name: str, value: int) -> None:
    if value < 0 or value > INT64_MAX:
        die(f"{name} must fit int64 Filecoin epoch range 0..{INT64_MAX}")


def parse_int_token(raw: str) -> int:
    token = raw.strip()
    match = re.match(r"^-?\d+", token)
    if not match:
        raise ValueError(f"expected integer token, got {raw!r}")
    return int(match.group(0))


def parse_string_token(raw: str) -> str:
    token = raw.strip()
    if not (token.startswith('"') and token.endswith('"')):
        raise ValueError(f"expected quoted string token, got {raw!r}")
    return json.loads(token)


def split_top_level(raw: str) -> list[str]:
    parts: list[str] = []
    depth = 0
    start = 0
    in_string = False
    escape = False

    for idx, ch in enumerate(raw):
        if in_string:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_string = False
            continue
        if ch == '"':
            in_string = True
        elif ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        elif ch == "," and depth == 0:
            parts.append(raw[start:idx].strip())
            start = idx + 1

    final = raw[start:].strip()
    if final:
        parts.append(final)
    return parts


def strip_wrapping(raw: str, open_char: str, close_char: str) -> str:
    text = raw.strip()
    if not (text.startswith(open_char) and text.endswith(close_char)):
        raise ValueError(f"expected {open_char}...{close_char}, got {raw!r}")
    return text[1:-1].strip()


def parse_uint_array(raw: str) -> list[int]:
    text = strip_wrapping(raw, "[", "]")
    if not text:
        return []
    return [parse_int_token(part) for part in split_top_level(text)]


def parse_deal_tuple(raw: str) -> dict[str, Any]:
    fields = split_top_level(strip_wrapping(raw, "(", ")"))
    if len(fields) != 10:
        raise ValueError(f"expected 10 deal fields, got {len(fields)} in {raw!r}")
    requirements = split_top_level(strip_wrapping(fields[3], "(", ")"))
    terms = split_top_level(strip_wrapping(fields[4], "(", ")"))
    if len(requirements) != 4:
        raise ValueError(f"expected 4 SLI requirement fields, got {len(requirements)}")
    if len(terms) != 3:
        raise ValueError(f"expected 3 deal term fields, got {len(terms)}")
    state = parse_int_token(fields[6])
    return {
        "dealId": parse_int_token(fields[0]),
        "client": fields[1].strip(),
        "provider": parse_int_token(fields[2]),
        "requirements": {
            "minSPs": parse_int_token(requirements[0]),
            "maxSPs": parse_int_token(requirements[1]),
            "minFilRep": parse_int_token(requirements[2]),
            "maxSectorFaultTolerance": parse_int_token(requirements[3]),
        },
        "terms": {
            "dealSizeBytes": parse_int_token(terms[0]),
            "maxPricePerTiBPerMonth": parse_int_token(terms[1]),
            "durationDays": parse_int_token(terms[2]),
        },
        "validator": fields[5].strip(),
        "state": state,
        "stateName": STATE_NAMES.get(state, f"Unknown({state})"),
        "railId": parse_int_token(fields[7]),
        "proposedAtBlock": parse_int_token(fields[8]),
        "manifestLocation": parse_string_token(fields[9]),
    }


def cid_to_contract_hex(value: Any) -> tuple[str, str]:
    cid: Optional[str] = None
    if isinstance(value, dict) and isinstance(value.get("/"), str):
        cid = value["/"]
    elif isinstance(value, str):
        cid = value
    else:
        raise ValueError(f"unsupported allocation Data shape: {value!r}")

    if cid.startswith("0x"):
        raw = bytes.fromhex(cid[2:])
        if not raw:
            raise ValueError("empty hex CID bytes")
        return cid.lower(), cid

    if not cid.startswith("b"):
        raise ValueError(f"unsupported CID encoding {cid!r}; expected CIDv1 base32 multibase or 0x bytes")

    encoded = cid[1:].upper()
    padding = "=" * ((8 - len(encoded) % 8) % 8)
    try:
        cid_bytes = base64.b32decode(encoded + padding)
    except Exception as exc:
        raise ValueError(f"failed to decode CID {cid!r} as base32 multibase") from exc
    if not cid_bytes:
        raise ValueError(f"decoded CID {cid!r} is empty")

    # VerifReg allocation CBOR stores CIDs as tag 42 byte strings with a leading
    # identity multibase byte. The contract rescue API takes the byte string body.
    return "0x00" + cid_bytes.hex(), cid


def cbor_fixed_numeric(major: int, value: int) -> bytes:
    if value < 0:
        raise ValueError("CBOR fixed numeric value cannot be negative")
    if value <= 23:
        return bytes([(major << 5) | value])
    if value <= 0xFF:
        return bytes([(major << 5) | 24, value])
    if value <= 0xFFFF:
        return bytes([(major << 5) | 25]) + value.to_bytes(2, "big")
    if value <= 0xFFFFFFFF:
        return bytes([(major << 5) | 26]) + value.to_bytes(4, "big")
    if value <= 0xFFFFFFFFFFFFFFFF:
        return bytes([(major << 5) | 27]) + value.to_bytes(8, "big")
    raise ValueError(f"CBOR value is too large: {value}")


def cbor_uint(value: int) -> bytes:
    return cbor_fixed_numeric(0, value)


def cbor_int(value: int) -> bytes:
    if value >= 0:
        return cbor_fixed_numeric(0, value)
    return cbor_fixed_numeric(1, -1 - value)


def cbor_bytes(hex_value: str, tag: Optional[int] = None) -> bytes:
    if not re.fullmatch(r"0x[0-9a-fA-F]*", hex_value):
        raise ValueError(f"expected hex bytes, got {hex_value!r}")
    raw = bytes.fromhex(hex_value[2:])
    prefix = b"" if tag is None else cbor_fixed_numeric(6, tag)
    return prefix + cbor_fixed_numeric(2, len(raw)) + raw


def cbor_array(items: list[bytes]) -> bytes:
    return cbor_fixed_numeric(4, len(items)) + b"".join(items)


def allocation_request_cbor(rescue: dict[str, Any]) -> bytes:
    return cbor_array([
        cbor_uint(rescue["oldProvider"]),
        cbor_bytes(rescue["data"], tag=42),
        cbor_uint(rescue["size"]),
        cbor_int(rescue["termMin"]),
        cbor_int(rescue["termMax"]),
        cbor_int(rescue["expiration"]),
    ])


def operator_data_cbor(rescues: list[dict[str, Any]]) -> str:
    allocations = cbor_array([allocation_request_cbor(rescue) for rescue in rescues])
    claim_extensions = cbor_array([])
    return "0x" + cbor_array([allocations, claim_extensions]).hex()


def uint256_bytes_hex(value: int) -> str:
    if value < 0:
        raise ValueError("amount cannot be negative")
    return "0x" + value.to_bytes(32, "big").hex()


def transfer_params_tuple(to_hex: str, amount_val: str, operator_data: str) -> str:
    return f"(({to_hex}),({amount_val},false),{operator_data})"


def cast_call(address: str, signature: str, args: list[str], rpc_url: str) -> str:
    return run(["cast", "call", address, signature, *args, "--rpc-url", rpc_url])


def read_rescue_role_status(client: str, signer: Optional[str], rpc_url: str) -> tuple[Optional[str], Optional[bool], list[str]]:
    warnings: list[str] = []
    if signer is None:
        warnings.append("RESCUE_ROLE was not checked because no rescue signer was supplied.")
        return None, None, warnings

    role = cast_call(client, "RESCUE_ROLE()(bytes32)", [], rpc_url)

    if not re.fullmatch(r"0x[0-9a-fA-F]{64}", role):
        raise ValueError(f"unexpected RESCUE_ROLE value: {role!r}")

    granted_raw = cast_call(client, "hasRole(bytes32,address)(bool)", [role, signer], rpc_url).strip().lower()
    if granted_raw not in ("true", "false"):
        raise ValueError(f"unexpected hasRole result for signer {signer}: {granted_raw!r}")
    granted = granted_raw == "true"
    if not granted:
        warnings.append(f"rescue signer {signer} does not currently have RESCUE_ROLE.")
    return role.lower(), granted, warnings


def read_deal(market: str, deal_id: int, rpc_url: str) -> dict[str, Any]:
    return parse_deal_tuple(cast_call(market, f"getDealProposal(uint256){DEAL_SIG}", [str(deal_id)], rpc_url))


def parse_deal_ids(value: str) -> list[int]:
    if not re.fullmatch(r"[0-9]+(,[0-9]+)*", value):
        die("--deal-ids must be a comma-separated list of positive integers")
    selected = [int(token) for token in value.split(",")]
    seen: set[int] = set()
    result: list[int] = []
    for deal_id in selected:
        if deal_id <= 0:
            die(f"deal IDs must be positive, got {deal_id}")
        if deal_id in seen:
            die(f"duplicate deal ID: {deal_id}")
        seen.add(deal_id)
        result.append(deal_id)
    return result


def read_tracked_ids(client: str, deal_id: int, rpc_url: str) -> list[int]:
    raw = cast_call(client, "getClientAllocationIdsPerDeal(uint256)(uint64[])", [str(deal_id)], rpc_url)
    return parse_uint_array(raw)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rpc", required=True)
    parser.add_argument("--expected-chain-id", required=True, type=int)
    parser.add_argument("--client", required=True)
    parser.add_argument("--market", required=True)
    parser.add_argument("--client-fil", required=True)
    parser.add_argument("--client-id", required=True, type=int)
    parser.add_argument("--term-min", required=True, type=int)
    parser.add_argument("--term-max", required=True, type=int)
    parser.add_argument("--expiration", required=True, type=int)
    parser.add_argument("--output", required=True)
    parser.add_argument("--rescue-signer")
    parser.add_argument("--deal-ids", required=True)
    args = parser.parse_args()

    require_address("--client", args.client)
    require_address("--market", args.market)
    if args.rescue_signer is not None:
        require_address("--rescue-signer", args.rescue_signer)
    require_epoch("--term-min", args.term_min)
    require_epoch("--term-max", args.term_max)
    require_epoch("--expiration", args.expiration)
    if args.term_max - args.term_min < MIN_CLAIM_WINDOW_EPOCHS:
        die(f"term window must be at least {MIN_CLAIM_WINDOW_EPOCHS} epochs")
    selected_deal_ids = parse_deal_ids(args.deal_ids)

    chain_id = int(run(["cast", "chain-id", "--rpc-url", args.rpc]))
    if chain_id != args.expected_chain_id:
        die(f"expected chain {args.expected_chain_id}, got {chain_id}")

    resolved_client_fil = rpc(args.rpc, "Filecoin.EthAddressToFilecoinAddress", [args.client])
    if resolved_client_fil != args.client_fil:
        die(f"client Filecoin address mismatch: shell={args.client_fil}, parser={resolved_client_fil}")
    resolved_client_id = rpc(args.rpc, "Filecoin.StateLookupID", [args.client_fil, []])
    if not isinstance(resolved_client_id, str) or not re.fullmatch(r"[ft]0[0-9]+", resolved_client_id):
        die(f"unexpected Client ID address from StateLookupID: {resolved_client_id!r}")
    if int(resolved_client_id[2:]) != args.client_id:
        die(f"client actor ID mismatch: shell={args.client_id}, parser={resolved_client_id}")

    chain_head = rpc(args.rpc, "Filecoin.ChainHead", [])["Height"]
    if not isinstance(chain_head, int) or chain_head < 0:
        die(f"unexpected chain head: {chain_head!r}")
    if args.expiration < chain_head:
        die(f"replacement expiration {args.expiration} is before current chain head {chain_head}")

    rescue_role, rescue_role_granted, role_warnings = read_rescue_role_status(
        args.client, args.rescue_signer, args.rpc
    )
    deals = []
    for deal_id in selected_deal_ids:
        deal = read_deal(args.market, deal_id, args.rpc)
        if deal["dealId"] != deal_id:
            die(f"deal {deal_id} does not exist")
        deals.append(deal)
    broken_deals: list[dict[str, Any]] = []
    skipped_allocations: list[dict[str, Any]] = []
    deals_with_tracked_allocations = 0

    for proposal in deals:
        if proposal["dealId"] not in selected_deal_ids:
            die(f"getDealProposal returned unexpected deal ID {proposal['dealId']}")
        if proposal["state"] != 2:
            continue

        allocation_ids = read_tracked_ids(args.client, proposal["dealId"], args.rpc)
        if allocation_ids:
            deals_with_tracked_allocations += 1

        rescues: list[dict[str, Any]] = []
        for allocation_id in allocation_ids:
            alloc = rpc(args.rpc, "Filecoin.StateGetAllocation", [args.client_fil, allocation_id, []])
            if alloc is None:
                skipped_allocations.append({
                    "dealId": proposal["dealId"],
                    "allocationId": allocation_id,
                    "reason": "missing-or-claimed-allocation",
                })
                continue

            reasons: list[str] = []
            if alloc.get("Client") != args.client_id:
                reasons.append(f"client-mismatch:{alloc.get('Client')}")
            if alloc.get("Provider") != proposal["provider"]:
                reasons.append(f"provider-mismatch:{alloc.get('Provider')}")
            old_window = alloc.get("TermMax", 0) - alloc.get("TermMin", 0)
            if alloc.get("Size", 0) <= 0:
                reasons.append("zero-size")

            if reasons:
                skipped_allocations.append({
                    "dealId": proposal["dealId"],
                    "allocationId": allocation_id,
                    "reason": ",".join(reasons),
                    "allocation": alloc,
                })
                continue

            try:
                data_hex, data_cid = cid_to_contract_hex(alloc["Data"])
            except Exception as exc:
                die(f"deal {proposal['dealId']} allocation {allocation_id} has unusable Data CID: {exc}")

            rescues.append({
                "badAllocationId": allocation_id,
                "oldClientActorId": alloc["Client"],
                "oldProvider": alloc["Provider"],
                "oldSize": alloc["Size"],
                "data": data_hex,
                "dataCid": data_cid,
                "size": alloc["Size"],
                "oldTermMin": alloc["TermMin"],
                "oldTermMax": alloc["TermMax"],
                "oldClaimWindow": old_window,
                "oldExpiration": alloc["Expiration"],
                "termMin": args.term_min,
                "termMax": args.term_max,
                "expiration": args.expiration,
            })

        if rescues:
            total_size = sum(item["size"] for item in rescues)
            if len(rescues) != len(allocation_ids):
                skipped_allocations.append({
                    "dealId": proposal["dealId"],
                    "reason": "partial-rescue-not-supported",
                    "trackedAllocationCount": len(allocation_ids),
                    "rescueCount": len(rescues),
                })
                continue
            operator_data = operator_data_cbor(rescues)
            amount_val = uint256_bytes_hex(total_size * 10**18)
            broken_deals.append({
                "dealId": proposal["dealId"],
                "state": proposal["state"],
                "stateName": proposal["stateName"],
                "client": proposal["client"],
                "provider": proposal["provider"],
                "validator": proposal["validator"],
                "railId": proposal["railId"],
                "proposedAtBlock": proposal["proposedAtBlock"],
                "manifestLocation": proposal["manifestLocation"],
                "dealSizeBytes": proposal["terms"]["dealSizeBytes"],
                "trackedAllocationIds": allocation_ids,
                "trackedAllocationCount": len(allocation_ids),
                "rescues": rescues,
                "rescueCount": len(rescues),
                "totalReplacementSize": total_size,
                "totalMatchesDealSize": total_size == proposal["terms"]["dealSizeBytes"],
                "transferParams": {
                    "to": VERIFREG_ACTOR_FIL_ADDRESS_HEX,
                    "amount": {
                        "val": amount_val,
                        "neg": False,
                    },
                    "operator_data": operator_data,
                    "castTuple": transfer_params_tuple(
                        VERIFREG_ACTOR_FIL_ADDRESS_HEX,
                        amount_val,
                        operator_data,
                    ),
                },
            })

    summary = {
        "dealsScanned": len(deals),
        "dealsWithTrackedAllocations": deals_with_tracked_allocations,
        "rescueDeals": len(broken_deals),
        "rescueCount": sum(len(deal["rescues"]) for deal in broken_deals),
        "totalReplacementSize": sum(deal["totalReplacementSize"] for deal in broken_deals),
        "skippedAllocationCount": len(skipped_allocations),
    }

    plan = {
        "version": 1,
        "generatedAt": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat(),
        "network": "mainnet",
        "chainId": chain_id,
        "chainHead": chain_head,
        "rpc": args.rpc,
        "clientProxy": args.client,
        "clientFilecoinAddress": args.client_fil,
        "clientActorId": args.client_id,
        "poRepMarket": args.market,
        "rescueSigner": args.rescue_signer,
        "rescueRole": rescue_role,
        "rescueRoleGranted": rescue_role_granted,
        "warnings": role_warnings,
        "dealIds": selected_deal_ids,
        "minClaimWindowEpochs": MIN_CLAIM_WINDOW_EPOCHS,
        "replacement": {
            "termMin": args.term_min,
            "termMax": args.term_max,
            "claimWindow": args.term_max - args.term_min,
            "expiration": args.expiration,
        },
        "summary": summary,
        "deals": broken_deals,
        "skippedAllocations": skipped_allocations,
    }

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", encoding="utf-8") as f:
        json.dump(plan, f, indent=2, sort_keys=True)
        f.write("\n")

    print(
        "Prepared rescue plan: "
        f"{summary['rescueDeals']} rescue deals, "
        f"{summary['rescueCount']} rescues, "
        f"{summary['totalReplacementSize']} bytes"
    )


if __name__ == "__main__":
    main()
