"""State model for the flyout verification harness (Phase 7.2.0).

Every state here is one the real daemon can actually emit: the property
sets are derived from `AmpState::recompute()` in
crates/devialet-remote-daemon/src/interface.rs (the Some/None branches),
not invented. Dimensions follow the investigation document's §5 cross
product; the amp dimension folds "short name / long fallback UDP name /
none selected / 0 known / 1 known auto-selected / 2+ known" into the
seven distinct, reachable combinations listed in AMP_VALUES.

Not-connected amp values collapse vol/mute/pow/src to the daemon's
None-branch values, so those dimensions are recorded as "-" (wildcard)
for such states and carry no inner product.
"""

import itertools

DIMS = ["amp", "vol", "mute", "pow", "src", "list", "slist"]

AMP_VALUES = ["0known", "1auto-short", "1auto-long", "1none", "2none", "2sel-short", "2sel-long"]
VOL_VALUES = ["-40.0", "-15.0", "0.0"]
MUTE_VALUES = ["off", "on"]
POW_VALUES = ["Off", "Booting", "On"]
SRC_VALUES = ["short", "long", "none"]
LIST_VALUES = ["closed", "open"]
# Phase 7.14.0: the source list overlay (SourceListOverlay.qml), driven
# through FlyoutContent.sourceListOpen exactly like `list` drives
# ampListOpen.
SLIST_VALUES = ["closed", "open"]

VALUES = {
    "amp": AMP_VALUES,
    "vol": VOL_VALUES,
    "mute": MUTE_VALUES,
    "pow": POW_VALUES,
    "src": SRC_VALUES,
    "list": LIST_VALUES,
    "slist": SLIST_VALUES,
}

BASE = {"amp": "1auto-short", "vol": "-40.0", "mute": "off", "pow": "On", "src": "short", "list": "closed", "slist": "closed"}

WILD = "-"

# ---- amp fixtures ---------------------------------------------------------
# A = the real amp as the live daemon reports it (busctl, 2026-09-02):
#     model name resolved via mDNS, so DeviceName is the model name.
# B = a second amp whose mDNS resolution never happened (model_name ""),
#     so DeviceName falls back to its raw UDP name - which is the
#     protocol's maximum 31 bytes (status.rs: data[19..19+31]).
AMP_A = ("192.168.0.22", "My Devialet-ETH", True, "Devialet Expert 140 Pro")
AMP_B_UDP_NAME = "Devialet-Expert-Living-Room-ETH"  # 31 chars
assert len(AMP_B_UDP_NAME) == 31
AMP_B = ("192.168.0.23", AMP_B_UDP_NAME, True, "")

# (known_amps, selected_ip, effective_ip) per amp value - `effective` is
# what recompute()'s effective_ip() would return: explicit selection, else
# the sole known amp when nothing was ever explicitly selected, else "".
AMP_SCENARIOS = {
    "0known": ([], "", ""),
    "1auto-short": ([AMP_A], "", AMP_A[0]),
    "1auto-long": ([AMP_B], "", AMP_B[0]),
    "1none": ([AMP_A], "", ""),          # explicit SelectAmp("") with one known amp
    "2none": ([AMP_A, AMP_B], "", ""),   # two known, nothing selected -> not connected
    "2sel-short": ([AMP_A, AMP_B], AMP_A[0], AMP_A[0]),
    "2sel-long": ([AMP_A, AMP_B], AMP_B[0], AMP_B[0]),
}

# ---- source table ---------------------------------------------------------
# The real amp's 30-slot table (busctl get-property Sources, 2026-09-02),
# with two deliberate edits for the harness: slot 14 ("Air" on the real
# amp) carries a 16-character name - the protocol's maximum slot-name
# length (status.rs: base+1..base+1+16) - for the `src=long` value, and
# slot 29 is blanked so `src=none` yields ActiveSourceName "" while
# connected (recompute(): current_source_name().unwrap_or("")).
SRC_LONG_NAME = "Chromecast Audio"  # 16 chars
assert len(SRC_LONG_NAME) == 16
SOURCE_TABLE = (
    [("Optical 1", 0, True), ("UPnP", 1, True), ("Roon Ready", 2, True), ("AirPlay", 3, True), ("Spotify", 4, True)]
    + [("Unknown", i, False) for i in range(5, 14)]
    + [(SRC_LONG_NAME, 14, True)]
    + [("Unknown", i, False) for i in range(15, 29)]
    + [("", 29, False)]
)
assert len(SOURCE_TABLE) == 30
SRC_INDEX = {"short": 0, "long": 14, "none": 29}

NOT_CONNECTED = {
    "DeviceName": "",
    "Online": False,
    "Power": False,
    "PowerState": "Off",
    "Muted": False,
    "VolumeRaw": 0,
    "VolumeDb": 0.0,
    "ActiveSourceIndex": 0,
    "ActiveSourceName": "",
    "Sources": [],
}


