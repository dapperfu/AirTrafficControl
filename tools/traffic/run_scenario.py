"""Fly the scenario on one BEAM node per airport.

Finite scales sleep sim_step / scale. max does not sleep. Every log line
carries the simulated clock sent with the transmission.
"""

from __future__ import annotations

import argparse
import glob
import json
import os
import signal
import socket
import subprocess
import sys
import time
import uuid
from pathlib import Path

ROOT_DEFAULT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT_DEFAULT / "apps" / "aircraft" / "src"))
sys.path.insert(0, str(ROOT_DEFAULT / "tools" / "navdata"))
sys.path.insert(0, str(ROOT_DEFAULT / "tools" / "traffic"))

from aircraft.enroute import TERMINAL_NM, EnrouteLeg, Field  # noqa: E402
from compose import frequency_arg, write_addresses, write_compose  # noqa: E402
from import_navdata import frequency_port  # noqa: E402

SCALES = {"1", "10", "100", "max"}


def pace(sim_seconds: float, scale: str) -> None:
    if scale == "max":
        return
    if scale not in SCALES:
        raise ValueError(scale)
    time.sleep(sim_seconds / float(scale))


def loopback_addresses(scenario: dict) -> dict[str, str]:
    hosts = {"CENTER": "127.0.1.1"}
    for index, icao in enumerate(sorted(scenario["airports"]), start=2):
        hosts[icao] = f"127.0.1.{index}"
    return hosts


def run(
    scenario: dict,
    scale: str,
    log_dir: Path,
    root: Path,
    radios_ready: bool = False,
) -> dict:
    if scale not in SCALES:
        raise ValueError(scale)
    log_dir.mkdir(parents=True, exist_ok=True)
    addresses = loopback_addresses(scenario)
    processes: list[subprocess.Popen] = []
    if not radios_ready:
        processes = start_radios(scenario, addresses, log_dir, root)
    started = time.monotonic()
    simulated = 0.0
    try:
        wait_ready(scenario, log_dir)
        check_schedulers(scenario, log_dir)
        flights = fly(scenario, addresses, scale)
        simulated = max(item["sim_time"] for item in flights)
        check_logs(log_dir, flights)
    finally:
        stop_radios(processes)
    elapsed = time.monotonic() - started
    if scale == "max" and simulated > 60 and elapsed > max(120.0, simulated / 20.0):
        raise RuntimeError(
            f"max scale slept: wall {elapsed:.1f}s for {simulated:.0f}s of simulation"
        )
    return {"flights": flights, "elapsed": elapsed, "simulated": simulated}


def start_radios(scenario, addresses, log_dir, root) -> list[subprocess.Popen]:
    processes = [
        start_radio(
            root,
            "CENTER",
            addresses["CENTER"],
            "enroute",
            "none",
            f"{scenario['enroute_mhz']}|Center|CTR",
            1,
            log_dir,
        )
    ]
    for icao, airport in sorted(scenario["airports"].items()):
        processes.append(
            start_radio(
                root,
                icao,
                addresses[icao],
                "tower",
                config_path(root, log_dir, icao),
                frequency_arg(airport),
                airport["schedulers"],
                log_dir,
            )
        )
    return processes


def config_path(root: Path, log_dir: Path, icao: str) -> str:
    candidates = [
        log_dir.parent / "airports" / f"{icao}.toml",
        root / "data" / "catalog" / "airports" / f"{icao}.toml",
    ]
    for path in candidates:
        if path.exists():
            return str(path)
    raise FileNotFoundError(icao)


def start_radio(root, icao, bind, mode, config, freqs, schedulers, log_dir) -> subprocess.Popen:
    erl = root / ".tools" / "erlang" / "bin" / "erl"
    paths = sorted(glob.glob(str(root / "_build" / "default" / "lib" / "*" / "ebin")))
    if not paths:
        raise RuntimeError("Erlang ebin is missing. Run make build first.")
    quoted = ",".join(erl_string(part) for part in (icao, bind, config, str(log_dir), mode, freqs))
    expression = f"atc_radio_cli:main([{quoted}]), receive stop -> ok end."
    command = [str(erl), "+S", f"{schedulers}:{schedulers}", "-noshell"]
    for path in paths:
        command.extend(["-pa", path])
    command.extend(["-eval", expression])
    console = open(log_dir / f"{icao}.console", "w")
    return subprocess.Popen(
        command,
        stdout=console,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        cwd=str(root),
    )


def erl_string(text: str) -> str:
    return '"' + str(text).replace("\\", "").replace('"', "") + '"'


def wait_ready(scenario, log_dir: Path) -> None:
    names = ["CENTER", *scenario["airports"].keys()]
    deadline = time.monotonic() + 40
    pending = set(names)
    while pending and time.monotonic() < deadline:
        ready = {name for name in pending if (log_dir / f"{name}.ready").exists()}
        pending -= ready
        if pending:
            time.sleep(0.1)
    if pending:
        details = []
        for name in sorted(pending):
            console = log_dir / f"{name}.console"
            tail = console.read_text(errors="replace")[-500:] if console.exists() else ""
            details.append(f"{name}: {tail}")
        raise RuntimeError("radio did not become ready: " + " | ".join(details))


def check_schedulers(scenario, log_dir: Path) -> None:
    expected = {"CENTER": 1}
    expected.update(
        {icao: airport["schedulers"] for icao, airport in scenario["airports"].items()}
    )
    for name, schedulers in expected.items():
        got = int((log_dir / f"{name}.ready").read_text().strip())
        if got != schedulers:
            raise RuntimeError(f"{name} schedulers {got} expected {schedulers}")


