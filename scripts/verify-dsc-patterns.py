#!/usr/bin/env python3
"""Verify Unseen's QuartzCore instruction patterns against real dyld caches."""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


PREPARE_SYMBOLS = (
    "__ZN2CA6Render7Updater14prepare_layer0ERNS1_11GlobalStateEPNS0_9LayerNodeEPNS0_5LayerERNS1_11LocalState0Ey",
    "__ZN2CA6Render7Updater14prepare_layer0ERNS1_11GlobalStateEPNS0_9LayerNodeEPKNS0_5LayerERNS1_11LocalState0Ey",
)
ALLOWED_SYMBOLS = (
    "__ZNK2CA6Render6Update17allowed_in_updateEPNS0_7ContextEPKNS0_5LayerE",
    "__ZN2CA6Render6Update17allowed_in_updateEPNS0_7ContextEPKNS0_5LayerE",
)
DISPLAY_INFO_SYMBOLS = (
    "__ZN2CA12WindowServer6Server16get_display_infoEPNS_6Render6ObjectEPvS5_",
)


@dataclass(frozen=True)
class Instruction:
    address: int
    raw: int
    disassembly: str


@dataclass(frozen=True)
class Function:
    symbol: str
    instructions: tuple[Instruction, ...]

    @property
    def address(self) -> int:
        return self.instructions[0].address


def _extract_json(stdout: str) -> dict:
    start = stdout.find("{")
    if start < 0:
        raise ValueError("ipsw did not emit JSON")
    return json.loads(stdout[start:])


def disassemble_symbol(cache: Path, symbols: Iterable[str], count: int | None = None) -> Function | None:
    for symbol in symbols:
        command = [
            "ipsw",
            "dyld",
            "disass",
            str(cache),
            "--symbol",
            symbol,
            "--symbol-image",
            "QuartzCore",
            "--quiet",
            "--json",
        ]
        if count is not None:
            command.extend(("--count", str(count)))

        completed = subprocess.run(command, capture_output=True, text=True, timeout=300)
        if completed.returncode != 0:
            continue

        try:
            document = _extract_json(completed.stdout)
            records = document.get(symbol)
            if not records and document:
                records = next(iter(document.values()))
            instructions = tuple(
                Instruction(int(record["addr"]), int(record["raw"]), record.get("disass", ""))
                for record in records
            )
        except (KeyError, TypeError, ValueError, json.JSONDecodeError):
            continue

        if instructions:
            return Function(symbol, instructions)
    return None


def _sign_extend(value: int, bits: int) -> int:
    sign = 1 << (bits - 1)
    return (value ^ sign) - sign


def decode_bl_target(instruction: Instruction) -> int | None:
    if instruction.raw & 0xFC000000 != 0x94000000:
        return None
    immediate = _sign_extend(instruction.raw & 0x03FFFFFF, 26)
    return instruction.address + (immediate << 2)


def decode_nonzero_branch_target(instruction: Instruction) -> tuple[str, int] | None:
    raw = instruction.raw
    if raw & 0xFFF8001F == 0x37000000:  # TBNZ W0, #0, target
        immediate = _sign_extend((raw >> 5) & 0x3FFF, 14)
        return "TBNZ", instruction.address + (immediate << 2)
    if raw & 0xFF00001F == 0x35000000:  # CBNZ W0, target
        immediate = _sign_extend((raw >> 5) & 0x7FFFF, 19)
        return "CBNZ", instruction.address + (immediate << 2)
    return None


def decode_str_xzr(instruction: Instruction) -> tuple[int, int] | None:
    raw = instruction.raw
    if raw & 0xFFC00000 != 0xF9000000 or raw & 0x1F != 31:
        return None
    return (raw >> 5) & 0x1F, ((raw >> 10) & 0xFFF) << 3


def find_legacy_update_pattern(function: Function) -> list[tuple[int, int]]:
    instructions = function.instructions
    results: list[tuple[int, int]] = []
    for index, instruction in enumerate(instructions):
        masked = instruction.raw & 0xFFFFFC1F
        if masked not in (0xF26C101F, 0xF26C141F, 0xF26C181F, 0xF26C1C1F):
            continue
        for candidate in instructions[index + 1 : index + 5]:
            if candidate.raw & 0xFF00001F == 0x54000001:
                results.append((instruction.address, candidate.address))
    return results


def find_allowed_update_pattern(
    function: Function, allowed_address: int
) -> list[tuple[int, int, int, str, int, int]]:
    instructions = function.instructions
    results: list[tuple[int, int, int, str, int, int]] = []
    for index, instruction in enumerate(instructions):
        if decode_bl_target(instruction) != allowed_address:
            continue
        for branch_index in range(index + 1, min(index + 5, len(instructions))):
            branch = instructions[branch_index]
            decoded_branch = decode_nonzero_branch_target(branch)
            if decoded_branch is None:
                continue
            branch_kind, branch_target = decoded_branch
            for store in instructions[branch_index + 1 : branch_index + 4]:
                decoded_store = decode_str_xzr(store)
                if decoded_store is None or branch_target != store.address + 4:
                    continue
                base_register, offset = decoded_store
                results.append(
                    (
                        instruction.address,
                        branch.address,
                        store.address,
                        branch_kind,
                        base_register,
                        offset,
                    )
                )
    return results


def _decode_load_32(raw: int) -> tuple[int, int, int] | None:
    if raw & 0xFFC00000 != 0xB9400000:
        return None
    return raw & 0x1F, (raw >> 5) & 0x1F, ((raw >> 10) & 0xFFF) << 2


