"""Build a tower-airport catalog and a busy-flow scenario.

OurAirports supplies positions, runways, and frequencies. The pinned FAA
NASR cycle says which fields have a tower. The pinned BTS T-100 month
supplies scheduled airline city pairs. General aviation is not in T-100,
so it is not in the load.
"""

from __future__ import annotations

import argparse
import csv
import io
import json
import re
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

from pins import (
    BAND_HIGH,
    BAND_LOW,
    ENROUTE_MHZ,
    NASR_APT_CSV,
    NASR_CYCLE,
    OURAIRPORTS_AIRPORTS,
    OURAIRPORTS_FREQUENCIES,
    OURAIRPORTS_RUNWAYS,
    T100_FORM,
    T100_MONTH,
    T100_YEAR,
    TOP_PAIRS,
)

RUNWAY_IDENT = re.compile(r"^\d{1,2}[LRC]?$")
USER_AGENT = "AirTrafficControl-navdata"


def schedulers_for(operations: int) -> int:
    """One BEAM scheduler bucket from departures plus arrivals."""
    if operations < 50:
        return 1
    if operations < 300:
        return 2
    if operations < 1000:
        return 4
    return 8


def frequency_port(mhz: float) -> int:
    return 20000 + int(round((mhz - 118.0) / 0.025))


def download(raw_dir: Path) -> None:
    raw_dir.mkdir(parents=True, exist_ok=True)
    _fetch(OURAIRPORTS_AIRPORTS, raw_dir / "airports.csv")
    _fetch(OURAIRPORTS_RUNWAYS, raw_dir / "runways.csv")
    _fetch(OURAIRPORTS_FREQUENCIES, raw_dir / "airport-frequencies.csv")
    _fetch(NASR_APT_CSV, raw_dir / "nasr-apt.zip")
    _download_t100(raw_dir / f"t100-{T100_YEAR}-{T100_MONTH:02d}.zip")


def build(source: Path, out_dir: Path, top_pairs: int = TOP_PAIRS) -> dict:
    airports = _airports(source)
    runways = _runways(source)
    frequencies = _frequencies(source)
    towers = _nasr_towers(source)
    catalog = _catalog(airports, runways, frequencies, towers)
    counts = _city_pairs(source, catalog)
    scenario = _scenario(catalog, counts, top_pairs)
    out_dir.mkdir(parents=True, exist_ok=True)
    airport_dir = out_dir / "airports"
    airport_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "catalog.json").write_text(json.dumps(catalog, indent=2) + "\n")
    (out_dir / "scenario.json").write_text(json.dumps(scenario, indent=2) + "\n")
    for airport in scenario["airports"].values():
        (airport_dir / f"{airport['icao']}.toml").write_text(tower_toml(airport))
    return scenario


def tower_toml(airport: dict) -> str:
    lines = [
        "[airport]",
        f'icao = "{airport["icao"]}"',
        f'latitude = {airport["latitude"]}',
        f'longitude = {airport["longitude"]}',
        "communications_distance_nm = 30.0",
        "computers = 1",
        "max_runways = 4",
        "max_aircraft = 8",
        "max_neighbors = 2",
        'wind = "270 at 10"',
        "",
    ]
    for runway in airport["runways"]:
        designation = "closed" if runway["closed"] else "both"
        lines.extend(
            [
                "[[runway]]",
                f'id = "{runway["id"]}"',
                f'designation = "{designation}"',
                "independent = true",
                "intersects = []",
                "",
            ]
        )
    lines.extend(
        [
            "[[neighbor]]",
            'icao = "Center"',
            f'latitude = {airport["latitude"]}',
            f'longitude = {airport["longitude"]}',
            "",
        ]
    )
    return "\n".join(lines)


def _fetch(url: str, dest: Path) -> None:
    if dest.exists() and dest.stat().st_size > 0:
        return
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=120) as response:
        dest.write_bytes(response.read())


