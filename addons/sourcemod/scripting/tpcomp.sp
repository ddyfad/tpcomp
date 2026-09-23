#include <sourcemod>
#include <sdktools>
#include <clientprefs>
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

// Pitch and yaw
float gF_LastAngles[MAXPLAYERS+1][2];
float gF_LastDelta[MAXPLAYERS+1][2];

// Angle changes the client hasn't applied yet, oldest first
float gF_Pending[MAXPLAYERS+1][MAX_PENDING][2];
int gI_PendingTick[MAXPLAYERS+1][MAX_PENDING];
int gI_PendingCount[MAXPLAYERS+1];

// Another plugin is handling the angles of this client's next loads itself.
bool gB_Suspended[MAXPLAYERS+1];

// better-seg's !seg_freeze setting. Frozen players already get their angles fixed by the freeze.
Cookie gC_SegFreeze;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	CreateNative("TPComp_Suspend", Native_Suspend);
	RegPluginLibrary("tpcomp");
	return APLRes_Success;
}

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
	gB_Suspended[client] = false;
}

public void OnAllPluginsLoaded()
{
	gC_SegFreeze = Cookie.Find("betterseg_freeze");
}

public any Native_Suspend(Handle plugin, int numParams)
{
	gB_Suspended[GetNativeCell(1)] = GetNativeCell(2);
	return 0;
}

// Same conditions better-seg freezes under: setting on (the default) and the run timer started
bool SegFreezing(int client)
{
	if (gC_SegFreeze == null)
	{
		return false;
	}

	if (AreClientCookiesCached(client))
	{
		char buf[8];
		gC_SegFreeze.Get(client, buf, sizeof(buf));

		if (buf[0] != '\0' && StringToInt(buf) == 0)
		{
			return false;
		}
	}

	return Shavit_GetTimerStatus(client) != Timer_Stopped && Shavit_GetClientTime(client) > 5.0 * GetTickInterval();
}

public void Shavit_OnCheckpointCacheLoaded(int client, cp_cache_t cache, int index)
{
	if (!gCV_Enabled.BoolValue || gB_Suspended[client] || IsFakeClient(client) || SegFreezing(client))
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

	float shift[2], d[2];
	PendingShift(client, shift);

	for (int i = 0; i < 2; i++)
	{
		d[i] = NormalizeAngle(target[i] - (gF_LastAngles[client][i] + shift[i]));
	}

	int n = gI_PendingCount[client];

	// Non-zero anglechange hasn't been sent yet, so merge into it
	if ((change[0] != 0.0 || change[1] != 0.0) && n > 0)
	{
		gF_Pending[client][n - 1][0] += d[0];
		gF_Pending[client][n - 1][1] += d[1];
	}
	else if (d[0] != 0.0 || d[1] != 0.0)
	{
		if (n == MAX_PENDING)
		{
			PopPending(client);
			n--;
		}

		gF_Pending[client][n][0] = d[0];
		gF_Pending[client][n][1] = d[1];
		gI_PendingTick[client][n] = GetGameTickCount();
		gI_PendingCount[client]++;
	}

	change[0] += d[0];
	change[1] += d[1];
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

	float delta[2], jump[2];

	for (int i = 0; i < 2; i++)
	{
		delta[i] = NormalizeAngle(angles[i] - gF_LastAngles[client][i]);
		jump[i] = delta[i] - gF_LastDelta[client][i];

		gF_LastAngles[client][i] = angles[i];
		gF_LastDelta[client][i] = delta[i];
	}

	if (gI_PendingCount[client] > 0)
	{
		float dp = gF_Pending[client][0][0];
		float dy = gF_Pending[client][0][1];
		int tick = gI_PendingTick[client][0];

		// First command after the client applies d jumps by about d
		float miss = FloatAbs(jump[0] - dp) + FloatAbs(jump[1] - dy);

		if (tickcount >= tick && (miss < FloatAbs(jump[0]) + FloatAbs(jump[1]) || tickcount > tick + gCV_Window.IntValue))
		{
			gF_LastDelta[client][0] = delta[0] - dp;
			gF_LastDelta[client][1] = delta[1] - dy;
			PopPending(client);
		}
	}

	float shift[2];
	PendingShift(client, shift);

	if (shift[0] == 0.0 && shift[1] == 0.0)
	{
		return Plugin_Continue;
	}

	// The client clamps pitch the same way when it applies the change
	angles[0] = ClampPitch(angles[0] + shift[0]);
	angles[1] = NormalizeAngle(angles[1] + shift[1]);

	return Plugin_Changed;
}

void PendingShift(int client, float shift[2])
{
	shift[0] = 0.0;
	shift[1] = 0.0;

	for (int i = 0; i < gI_PendingCount[client]; i++)
	{
		shift[0] += gF_Pending[client][i][0];
		shift[1] += gF_Pending[client][i][1];
	}
}

void PopPending(int client)
{
	gI_PendingCount[client]--;

	for (int i = 0; i < gI_PendingCount[client]; i++)
	{
		gF_Pending[client][i][0] = gF_Pending[client][i + 1][0];
		gF_Pending[client][i][1] = gF_Pending[client][i + 1][1];
		gI_PendingTick[client][i] = gI_PendingTick[client][i + 1];
	}
}

float NormalizeAngle(float angle)
{
	while (angle > 180.0)
	{
		angle -= 360.0;
	}

	while (angle < -180.0)
	{
		angle += 360.0;
	}

	return angle;
}

float ClampPitch(float pitch)
{
	if (pitch > 89.0)
	{
		return 89.0;
	}

	if (pitch < -89.0)
	{
		return -89.0;
	}

	return pitch;
}