def _decode_store_32(raw: int) -> tuple[int, int, int] | None:
    if raw & 0xFFC00000 != 0xB9000000:
        return None
    return raw & 0x1F, (raw >> 5) & 0x1F, ((raw >> 10) & 0xFFF) << 2


def _decode_add_imm_64(raw: int) -> tuple[int, int, int] | None:
    if raw & 0x80000000 == 0 or raw & 0x7F000000 != 0x11000000:
        return None
    shift = (raw >> 22) & 0x3
    if shift > 1:
        return None
    immediate = (raw >> 10) & 0xFFF
    if shift == 1:
        immediate <<= 12
    return raw & 0x1F, (raw >> 5) & 0x1F, immediate


def find_display_flags_pattern(function: Function) -> list[tuple[str, int, int, int]]:
    instructions = function.instructions[:512]
    results: list[tuple[str, int, int, int]] = []
    for index in range(max(0, len(instructions) - 5)):
        load = _decode_load_32(instructions[index].raw)
        store = _decode_store_32(instructions[index + 1].raw)
        if load is None or store is None or load[0] != store[0]:
            continue
        _, load_base, load_offset = load
        _, _, store_offset = store
        if store_offset < 0x1000:
            continue
        for candidate in instructions[index + 2 : index + 6]:
            add = _decode_add_imm_64(candidate.raw)
            if add is not None and add[1] == load_base and add[2] == load_offset + 4:
                results.append(("packed", instructions[index].address, load_offset, store_offset))

    for index in range(max(0, len(instructions) - 5)):
        loads = [_decode_load_32(instructions[index + pair * 2].raw) for pair in range(3)]
        stores = [_decode_store_32(instructions[index + pair * 2 + 1].raw) for pair in range(3)]
        if any(value is None for value in loads) or any(value is None for value in stores):
            continue
        if any(loads[pair][0] != stores[pair][0] for pair in range(3)):
            continue
        if stores[0][2] < 0x1000:
            continue
        if not (
            loads[1][1] == loads[0][1] == loads[2][1]
            and stores[1][1] == stores[0][1] == stores[2][1]
            and loads[1][2] == loads[0][2] + 4
            and loads[2][2] == loads[0][2] + 8
            and stores[1][2] == stores[0][2] + 4
            and stores[2][2] == stores[0][2] + 8
        ):
            continue
        results.append(("expanded", instructions[index].address, loads[0][2], stores[0][2]))
    return results


def discover_caches(root: Path, explicit: list[Path]) -> list[Path]:
    if explicit:
        return sorted(path.resolve() for path in explicit)
    names = {"dyld_shared_cache_arm64", "dyld_shared_cache_arm64e"}
    return sorted(path for path in root.rglob("dyld_shared_cache_arm64*") if path.name in names)


def short_symbol(symbol: str | None) -> str:
    if symbol is None:
        return "missing"
    if symbol in ALLOWED_SYMBOLS:
        return "const" if symbol.startswith("__ZNK") else "nonconst"
    if "EPKNS0_5Layer" in symbol:
        return "const-layer"
    return "mutable-layer"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("caches", nargs="*", type=Path, help="explicit main DSC files")
    parser.add_argument("--root", type=Path, default=Path("/Users/82flex/Desktop/dyld"))
    args = parser.parse_args()

    if shutil.which("ipsw") is None:
        parser.error("ipsw is not in PATH")
    caches = discover_caches(args.root, args.caches)
    if not caches:
        parser.error("no main arm64/arm64e DSC files found")

    print("cache\tprepare\tallowed\tupdate-pattern\tdisplay-pattern\tresult", flush=True)
    failures = 0
    for cache in caches:
        label = cache.parent.name
        prepare = disassemble_symbol(cache, PREPARE_SYMBOLS)
        allowed = disassemble_symbol(cache, ALLOWED_SYMBOLS, count=1)
        display = disassemble_symbol(cache, DISPLAY_INFO_SYMBOLS)

        legacy_hits = find_legacy_update_pattern(prepare) if prepare else []
        allowed_hits = (
            find_allowed_update_pattern(prepare, allowed.address) if prepare and allowed else []
        )
        display_hits = find_display_flags_pattern(display) if display else []

        if len(allowed_hits) == 1:
            call, branch, store, kind, base, offset = allowed_hits[0]
            update_text = f"allowed/{kind}@0x{store:x}[x{base}+0x{offset:x}]"
        elif len(legacy_hits) == 1:
            _, branch = legacy_hits[0]
            update_text = f"legacy/B.NE@0x{branch:x}"
        elif allowed_hits or legacy_hits:
            update_text = f"ambiguous(a={len(allowed_hits)},l={len(legacy_hits)})"
        else:
            update_text = "missing"

        if len(display_hits) == 1:
            layout, _, source_offset, output_offset = display_hits[0]
            display_text = f"{layout}:0x{output_offset:x}<-0x{source_offset:x}"
        elif display_hits:
            display_text = f"ambiguous({len(display_hits)})"
        else:
            display_text = "missing"

        success = (len(allowed_hits) == 1 or len(legacy_hits) == 1) and len(display_hits) == 1
        if not success:
            failures += 1
        print(
            f"{label}\t{short_symbol(prepare.symbol if prepare else None)}\t"
            f"{short_symbol(allowed.symbol if allowed else None)}\t{update_text}\t"
            f"{display_text}\t{'PASS' if success else 'FAIL'}",
            flush=True,
        )

    print(f"\n{len(caches) - failures}/{len(caches)} caches passed")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
