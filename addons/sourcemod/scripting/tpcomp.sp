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

static const float NULL_ANGLES[2] = { 0.0, 0.0 };

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
ConVar gCV_Pitch;

int gI_PlayerState;

// Pitch and yaw
float gF_LastAngles[MAXPLAYERS+1][2];
float gF_LastDelta[MAXPLAYERS+1][2];

// Angle changes the client hasn't applied yet, oldest first
float gF_Pending[MAXPLAYERS+1][MAX_PENDING][2];
int gI_PendingTick[MAXPLAYERS+1][MAX_PENDING];
int gI_PendingCount[MAXPLAYERS+1];

// An entry left as shavit's own absolute snap. That sets the client's angles
// outright instead of adding to them, so it carries pitch, but the yaw the
// player moved while it was in flight is thrown away and has to be handed back.
bool gB_PendingSnap[MAXPLAYERS+1][MAX_PENDING];
float gF_PendingTarget[MAXPLAYERS+1][MAX_PENDING][2];
float gF_PendingFrom[MAXPLAYERS+1][MAX_PENDING];

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
	gCV_Pitch = CreateConVar("sm_tpcomp_pitch", "1", "Restore the checkpoint pitch. Off keeps the old yaw-only behaviour, where the view never jumps but pitch is left alone.", 0, true, 0.0, true, 1.0);

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

	if (gCV_Pitch.BoolValue)
	{
		SnapAndCatchUp(client, target);
		return;
	}

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
		PushPending(client, d, false, NULL_ANGLES, 0.0);
	}

	change[0] += d[0];
	change[1] += d[1];
	change[2] = 0.0;

	SetEntData(client, gI_PlayerState + FIXANGLE_OFFSET, FIXANGLE_RELATIVE);
	SetEntDataVector(client, gI_PlayerState + ANGLECHANGE_OFFSET, change);
}

// Leave shavit's snap alone so the client gets the checkpoint pitch, and note
// where the player was looking so the yaw the snap eats can be handed back once
// it lands.
void SnapAndCatchUp(int client, const float target[3])
{
	float d[2], aim[2];

	for (int i = 0; i < 2; i++)
	{
		aim[i] = target[i];
		d[i] = NormalizeAngle(target[i] - gF_LastAngles[client][i]);
	}

	if (d[0] == 0.0 && d[1] == 0.0)
	{
		return;
	}

	// The snap lands on the checkpoint angles whatever else is queued, so
	// anything the client hasn't applied yet stops mattering and the shift for
	// commands still in flight is the whole way from where the player is.
	gI_PendingCount[client] = 0;

	PushPending(client, d, true, aim, gF_LastAngles[client][1]);

	// An unsent anglechange would ride along with the next relative snap
	SetEntDataVector(client, gI_PlayerState + ANGLECHANGE_OFFSET, NULL_VECTOR);
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	if (IsFakeClient(client))
	{
		return Plugin_Continue;
	}

	float prevAngles[2], prevDelta[2];
	prevAngles = gF_LastAngles[client];
	prevDelta = gF_LastDelta[client];

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
		bool snap = gB_PendingSnap[client][0];
		float expect[2];

		if (snap)
		{
			// A snap replaces the angles, so the change that shows up is the
			// whole distance to the checkpoint rather than a fixed amount.
			for (int i = 0; i < 2; i++)
			{
				expect[i] = NormalizeAngle(gF_PendingTarget[client][0][i] - prevAngles[i]) - prevDelta[i];
			}
		}
		else
		{
			expect[0] = gF_Pending[client][0][0];
			expect[1] = gF_Pending[client][0][1];
		}

		int tick = gI_PendingTick[client][0];

		// First command after the client applies the change jumps by about it
		float miss = FloatAbs(jump[0] - expect[0]) + FloatAbs(jump[1] - expect[1]);

		if (tickcount >= tick && (miss < FloatAbs(jump[0]) + FloatAbs(jump[1]) || tickcount > tick + gCV_Window.IntValue))
		{
			gF_LastDelta[client][0] = delta[0] - expect[0];
			gF_LastDelta[client][1] = delta[1] - expect[1];

			// Everything the player turned while the snap was in flight
			float lost = snap ? NormalizeAngle(prevAngles[1] - gF_PendingFrom[client][0]) : 0.0;

			PopPending(client);

			if (lost != 0.0)
			{
				GiveBackYaw(client, lost);
			}
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

// The snap threw the player's own turning away. Send it back as a relative
// change, which the client adds to wherever it is looking, and keep shifting
// commands by it until the client has it.
void GiveBackYaw(int client, float amount)
{
	if (GetEntData(client, gI_PlayerState + FIXANGLE_OFFSET) != 0)
	{
		return;
	}

	float change[3];
	change[1] = amount;

	SetEntData(client, gI_PlayerState + FIXANGLE_OFFSET, FIXANGLE_RELATIVE);
	SetEntDataVector(client, gI_PlayerState + ANGLECHANGE_OFFSET, change);

	float d[2];
	d[1] = amount;

	PushPending(client, d, false, NULL_ANGLES, 0.0);
}

void PushPending(int client, const float d[2], bool snap, const float target[2], float from)
{
	int n = gI_PendingCount[client];

	if (n == MAX_PENDING)
	{
		PopPending(client);
		n--;
	}

	gF_Pending[client][n][0] = d[0];
	gF_Pending[client][n][1] = d[1];
	gB_PendingSnap[client][n] = snap;
	gF_PendingTarget[client][n][0] = target[0];
	gF_PendingTarget[client][n][1] = target[1];
	gF_PendingFrom[client][n] = from;
	gI_PendingTick[client][n] = GetGameTickCount();
	gI_PendingCount[client]++;
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
		gB_PendingSnap[client][i] = gB_PendingSnap[client][i + 1];
		gF_PendingTarget[client][i][0] = gF_PendingTarget[client][i + 1][0];
		gF_PendingTarget[client][i][1] = gF_PendingTarget[client][i + 1][1];
		gF_PendingFrom[client][i] = gF_PendingFrom[client][i + 1];
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
