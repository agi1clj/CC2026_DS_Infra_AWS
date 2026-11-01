"""Unit tests for energy_etl.py (run: pytest terraform/modules/data-pipeline/glue)."""
import pandas as pd
import pytest

import energy_etl as etl

GOOD = {
    "device_id": "device-001",
    "timestamp": "2025-11-01T00:00:00Z",
    "temperature": "20.5",
    "humidity": "55",
    "kwh": "0.05",
    "location": "Office-A",
}


def frame(*overrides):
    """Raw (all-string) DataFrame; each override changes the good row."""
    return pd.DataFrame([{**GOOD, **o} for o in overrides], dtype=str)


def reasons(raw):
    return list(etl.clean(raw)[1]["reject_reason"])


def test_good_row_goes_to_silver_with_date_column():
    silver, rejected, duplicates = etl.clean(frame({}))
    assert len(silver) == 1 and rejected.empty and duplicates == 0
    assert silver.loc[0, "date"] == "2025-11-01"
    assert silver["kwh"].dtype == "float64"
    assert pd.api.types.is_datetime64_any_dtype(silver["timestamp"])


@pytest.mark.parametrize(
    "bad_values, reason",
    [
        ({"kwh": ""}, "empty_kwh"),
        ({"kwh": "-0.1"}, "negative_kwh"),
        ({"humidity": "100.5"}, "humidity_out_of_range"),
        ({"humidity": "-1"}, "humidity_out_of_range"),
        ({"temperature": "-999"}, "temperature_out_of_range"),
        ({"temperature": "61"}, "temperature_out_of_range"),
        ({"timestamp": "not a date"}, "invalid_timestamp_or_device"),
    ],
)
def test_validity_rules_reject_with_reason(bad_values, reason):
    silver, rejected, _ = etl.clean(frame({}, {"timestamp": "2025-11-01T00:05:00Z", **bad_values}))
    assert len(silver) == 1
    assert list(rejected["reject_reason"]) == [reason]
    assert rejected.iloc[0]["device_id"] == "device-001"  # the raw row is kept


def test_boundary_values_are_valid():
    raw = frame(
        {"humidity": "0"},
        {"timestamp": "2025-11-01T00:05:00Z", "humidity": "100"},
        {"timestamp": "2025-11-01T00:10:00Z", "temperature": "-40"},
        {"timestamp": "2025-11-01T00:15:00Z", "temperature": "60", "kwh": "0"},
    )
    silver, rejected, _ = etl.clean(raw)
    assert len(silver) == 4 and rejected.empty


def test_duplicates_keep_the_first_and_are_counted_not_rejected():
    raw = frame({"kwh": "0.05"}, {"kwh": "0.99"})  # same device and timestamp
    silver, rejected, duplicates = etl.clean(raw)
    assert len(silver) == 1 and silver.loc[0, "kwh"] == 0.05
    assert rejected.empty and duplicates == 1


def test_missing_column_raises():
    with pytest.raises(ValueError, match="Missing required columns: kwh"):
        etl.clean(frame({}).drop(columns=["kwh"]))


def test_reject_ratio_check():
    etl.check_reject_ratio(100, 10, 0.10)  # exactly at the limit is fine
    with pytest.raises(ValueError, match="Too many rejected rows"):
        etl.check_reject_ratio(100, 11, 0.10)
    etl.check_reject_ratio(0, 0, 0.10)  # an empty file is reported by check_valid_rows


def test_gold_daily_by_device_shape():
    silver, _, _ = etl.clean(frame({}, {"timestamp": "2025-11-01T00:05:00Z", "kwh": "0.07"}))
    (record,) = etl.gold_daily_by_device(silver)
    assert record == {
        "device_id": "device-001",
        "location": "Office-A",
        "date": "2025-11-01",
        "total_kwh": 0.12,
        "avg_temperature": 20.5,
        "avg_humidity": 55.0,
        "readings": 2,
    }


def test_half_empty_kwh_trips_the_reject_ratio():
    rows = [
        {"timestamp": f"2025-11-01T00:{minute:02d}:00Z", "kwh": "" if minute % 2 else "0.05"}
        for minute in range(10)
    ]
    raw = frame(*rows)
    _, rejected, _ = etl.clean(raw)
    with pytest.raises(ValueError, match="Too many rejected rows"):
        etl.check_reject_ratio(len(raw), len(rejected), 0.10)


@pytest.mark.parametrize("rows", [[], [{"kwh": ""}, {"timestamp": "2025-11-01T00:05:00Z", "humidity": "150"}]])
def test_no_valid_rows_raises(rows):
    raw = frame(*rows) if rows else pd.DataFrame(columns=etl.REQUIRED_COLUMNS, dtype=str)
    silver, _, _ = etl.clean(raw)
    with pytest.raises(ValueError, match="No valid rows: nothing to publish"):
        etl.check_valid_rows(silver)


def test_gold_by_location_shape():
    raw = frame(
        {"kwh": "0.10"},
        {"timestamp": "2025-11-01T00:05:00Z", "kwh": "0.20"},
        {"timestamp": "2025-11-02T00:00:00Z", "kwh": "0.30"},
        {"device_id": "device-002", "location": "Lab", "kwh": "1"},
    )
    silver, _, _ = etl.clean(raw)
    assert etl.gold_by_location(silver) == [
        {"location": "Lab", "total_kwh": 1.0, "devices": 1, "avg_kwh_per_day": 1.0},
        {"location": "Office-A", "total_kwh": 0.6, "devices": 1, "avg_kwh_per_day": 0.3},
    ]
