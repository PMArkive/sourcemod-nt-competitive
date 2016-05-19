#pragma semicolon 1

// If you need to run this plugin on a server behind a NAT, enable this to properly announce your IP address.
// You will then also need the latest SteamTools include + extension for the server: https://forums.alliedmods.net/forumdisplay.php?f=147
#define USE_STEAMTOOLS 0

#include <sdktools_sound>
#include <sourcemod>
#if USE_STEAMTOOLS == 1
	#include <steamtools>
#endif
#include <smlib>

#define PLUGIN_VERSION "0.1"

#define MAX_STEAMID_LENGTH 44
#define MENU_TIME_INVITE 60

enum {
	SERVER_ID = 0,
	SERVER_HOSTNAME,
	SERVER_NAME,
	SERVER_STATUS,
	SERVER_PASSWORD,
	SERVER_ENUM_COUNT
};

enum {
	STATE_ERROR = 0,
	STATE_OFFLINE,
	STATE_BUSY,
	STATE_AVAILABLE,
	STATE_CONFIRMING,
	STATE_WAITING,
	STATE_LIVE
};

enum {
	PUGGER_STATUS_QUEUING = 0,
	PUGGER_STATUS_RESERVED, // todo: clear reserved state on !unpug
	PUGGER_STATUS_PLAYING
};

Database db = null;

new Handle:g_hCvar_DbConfig;

new wantedPuggers = 1;
new g_pugInviteTimer[MAXPLAYERS+1];

new const String:g_tag[] = "[PUG]";
new const String:g_sqlTable_Puggers[] = "puggers";
new const String:g_sqlTable_Servers[] = "servers";

new String:puggers[MAXPLAYERS+1][MAX_STEAMID_LENGTH];
new String:g_reservedServer[SERVER_ENUM_COUNT][128];

new bool:g_isDatabaseDown;
new bool:g_isPugging[MAXPLAYERS+1];
new bool:g_isDisconnecting[MAXPLAYERS+1];
new bool:g_isInvited[MAXPLAYERS+1];

public Plugin:myinfo = {
	name			= "NT Competitive, PUG module",
	description	= "",
	author			= "Rain",
	version			= PLUGIN_VERSION,
	url				= ""
};

public OnPluginStart()
{
	RegConsoleCmd("sm_pug", Command_Pug);
	RegConsoleCmd("sm_unpug", Command_UnPug);
	RegConsoleCmd("sm_join", Command_JoinPugServer);
	
	g_hCvar_DbConfig = CreateConVar("sm_pug_db_cfg", "pug", "Database config entry name", FCVAR_PROTECTED);
	
	CreateTimer(3.0, Timer_Purge);
}

public OnConfigsExecuted()
{
	Database_Initialize();
	Database_UpdatePuggers();
}

public OnClientConnected(client)
{
	g_isDisconnecting[client] = false;
}

public OnClientDisconnect(client)
{
	g_isDisconnecting[client] = true;
	g_isPugging[client] = false;
	g_isInvited[client] = false;
	CreateTimer(0.1, Timer_Purge);
}

public Action:Timer_Purge(Handle:timer)
{
	Puggers_Purge();
}

public Action:Command_Pug(client, args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "This command cannot be used from the server console.");
		return Plugin_Stop;
	}
	
	if (g_isDatabaseDown)
	{
			ReplyToCommand(client, "%s Command failed due to database error.", g_tag);
			ReplyToCommand(client, "Please contact server admins for help.");
			return Plugin_Stop;
	}
	
	decl String:steamid[MAX_STEAMID_LENGTH];
	GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid));
	
	for (new i = 0; i < sizeof(puggers); i++)
	{
		if (StrEqual(steamid, puggers[i]))
		{
			ReplyToCommand(client, "%s You've already signed up for pugging.", g_tag);
			ReplyToCommand(client, "Use !unpug or disconnect to remove yourself from the list.");
			return Plugin_Stop;
		}
	}
	
	Database_UpdatePuggers();
	Database_AddPugger(client);
	
	return Plugin_Handled;
}

