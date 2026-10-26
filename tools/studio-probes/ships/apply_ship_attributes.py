#!/usr/bin/env python3
"""Re-apply BRINE's per-hull ship attributes to the open Studio place.

These are ATTRIBUTES on the ship models, not script source, so they cannot live in
src/ (Rojo does not carry attributes for hand-made models). This script is the source
of truth for them: run it after a fresh clone, or after changing a value in Studio.

    python3 tools/studio-probes/ships/apply_ship_attributes.py [--check]

--check reads the place back and prints what differs instead of writing.
Values are the ones measured and documented in docs/audit/07-ships.md.
"""
import json, subprocess, sys

SHIPS = {
    # Steering rule: steady turn radius at top speed ~ 1.3 hull lengths, the ratio the
    # reference ServerBoat already has (58.2 studs of radius on a 45-stud Main).
    # Top speed from the model's own drag balance: EngineAccel = 0.08 v + 0.0067 v^2.
    "WoodenShip": {  # Main 12.7x3.4x88.0, mass 2663 -> 26.0 studs/s, 113-stud radius
        "Draft": 5.5, "SinkRestOffset": -2.0,
        "EngineAccel": 6.6, "ReverseAccel": 1.7, "BrakeAccel": 7.0,
        "LateralDamping": 1.4, "ThrottleSpool": 1.2,
        "MaxTurnRate": 0.23, "TurnReferenceSpeed": 8.0,
    },
    "MisoSoup": {  # Main 20.4x2.0x125.4, mass 19565 -> 18.0 studs/s, 163-stud radius
        "Draft": -7.3, "SinkRestOffset": 2.4,
        "EngineAccel": 3.6, "ReverseAccel": 0.9, "BrakeAccel": 6.0,
        "LateralDamping": 2.0, "ThrottleSpool": 0.8,
        "MaxTurnRate": 0.11, "TurnReferenceSpeed": 10.0,
    },
    "Boathouse": {  # Main 13.0x3.4x45.0, mass 2757 -> 13.9 studs/s, 58-stud radius
        "Draft": 3.5,
        "EngineAccel": 2.4, "ReverseAccel": 0.7, "BrakeAccel": 5.0,
        "LateralDamping": 1.2, "ThrottleSpool": 1.0,
        "MaxTurnRate": 0.24, "TurnReferenceSpeed": 6.0,
    },
    # ServerBoat is the physics reference: no attributes, and its own legacy Handler
    # drives it. Do not add any.
}


def run_luau(code, dm="edit", timeout=45):
    args = json.dumps({"dm": dm, "timeout": timeout, "code": code})
    out = subprocess.run(["python3", "/home/user/.mcp/call.py", "probe", args],
                         capture_output=True, text=True, cwd="/home/user").stdout
    try:
        payload = json.loads(out)["result"]["content"][0]["text"]
        decoded = json.loads(payload).get("decoded", {})
        return decoded.get("result") or decoded.get("returned") or payload
    except Exception:
        return "RAW: " + out[:800]


def lua_table(attrs):
    parts = [f"{k} = {repr(v)}" for k, v in attrs.items()]
    return "{" + ", ".join(parts) + "}"


def main():
    check = "--check" in sys.argv
    if check:
        rows = []
        for name, attrs in SHIPS.items():
            fmt = ", ".join(f"{k}=%s" for k in attrs)
            args = ", ".join(f'm:GetAttribute("{k}")' for k in attrs)
            code = (
                f'local m = workspace:FindFirstChild("{name}")\n'
                f'if not m then return "{name} MISSING" end\n'
                f'return string.format("{name} {fmt}", {args})'
            )
            rows.append(run_luau(code))
        print("\n".join(str(r) for r in rows))
        print("\nexpected:")
        for name, attrs in SHIPS.items():
            print("  " + name + " " + " ".join(f"{k}={v}" for k, v in attrs.items()))
        return
    for name, attrs in SHIPS.items():
        code = (f'local m = workspace:FindFirstChild("{name}")\n'
                f'if not m then return "{name} MISSING" end\n'
                f'local attrs = {lua_table(attrs)}\n'
                f'local n = 0\n'
                f'for k, v in pairs(attrs) do m:SetAttribute(k, v); n += 1 end\n'
                f'return "{name}: set " .. n .. " attributes"')
        print(run_luau(code))


if __name__ == "__main__":
    main()
