#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <dhooks>

#pragma semicolon 1
#pragma newdecls required

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
	description = "Keeps teleport angles in sync with commands already in flight",
	version = "1.0",
	url = "https://github.com/ddyfad/tpcomp"
};

ConVar gCV_Enabled;
ConVar gCV_Window;
ConVar gCV_Pitch;

int gI_PlayerState;

DynamicHook gH_Teleport;

float gF_LastAngles[MAXPLAYERS+1][2];
float gF_LastDelta[MAXPLAYERS+1][2];

float gF_Pending[MAXPLAYERS+1][MAX_PENDING][2];
int gI_PendingTick[MAXPLAYERS+1][MAX_PENDING];
int gI_PendingCount[MAXPLAYERS+1];

bool gB_PendingSnap[MAXPLAYERS+1][MAX_PENDING];
float gF_PendingTarget[MAXPLAYERS+1][MAX_PENDING][2];
float gF_PendingFrom[MAXPLAYERS+1][MAX_PENDING];

bool gB_SnapWaiting[MAXPLAYERS+1];

bool gB_Suspended[MAXPLAYERS+1];

bool gB_Predicts[MAXPLAYERS+1];

int gI_TriggerToucher;

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	CreateNative("TPComp_Suspend", Native_Suspend);
	CreateNative("TPComp_SetClientPredicts", Native_SetClientPredicts);
	RegPluginLibrary("tpcomp");
	return APLRes_Success;
}

public void OnPluginStart()
{
	gCV_Enabled = CreateConVar("sm_tpcomp_enabled", "1", "Compensate teleport angles for latency.", 0, true, 0.0, true, 1.0);
	gCV_Window = CreateConVar("sm_tpcomp_window", "2", "How many ticks past the teleport tick a command's tickcount can be before the client is assumed to have the new angle.", 0, true, 0.0, true, 64.0);
	gCV_Pitch = CreateConVar("sm_tpcomp_pitch", "1", "Restore the teleport's pitch. 0 compensates yaw only: the view never jumps, but pitch isn't restored.", 0, true, 0.0, true, 1.0);

	gI_PlayerState = FindSendPropInfo("CBasePlayer", "deadflag");

	if (gI_PlayerState <= 0)
	{
		SetFailState("Couldn't find CBasePlayer::pl.deadflag");
	}

	HookEvent("player_spawn", Event_PlayerSpawn);

	GameData gd = new GameData("sdktools.games");
	int offset = gd.GetOffset("Teleport");
	delete gd;

	if (offset == -1)
	{
		SetFailState("Couldn't find the Teleport offset in sdktools.games");
	}

	gH_Teleport = new DynamicHook(offset, HookType_Entity, ReturnType_Void, ThisPointer_CBaseEntity);
	gH_Teleport.AddParam(HookParamType_VectorPtr);
	gH_Teleport.AddParam(HookParamType_VectorPtr);
	gH_Teleport.AddParam(HookParamType_VectorPtr);

	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client))
		{
			OnClientPutInServer(client);
		}
	}

	int entity = -1;

	while ((entity = FindEntityByClassname(entity, "trigger_teleport")) != -1)
	{
		HookTrigger(entity);
	}
}

public void OnEntityCreated(int entity, const char[] classname)
{
	if (StrEqual(classname, "trigger_teleport"))
	{
		HookTrigger(entity);
	}
}

void HookTrigger(int entity)
{
	SDKHook(entity, SDKHook_Touch, Trigger_Touch);
	SDKHook(entity, SDKHook_TouchPost, Trigger_TouchPost);
}

// trigger_teleport teleports from Touch, so this tells its teleports apart from others
public Action Trigger_Touch(int entity, int other)
{
	gI_TriggerToucher = other;
	return Plugin_Continue;
}

public void Trigger_TouchPost(int entity, int other)
{
	gI_TriggerToucher = 0;
}

public void OnClientPutInServer(int client)
{
	gI_PendingCount[client] = 0;
	gB_Suspended[client] = false;
	gB_Predicts[client] = false;

	if (!IsFakeClient(client))
	{
		gH_Teleport.HookEntity(Hook_Pre, client, Teleport_Pre);
		gH_Teleport.HookEntity(Hook_Post, client, Teleport_Post);
	}
}

public void Event_PlayerSpawn(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));

	if (client != 0)
	{
		gI_PendingCount[client] = 0;
	}
}

public any Native_Suspend(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);

	if (client < 1 || client > MaxClients)
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %d", client);
	}

	gB_Suspended[client] = GetNativeCell(2);
	return 0;
}

public any Native_SetClientPredicts(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);

	if (client < 1 || client > MaxClients)
	{
		return ThrowNativeError(SP_ERROR_NATIVE, "Invalid client index %d", client);
	}

	gB_Predicts[client] = GetNativeCell(2);
	return 0;
}

// Notes whether this teleport will overwrite one of our snaps that hasn't gone out yet
public MRESReturn Teleport_Pre(int client, DHookParam params)
{
	int n = gI_PendingCount[client];
	gB_SnapWaiting[client] = false;

	if (n > 0 && gB_PendingSnap[client][n - 1] && GetEntData(client, gI_PlayerState + FIXANGLE_OFFSET) == FIXANGLE_ABSOLUTE)
	{
		float v[3];
		GetEntDataVector(client, gI_PlayerState + V_ANGLE_OFFSET, v);
		gB_SnapWaiting[client] = (v[0] == gF_PendingTarget[client][n - 1][0] && v[1] == gF_PendingTarget[client][n - 1][1]);
	}

	return MRES_Ignored;
}

