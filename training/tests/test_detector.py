"""The Python copy of the counting rules: same behaviour and same numbers as the Swift original."""

import re
from pathlib import Path

from detector import Settings, combine, count_blinks

SWIFT_DETECTOR = Path(__file__).resolve().parents[2] / "Sources/BlinkCore/Detection/BlinkDetector.swift"
OPEN, CLOSED = 0.02, 0.98


def blinks(stream: list[float | None]) -> int:
    """How many blinks a stream of answers at 30 frames a second holds."""
    return len(count_blinks([i / 30 for i in range(len(stream))], stream))


def test_numbers_are_the_swift_numbers():
    source = SWIFT_DETECTOR.read_text()

    def swift(name: str) -> float:
        match = re.search(rf"public var {name} = ([0-9.]+)", source)
        assert match, f"{name} not found in {SWIFT_DETECTOR.name}"
        return float(match.group(1))

    settings = Settings()
    assert settings.closed_above == swift("closedAbove")
    assert settings.open_below == swift("openBelow")
    assert settings.minimum_closed_frames == swift("minimumClosedFrames")
    assert settings.single_frame_sure == swift("singleFrameSure")
    assert settings.maximum_blink_seconds == swift("maximumBlinkSeconds")
    assert settings.maximum_gap_seconds == swift("maximumGapSeconds")
    assert settings.maximum_up_down == swift("maximumUpDown")


def test_one_blink():
    assert blinks([OPEN] * 15 + [CLOSED] * 4 + [OPEN] * 5) == 1


def test_two_blinks_in_a_row():
    assert blinks([OPEN] * 10 + [CLOSED] * 3 + [OPEN] * 10 + [CLOSED] * 3 + [OPEN] * 5) == 2


def test_a_lone_hesitant_frame_is_a_model_mistake():
    assert blinks([OPEN] * 10 + [0.7] + [OPEN] * 10) == 0
    assert blinks([OPEN] * 10 + [0.79] + [OPEN] * 10) == 0


def test_a_lone_frame_counts_when_the_model_is_very_sure():
    assert blinks([OPEN] * 10 + [0.97] + [OPEN] * 10) == 1


def test_hovering_around_half_is_not_a_blink():
    assert blinks([OPEN] * 5 + [0.45, 0.55] * 15 + [OPEN] * 5) == 0


def test_a_dip_in_the_middle_is_still_one_blink():
    assert blinks([OPEN] * 10 + [CLOSED, 0.5, 0.5, CLOSED] + [OPEN] * 5) == 1


def test_a_long_closure_is_not_a_blink():
    assert blinks([OPEN] * 10 + [CLOSED] * 45 + [OPEN] * 5) == 0


def test_a_gap_while_closed_counts_nothing():
    assert blinks([OPEN] * 10 + [CLOSED] * 2 + [None] * 30 + [OPEN] * 10) == 0


def test_eyes_already_closed_at_the_start_count_nothing():
    assert blinks([CLOSED] * 5 + [OPEN] * 10) == 0


def test_the_two_eyes_are_averaged():
    assert combine(1.0, 0.5) == 0.75


# Rule 5, on the streams of DetectionTests.swift: where the eyes were, 150 pixels apart.


def blinks_at(stream: list[tuple[float, float]]) -> int:
    answers = [closed for closed, _ in stream]
    levels = [(height, 150.0) for _, height in stream]
    return len(count_blinks([i / 30 for i in range(len(stream))], answers, levels=levels))


def test_a_nod_that_looks_like_closing_eyes_is_not_a_blink():
    down = [520, 550, 580, 600, 600, 580, 550, 520]
    assert blinks_at([(OPEN, 500)] * 10 + [(CLOSED, h) for h in down] + [(OPEN, 500)] * 5) == 0


def test_a_blink_with_the_head_still_is_counted():
    lid = [504, 509, 509, 505]
    assert blinks_at([(OPEN, 500)] * 10 + [(CLOSED, h) for h in lid] + [(OPEN, 501)] * 5) == 1


def test_the_up_down_limit_is_the_swift_one():
    def count(moving_by: float) -> int:
        return blinks_at([(OPEN, 500)] * 10 + [(CLOSED, 500 - moving_by)] * 2 + [(OPEN, 500)] * 5)

    assert (count(22), count(23), count(-23)) == (1, 0, 0)


def test_without_a_place_for_the_eyes_the_rule_does_not_apply():
    assert blinks([OPEN] * 10 + [CLOSED] * 3 + [OPEN] * 5) == 1