public Action:Command_UnPug(client, args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "This command cannot be used from the server console.");
		return Plugin_Stop;
	}
	
	g_isInvited[client] = false;
	g_isPugging[client] = false;
	Database_RemovePugger(client);
	
	return Plugin_Handled;
}

public Action:Command_JoinPugServer(client, args)
{
	if (!g_isInvited[client])
	{
		if (!g_isPugging[client])
		{
			ReplyToCommand(client, "%s You are not queued for pugging.", g_tag);
			ReplyToCommand(client, "Use !pug to enter yourself to the puggers list.");
		}
		else
		{
			ReplyToCommand(client, "%s You are not currently invited to a pug server.", g_tag);
			ReplyToCommand(client, "Please wait for enough puggers to queue up for a match.", g_tag);
		}
		
		return Plugin_Stop;
	}
	
	decl String:clientName[MAX_NAME_LENGTH];
	GetClientName(client, clientName, sizeof(clientName));
	
	decl String:joinPassword[10 + sizeof(g_reservedServer[])];
	Format(joinPassword, sizeof(joinPassword), "password %s", g_reservedServer[SERVER_PASSWORD]);
	
	decl String:joinCmd[9 + sizeof(g_reservedServer[])];
	Format(joinCmd, sizeof(joinCmd), "connect %s", g_reservedServer[SERVER_HOSTNAME]);
	
	// Set pug server password
	ClientCommand(client, joinPassword);
	// Join pug server
	ClientCommand(client, joinCmd);
	// Client state will be cleared in OnClientDisconnect()
	
	PrintToChatAll("%s %s has joined a PUG", g_tag, clientName);
	
	/*
		Yay, clients get to join the PUG!
		
		To do:
					- Update server status (now occupied by this PUG, so not available for other PUGs)
						- Should be done by another plugin PUG server side (branch main comp plugin?)
					
					- Remove joining players from available puggers pool
						- Need pugger status to confirm server joiners. Add new column for pugger state in db? (looking for pug/playing pug)
					
					- Make server available again once no longer occupied by puggers
	*/	
	
	return Plugin_Handled;
}

void Database_AddPugger(client)
{
	if ( !Client_IsValid(client) )
		ThrowError("Invalid client %i", client);
	
	Database_Initialize();
	
	decl String:error[256];
	decl String:sql[256];
	decl String:steamid[MAX_STEAMID_LENGTH];
	GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid));
	
	// Check for existing rows with this steamid
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE steamid = ?", g_sqlTable_Puggers);
	
	new Handle:stmt = SQL_PrepareQuery(db, sql, error, sizeof(error));
	if (stmt == INVALID_HANDLE)
		ThrowError(error);
	
	SQL_BindParamString(stmt, 0, steamid, false);
	SQL_Execute(stmt);
	
	new foundRows = SQL_GetRowCount(stmt);
	CloseHandle(stmt);
	if (foundRows > 1)
	{
		ThrowError("Found %i rows matching steamid %s, expected to find 0 or 1.", foundRows, steamid);
	}
	else if (foundRows == 1)
	{
		ReplyToCommand(client, "%s You've already signed up for pugging.", g_tag);
		ReplyToCommand(client, "Use !unpug or disconnect to remove yourself from the list.");
		return;
	}
	
	// Insert client steamid into database
	Format(sql, sizeof(sql), "INSERT INTO %s (steamid, status) VALUES (?, ?)", g_sqlTable_Puggers);
	
	stmt = SQL_PrepareQuery(db, sql, error, sizeof(error));
	if (stmt == INVALID_HANDLE)
		ThrowError(error);
	
	new paramIndex;
	SQL_BindParamString(stmt, paramIndex++, steamid, false);
	SQL_BindParamInt(stmt, paramIndex++, PUGGER_STATUS_QUEUING, false);
	
	SQL_Execute(stmt);
	CloseHandle(stmt);
	
	decl String:clientName[MAX_NAME_LENGTH];
	GetClientName(client, clientName, sizeof(clientName));
	
	g_isPugging[client] = true;
	PrintToChatAll("%s %s entered the PUG list (%i / %i)", g_tag, clientName, Database_GetPuggerCount(), wantedPuggers);
	
	Database_UpdatePuggers();
	Database_FindMatch();
}

