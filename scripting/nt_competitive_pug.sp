/*  The IsAdmin function borrowed from the smlib library
under the GPLv3 license: https://github.com/bcserv/smlib */

#pragma semicolon 1

#define PLUGIN_PUG 1
#define PLUGIN_VERSION "0.1"

// NOTE: Make sure this is set to 0 unless you really want to
// debug the SQL as it disables some safety checks!
#define DEBUG_SQL true
// Same as above with this option.
#define DEBUG_ALLOW_LAN_STEAMIDS true

// This debug flag is safe to use for pub servers.
#define DEBUG true

new bool:g_bIsQueueActive;

new const String:g_sTag[] = "[PUG]";

new const String:g_sMenuSoundOk[] = "buttons/button14.wav";
new const String:g_sMenuSoundCancel[] = "buttons/combine_button7.wav";
new const String:g_sPugInvite1[] = "friends/friend_join.wav";
new const String:g_sPugInvite2[] = "player/CPcaptured.wav";

#include <sourcemod>
#include <sdktools>
#include <neotokyo>
#include "nt_competitive/shared_variables"
#include "nt_competitive/shared_functions"
#include "nt_competitive/nt_competitive_sql"

public Plugin:myinfo = {
	name = "Neotokyo competitive, PUG Module",
	description =  "",
	author = "Rain",
	version = PLUGIN_VERSION,
	url = "https://github.com/Rainyan/sourcemod-nt-competitive"
};

public OnPluginStart()
{
#if !defined PLUGIN_PUG
	#error Compile flag PLUGIN_PUG needs to be set in nt_competitive_pug.sp.
#endif
	g_hCvar_DbConfig = CreateConVar("sm_pug_db_cfg", "pug",
		"Database config entry name", FCVAR_PROTECTED);

#if DEBUG_SQL || DEBUG_ALLOW_LAN_STEAMIDS
	decl String:pluginFilename[PLATFORM_MAX_PATH];
	GetPluginFilename(INVALID_HANDLE, pluginFilename, sizeof(pluginFilename));
#endif

#if DEBUG_SQL
	PrintToServer("### WARNING ### DEBUG_SQL is enabled. It should only be enabled for plugin \
development and not for public servers! Please consider recompiling %s", pluginFilename);
	CheckSQLConstants();
#endif

#if DEBUG_ALLOW_LAN_STEAMIDS
	PrintToServer("### WARNING ### DEBUG_ALLOW_LAN_STEAMIDS is enabled. \
It should only be enabled for plugin development and not for public servers! \
Please consider recompiling %s", pluginFilename);
#endif

	Database_Initialize();
	if (g_bIsDatabaseDown)
		SetFailState("Failed to join database");
	
	RegConsoleCmd("sm_pug", Command_Pug);
	RegConsoleCmd("sm_unpug", Command_UnPug);
	RegConsoleCmd("sm_join", Command_Join);

	GenerateIdentifier_This(g_sIdentifier);

	Threaded_Organizers_Update_This(DB_ORG_INACTIVE);
	CreateTimer(MATCHMAKE_LOOKUP_TIMER, Timer_CheckPugs, _, TIMER_REPEAT);
	
	PrecacheSound(g_sMenuSoundOk);
	PrecacheSound(g_sMenuSoundCancel);
	PrecacheSound(g_sPugInvite1);
	PrecacheSound(g_sPugInvite2);
}

public void OnClientDisconnect(int client)
{
	g_iLastSeenQueueState[client] = PUGGER_STATE_INACTIVE;
	g_iLoopCounter[client] = 0;
}

public Action Timer_CheckPugs(Handle timer)
{
	int time = GetTime();
	bool showExtraInfo = false;
	// Only check for db messages once per minute
	if (time > g_iLastEpoch_CheckPugs + 60)
	{
		showExtraInfo = true;
		g_iLastEpoch_CheckPugs = time;
	}

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidClient(i) || IsFakeClient(i))
		{
			continue;
		}
#if !DEBUG_ALLOW_LAN_STEAMIDS
		else if (!IsClientAuthorized(i))
		{
			continue;
		}
#endif
		else if (!IsClientInGame(i))
		{
			continue;
		}

		if (showExtraInfo)
		{
			Threaded_Pugger_AdvertiseQueueState_If_Queued(GetClientUserId(i));
			Threaded_Pugger_DisplayDbMessage(i);
		}
		Threaded_Pugger_CheckQueuingStatus(i);
	}
	return Plugin_Continue;
}

