"""
Station configuration (callsign, QTH, APRS, helper services).

Personal values live in config.json next to this file (not committed to git).
Copy config.example.json to config.json and edit it. Another location can be
given with the IC7000_CONFIG environment variable.
"""
import json, os

_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.environ.get("IC7000_CONFIG", os.path.join(_DIR, "config.json"))

DEFAULTS = {
    "callsign":         "N0CALL",        # your callsign (APRS TX is blocked while N0CALL)
    "locator":          "AA00aa",        # Maidenhead locator, shown in the UI
    "lat":              0.0,             # QTH latitude  (decimal degrees, N = +)
    "lon":              0.0,             # QTH longitude (decimal degrees, E = +)
    "aprs_symbol_table": "/",
    "aprs_symbol":      "-",             # "-" = house
    "aprs_path":        ["WIDE1-1", "WIDE2-1"],
    "aprs_tocall":      "APZIC7",
    "kiss_host":        "127.0.0.1",
    "kiss_port":        8001,
    "fldigi_url":       "http://127.0.0.1:7362",
    "direwolf_conf":    "~/direwolf.conf",
    "direwolf_log":     "~/direwolf.log",
}

PLACEHOLDER_CALLS = ("N0CALL", "NOCALL", "")


def load(path=CONFIG_PATH):
    cfg = dict(DEFAULTS)
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
        if isinstance(data, dict):
            for k, v in data.items():
                if k in DEFAULTS:
                    cfg[k] = v
                elif not k.startswith("_"):
                    print(f"config: unknown key '{k}' ignored")
    except FileNotFoundError:
        print(f"config: {path} not found - using defaults "
              f"(copy config.example.json to config.json)")
    except Exception as e:
        print(f"config: cannot read {path}: {e} - using defaults")
    cfg["callsign"] = str(cfg["callsign"]).strip().upper()
    cfg["lat"] = float(cfg["lat"])
    cfg["lon"] = float(cfg["lon"])
    cfg["kiss_port"] = int(cfg["kiss_port"])
    cfg["aprs_path"] = [str(p).upper() for p in (cfg["aprs_path"] or [])]
    return cfg


CONFIG = load()