void Database_RemovePugger(client = 0, bool:bySteamid = false, const String:sentSteamid[] = "")
{
	PrintToServer("Database_RemovePugger(client = %i, bySteamid = %b, sentSteamid = \"%s\")", client, bySteamid, sentSteamid);
	
	if ( !bySteamid && !Client_IsValid(client) )
		ThrowError("Invalid client %i", client);
	else if ( bySteamid && client == 0 && strlen(sentSteamid) < 1)
		return;
	
	Database_Initialize();
	
	decl String:error[256];
	decl String:sql[256];
	decl String:steamid[MAX_STEAMID_LENGTH];
	
	if (!bySteamid)
		GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid));
	else
		strcopy(steamid, sizeof(steamid), sentSteamid);
	
	// Check for existing rows with this steamid
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE steamid = ?", g_sqlTable_Puggers);
	
	new Handle:stmt = SQL_PrepareQuery(db, sql, error, sizeof(error));
	if (stmt == INVALID_HANDLE)
		ThrowError(error);
	
	SQL_BindParamString(stmt, 0, steamid, false);
	SQL_Execute(stmt);
	
	new foundRows = SQL_GetRowCount(stmt);
	CloseHandle(stmt);
	if (foundRows > 1)
	{
		LogError("Found %i rows matching steamid %s, expected to find 0 or 1.", foundRows, steamid);
	}
	else if (foundRows < 1)
	{
		ReplyToCommand(client, "%s You aren't listed to pugging.", g_tag);
		ReplyToCommand(client, "Use !pug to enter yourself to the puggers list.");
		return;
	}
	
	Format(sql, sizeof(sql), "DELETE FROM %s WHERE steamid = ?", g_sqlTable_Puggers);
	
	stmt = SQL_PrepareQuery(db, sql, error, sizeof(error));
	if (stmt == INVALID_HANDLE)
		ThrowError("SQL error: %s", error);
	
	SQL_BindParamString(stmt, 0, steamid, false);
	SQL_Execute(stmt);
	CloseHandle(stmt);
	
	decl String:clientName[MAX_NAME_LENGTH];
	GetClientName(client, clientName, sizeof(clientName));
	
	Database_UpdatePuggers();
	PrintToChatAll("%s %s has left the PUG list (%i / %i)", g_tag, clientName, Database_GetPuggerCount(), wantedPuggers);
}

void Database_ReservePugger(const String:steamid[])
{
	PrintToServer("Database_ReservePugger(\"%s\")", steamid);
	
	Database_Initialize();
	
	decl String:sql[256];
	decl String:error[256];
	
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE steamid = ?", g_sqlTable_Puggers);
	
	new Handle:stmt = SQL_PrepareQuery(db, sql, error, sizeof(error));
	if (stmt == INVALID_HANDLE)
		ThrowError(error);
	
	SQL_BindParamString(stmt, 0, steamid, false);
	SQL_Execute(stmt);
	
	new rows;
	while (SQL_FetchRow(stmt))
	{
		rows++;
		
		new id = SQL_FetchInt(stmt, 0);
		
		if (rows > 1)
		{
			LogError("Found more than 1 result for SteamID %s in puggers database. Removing duplicate entry.", steamid);
			
			Format(sql, sizeof(sql), "DELETE FROM %s WHERE id = ?", g_sqlTable_Puggers);
			
			new Handle:stmt_deleteRow = SQL_PrepareQuery(db, sql, error, sizeof(error));
			if (stmt_deleteRow == INVALID_HANDLE)
				ThrowError(error);
			
			SQL_BindParamInt(stmt_deleteRow, 0, id);
			
			if (!SQL_Execute(stmt_deleteRow))
			{
				if (stmt_deleteRow != INVALID_HANDLE)
				{
					CloseHandle(stmt_deleteRow);
					stmt_deleteRow = INVALID_HANDLE;
				}
				ThrowError(error);
			}
			
			CloseHandle(stmt_deleteRow);
			continue;
		}
		
		PrintToServer("RESERVE CLIENT");
		
		Format(sql, sizeof(sql), "UPDATE %s SET status = ?, reservee = ? WHERE id = ?", g_sqlTable_Puggers);
		
		new Handle:stmt_updateRow = SQL_PrepareQuery(db, sql, error, sizeof(error));
		if (stmt_updateRow == INVALID_HANDLE)
			ThrowError(error);
		
		decl String:serverIP[128];
		Server_GetIPString(serverIP, sizeof(serverIP));
		PrintToServer("IP STRING: %s", serverIP);
		
		new paramIndex;
		SQL_BindParamInt(stmt_updateRow, paramIndex++, PUGGER_STATUS_RESERVED);
		SQL_BindParamString(stmt_updateRow, paramIndex++, serverIP, false);
		SQL_BindParamInt(stmt_updateRow, paramIndex++, id);
		
		if (!SQL_Execute(stmt_updateRow))
			ThrowError(error);
		
		CloseHandle(stmt_updateRow);
	}
	
	CloseHandle(stmt);
}