def _download_t100(dest: Path) -> None:
    if dest.exists() and dest.stat().st_size > 0:
        return
    page = _form_page()
    fields = {
        "__EVENTTARGET": "",
        "__EVENTARGUMENT": "",
        "__LASTFOCUS": "",
        "__VIEWSTATE": _hidden(page, "__VIEWSTATE"),
        "__VIEWSTATEGENERATOR": _hidden(page, "__VIEWSTATEGENERATOR"),
        "__EVENTVALIDATION": _hidden(page, "__EVENTVALIDATION"),
        "cboGeography": "All",
        "cboYear": str(T100_YEAR),
        "cboPeriod": str(T100_MONTH),
        "chkDownloadZip": "on",
        "ORIGIN": "on",
        "DEST": "on",
        "DEPARTURES_PERFORMED": "on",
        "YEAR": "on",
        "MONTH": "on",
        "btnDownload": "Download",
    }
    data = urllib.parse.urlencode(fields).encode()
    request = urllib.request.Request(
        T100_FORM,
        data=data,
        headers={
            "User-Agent": USER_AGENT,
            "Referer": T100_FORM,
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )
    with urllib.request.urlopen(request, timeout=180) as response:
        dest.write_bytes(response.read())


def _form_page() -> str:
    request = urllib.request.Request(T100_FORM, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(request, timeout=60) as response:
        return response.read().decode("utf-8", "replace")


def _hidden(page: str, name: str) -> str:
    marker = f'name="{name}"'
    start = page.find(marker)
    if start < 0:
        raise RuntimeError(f"T-100 form is missing {name}")
    value = page.find('value="', start)
    end = page.find('"', value + 7)
    return page[value + 7 : end]


def _read_csv(source: Path, name: str) -> list[dict]:
    path = source / name
    if path.exists():
        text = path.read_text(encoding="utf-8", errors="replace")
        return list(csv.DictReader(io.StringIO(text)))
    return []


def _airports(source: Path) -> list[dict]:
    return _read_csv(source, "airports.csv")


def _runways(source: Path) -> dict[str, list[dict]]:
    grouped: dict[str, list[dict]] = {}
    for row in _read_csv(source, "runways.csv"):
        grouped.setdefault(row["airport_ident"], []).append(row)
    return grouped


def _frequencies(source: Path) -> dict[str, list[dict]]:
    grouped: dict[str, list[dict]] = {}
    for row in _read_csv(source, "airport-frequencies.csv"):
        grouped.setdefault(row["airport_ident"], []).append(row)
    return grouped


def _nasr_towers(source: Path) -> set[str]:
    rows = _nasr_rows(source)
    towers = set()
    for row in rows:
        kind = (row.get("TWR_TYPE_CODE") or "").strip()
        if not kind.startswith("ATCT"):
            continue
        icao = (row.get("ICAO_ID") or "").strip()
        if icao:
            towers.add(icao)
    return towers


def _nasr_rows(source: Path) -> list[dict]:
    plain = source / "APT_BASE.csv"
    if plain.exists():
        return list(csv.DictReader(plain.open(encoding="utf-8", errors="replace")))
    archive = source / "nasr-apt.zip"
    if not archive.exists():
        return []
    with zipfile.ZipFile(archive) as bundle:
        text = bundle.read("APT_BASE.csv").decode("utf-8", "replace")
    return list(csv.DictReader(io.StringIO(text)))


def _catalog(airports, runways, frequencies, towers) -> dict:
    catalog = {}
    for row in airports:
        if row.get("iso_country") != "US":
            continue
        icao = row["ident"]
        if icao not in towers:
            continue
        freqs = _band_frequencies(frequencies.get(icao, []))
        if not freqs:
            continue
        exported = _export_runways(runways.get(icao, []))
        if not exported:
            continue
        catalog[icao] = {
            "icao": icao,
            "iata": (row.get("iata_code") or "").strip(),
            "name": row.get("name") or icao,
            "municipality": row.get("municipality") or "",
            "latitude": float(row["latitude_deg"]),
            "longitude": float(row["longitude_deg"]),
            "elevation_ft": float(row["elevation_ft"] or 0),
            "frequencies": freqs,
            "runways": exported,
            "primary_runway": next(
                (item["id"] for item in exported if not item["closed"]),
                exported[0]["id"],
            ),
            "tower_mhz": _tower_mhz(freqs),
            "nasr_cycle": NASR_CYCLE,
            "operations": 0,
            "schedulers": 1,
        }
    return catalog


def _band_frequencies(rows: list[dict]) -> list[dict]:
    found = []
    seen = set()
    for row in rows:
        try:
            mhz = float(row["frequency_mhz"])
        except (TypeError, ValueError):
            continue
        if mhz < BAND_LOW or mhz > BAND_HIGH:
            continue
        description = (row.get("description") or "Tower").strip()
        kind = (row.get("type") or "").strip()
        key = (mhz, kind, description)
        if key in seen:
            continue
        seen.add(key)
        found.append(
            {
                "mhz": mhz,
                "type": kind,
                "description": description,
                "port": frequency_port(mhz),
            }
        )
    return found


def _tower_mhz(freqs: list[dict]) -> float:
    for freq in freqs:
        if freq["type"] == "TWR":
            return freq["mhz"]
    return freqs[0]["mhz"]


def _export_runways(rows: list[dict]) -> list[dict]:
    usable = []
    for row in rows:
        for end in ("le_ident", "he_ident"):
            ident = (row.get(end) or "").strip().upper()
            if not RUNWAY_IDENT.match(ident):
                continue
            try:
                length = int(float(row.get("length_ft") or 0))
            except ValueError:
                length = 0
            usable.append(
                {
                    "id": ident,
                    "length_ft": length,
                    "closed": str(row.get("closed") or "0").strip() in {"1", "true", "TRUE"},
                }
            )
    usable.sort(key=lambda item: item["length_ft"], reverse=True)
    chosen = []
    seen = set()
    for runway in usable:
        if runway["id"] in seen:
            continue
        seen.add(runway["id"])
        chosen.append(runway)
        if len(chosen) == 4:
            break
    return chosen


def _city_pairs(source: Path, catalog: dict) -> dict[tuple[str, str], int]:
    by_iata = {}
    for airport in catalog.values():
        if airport["iata"]:
            by_iata.setdefault(airport["iata"], airport["icao"])
    counts: dict[tuple[str, str], int] = {}
    operations: dict[str, int] = {icao: 0 for icao in catalog}
    for row in _t100_rows(source):
        try:
            performed = int(float(row["DEPARTURES_PERFORMED"]))
        except (TypeError, ValueError):
            continue
        origin = by_iata.get((row.get("ORIGIN") or "").strip())
        dest = by_iata.get((row.get("DEST") or "").strip())
        if origin is None or dest is None or origin == dest:
            continue
        counts[(origin, dest)] = counts.get((origin, dest), 0) + performed
        operations[origin] += performed
        operations[dest] += performed
    for icao, count in operations.items():
        catalog[icao]["operations"] = count
        catalog[icao]["schedulers"] = schedulers_for(count)
    return counts


def _t100_rows(source: Path) -> list[dict]:
    plain = source / "t100.csv"
    if plain.exists():
        return list(csv.DictReader(plain.open(encoding="utf-8", errors="replace")))
    archive = source / f"t100-{T100_YEAR}-{T100_MONTH:02d}.zip"
    if not archive.exists():
        return []
    with zipfile.ZipFile(archive) as bundle:
        name = next(
            item
            for item in bundle.namelist()
            if item.endswith(".csv") and not item.startswith("Documentation")
        )
        text = bundle.read(name).decode("utf-8", "replace")
    return list(csv.DictReader(io.StringIO(text)))


def _scenario(catalog: dict, counts: dict, top_pairs: int) -> dict:
    ranked = sorted(counts.items(), key=lambda item: (-item[1], item[0]))
    selected = ranked[:top_pairs]
    forced = ("KSFO", "KORD")
    if forced in counts and forced not in dict(selected):
        selected.append((forced, counts[forced]))
    pairs = []
    used = set()
    for index, ((origin, dest), departures) in enumerate(selected, start=1):
        used.add(origin)
        used.add(dest)
        pairs.append(
            {
                "origin": origin,
                "destination": dest,
                "departures": departures,
                "callsign": f"UAL{index:04d}",
                "category": "jet",
            }
        )
    airports = {icao: catalog[icao] for icao in sorted(used)}
    return {
        "t100_year": T100_YEAR,
        "t100_month": T100_MONTH,
        "nasr_cycle": NASR_CYCLE,
        "enroute_mhz": ENROUTE_MHZ,
        "pairs": pairs,
        "airports": airports,
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--download", type=Path)
    parser.add_argument("--source", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--top-pairs", type=int, default=TOP_PAIRS)
    args = parser.parse_args()
    if args.download:
        download(args.download)
    source = args.source or args.download
    if source is None:
        raise SystemExit("pass --source or --download")
    scenario = build(source, args.out, args.top_pairs)
    print(
        f"towers in scenario {len(scenario['airports'])} "
        f"pairs {len(scenario['pairs'])}"
    )


if __name__ == "__main__":
    main()