def is_connected(amp_value):
    return AMP_SCENARIOS[amp_value][2] != ""


def normalize(dims):
    """Collapse the inner dimensions to WILD for not-connected amp values."""
    d = dict(dims)
    if not is_connected(d["amp"]):
        # `slist` collapses too: the source row is disabled while not
        # connected (no amp / no enabled sources), so an open source list
        # is unreachable there - unlike the amp list, which is exactly
        # what you open in those states.
        for k in ("vol", "mute", "pow", "src", "slist"):
            d[k] = WILD
    return d


def state_id(dims):
    return "_".join(f"{k}={dims[k]}" for k in DIMS)


def build_props(dims):
    """Amp1 property values for a (normalized) dims dict."""
    known, selected, effective = AMP_SCENARIOS[dims["amp"]]
    props = {"KnownAmps": list(known), "SelectedAmpIp": selected, "AmpIp": effective}
    if effective == "":
        props.update(NOT_CONNECTED)
        return props
    entry = next(k for k in known if k[0] == effective)
    props["DeviceName"] = entry[3] if entry[3] else entry[1]
    props["Online"] = True
    props["Power"] = dims["pow"] == "On"
    props["PowerState"] = dims["pow"]
    props["Muted"] = dims["mute"] == "on"
    db = float(dims["vol"])
    props["VolumeDb"] = db
    props["VolumeRaw"] = int(round(195 + 2 * db))  # Status::volume_db() inverted
    idx = SRC_INDEX[dims["src"]]
    props["ActiveSourceIndex"] = idx
    props["Sources"] = [(name, i, enabled, i == idx) for (name, i, enabled) in SOURCE_TABLE]
    props["ActiveSourceName"] = SOURCE_TABLE[idx][0]
    return props


def build_ui(dims):
    return {
        "ampListOpen": "true" if dims["list"] == "open" else "false",
        "sourceListOpen": "true" if dims["slist"] == "open" else "false",
    }


def make_state(dims):
    d = normalize(dims)
    return {"id": state_id(d), "dims": d, "props": build_props(d), "ui": build_ui(d)}


def _dedupe(states):
    seen, out = set(), []
    for s in states:
        if s["id"] not in seen:
            seen.add(s["id"])
            out.append(s)
    return out


def vary(dim_names):
    """Product over the named dims, every other dim held at BASE."""
    for name in dim_names:
        if name not in DIMS:
            raise ValueError(f"unknown dimension {name!r}; known: {DIMS}")
    out = []
    for combo in itertools.product(*(VALUES[n] for n in dim_names)):
        d = dict(BASE)
        d.update(dict(zip(dim_names, combo)))
        out.append(make_state(d))
    return _dedupe(out)


def full():
    return vary(DIMS)


def smoke():
    base = make_state(BASE)
    variants = [
        dict(BASE, list="open"),
        dict(BASE, slist="open"),
        dict(BASE, vol="0.0"),
        dict(BASE, mute="on"),
        dict(BASE, pow="Booting"),
        dict(BASE, src="long"),
        dict(BASE, amp="0known"),
    ]
    return _dedupe([base] + [make_state(v) for v in variants])


SETS = {
    "smoke": smoke,
    "amp": lambda: vary(["amp", "list"]),
    "volume-mute": lambda: vary(["vol", "mute"]),
    "power": lambda: vary(["pow", "mute"]),
    "source": lambda: vary(["src", "slist"]),
    "full": full,
}


def select(set_name=None, vary_dims=None, fixes=None):
    """Resolve CLI selection into an ordered list of states."""
    if set_name and vary_dims:
        raise ValueError("use either --set or --vary, not both")
    if vary_dims:
        states = vary(vary_dims)
    else:
        states = SETS[set_name or "smoke"]()
    for k, v in (fixes or {}).items():
        if k not in DIMS:
            raise ValueError(f"unknown dimension {k!r} in --fix; known: {DIMS}")
        states = [s for s in states if s["dims"][k] == v]
    return states


def adjacent_pairs(states):
    """Pairs of states differing in exactly one dimension.

    A WILD side is compatible with the other side only when that side holds
    the BASE value for that dimension, so a not-connected state pairs with
    the base connected state (differing in `amp` only) rather than with
    all 108 connected variants.
    """
    pairs = []
    for i in range(len(states)):
        for j in range(i + 1, len(states)):
            a, b = states[i]["dims"], states[j]["dims"]
            differing = []
            ok = True
            for k in DIMS:
                av, bv = a[k], b[k]
                if av == bv:
                    continue
                if av == WILD or bv == WILD:
                    other = bv if av == WILD else av
                    if other != BASE[k]:
                        ok = False
                        break
                    continue
                differing.append(k)
            if ok and len(differing) == 1:
                pairs.append((states[i]["id"], states[j]["id"], differing[0]))
    return pairs