bool Database_Pugger_IsReservedForThisServer(const String:steamid[])
{
	PrintToServer("Database_Pugger_IsReservedForThisServer(\"%s\")", steamid);
	
	Database_Initialize();
	
	decl String:sql[256];
	decl String:error[256];
	
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE steamid = ? AND reservee = ?", g_sqlTable_Puggers);
	
	new Handle:stmt = SQL_PrepareQuery(db, sql, error, sizeof(error));
	if (stmt == INVALID_HANDLE)
		ThrowError(error);
	
	decl String:serverIP[128];
	Server_GetIPString(serverIP, sizeof(serverIP));
	
	new paramIndex;
	SQL_BindParamString(stmt, paramIndex++, steamid, false);
	SQL_BindParamString(stmt, paramIndex++, serverIP, false);
	
	if (!SQL_Execute(stmt))
		ThrowError(error);
	
	new rowCount = SQL_GetRowCount(stmt);
	new bool:isReserved;
	
	if (rowCount > 0)
	{
		isReserved = true;
		
		if (rowCount > 1)
			LogError("Found multiple entries for SteamID %s in puggers database.", steamid);
	}
	
	CloseHandle(stmt);
	
	return isReserved;
}

void Puggers_Purge()
{
	PrintToServer("Puggers_Purge()");
	
	decl String:steamidBuffer[MAX_STEAMID_LENGTH];
	new bool:steamidFound;
	for (new i = 0; i < sizeof(puggers); i++)
	{
		steamidFound = false;
		
		if (StrEqual(puggers[i], ""))
			continue;
		
		for (new j = 1; j < MaxClients; j++)
		{
			if (g_isDisconnecting[j])
			{
				g_isDisconnecting[j] = false;
				continue;
			}
			
			if (!Client_IsValid(j))
				continue;
			
			GetClientAuthId(j, AuthId_Steam2, steamidBuffer, sizeof(steamidBuffer[]));
			
			if (StrEqual(steamidBuffer, puggers[i]))
			{
				steamidFound = true;
				break;
			}
		}
		
		if (!steamidFound)
		{
			PrintToServer("Purging steamid entry %s at index %i", puggers[i], i);
			Database_RemovePugger(_, true, puggers[i]);
			strcopy(puggers[i], sizeof(puggers[]), "");
		}
		else
		{
			PrintToServer("Keeping steamid entry %s at index %i", puggers[i], i);
		}
	}
}

void Database_Initialize()
{
	PrintToServer("Database_Initialize()");
	
	decl String:error[256];
	decl String:configName[64];
	GetConVarString(g_hCvar_DbConfig, configName, sizeof(configName));
	
	db = SQL_Connect(configName, true, error, sizeof(error));
	
	if (db == null)
	{
		g_isDatabaseDown = true;
		ThrowError(error);
	}
	else
	{
		g_isDatabaseDown = false;
	}
}

