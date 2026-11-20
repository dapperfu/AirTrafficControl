"""Write a compose file with one airport service per scenario field."""

from __future__ import annotations

import json
from pathlib import Path


def frequency_arg(airport: dict) -> str:
    parts = []
    for freq in airport["frequencies"]:
        description = freq["description"].replace("|", " ").replace(";", " ").replace('"', "")
        parts.append(f"{freq['mhz']}|{description}|{freq['type']}")
    return ";".join(parts)


def service_name(icao: str) -> str:
    return "airport-" + icao.lower()


def write_compose(scenario: dict, path: Path) -> None:
    lines = [
        "# Generated for the national radio simulation.",
        "services:",
        "  enroute:",
        "    image: atc-airport:2",
        "    environment:",
        '      ICAO: "CENTER"',
        '      BIND: "0.0.0.0"',
        '      SCHEDULERS: "1"',
        '      MODE: "enroute"',
        '      CONFIG: "none"',
        '      LOG_DIR: "/logs"',
        f'      FREQS: "{scenario["enroute_mhz"]}|Center|CTR"',
        "    volumes:",
        "      - ./logs:/logs",
    ]
    depends = ["enroute"]
    for icao, airport in sorted(scenario["airports"].items()):
        name = service_name(icao)
        depends.append(name)
        lines.extend(
            [
                f"  {name}:",
                "    image: atc-airport:2",
                "    environment:",
                f'      ICAO: "{icao}"',
                '      BIND: "0.0.0.0"',
                f'      SCHEDULERS: "{airport["schedulers"]}"',
                '      MODE: "tower"',
                f'      CONFIG: "/catalog/{icao}.toml"',
                '      LOG_DIR: "/logs"',
                f'      FREQS: "{frequency_arg(airport)}"',
                "    volumes:",
                "      - ./data/catalog/airports:/catalog:ro",
                "      - ./logs:/logs",
            ]
        )
    lines.extend(
        [
            "  traffic:",
            "    image: atc-traffic:2",
            "    environment:",
            '      SCALE: "max"',
            "    depends_on:",
        ]
    )
    for name in depends:
        lines.append(f"      - {name}")
    lines.extend(
        [
            "    volumes:",
            "      - ./data/catalog:/catalog:ro",
            "      - ./logs:/logs",
            "    command:",
            '      - "--scenario"',
            '      - "/catalog/scenario.json"',
            '      - "--scale"',
            '      - "max"',
            '      - "--log"',
            '      - "/logs"',
            '      - "--radios-ready"',
            "",
        ]
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines))


def addresses_for_docker(scenario: dict) -> dict:
    hosts = {"CENTER": "enroute"}
    for icao in scenario["airports"]:
        hosts[icao] = service_name(icao)
    return hosts


def write_addresses(scenario: dict, path: Path) -> None:
    path.write_text(json.dumps(addresses_for_docker(scenario), indent=2) + "\n")