void ShowPanel(int client, int state)
{
	if (!IsValidClient(client))
		return;

	if (state != PUGGER_STATE_CONFIRMING && state != PUGGER_STATE_LIVE)
		return;

	Panel panel = CreatePanel();
	switch (state)
	{
		case PUGGER_STATE_CONFIRMING:
		{
			EmitSoundToClient(client, g_sPugInvite1, _, _, _, _, _, 135);
			panel.SetTitle("You have a new PUG invitation!");
			panel.DrawText(" ");
			panel.DrawItem("Accept match");
			panel.DrawItem("Decline");
			panel.Send(client, PanelHandler_ShowPanel_Confirm, MENU_TIME_FOREVER);
		}
		case PUGGER_STATE_LIVE:
		{
			EmitSoundToClient(client, g_sPugInvite2, _, _, _, _, _, 135);
			panel.SetTitle("Your PUG match is ready!");
			panel.DrawText(" ");
			panel.DrawItem("Join match");
			panel.DrawItem("Join later (max. 2 minutes to join)");
			panel.Send(client, PanelHandler_ShowPanel_Join, MENU_TIME_FOREVER);
		}
	}
	delete panel;
}

public int PanelHandler_ShowPanel_Confirm(Menu menu, MenuAction action, int client, int choice)
{
	if (action != MenuAction_Select)
		return;

	switch (choice)
	{
		// Accept
		case 1:
		{
			EmitSoundToClient(client, g_sMenuSoundOk);
			Command_Join(client, 1);
		}
		// Decline
		case 2:
		{
			EmitSoundToClient(client, g_sMenuSoundCancel);
			Command_UnPug(client, 1);
		}
	}
}

public int PanelHandler_ShowPanel_Join(Menu menu, MenuAction action, int client, int choice)
{
	if (action != MenuAction_Select)
		return;

	switch (choice)
	{
		// Join
		case 1:
		{
			EmitSoundToClient(client, g_sMenuSoundOk);
			Command_Join(client, 1);
		}
		// Don't join (yet)
		case 2:
		{
			// do nothing
			EmitSoundToClient(client, g_sMenuSoundCancel);
		}
	}
}

void PrintMatchInformation(int client)
{
	if (!IsValidClient(client))
		return;

	decl String:steamid[MAX_STEAMID_LENGTH];
	GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid));

	Threaded_Pugger_PrintMatchInformation(steamid);
}

public Action Command_Pug(int client, int args)
{
	if (!IsValidClient(client) || IsFakeClient(client))
	{
		return Plugin_Stop;
	}
	
#if !DEBUG_ALLOW_LAN_STEAMIDS
	if (!IsClientAuthorized(client))
	{
		ReplyToCommand(client, "%s Failed to read your SteamID, please try again.", g_sTag);
		return Plugin_Stop;
	}
#endif

	Threaded_Pugger_JoinQueue(client);

	return Plugin_Handled;
}

public Action Command_UnPug(int client, int args)
{
	if (!IsValidClient(client) || IsFakeClient(client))
	{
		return Plugin_Stop;
	}
	
#if !DEBUG_ALLOW_LAN_STEAMIDS
	if (!IsClientAuthorized(client))
	{
		ReplyToCommand(client, "Could not read your SteamID, please try again.");
		return Plugin_Stop;
	}
#endif

	Threaded_Pugger_LeaveQueue(client);
	return Plugin_Handled;
}

public Action Command_Join(int client, int args)
{
	if (!IsValidClient(client) || IsFakeClient(client))
	{
		return Plugin_Stop;
	}
	
#if !DEBUG_ALLOW_LAN_STEAMIDS
	if (!IsClientAuthorized(client))
	{
		ReplyToCommand(client, "Could not read your SteamID, please try again.");
		return Plugin_Stop;
	}
#endif

	decl String:steamid[MAX_STEAMID_LENGTH];
	GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid));

	Threaded_Pugger_JoinActiveMatch(steamid);
	return Plugin_Handled;
}

void SendPlayerToMatch(int client, const char[] connectIP, int connectPort, const char[] connectPassword)
{
	PrintToConsole(client, "%s Joining PUG: %s:%i password %s",
		g_sTag, connectIP, connectPort, connectPassword);

	decl String:cmd[MAX_CVAR_LENGTH+MAX_IP_LENGTH+32];
	Format(cmd, sizeof(cmd), "password %s; connect %s:%i",
		connectPassword, connectIP, connectPort);
	ClientCommand(client, cmd);
}

// Purpose: Generate a unique identifier for
// recognizing this server in the database, based on ip:port
void GenerateIdentifier_This(char[] identifier)
{
	// The identifier has been manually set before compiling,
	// no need to generate one here.
	// Manually setting the identifier can get around issues where
	// the IP returns "localhost" or similar. The identifier doesn't
	// actually have to be the IP:port, as long as it's unique.
	if (!StrEqual(identifier, ""))
		return;

	char ipAddress[MAX_IP_LENGTH];
	int port;
	if (!GetServerConnectionDetails(ipAddress, port))
		SetFailState("Failed retrieving server IP and port information.");

	Format(identifier, MAX_IDENTIFIER_LENGTH, "%s:%i", ipAddress, port);
}
