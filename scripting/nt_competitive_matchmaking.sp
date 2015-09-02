#pragma semicolon 1

#include <sourcemod>
#include <smlib>
#include "nt_competitive/nt_competitive_sql"

#define PLUGIN_VERSION "0.1"

new Handle:g_hMatchmaking;
new Handle:g_hMatchSize;

new Handle:g_hTimer_CheckMMStatus = INVALID_HANDLE;

new bool:g_isServerOfferingMatch;

public Plugin:myinfo = {
	name		=	"Neotokyo Competitive Plugin, Matchmaking Module",
	description	=	"Handle queue based matchmaking",
	author		=	"Rain",
	version		=	PLUGIN_VERSION,
	url				=	"https://github.com/Rainyan/sourcemod-nt-competitive"
};

public OnAllPluginsLoaded()
{
	// Make sure we are running the base competitive plugin
	new Handle:hPluginBase = FindPluginByFile("nt_competitive.smx");
	new PluginStatus:hPluginBase_Status = GetPluginStatus(hPluginBase);
	
	if (hPluginBase == INVALID_HANDLE || hPluginBase_Status != Plugin_Running)
		SetFailState("Matchmaking module requires the base nt_competitive plugin to run");
	
	g_hMatchSize = FindConVar("sm_competitive_players_total");
}

public OnPluginStart()
{
	g_hMatchmaking = CreateConVar("sm_competitive_matchmaking",	"1",	"Enable matchmaking mode (automated queue system instead of manual join)", _, true, 0.0, true, 1.0);
	
	HookConVarChange(g_hMatchmaking, Event_Matchmaking);
}

public OnConfigsExecuted()
{
	if (GetConVarBool(g_hMatchmaking))
	{
		InitSQL();
		
		if (g_hTimer_CheckMMStatus == INVALID_HANDLE)
			g_hTimer_CheckMMStatus = CreateTimer(60.0, Timer_CheckMMStatus, _, TIMER_REPEAT);
	}
}

int GetPlayersQueued()
{
	if (db == INVALID_HANDLE)
	{
		LogError("SQL error: database handle is invalid");
		return 0;
	}
	
	decl String:sql[MAX_SQL_LENGTH];
	
	Format(sql, sizeof(sql), "SELECT players_queued FROM %s", SQL_TABLE_QUEUED);
	
	new Handle:query = SQL_Query(db, sql);
	
	if (query == INVALID_HANDLE)
	{
		LogError("SQL error: query failed");
		return 0;
	}
	
	new playersQueued;
	
	while (SQL_FetchRow(query))
		playersQueued = SQL_FetchInt(query, 0);
	
	CloseHandle(query);
	
	return playersQueued;
}

void OfferMatch()
{
	if (!g_isSQLInitialized || g_isServerOfferingMatch)
		return;
	
	decl String:serverIP[16];
	Server_GetIPString(serverIP, sizeof(serverIP));
	new serverPort = Server_GetPort();
	
	decl String:sql[MAX_SQL_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE server_ip=? AND server_port=?, ", SQL_TABLE_OFFER_MATCH);
	
	decl String:sqlError[256];
	new Handle:stmt = SQL_PrepareQuery(db, sql, sqlError, sizeof(sqlError));
	
	if (stmt == INVALID_HANDLE)
	{
		LogError("SQL error: %s", sqlError);
		return;
	}
	
	SQL_BindParamString(stmt, 0, serverIP, false);
	SQL_BindParamInt(stmt, 1, serverPort);
	
	if (!SQL_Execute(stmt))
	{
		LogError("SQL error: %s", sqlError);
		
		if (stmt != INVALID_HANDLE)
			CloseHandle(stmt);
		
		return;
	}
	
	new entries;
	
	while (SQL_FetchRow(stmt))
	{
		entries = SQL_FetchInt(stmt, 0);
	}
	
	CloseHandle(stmt);
	
	PrintToServer("Found entries: %i", entries);
	
	return;
}

public Event_Matchmaking(Handle:cvar, const String:oldVal[], const String:newVal[])
{
	if (StringToInt(newVal) == 1)
		InitSQL();
}

public Action:Timer_CheckMMStatus(Handle:timer)
{
	// We're not in "matchmaking" mode anymore, stop this timer
	if ( !GetConVarBool(g_hMatchmaking) )
	{
		if (g_hTimer_CheckMMStatus != INVALID_HANDLE)
		{
			KillTimer(g_hTimer_CheckMMStatus);
			return Plugin_Stop;
		}
	}
	
	// There's enough people queued up to start a match
	if ( GetPlayersQueued() >= GetConVarInt(g_hMatchSize) )
	{
		if (!g_isServerOfferingMatch)
			OfferMatch();
	}
	
	return Plugin_Continue;
}