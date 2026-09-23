#include <sourcemod>
#include <sdktools>
#include <shavit/core>
#include <shavit/checkpoints>

#pragma semicolon 1
#pragma newdecls required

// CPlayerState offsets from pl.deadflag, 32-bit only
#define V_ANGLE_OFFSET 4
#define FIXANGLE_OFFSET 20
#define ANGLECHANGE_OFFSET 24

#define FIXANGLE_ABSOLUTE 1
#define FIXANGLE_RELATIVE 2

#define MAX_PENDING 16

public Plugin myinfo =
{
	name = "tpcomp",
	author = "daf",
	description = "Keeps checkpoint teleport angles in sync with commands already in flight",
	version = "1.0",
	url = "https://github.com/ddyfad/tpcomp"
};

ConVar gCV_Enabled;
ConVar gCV_Window;

int gI_PlayerState;

float gF_LastYaw[MAXPLAYERS+1];
float gF_LastDelta[MAXPLAYERS+1];

// Yaw changes the client hasn't applied yet, oldest first
float gF_Pending[MAXPLAYERS+1][MAX_PENDING];
int gI_PendingTick[MAXPLAYERS+1][MAX_PENDING];
int gI_PendingCount[MAXPLAYERS+1];

public void OnPluginStart()
{
	gCV_Enabled = CreateConVar("sm_tpcomp_enabled", "1", "Compensate checkpoint teleport angles for latency.", 0, true, 0.0, true, 1.0);
	gCV_Window = CreateConVar("sm_tpcomp_window", "2", "How many ticks past the teleport tick a command's tickcount can be before the client is assumed to have the new angle.", 0, true, 0.0, true, 64.0);

	gI_PlayerState = FindSendPropInfo("CBasePlayer", "deadflag");

	if (gI_PlayerState <= 0)
	{
		SetFailState("Couldn't find CBasePlayer::pl.deadflag");
	}
}

public void OnClientPutInServer(int client)
{
	gI_PendingCount[client] = 0;
}

public void Shavit_OnCheckpointCacheLoaded(int client, cp_cache_t cache, int index)
{
	if (!gCV_Enabled.BoolValue || IsFakeClient(client))
	{
		return;
	}

	// Only an absolute snap throws away mouse movement
	if (GetEntData(client, gI_PlayerState + FIXANGLE_OFFSET) != FIXANGLE_ABSOLUTE)
	{
		return;
	}

	float target[3], change[3];
	GetEntDataVector(client, gI_PlayerState + V_ANGLE_OFFSET, target);
	GetEntDataVector(client, gI_PlayerState + ANGLECHANGE_OFFSET, change);

	float d = NormalizeYaw(target[1] - (gF_LastYaw[client] + PendingShift(client)));
	int n = gI_PendingCount[client];

	// Non-zero anglechange hasn't been sent yet, so merge into it
	if (change[1] != 0.0 && n > 0)
	{
		gF_Pending[client][n - 1] += d;
	}
	else if (d != 0.0)
	{
		if (n == MAX_PENDING)
		{
			PopPending(client);
			n--;
		}

		gF_Pending[client][n] = d;
		gI_PendingTick[client][n] = GetGameTickCount();
		gI_PendingCount[client]++;
	}

	change[0] = 0.0;
	change[1] += d;
	change[2] = 0.0;

	SetEntData(client, gI_PlayerState + FIXANGLE_OFFSET, FIXANGLE_RELATIVE);
	SetEntDataVector(client, gI_PlayerState + ANGLECHANGE_OFFSET, change);
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	if (IsFakeClient(client))
	{
		return Plugin_Continue;
	}

	float delta = NormalizeYaw(angles[1] - gF_LastYaw[client]);
	float jump = delta - gF_LastDelta[client];

	gF_LastYaw[client] = angles[1];
	gF_LastDelta[client] = delta;

	if (gI_PendingCount[client] > 0)
	{
		float d = gF_Pending[client][0];
		int tick = gI_PendingTick[client][0];

		// First command after the client applies d jumps by about d
		if (tickcount >= tick && (FloatAbs(jump - d) < FloatAbs(jump) || tickcount > tick + gCV_Window.IntValue))
		{
			gF_LastDelta[client] = delta - d;
			PopPending(client);
		}
	}

	float shift = PendingShift(client);

	if (shift == 0.0)
	{
		return Plugin_Continue;
	}

	angles[1] = NormalizeYaw(angles[1] + shift);

	return Plugin_Changed;
}

float PendingShift(int client)
{
	float shift = 0.0;

	for (int i = 0; i < gI_PendingCount[client]; i++)
	{
		shift += gF_Pending[client][i];
	}

	return shift;
}

void PopPending(int client)
{
	gI_PendingCount[client]--;

	for (int i = 0; i < gI_PendingCount[client]; i++)
	{
		gF_Pending[client][i] = gF_Pending[client][i + 1];
		gI_PendingTick[client][i] = gI_PendingTick[client][i + 1];
	}
}

float NormalizeYaw(float yaw)
{
	while (yaw > 180.0)
	{
		yaw -= 360.0;
	}

	while (yaw < -180.0)
	{
		yaw += 360.0;
	}

	return yaw;
}
