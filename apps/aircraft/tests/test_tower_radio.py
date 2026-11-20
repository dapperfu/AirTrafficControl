"""Aircraft phrases go to the tower radio. Stand-by is not a clearance."""

import socket
import subprocess
from pathlib import Path

import pytest

from aircraft.aircraft import Aircraft, Phase
from aircraft.config import load_config
from aircraft.tower_radio import TowerRadio, apply_reply, is_standby, mhz_port

ROOT = Path(__file__).resolve().parents[3]
FLIGHT = "11111111-2222-4333-8444-555555555555"


def test_standby_does_not_change_the_aircraft() -> None:
    aircraft = Aircraft(load_config(ROOT / "config" / "n123ab.toml"))
    assert apply_reply(aircraft, "flight x\nstand by\n") is None
    assert aircraft.phase is Phase.RAMP


def test_guard_assign_reply_is_a_taxi_clearance() -> None:
    aircraft = Aircraft(load_config(ROOT / "config" / "n123ab.toml"))
    apply_reply(aircraft, "flight x\nrunway 27 for departure\n")
    assert aircraft.phase is Phase.TAXI


def test_aircraft_phrase_reaches_the_tower(tmp_path: Path) -> None:
    erl = ROOT / ".tools" / "erlang" / "bin" / "erl"
    libs = list((ROOT / "_build" / "default" / "lib").glob("*/ebin"))
    if not erl.exists() or not libs:
        pytest.skip("compiled tower radio is not available")
    port = mhz_port(135.0)
    if _port_open(port):
        pytest.skip("training radio port is already in use")
    log_dir = tmp_path / "radio"
    log_dir.mkdir()
    data_dir = tmp_path / "ra"
    data_dir.mkdir()
    config = ROOT / "config" / "example-airport.toml"
    command = [
        str(erl),
        "-noshell",
        *[item for path in libs for item in ("-pa", str(path))],
        "-eval",
        _start(config, log_dir, data_dir),
    ]
    process = subprocess.Popen(
        command,
        cwd=tmp_path,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    radio = TowerRadio("127.0.0.1", port)
    try:
        _wait_ready(log_dir / "KEXAMPLE.ready", process)
        aircraft = Aircraft(load_config(ROOT / "config" / "n123ab.toml"))
        request = aircraft.request_taxi()
        assert request is not None
        radio.publish_track("N123AB", 1, 3000, 400, 0, 0, 0, "small", "27")
        issued = radio.exchange(FLIGHT, "departure", "N123AB", request.phrase)
        assert not is_standby(issued)
        assert "runway" in issued.lower()
        apply_reply(aircraft, issued)
        assert aircraft.phase is Phase.TAXI
        standby = radio.exchange(
            FLIGHT, "departure", "N123AB", "request IFR clearance to Chicago"
        )
        assert is_standby(standby)
        assert aircraft.phase is Phase.TAXI
    finally:
        radio.close()
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()


def _port_open(port: int) -> bool:
    probe = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        probe.bind(("127.0.0.1", port))
    except OSError:
        return True
    else:
        return False
    finally:
        probe.close()


def _wait_ready(path: Path, process: subprocess.Popen[str]) -> None:
    for _ in range(50):
        if path.exists():
            return
        if process.poll() is not None:
            output = process.stdout.read() if process.stdout is not None else ""
            raise RuntimeError(output)
        socket_wait()
    raise RuntimeError("tower radio did not become ready")


def socket_wait() -> None:
    import time

    time.sleep(0.1)


def _start(config: Path, log_dir: Path, data_dir: Path) -> str:
    return (
        f'ra:start([{{data_dir, "{data_dir}"}}]), '
        "application:ensure_all_started(atc_radio), "
        "{ok, _} = atc_radio_server:start_link(#{icao => <<\"KEXAMPLE\">>, "
        'bind => "127.0.0.1", '
        f'config => "{config}", '
        f'log_dir => "{log_dir}", '
        "mode => tower, "
        'freqs => "135.0|Example Tower|TWR"}), '
        "timer:sleep(infinity)."
    )