public MRESReturn Teleport_Post(int client, DHookParam params)
{
	bool waiting = gB_SnapWaiting[client];
	gB_SnapWaiting[client] = false;

	if (params.IsNull(2))
	{
		return MRES_Ignored;
	}

	if (waiting)
	{
		gI_PendingCount[client]--;
	}

	if (!gCV_Enabled.BoolValue || gB_Suspended[client])
	{
		return MRES_Ignored;
	}

	if (gB_Predicts[client] && gI_TriggerToucher == client)
	{
		return MRES_Ignored;
	}

	if (GetEntData(client, gI_PlayerState + FIXANGLE_OFFSET) != FIXANGLE_ABSOLUTE)
	{
		return MRES_Ignored;
	}

	float target[3], change[3];
	GetEntDataVector(client, gI_PlayerState + V_ANGLE_OFFSET, target);
	GetEntDataVector(client, gI_PlayerState + ANGLECHANGE_OFFSET, change);

	if (gCV_Pitch.BoolValue)
	{
		SnapAndCatchUp(client, target, change);
		return MRES_Ignored;
	}

	float shift[2], d[2];
	PendingShift(client, shift);

	for (int i = 0; i < 2; i++)
	{
		d[i] = NormalizeAngle(target[i] - (gF_LastAngles[client][i] + shift[i]));
	}

	int n = gI_PendingCount[client];

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
	return MRES_Ignored;
}

// Keeps the teleport's snap for its pitch; the yaw it throws away is handed back once it lands
void SnapAndCatchUp(int client, const float target[3], const float change[3])
{
	float d[2], aim[2];

	for (int i = 0; i < 2; i++)
	{
		aim[i] = target[i];
		d[i] = NormalizeAngle(target[i] - gF_LastAngles[client][i]);
	}

	int n = gI_PendingCount[client];

	if (n > 0 && !gB_PendingSnap[client][n - 1] && (change[0] != 0.0 || change[1] != 0.0))
	{
		gI_PendingCount[client]--;
	}

	PushPending(client, d, true, aim, gF_LastAngles[client][1]);

	SetEntDataVector(client, gI_PlayerState + ANGLECHANGE_OFFSET, NULL_VECTOR);
}

public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3], int &weapon, int &subtype, int &cmdnum, int &tickcount, int &seed, int mouse[2])
{
	if (IsFakeClient(client))
	{
		return Plugin_Continue;
	}

	float prevAngles[2];
	prevAngles = gF_LastAngles[client];

	float delta[2], jump[2];

	for (int i = 0; i < 2; i++)
	{
		delta[i] = NormalizeAngle(angles[i] - gF_LastAngles[client][i]);
		jump[i] = NormalizeAngle(delta[i] - gF_LastDelta[client][i]);

		gF_LastAngles[client][i] = angles[i];
		gF_LastDelta[client][i] = delta[i];
	}

	if (gI_PendingCount[client] > 0)
	{
		bool snap = gB_PendingSnap[client][0];
		float expect[2];

		if (snap)
		{
			for (int i = 0; i < 2; i++)
			{
				expect[i] = NormalizeAngle(gF_PendingTarget[client][0][i] - prevAngles[i]);
			}
		}
		else
		{
			expect[0] = gF_Pending[client][0][0];
			expect[1] = gF_Pending[client][0][1];
		}

		int tick = gI_PendingTick[client][0];

		float miss = FloatAbs(NormalizeAngle(jump[0] - expect[0])) + FloatAbs(NormalizeAngle(jump[1] - expect[1]));

		bool landed = tickcount >= tick - 2 && miss < FloatAbs(jump[0]) + FloatAbs(jump[1]);

		if (landed || tickcount > tick + gCV_Window.IntValue)
		{
			if (landed)
			{
				gF_LastDelta[client][0] = NormalizeAngle(delta[0] - expect[0]);
				gF_LastDelta[client][1] = NormalizeAngle(delta[1] - expect[1]);
			}

			float lost = snap && landed ? NormalizeAngle(prevAngles[1] - gF_PendingFrom[client][0]) : 0.0;

			PopPending(client);

			bool later = false;

			for (int i = 0; i < gI_PendingCount[client]; i++)
			{
				if (gB_PendingSnap[client][i])
				{
					gF_Pending[client][i][0] -= expect[0];
					gF_Pending[client][i][1] = NormalizeAngle(gF_Pending[client][i][1] - expect[1]);
					gF_PendingFrom[client][i] = NormalizeAngle(gF_PendingFrom[client][i] + expect[1]);
					later = true;
				}
			}

			bool frozen = GetEntityMoveType(client) == MOVETYPE_NONE || (GetEntityFlags(client) & FL_FROZEN);

			if (lost != 0.0 && !later && !frozen)
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

	angles[0] = ClampPitch(angles[0] + shift[0]);
	angles[1] = NormalizeAngle(angles[1] + shift[1]);

	return Plugin_Changed;
}

// Relative snap, added to wherever the client is looking
void GiveBackYaw(int client, float amount)
{
	int fixangle = GetEntData(client, gI_PlayerState + FIXANGLE_OFFSET);

	if (fixangle == FIXANGLE_ABSOLUTE)
	{
		return;
	}

	float change[3];

	if (fixangle == FIXANGLE_RELATIVE)
	{
		GetEntDataVector(client, gI_PlayerState + ANGLECHANGE_OFFSET, change);
	}

	change[1] += amount;

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

// A snap sets the angles outright, so only changes from the last snap on add up
void PendingShift(int client, float shift[2])
{
	shift[0] = 0.0;
	shift[1] = 0.0;

	int first = 0;

	for (int i = 0; i < gI_PendingCount[client]; i++)
	{
		if (gB_PendingSnap[client][i])
		{
			first = i;
		}
	}

	for (int i = first; i < gI_PendingCount[client]; i++)
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
