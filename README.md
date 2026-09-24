# tpcomp

Lag compensation for CS:S teleports that set a player's view angles: checkpoint loads, map `trigger_teleport`s, anything calling `TeleportEntity` with angles.

Until the client gets the new angles, the commands it has already sent still aim the old way. tpcomp shifts their yaw by the teleport's angle change, so the player moves the way they would have with the new view. It only changes command angles, never position, velocity or the timer.

Needs a 32-bit CS:S server and DHooks.

## Cvars

- `sm_tpcomp_enabled` (1): turn it on or off.
- `sm_tpcomp_pitch` (1): restore the teleport's pitch. The view lands on the teleport angles, and the mouse movement from the round trip is added back when it arrives. 0 compensates yaw only, so the view never jumps.
- `sm_tpcomp_window` (2): ticks past the teleport to wait for the client's new angle.

## lagfix branch

For servers running tpredict or players using the lagfix. Adds `TPComp_Suspend(client, bool)`, which tpredict uses around teleports the client already predicted, and `TPComp_SetClientPredicts(client, bool)`, which leaves `trigger_teleport`s alone for clients whose game predicts them.
