#!/usr/bin/env python3
"""Repo <-> Studio parity by content hash (FNV-1a 32), using a survey_place dump.

    MCP_MAX=8000000 python3 .mcp/call.py survey_place '{"includeSource":true}' > /tmp/s.json
    python3 tools/studio-probes/bridge/parity_hash.py /tmp/s.json

survey_place withholds `source` for large scripts (`sourceWithheld`), which makes a
source-comparison report every big script as a difference. The plugin's own `hash`
field is computed for every script, so compare that instead. Pairs are declared below,
mirroring default.project.json; `Workspace.singletons.Ship` does not exist in the
place, so each hull carries its own copy and all three are checked.

`ReplicatedStorage.Gerstner.init` is deliberately absent: the Studio copy was deleted as a
debug leftover in the prompt-04 cleanup, and the repo keeps the file because Rojo needs it.

A pair whose only difference is a trailing newline is reported as MATCH-NL rather than
DIFFERS: Studio strips or adds the final newline depending on how the source was last
written, and that is not a drift worth chasing.
"""
import json, pathlib, sys

REPO = pathlib.Path("/home/user/BRINE")

PAIRS = {
    # ReplicatedStorage
    "ReplicatedStorage.Gerstner.Settings": "src/ReplicatedStorage/Gerstner/Settings/init.luau",
    "ReplicatedStorage.Gerstner.HeightLookup": "src/ReplicatedStorage/Gerstner/HeightLookup.luau",
    "ReplicatedStorage.Gerstner.Helper": "src/ReplicatedStorage/Gerstner/Helper.luau",
    "ReplicatedStorage.Gerstner.Serial.ZoneManager": "src/ReplicatedStorage/Gerstner/Serial/ZoneManager/init.luau",
    "ReplicatedStorage.FloatingObjectGeneration.WaveFloat": "src/ReplicatedStorage/FloatingObjectGeneration/WaveFloat.luau",
    "ReplicatedStorage.FloatingObjectGeneration.FloatingObjectConfig": "src/ReplicatedStorage/FloatingObjectGeneration/FloatingObjectConfig.luau",
    "ReplicatedStorage.IslandGeneration.Density": "src/ReplicatedStorage/IslandGeneration/Density.luau",
    "ReplicatedStorage.IslandGeneration.Discovery": "src/ReplicatedStorage/IslandGeneration/Discovery.luau",
    "ReplicatedStorage.IslandGeneration.Placement": "src/ReplicatedStorage/IslandGeneration/Placement.luau",
    "ReplicatedStorage.IslandGeneration.Presentation": "src/ReplicatedStorage/IslandGeneration/Presentation.luau",
    "ReplicatedStorage.IslandGeneration.Proximity": "src/ReplicatedStorage/IslandGeneration/Proximity.luau",
    "ReplicatedStorage.IslandGeneration.IslandGenerator": "src/ReplicatedStorage/IslandGeneration/IslandGenerator.luau",
    "ReplicatedStorage.FloatingObjectGeneration.FloatingObjectGenerator": "src/ReplicatedStorage/FloatingObjectGeneration/FloatingObjectGenerator.luau",
    "ReplicatedStorage.ShipHandling.ShipDrive": "src/ReplicatedStorage/ShipHandling/ShipDrive.luau",
    "ReplicatedStorage.ShipHandling.ShipGuard": "src/ReplicatedStorage/ShipHandling/ShipGuard.luau",
    "ReplicatedStorage.Swimming.SwimModel": "src/ReplicatedStorage/Swimming/SwimModel.luau",
    "ReplicatedStorage.HandHolding.HandHoldingConfig": "src/ReplicatedStorage/HandHolding/HandHoldingConfig.luau",
    "ReplicatedStorage.IslandGeneration.IslandConfig": "src/ReplicatedStorage/IslandGeneration/IslandConfig.luau",
    # ServerScriptService
    "ServerScriptService.HandHoldingServer": "src/ServerScriptService/HandHoldingServer.server.luau",
    "ServerScriptService.IslandGenerationServer": "src/ServerScriptService/IslandGenerationServer.server.luau",
    "ServerScriptService.FloatingObjectGenerationServer": "src/ServerScriptService/FloatingObjectGenerationServer.server.luau",
    # StarterPlayerScripts
    "StarterPlayer.StarterPlayerScripts.HandHoldingClient": "src/StarterPlayerScripts/HandHoldingClient.client.luau",
    "StarterPlayer.StarterPlayerScripts.FloatingObjectsClient": "src/StarterPlayerScripts/FloatingObjectsClient.client.luau",
    "StarterPlayer.StarterPlayerScripts.AmbientSea": "src/StarterPlayerScripts/AmbientSea.client.luau",
    "StarterPlayer.StarterPlayerScripts.OceanParallel": "src/StarterPlayerScripts/OceanParallel/init.client.luau",
    "StarterPlayer.StarterPlayerScripts.OceanParallel.ParallelWorker": "src/StarterPlayerScripts/OceanParallel/ParallelWorker.client.luau",
    "StarterPlayer.StarterPlayerScripts.SwimClient": "src/StarterPlayerScripts/SwimClient.client.luau",
    "StarterPlayer.StarterPlayerScripts.DiveSplash": "src/StarterPlayerScripts/DiveSplash.client.luau",
    # Workspace
    "Workspace.FloatingGui": "src/Workspace/FloatingGui.luau",
    # StarterPack (fishing)
    "StarterPack.StickFishingRod.FishingConfig": "src/Workspace/StickFishingRod/FishingConfig.luau",
    "StarterPack.StickFishingRod.FishingClient": "src/Workspace/StickFishingRod/FishingClient.client.luau",
    "StarterPack.StickFishingRod.FishingServer": "src/Workspace/StickFishingRod/FishingServer.server.luau",
    "StarterPack.StickFishingRod.FishPose": "src/Workspace/StickFishingRod/FishPose.luau",
    # Each hull carries its own copy of the ship scripts
    "Workspace.WoodenShip.Handler": "src/Workspace/singletons/Ship/Handler.server.luau",
    "Workspace.WoodenShip.Client": "src/Workspace/singletons/Ship/Client.client.luau",
    "Workspace.MisoSoup.Handler": "src/Workspace/singletons/Ship/Handler.server.luau",
    "Workspace.MisoSoup.Client": "src/Workspace/singletons/Ship/Client.client.luau",
    "Workspace.Boathouse.Handler": "src/Workspace/singletons/Ship/Handler.server.luau",
    "Workspace.Boathouse.Client": "src/Workspace/singletons/Ship/Client.client.luau",
}


