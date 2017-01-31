/*
	GPLv3
		- IsAdmin function borrowed from the smlib library:
			https://github.com/bcserv/smlib
*/
#pragma semicolon 1

#define PLUGIN_PUG 1
#define PLUGIN_VERSION "0.1"

#define DEBUG 1
#define DEBUG_SQL 1 /* Make sure this is set to 0 unless you really want to
debug the SQL as it disables some safety checks */

new bool:g_bIsDatabaseDown;
new bool:g_bIsJustLoaded = true;
new bool:g_bIsQueueActive;

new const String:g_sTag[] = "[PUG]";

#include <sourcemod>
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

	// Just do this once
	if (g_bIsJustLoaded)
	{
		Database_Initialize();
		GenerateIdentifier_This(g_sIdentifier);
		if (!Organizers_Update_This())
			SetFailState("Failed to join database");
#if DEBUG_SQL
		CheckSQLConstants();
#endif
		g_bIsJustLoaded = false;
	}

	RegConsoleCmd("sm_pug", Command_Pug);
	RegConsoleCmd("sm_unpug", Command_UnPug);
	RegConsoleCmd("sm_join", Command_Join);
}

public Action Command_Pug(int client, int args)
{
	if (!IsValidClient(client) || IsFakeClient(client))
	{
		return Plugin_Stop;
	}
	if (!IsClientAuthorized(client))
	{
		ReplyToCommand(client, "Could not read your SteamID, please try again.");
		return Plugin_Stop;
	}

	decl String:steamid[MAX_STEAMID_LENGTH];
	GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid));

	int queuingState = Pugger_GetQueuingState(_, _, _, true, steamid);
	switch (queuingState)
	{
		case PUGGER_STATE_INACTIVE:
		{
			if (!Database_AddPugger(_, true, steamid))
			{
				ReplyToCommand(client, "%s Failed to queue, please try again.", g_sTag);
				ReplyToCommand(client, "This error has been logged.");
			}
			else
			{
				int searching = Puggers_GetCountPerState(PUGGER_STATE_QUEUING);
				int playing = Puggers_GetCountPerState(PUGGER_STATE_LIVE);
				int desiredPlayers = Database_GetDesiredPlayerCount();
				ReplyToCommand(client, "%s You have joined the queue!", g_sTag);
				ReplyToCommand(client, "Players queuing: %i / %i (%i currently playing a match)",
					searching, desiredPlayers, playing);
			}
		}
		case PUGGER_STATE_QUEUING:
		{
			ReplyToCommand(client, "%s You are already queuing! \
Use !unpug instead to leave the queue.", g_sTag);
		}
		case PUGGER_STATE_CONFIRMING:
		{
			ReplyToCommand(client, "%s You are have a pending match invitation! \
Use !join to accept, or !unpug to decline the match.", g_sTag);
		}
		case PUGGER_STATE_ACCEPTED:
		{
			ReplyToCommand(client, "%s You have already accepted a match, \
please wait for the server join invitation.", g_sTag);
		}
		case PUGGER_STATE_LIVE:
		{
			ReplyToCommand(client, "%s You have already been assigned to a match, \
please use !join to enter the PUG server.", g_sTag);
		}
	}
	return Plugin_Handled;
}

public Action Command_UnPug(int client, int args)
{
	if (!IsValidClient(client) || IsFakeClient(client))
	{
		return Plugin_Stop;
	}
	if (!IsClientAuthorized(client))
	{
		ReplyToCommand(client, "Could not read your SteamID, please try again.");
		return Plugin_Stop;
	}

	decl String:steamid[MAX_STEAMID_LENGTH];
	GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid));

	int queuingState = Pugger_GetQueuingState(_, _, _, true, steamid);
	switch (queuingState)
	{
		case PUGGER_STATE_INACTIVE:
		{
			ReplyToCommand(client, "%s You are not in the PUG queue!", g_sTag);
		}
		case PUGGER_STATE_QUEUING:
		{
			if (!Pugger_SetQueuingState(_, PUGGER_STATE_INACTIVE, true, steamid))
			{
				ReplyToCommand(client, "%s Failed leaving the queue, please try again.", g_sTag);
				ReplyToCommand(client, "This error has been logged.");
			}
			else
			{
				ReplyToCommand(client, "%s You have left the PUG queue.", g_sTag);
			}
		}
		case PUGGER_STATE_CONFIRMING:
		{
			if (!Pugger_SetQueuingState(_, PUGGER_STATE_INACTIVE, true, steamid))
			{
				ReplyToCommand(client, "%s Failed leaving the queue, please try again.", g_sTag);
				ReplyToCommand(client, "This error has been logged.");
			}
			else
			{
				ReplyToCommand(client, "%s You have declined the match invitation, \
and left the PUG queue.", g_sTag);
			}
		}
		case PUGGER_STATE_ACCEPTED:
		{
			ReplyToCommand(client, "%s You have already accepted this match! \
Please wait while the invitation processes.", g_sTag);
		}
		case PUGGER_STATE_LIVE:
		{
			// todo: option to late decline/abandon the match here
			ReplyToCommand(client, "%s You have already been assigned to a match, \
please use !join to enter the PUG server.", g_sTag);
		}
	}
	return Plugin_Handled;
}