void Database_UpdatePuggers()
{
	PrintToServer("Database_UpdatePuggers()");
	
	Database_Initialize();
	
	decl String:error[256];
	decl String:sql[128];
	
	Format(sql, sizeof(sql), "SELECT steamid FROM %s", g_sqlTable_Puggers);
	
	new Handle:stmt = SQL_PrepareQuery(db, sql, error, sizeof(error));
	if (stmt == INVALID_HANDLE)
		ThrowError("SQL error: %s", error);
	
	if (!SQL_Execute(stmt))
	{
		if (stmt != INVALID_HANDLE)
		{
			CloseHandle(stmt);
			stmt = INVALID_HANDLE;
		}
		ThrowError(error);
	}
	
	Puggers_Empty();
	new i;
	while (SQL_FetchRow(stmt))
	{
		SQL_FetchString(stmt, 0, puggers[i], sizeof(puggers[]));
		i++;
	}
	
	PrintToServer("Rows found: %i", i);
	
	for (i = 0; i < sizeof(puggers); i++)
	{
		if (strlen(puggers[i]) == 0)
			continue;
		
		PrintToServer("Found pugger: %s at index %i", puggers[i], i);
	}
	
	CloseHandle(stmt);
	
	PrintToServer("Pugger amount: %i", Database_GetPuggerCount());
}

void Puggers_Empty()
{
	PrintToServer("Puggers_Empty()");
	
	for (new i = 0; i < sizeof(puggers); i++)
	{
		strcopy(puggers[i], sizeof(puggers[]), "");
	}
}

int Database_GetPuggerCount(bool:justLocalAmount = false)
{
	PrintToServer("Database_GetPuggerCount()");
	new result;
	
	// Just return local server pugger count
	if (justLocalAmount)
	{
		PrintToServer("Returning local pugger amount");
		
		for (new i = 0; i < sizeof(puggers); i++)
		{
			if (strlen(puggers[i]) == 0)
				continue;
			
			result++;
		}
	}
	// Return total pugger count from database
	else
	{
		PrintToServer("Returning database pugger amount");
		
		Database_Initialize();
		
		decl String:sql[256];
		Format(sql, sizeof(sql), "SELECT * FROM %s", g_sqlTable_Puggers);
		
		new Handle:query = SQL_Query(db, sql);
		if (query == INVALID_HANDLE)
			ThrowError("SQL query failed: \"%s\"", sql);
		
		result = SQL_GetRowCount(query);
		CloseHandle(query);
	}
	
	return result;
}

void Database_FindMatch()
{
	PrintToServer("Database_FindMatch()");
	
	Database_Initialize();
	
	decl String:sql[128];
	Format(sql, sizeof(sql), "SELECT * FROM %s", g_sqlTable_Puggers);
	
	new Handle:result = SQL_Query(db, sql);
	
	new foundRows;
	new id[wantedPuggers];
	new String:chosenPuggers[wantedPuggers][MAX_STEAMID_LENGTH];
	while (SQL_FetchRow(result))
	{
		new puggerStatus = SQL_FetchInt(result, 3);
		
		decl String:steamidBuffer[MAX_STEAMID_LENGTH];
		SQL_FetchString(result, 1, steamidBuffer, sizeof(steamidBuffer));
		
		if (puggerStatus == PUGGER_STATUS_QUEUING ||
			puggerStatus == PUGGER_STATUS_RESERVED && Database_Pugger_IsReservedForThisServer(steamidBuffer) )
		{
			foundRows++;
			
			if (foundRows > wantedPuggers)
				break;
			
			Database_ReservePugger(steamidBuffer);
			
			id[foundRows-1] = SQL_FetchInt(result, 0);
			strcopy(chosenPuggers[foundRows-1], MAX_STEAMID_LENGTH, steamidBuffer);
			PrintToServer("chosenPuggers[%i]: %s", foundRows-1, chosenPuggers[foundRows-1]);
		}
	}
	
	CloseHandle(result);
	
	if (Servers_ReserveForPug())
	{
		Puggers_Invite(chosenPuggers, wantedPuggers);
	}
	else
	{
		PrintToPuggers("%s All %i pug servers are currently full. Waiting for a server to free up...", g_tag, Database_GetServerCount());
	}
}