def fly(scenario, addresses, scale: str) -> list[dict]:
    clock = 0
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.1.200", 0))
    flights = []
    try:
        for pair in scenario["pairs"]:
            origin = scenario["airports"][pair["origin"]]
            dest = scenario["airports"][pair["destination"]]
            flight_id = str(uuid.uuid4())
            callsign = pair["callsign"]
            clock = departure(sock, addresses, origin, dest, flight_id, callsign, clock, scale)
            clock = enroute(sock, addresses, scenario, origin, dest, flight_id, callsign, clock, scale)
            clock = arrival(sock, addresses, dest, flight_id, callsign, clock, scale)
            flights.append(
                {
                    "uuid": flight_id,
                    "callsign": callsign,
                    "origin": origin["icao"],
                    "destination": dest["icao"],
                    "sim_time": clock,
                }
            )
    finally:
        sock.close()
    return flights


def departure(sock, addresses, origin, dest, flight_id, callsign, clock, scale) -> int:
    port = frequency_port(origin["tower_mhz"])
    host = addresses[origin["icao"]]
    facility = tower_name(origin)
    runway = origin["primary_runway"]
    phrases = [
        f"{facility}, {callsign}, request IFR clearance to {dest['icao']}",
        f"{facility}, {callsign}, request taxi",
        f"runway {runway} for departure",
        "hold short",
        "line up and wait",
        "cleared for takeoff",
        f"{callsign}, climb and maintain flight level three five zero",
        "contact Center",
    ]
    for english in phrases:
        clock = transmit(sock, host, port, flight_id, "departure", callsign, english, clock, scale)
    return clock


def enroute(sock, addresses, scenario, origin, dest, flight_id, callsign, clock, scale) -> int:
    port = frequency_port(scenario["enroute_mhz"])
    host = addresses["CENTER"]
    clock = transmit(
        sock,
        host,
        port,
        flight_id,
        "enroute",
        callsign,
        f"Center, {callsign}, climb and maintain flight level three five zero",
        clock,
        scale,
    )
    leg = EnrouteLeg(field(origin), field(dest), "jet")
    leg.fly_to_terminal(30.0)
    if leg.state.distance_remaining_nm >= TERMINAL_NM:
        raise RuntimeError(f"{callsign} did not reach the arrival terminal")
    clock = advance(clock, leg.steps * 30, scale)
    clock = transmit(
        sock,
        host,
        port,
        flight_id,
        "enroute",
        callsign,
        f"Center, {callsign}, request descent",
        clock,
        scale,
    )
    clock = transmit(
        sock,
        host,
        port,
        flight_id,
        "enroute",
        callsign,
        f"contact {dest['icao']} approach",
        clock,
        scale,
    )
    return clock


def arrival(sock, addresses, dest, flight_id, callsign, clock, scale) -> int:
    port = frequency_port(dest["tower_mhz"])
    host = addresses[dest["icao"]]
    runway = dest["primary_runway"]
    for english in (
        f"runway {runway} for arrival",
        "cleared to land",
        "runway vacated",
        "contact Center",
    ):
        clock = transmit(sock, host, port, flight_id, "arrival", callsign, english, clock, scale)
    return clock


def transmit(sock, host, port, flight_id, chapter, callsign, english, clock, scale) -> int:
    clock = advance(clock, 1, scale)
    sock.sendto(f"clock {clock}\n".encode(), (host, port))
    packet = f"flight {flight_id} {chapter} {callsign}\n{english}\n".encode()
    sock.sendto(packet, (host, port))
    sock.settimeout(5)
    data, _source = sock.recvfrom(8192)
    text = data.decode()
    if "unable" in text:
        raise RuntimeError(f"{callsign} {chapter} refused: {english} -> {text.strip()}")
    return clock


def advance(clock: int, seconds: float, scale: str) -> int:
    pace(seconds, scale)
    return clock + int(seconds)


def field(airport: dict) -> Field:
    return Field(airport["latitude"], airport["longitude"], airport["elevation_ft"])


def tower_name(airport: dict) -> str:
    for freq in airport["frequencies"]:
        if freq["type"] == "TWR":
            return freq["description"]
    return airport["name"]


def check_logs(log_dir: Path, flights: list[dict]) -> None:
    for flight in flights:
        folder = log_dir / flight["uuid"]
        departure = (folder / "departure.jsonl").read_text()
        arrival = (folder / "arrival.jsonl").read_text()
        enroute_text = (folder / "enroute.jsonl").read_text()
        if "cleared for takeoff" not in departure or '"direction":"out"' not in departure:
            raise RuntimeError(f"{flight['callsign']} departure log is incomplete")
        if "cleared to land" not in arrival or '"direction":"out"' not in arrival:
            raise RuntimeError(f"{flight['callsign']} arrival log is incomplete")
        if '"sim_time"' not in departure or '"sim_time"' not in enroute_text:
            raise RuntimeError(f"{flight['callsign']} log is missing the simulated clock")


def stop_radios(processes: list[subprocess.Popen]) -> None:
    for process in processes:
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
    for process in processes:
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", type=Path, required=True)
    parser.add_argument("--scale", default="max")
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--root", type=Path, default=ROOT_DEFAULT)
    parser.add_argument("--radios-ready", action="store_true")
    parser.add_argument("--compose", type=Path)
    args = parser.parse_args()
    scenario = json.loads(args.scenario.read_text())
    if args.compose:
        write_compose(scenario, args.compose)
        write_addresses(scenario, args.compose.with_suffix(".addresses.json"))
    result = run(scenario, args.scale, args.log, args.root, args.radios_ready)
    print(
        f"flights {len(result['flights'])} sim {result['simulated']}s "
        f"wall {result['elapsed']:.1f}s scale {args.scale}"
    )


if __name__ == "__main__":
    main()