def fnv(data: bytes) -> str:
    h = 2166136261
    for b in data:
        h = ((h ^ b) * 16777619) & 0xFFFFFFFF
    return f"{h:08x}"


def main():
    survey = json.load(open(sys.argv[1]))
    index = {s["path"]: s for s in survey["scripts"]}
    match = differ = missing = 0
    for path, rel in sorted(PAIRS.items()):
        entry = index.get(path)
        local = REPO / rel
        if entry is None:
            print(f"MISSING  {path:<62} (not in the place)")
            missing += 1
            continue
        if not local.exists():
            print(f"MISSING  {path:<62} (no repo file {rel})")
            missing += 1
            continue
        data = local.read_bytes()
        want = fnv(data)
        got = entry.get("hash")
        if want == got:
            match += 1
            print(f"{'match   '}{path:<62} {got}  ({rel})")
        elif fnv(data.rstrip(b"\n")) == got or fnv(data + b"\n") == got:
            match += 1
            print(f"{'MATCH-NL'}{path:<62} {got}  ({rel})  (trailing newline only)")
        else:
            differ += 1
            print(f"{'DIFFERS '}{path:<62} {got} / {want}  ({rel})")
    print(f"\npairs={len(PAIRS)} match={match} differs={differ} missing={missing}")


if __name__ == "__main__":
    main()