void Puggers_Invite(const String:chosenPuggers[][], arraySize = 0)
{
	PrintToServer("Puggers_Invite(chosenPuggers[%i][])", arraySize);
	
	if (arraySize != wantedPuggers)
		LogError("chosenPuggers[][] string array size does not match wantedPuggers size. This might be a mistake if wantedPuggers wasn't recently changed.");
	
	new client;
	for (new i = 0; i < arraySize; i++)
	{
		// Only invite players listed on this server
		client = Pugger_GetClient(chosenPuggers[i]);
		if (client == 0)
			continue;
		
		PrintToServer("steamid: %s, client: %i", chosenPuggers[i], client);
		
		g_pugInviteTimer[client] = MENU_TIME_INVITE;
		Client_InviteToPug(client);
	}
}

int Pugger_GetClient(const String:steamid[])
{
	PrintToServer("Pugger_GetClient(%s)", steamid);
	
	for (new i = 0; i < sizeof(puggers); i++)
	{
		PrintToServer("#1 Comparing \"%s\" to puggers index %i: \"%s\"", steamid, i, puggers[i]);
		
		if (StrEqual(steamid, puggers[i]))
		{
			decl String:steamidBuffer[MAX_STEAMID_LENGTH];
			for (new j = 1; j < MaxClients; j++)
			{
				if (!Client_IsValid(j))
					continue;
				
				GetClientAuthId(j, AuthId_Steam2, steamidBuffer, sizeof(steamidBuffer));
				PrintToServer("#2 Comparing \"%s\" to \"%s\"", puggers[i], steamidBuffer);
				
				if (!StrEqual(puggers[i], steamidBuffer))
					continue;
				
				return j;
			}
		}
	}
	
	PrintToServer("Returning 0 for %s", steamid);
	
	return 0;
}

void Client_InviteToPug(client)
{
	if (client == 0 || !Client_IsValid(client))
	{
		g_isInvited[client] = false;
		ThrowError("Invalid client: %i", client);
	}
	
	CreateTimer(1.0, Timer_UpdatePugInvite, client);
	
	if (!g_isInvited[client])
	{
		g_isInvited[client] = true;
		
		PrintToServer("Client_InviteToPug(%i)", client);
		PrintToChat(client, "%s Your match is ready: %s (%s)", g_tag, g_reservedServer[SERVER_NAME], g_reservedServer[SERVER_HOSTNAME]);
		
		PlayInviteSound(client);
	}
	
	new Handle:panel = CreatePanel();
	SetPanelTitle(panel, "PUG Match Ready!");
	DrawPanelText(panel, " ");
	
	DrawPanelText(panel, "Type !join to enter the match, or");
	DrawPanelText(panel, "type !unpug to leave the queue.");
	DrawPanelText(panel, " ");
	
	DrawPanelText(panel, "Matches tend to last 30-60 minutes.");
	DrawPanelText(panel, "Be nice and stay until the end of a match.");
	DrawPanelText(panel, " ");
	
	decl String:timeRemaining[22];
	Format(timeRemaining, sizeof(timeRemaining), "Time remaining: %i", g_pugInviteTimer[client]);
	
	DrawPanelText(panel, timeRemaining);
	
//	DrawPanelItem(panel, "Close window");
	
	// Close panel instance after 2 seconds. Panel status is updated once per second.
	SendPanelToClient(panel, client, PanelHandler_InviteToPug, 2);
	CloseHandle(panel);
}

public PanelHandler_InviteToPug(Handle:menu, MenuAction:action, client, choice)
{
	return;
}

public Action:Timer_UpdatePugInvite(Handle:timer, any:client)
{
	if (!g_isInvited[client])
		return Plugin_Stop;
	
	if (g_pugInviteTimer[client] < 1)
	{
		g_isInvited[client] = false;
		
		if (g_isPugging[client])
		{
			PrintToChat(client, "%s Your PUG invite has expired.", g_tag);
			PrintToChat(client, "You can type !unpug to leave the queue, or wait for the next match.");
		}
		return Plugin_Stop;
	}
	
	g_pugInviteTimer[client]--;
	Client_InviteToPug(client);
	
	return Plugin_Continue;
}

void PrintToPuggers(const String:message[], any ...)
{
	PrintToServer("PrintToPuggers()");
	decl String:formatMsg[512];
	VFormat(formatMsg, sizeof(formatMsg), message, 2);
	
	for (new i = 1; i < MaxClients; i++)
	{
		if (!g_isPugging[i])
			continue;
		
		PrintToChat(i, formatMsg);
	}
}