public Action Command_Join(int client, int args)
{
	if (!IsValidClient(client) || IsFakeClient(client))
	{
		return Plugin_Stop;
	}
	if (!IsClientAuthorized(client))
	{
		ReplyToCommand(client, "Could not read your SteamID, please try again.");
		return Plugin_Stop;
	}

	decl String:steamid[MAX_STEAMID_LENGTH];
	GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid));

	int queuingState = Pugger_GetQueuingState(_, _, _, true, steamid);
	if (queuingState == PUGGER_STATE_INACTIVE)
	{
		ReplyToCommand(client, "%s You are not in the PUG queue! Use !pug to join.",
			g_sTag);
		return Plugin_Stop;
	}
	else if (queuingState != PUGGER_STATE_LIVE &&
		queuingState != PUGGER_STATE_CONFIRMING)
	{
		ReplyToCommand(client, "%s You don't have an active match invitation!", g_sTag);
		ReplyToCommand(client, "Please wait while the system is looking for a match \
for you.");
		return Plugin_Stop;
	}

	int matchid;
	decl String:connectPassword[MAX_CVAR_LENGTH];
	decl String:connectIP[MAX_IP_LENGTH];
	int connectPort;

	if (!Pugger_GetLastMatchDetails(
		steamid, matchid, connectIP, connectPort, connectPassword))
	{
		ReplyToCommand(client, "%s Failed to retrieve your match information.", g_sTag);
		ReplyToCommand(client, "Please try again later. The error has been logged.");
		return Plugin_Stop;
	}
	if (matchid == INVALID_MATCH_ID)
	{
		ReplyToCommand(client, "%s Could not find an active match for you.", g_sTag);
		ReplyToCommand(client, "Please contact server admins if you think this is an error.");
		return Plugin_Stop;
	}

	PrintToChatAll("matchid: %i", matchid);

	int matchStatus = Database_GetMatchStatus(matchid);
	switch (matchStatus)
	{
		case MATCHMAKE_ERROR:
		{
			ReplyToCommand(client, "%s Your match reports an error status.", g_sTag);
			ReplyToCommand(client, "This is probably an error, please try again later.");
		}
		case MATCHMAKE_WARMUP:
		{
			SendPlayerToMatch(client, connectIP, connectPort, connectPassword);
		}
		case MATCHMAKE_LIVE:
		{
			// join (check if the player hasn't abandoned match first)
			SendPlayerToMatch(client, connectIP, connectPort, connectPassword);
		}
		case MATCHMAKE_PAUSED:
		{
			// join (check if the player hasn't abandoned match first)
			SendPlayerToMatch(client, connectIP, connectPort, connectPassword);
		}
		case MATCHMAKE_FINISHED:
		{
			ReplyToCommand(client, "%s Your match has finished!");
			ReplyToCommand(client, "Please contact server admins \
if you think this is an error.");
		}
		case MATCHMAKE_CANCELLED:
		{
			ReplyToCommand(client, "%s Your match was cancelled!");
			ReplyToCommand(client, "Please contact server admins \
if you think this is an error.");
		}
	}
	return Plugin_Handled;
}

void SendPlayerToMatch(int client, const char[] connectIP, int connectPort, const char[] connectPassword)
{
	PrintToConsole(client, "%s Joining PUG: %s:%i password %s",
		g_sTag, connectIP, connectPort, connectPassword);
}

// Purpose: Generate a unique identifier for
// recognizing this server in the database, based on ip:port
void GenerateIdentifier_This(char[] identifier)
{
	// The identifier has been manually set before compiling,
	// no need to generate one
	if (!StrEqual(identifier, ""))
		return;

	char ipAddress[MAX_IP_LENGTH];
	int port;
	if (!GetServerConnectionDetails(ipAddress, port))
		SetFailState("Failed retrieving server IP and port information.");

	Format(identifier, MAX_IDENTIFIER_LENGTH, "%s:%i", ipAddress, port);
}
