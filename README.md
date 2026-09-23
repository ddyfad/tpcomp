# tpcomp

Lag compensation for shavit checkpoint teleports (`sm_tele`) in CS:S. No changes to shavit needed.

## The problem

When a checkpoint loads, shavit teleports you with the saved angles. The server sends those angles to your client as an absolute view snap. Two things go wrong while that message is on its way:

- The commands you already sent still have your old yaw. The server moves you with them, so for a full round trip you strafe in the wrong direction relative to your new velocity.
- When the snap arrives, your view is set straight to the checkpoint angle, and any mouse movement from that round trip is thrown away.

## What this does

After shavit's teleport, the plugin changes the pending absolute snap into the engine's relative mode (`FIXANGLE_RELATIVE`). The client then adds the yaw difference to wherever it's looking, so mouse movement is kept. Until the client has applied that difference, the server adds the same difference to every incoming command's yaw. The first command made after the client applies it shows a yaw jump of that size, and that jump is how the plugin knows to stop shifting.

Pitch from the checkpoint isn't restored, because the relative snap only carries yaw. Movement ignores pitch anyway.

## Results

These came from alternating compensated and default loads on a 100 tick server. They're medians over teleports where the player strafed out of the checkpoint. Misalignment means the angle between view yaw and velocity direction in the air.

| latency | mode | max misalignment | largest yaw jump |
|---|---|---|---|
| ~57ms | tpcomp | 3.2° | 0.3° |
| ~57ms | default | 40.0° | 38.3° |
| ~162ms | tpcomp | 2.0° | 0.4° |
| ~162ms | default | 71.7° | 87.4° |

## Cvars

- `sm_tpcomp_enabled` (1): turn compensation on or off.
- `sm_tpcomp_window` (2): how many ticks past the teleport tick to wait for the yaw jump before assuming the client has the new angle.

## Requirements

- shavit-checkpoints with the `Shavit_OnCheckpointCacheLoaded` forward.
- A 32-bit CS:S server. `fixangle` and `anglechange` aren't in the datamap, so they're read at fixed offsets from `pl.deadflag`, and those offsets change on 64-bit builds.