int Database_GetServerCount(bool:onlyAvailableServers = false)
{
	Database_Initialize();
	
	decl String:error[256];
	decl String:sql[128];
	
	Format(sql, sizeof(sql), "SELECT * FROM %s", g_sqlTable_Servers);
	
	new Handle:result = SQL_Query(db, sql);
	
	if (result == INVALID_HANDLE)
	{
		LogError(error);
		return 0;
	}
	
	new rows;
	
	if (!onlyAvailableServers)
	{
		rows = SQL_GetRowCount(result);
	}
	else
	{
		while (SQL_FetchRow(result))
		{
			new status = SQL_FetchInt(result, SERVER_STATUS);
			if (status == STATE_AVAILABLE)
				rows++;
		}
	}
	CloseHandle(result);
	
	return rows;
}

bool Servers_ReserveForPug()
{
	Database_Initialize();
	
	decl String:error[256];
	decl String:sql[128];
	
	Format(sql, sizeof(sql), "SELECT * FROM %s", g_sqlTable_Servers);
	
	new Handle:result = SQL_Query(db, sql);
	
	if (result == INVALID_HANDLE)
	{
		LogError(error);
		return false;
	}
	
	new foundRows = SQL_GetRowCount(result);
	decl String:serverInfo[foundRows][SERVER_ENUM_COUNT][64];
	
	new row;
	while (SQL_FetchRow(result))
	{
		SQL_FetchString(result, SERVER_ID, serverInfo[row][SERVER_ID], 64);
		SQL_FetchString(result, SERVER_HOSTNAME, serverInfo[row][SERVER_HOSTNAME], 64);
		SQL_FetchString(result, SERVER_NAME, serverInfo[row][SERVER_NAME], 64);
		SQL_FetchString(result, SERVER_STATUS, serverInfo[row][SERVER_STATUS], 64);
		SQL_FetchString(result, SERVER_PASSWORD, serverInfo[row][SERVER_PASSWORD], 64);
		row++;
	}
	
	CloseHandle(result);
	
	for (new i = 0; i < foundRows; i++)
	{
		PrintToServer("Server index %i:\tid:%s\thost:%s\tname:%s\tstatus:%s\tpassword:%s", i, serverInfo[i][SERVER_ID], serverInfo[i][SERVER_HOSTNAME], serverInfo[i][SERVER_NAME], serverInfo[i][SERVER_STATUS], serverInfo[i][SERVER_PASSWORD]);
	}
	
	for (new i = 0; i < foundRows; i++)
	{
		// Found an available pug server
		if (StringToInt(serverInfo[i][SERVER_STATUS]) == STATE_AVAILABLE)
		{
			// Store pug server info to global var for inviting clients
			for (new j = 0; j < sizeof(g_reservedServer); j++)
			{
				strcopy(g_reservedServer[j], sizeof(g_reservedServer[]), serverInfo[i][j]);
			}
			return true;
		}
	}
	
	return false;
}

void PlayInviteSound(client)
{
	new burstAmount = 8;					// How many sound bursts to play
	new soundsPerBurst = 3;				// How many notes make a burst
	new Float:burstDelay = 0.4;			// How long to wait between bursts
	new Float:burstIncrement = 0.05;	// How long should burst increments be
	
	new Float:timer;
	new Float:increment;
	for (new i = 0; i < burstAmount; i++)
	{
		timer += burstDelay;
		
		for (new j = 0; j < soundsPerBurst; j++)
		{
			CreateTimer(timer + increment, Timer_InviteSound, client);
			increment += burstIncrement;
		}
	}
}

public Action:Timer_InviteSound(Handle:timer, any:client)
{
	new const String:inviteSound[] = "buttons/button17.wav";
	PrecacheSound(inviteSound);
	
	new Float:volume	= 1.0;	// Volume between 0.0 - 1.0 (original volume is 1.0)
	new pitch				= 175;	// Pitch between 0 - 255 (original pitch is 100)
	
	EmitSoundToClient(client, inviteSound, _, _, _, _, volume, pitch);
}