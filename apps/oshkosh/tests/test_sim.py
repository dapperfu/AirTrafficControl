"""The fly-in lands only on marks the open runways can spare."""

from oshkosh.field import (
    ARRIVAL_CLOSE_S,
    ARRIVAL_OPEN_S,
    CLOSED,
    SHOW,
    SHOW_CLOSE_S,
    SHOW_RESUME_S,
    accepting,
)
from oshkosh.sim import Aircraft, fly_in, land


OPEN = ARRIVAL_OPEN_S + 3600


def _light(seq: int, at_s: int, occupancy_s: int = 40) -> Aircraft:
    return Aircraft(seq, at_s, 1500, 40, occupancy_s)


def test_a_second_mark_is_used_before_the_first_aircraft_exits() -> None:
    first = _light(0, OPEN)
    second = _light(1, OPEN + 1)
    result = land([first, second], runways=("36L",), simultaneous=True)
    assert result.landed == 2
    assert result.diverted == 0
    early, later = result.landings
    assert early.spot == "purple dot"
    assert later.spot == "yellow dot"
    assert later.at_s == early.at_s + 15
    assert later.at_s < early.at_s + first.occupancy_s


def test_the_same_mark_waits_until_the_occupant_is_off() -> None:
    first = Aircraft(0, OPEN, 4000, 40, 40)
    second = Aircraft(1, OPEN + 1, 4000, 40, 40)
    result = land([first, second], runways=("36L",), simultaneous=True)
    assert [item.spot for item in result.landings] == ["purple dot", "purple dot"]
    assert result.landings[1].at_s == result.landings[0].at_s + first.occupancy_s


def test_a_short_mark_is_refused_when_the_landing_needs_more_pavement() -> None:
    aircraft = Aircraft(0, OPEN, 4000, 40, 40)
    result = land([aircraft], runways=("27",))
    assert result.landed == 1
    assert result.landings[0].spot == "displaced threshold"
    assert result.landings[0].spot != "green dot"


def test_the_narrow_parallel_refuses_a_wide_aircraft() -> None:
    wide = Aircraft(0, OPEN, 2000, 80, 40)
    result = land([wide], runways=("36R",))
    assert result.landed == 0
    assert result.go_arounds == 0
    assert result.diverted == 1


def test_the_airshow_holds_one_arrival_until_the_field_reopens() -> None:
    aircraft = _light(0, SHOW_CLOSE_S)
    result = land([aircraft], runways=("36L",))
    assert result.landed == 1
    assert result.landings[0].at_s == SHOW_RESUME_S


def test_an_arrival_after_the_day_closes_diverts() -> None:
    result = land([_light(0, ARRIVAL_CLOSE_S)], runways=("36L",))
    assert result.landed == 0
    assert result.diverted == 1


def test_a_full_hold_diverts_during_the_airshow() -> None:
    result = land([_light(0, SHOW_CLOSE_S)], runways=("36L",), hold_limit=0)
    assert result.landed == 0
    assert result.diverted == 1


def test_a_closed_runway_accepts_nobody() -> None:
    result = land([_light(0, OPEN)], runways=("05/23",))
    assert result.landed == 0
    assert result.diverted == 1
    assert result.go_arounds == 0


def test_the_show_flow_does_not_use_the_closed_runways() -> None:
    result = land(fly_in(80, seed=2), flow="36-27")
    used = {item.runway for item in result.landings}
    assert used.isdisjoint(CLOSED)
    assert result.landed + result.diverted == 80


def test_colored_marks_land_more_of_a_rush_than_one_aircraft_at_a_time() -> None:
    rush = [_light(seq, OPEN + seq) for seq in range(40)]
    show = land(rush, flow="36-27", simultaneous=True)
    serial = land(rush, flow="36-27", simultaneous=False)
    paved = land(rush, runways=("36L", "27"), simultaneous=False)
    assert show.landed > serial.landed
    assert serial.landed >= paved.landed
    assert show.landed + show.diverted == 40
    assert paved.landed + paved.diverted == 40


def test_one_aircraft_at_a_time_blocks_the_other_mark() -> None:
    first = _light(0, OPEN)
    second = _light(1, OPEN + 1)
    result = land([first, second], runways=("36L",), simultaneous=False)
    assert result.landings[1].at_s == result.landings[0].at_s + first.occupancy_s


def test_the_fly_in_is_deterministic_and_stays_inside_open_hours() -> None:
    assert fly_in(30, seed=4) == fly_in(30, seed=4)
    assert fly_in(30, seed=4) != fly_in(30, seed=5)
    for item in fly_in(30, seed=4):
        assert accepting(item.at_s)
    assert fly_in(0) == []
    assert land([]).flew_in == 0


def test_show_surfaces_list_the_notice_marks_and_the_closed_pair() -> None:
    by_name = {surface.runway: surface for surface in SHOW}
    assert [spot.name for spot in by_name["36L"].spots] == ["purple dot", "yellow dot"]
    assert [spot.remaining_ft for spot in by_name["36L"].spots] == [4950, 3400]
    assert [spot.name for spot in by_name["36R"].spots] == ["green square", "red square"]
    assert by_name["36R"].width_ft == 60
    assert [spot.name for spot in by_name["27"].spots] == [
        "displaced threshold",
        "orange dot",
        "green dot",
    ]
    assert by_name["05/23"].spots == ()
    assert by_name["13/31"].spots == ()
    assert not accepting(SHOW_CLOSE_S)
    assert accepting(SHOW_RESUME_S)
