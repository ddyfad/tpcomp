# tpcomp

Lag compensation for shavit checkpoint teleports (`sm_tele`) in CS:S. No changes to shavit needed.

## The problem

When a checkpoint loads, shavit teleports you with the saved angles. The server sends those angles to your client as an absolute view snap. Two things go wrong while that message is on its way:

- The commands you already sent still have your old yaw. The server moves you with them, so for a full round trip you strafe in the wrong direction relative to your new velocity.
- When the snap arrives, your view is set straight to the checkpoint angle, and any mouse movement from that round trip is thrown away.

## What this does

Until the client has the new angles, the server adds the teleport's angle difference to every incoming command's yaw, so commands still carrying the old yaw move you in the right direction relative to your new velocity. The first command made after the client applies the new angles shows a yaw jump of about that size, and that jump is how the plugin knows to stop shifting.

Keeping mouse movement needs the engine's relative snap (`FIXANGLE_RELATIVE`), because the client adds that to wherever it's looking instead of replacing the view. It only carries yaw: `CL_ApplyAddAngle` ignores the pitch component. So shavit's absolute snap is left in place, which lands the checkpoint pitch and yaw exactly the way a normal teleport does, and the plugin measures how far the player turned while that snap was in flight and hands it back as a relative change once the snap lands. The view ends up on the checkpoint angles plus everything the player did with the mouse in the meantime, same as the old yaw-only version, with pitch as well.

What this costs is that the view sits on the checkpoint yaw for about one round trip before it catches up, instead of never jumping at all. Server-side the shifting is unchanged, so movement is correct the whole way through. `sm_tpcomp_pitch 0` goes back to the old behaviour: no jump, and pitch left wherever the player was looking.

## Results

These came from alternating compensated and default loads on a 100 tick server. They're medians over teleports where the player strafed out of the checkpoint. Misalignment means the angle between view yaw and velocity direction in the air.

| latency | mode | max misalignment | largest yaw jump |
|---|---|---|---|
| ~57ms | tpcomp | 3.2° | 0.3° |
| ~57ms | default | 40.0° | 38.3° |
| ~162ms | tpcomp | 2.0° | 0.4° |
| ~162ms | default | 71.7° | 87.4° |

These were measured with the yaw-only behaviour, now `sm_tpcomp_pitch 0`. Misalignment is the same with pitch restore on, since the server-side shifting doesn't change. The yaw jump column doesn't hold: the view lands on the checkpoint yaw first and catches up a round trip later, so it sits between the two rows.

## Cvars

- `sm_tpcomp_enabled` (1): turn compensation on or off.
- `sm_tpcomp_pitch` (1): restore the checkpoint pitch. Off keeps the old yaw-only behaviour.
- `sm_tpcomp_window` (2): how many ticks past the teleport tick to wait for the yaw jump before assuming the client has the new angle.

## Requirements

- shavit-checkpoints with the `Shavit_OnCheckpointCacheLoaded` forward.
- A 32-bit CS:S server. `fixangle` and `anglechange` aren't in the datamap, so they're read at fixed offsets from `pl.deadflag`, and those offsets change on 64-bit builds.
