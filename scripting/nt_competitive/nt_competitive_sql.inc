// Double-include prevention
#if defined _sql_included_
	#endinput
#endif
#define _sql_included_

bool Database_Initialize(bool checkTables = true)
{
	//PrintDebug("Database_Initialize()");

	decl String:configName[MAX_CVAR_LENGTH];
	GetConVarString(g_hCvar_DbConfig, configName, sizeof(configName));
	if (!SQL_CheckConfig(configName))
	{
		g_bIsDatabaseDown = true;
		LogError("Database_Initialize: Could not find a config named \"%s\". \
		Please check your databases.cfg", configName);
		return false;
	}

	// Persistent connection
	decl String:error[MAX_SQL_ERROR_LENGTH];
	g_hDB = SQL_Connect(configName, true, error, sizeof(error));

	if (g_hDB == null)
	{
		g_bIsDatabaseDown = true;
		LogError("Database_Initialize: %s", error);
		return false;
	}

	if (checkTables && !Database_DoTablesExist())
	{
		g_bIsDatabaseDown = true;
		LogError("Database_Initialize: Database tables do not exist.");
		return false;
	}

	g_bIsDatabaseDown = false;
	return true;
}

// Purpose: Check string for "dangerous" SQL characters
// that could lead to incorrect database statements.
// Not intended for user input checking.
void CheckForSpookiness(const String:haystack[])
{
	if (StrContains(haystack, "\"") != -1 || StrContains(haystack, ";") != -1)
	{
		SetFailState("Found potentially dangerous characters \" or ; \
inside the plugin's SQL string, which could result to \
incorrect SQL statements. Check your plugin source code for errors. \
String contents: \"%s\"", haystack);
	}
}

int Database_GetRowCountForTableName(const String:tableName[], bool checkTablesValidity = true)
{
	CheckForSpookiness(tableName);
	Database_Initialize(checkTablesValidity);

	// We only want to throw error if table creation isn't currently happening
	if (!checkTablesValidity && !Database_DoTablesExist())
		return 0;

	decl String:sql[MAX_SQL_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s", tableName);
	new Handle:query = SQL_Query(g_hDB, sql);
	new rows = SQL_GetRowCount(query);

	CloseHandle(query);
	return rows;
}

bool Database_RemovePugger(const char[] steamID)
{
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "DELETE FROM %s WHERE %s = ?",
	g_sqlTable[TABLES_PUGGERS], g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID]);

	new Handle:stmt_Delete = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt_Delete == INVALID_HANDLE)
	{
		LogError(error);
		return false;
	}

	SQL_BindParamString(stmt_Delete, 0, steamID, false);
	SQL_Execute(stmt_Delete);
	CloseHandle(stmt_Delete);
	return true;
}

#if defined PLUGIN_PUG
void Pugger_Remove(client = 0, bool bySteamID = false, String:steamID[MAX_STEAMID_LENGTH] = "")
{
	// Make sure client index is valid,
	// unless removing player directly with SteamID instead
	if (!bySteamID)
	{
		if (!IsValidClient(client) || IsFakeClient(client))
			ThrowError("Invalid client %i", client);

		if (!GetClientAuthId(client, AuthId_Steam2, steamID, sizeof(steamID)))
			ThrowError("Could not fetch SteamID for client %i", client);
	}

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE steamid = ?",
	g_sqlTable[TABLES_PUGGERS]);

	new Handle:stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == INVALID_HANDLE)
		ThrowError(error);

	PrintDebug("Perceived SteamID: %s", steamID);

	SQL_BindParamString(stmt, 0, steamID, false);
	SQL_Execute(stmt);

	new results = SQL_GetRowCount(stmt);
	new state;

	if (results > 1)
	{
		LogError("Pugger_Remove: Found %i results for SteamID \"%s\" \
		in database, expected to find 1. Deleting duplicates.", results, steamID);

		if (!Database_RemovePugger(steamID))
		{
			CloseHandle(stmt);
			ThrowError("Failed removing pugger.");
		}
	}
	if (results > 1 || results == 0)
	{
		if (results == 0)
		{
			LogError("Pugger_Remove: Found 0 results for SteamID \"%s\" \
in database, inserting a row with PUGGER_STATE_INACTIVE", steamID);
		}

		Format(sql, sizeof(sql), "INSERT INTO %s (%s, %s) VALUES (?, ?)",
		g_sqlTable[TABLES_PUGGERS],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE]);

		new Handle:stmt_Insert = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
		if (stmt_Insert == INVALID_HANDLE)
		{
			CloseHandle(stmt);
			ThrowError(error);
		}

		new paramIndex;
		SQL_BindParamString(stmt_Insert, paramIndex++, steamID, false);
		SQL_BindParamInt(stmt_Insert, paramIndex++, PUGGER_STATE_INACTIVE);
		SQL_Execute(stmt_Insert);
		CloseHandle(stmt_Insert);
	}
	else if (results == 1)
	{
		// Client is on this server, respond to them accordingly
		if (!bySteamID)
		{
			while (SQL_FetchRow(stmt))
			{
				state = SQL_FetchInt(stmt, SQL_TABLE_PUGGER_STATE);

				if (state == PUGGER_STATE_INACTIVE)
				{
					ReplyToCommand(client, "%s You are not in a PUG queue.", g_sTag);
					CloseHandle(stmt);
					return;
				}
				else if (state == PUGGER_STATE_QUEUING)
				{
					ReplyToCommand(client, "%s You have left the PUG queue.", g_sTag);
				}
				else if (state == PUGGER_STATE_CONFIRMING)
				{
					ReplyToCommand(client, "%s You have left the PUG queue. \
					Declining offered match.", g_sTag);
				}
				else if (state == PUGGER_STATE_ACCEPTED)
				{
					ReplyToCommand(client, "%s You have already accepted this match.", g_sTag);
					CloseHandle(stmt);
					return;
				}
				else if (state == PUGGER_STATE_LIVE)
				{
					ReplyToCommand(client, "%s You already have a match live!", g_sTag);
					CloseHandle(stmt);
					return;
				}
				else
				{
					LogError("Pugger_Remove(): Pugger state for \"%s\" returned %i. \
This should never happen.", steamID, state);
				}
			}
		}
		CloseHandle(stmt);

		Pugger_SetQueuingState(client, PUGGER_STATE_INACTIVE, bySteamID, steamID);
	}

	// This needs to be done after the player is removed from active PUG queue
	if (state == PUGGER_STATE_CONFIRMING)
	{
		// Give up current invite, move accepted players back in queue
		Database_GiveUpMatch(true, steamID);
		Database_LogIgnore(client);
		Pugger_CloseMatchOfferMenu(client);

		// Try to find a new match
		FindNewMatch();
	}
}
#endif

bool Database_AddPugger(client = 0, bool bySteamID = false, const char[] steamID = "", state = PUGGER_STATE_QUEUING)
{
	if (!bySteamID)
	{
		if (!IsValidClient(client) || IsFakeClient(client))
			ThrowError("Invalid client %i", client);
	}
	if (state < 0 || state >= PUGGER_STATE_ENUM_COUNT)
	{
		ThrowError("Invalid state enum %i, expected value in range 0 - %i",
			state, PUGGER_STATE_ENUM_COUNT-1);
	}

	decl String:steamIDBuffer[MAX_STEAMID_LENGTH];
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	if (!bySteamID)
		GetClientAuthId(client, AuthId_Steam2, steamIDBuffer, sizeof(steamIDBuffer));
	else
		strcopy(steamIDBuffer, sizeof(steamIDBuffer), steamID);

	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE steamid = ?",
	g_sqlTable[TABLES_PUGGERS]);

	new Handle:stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == INVALID_HANDLE)
		ThrowError(error); // TODO: fail gracefully

	SQL_BindParamString(stmt, 0, steamIDBuffer, false);
	SQL_Execute(stmt);

	// Pugger exists in database, update
	if (SQL_GetRowCount(stmt) > 0)
	{
		while (SQL_FetchRow(stmt))
		{
			Format(sql, sizeof(sql), "UPDATE %s SET %s = ?, %s = NOW() WHERE %s = ?",
			g_sqlTable[TABLES_PUGGERS],
			g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE],
			g_sqlRow_Puggers[SQL_TABLE_PUGGER_TIMESTAMP],
			g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID]);

			new Handle:updateStmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));

			new paramIndex;
			SQL_BindParamInt(updateStmt, paramIndex++, state);
			SQL_BindParamString(updateStmt, paramIndex++, steamIDBuffer, false);

			SQL_Execute(updateStmt);
			CloseHandle(updateStmt);

			if (SQL_MoreRows(stmt))
			{
				LogError("Database_AddPugger: Found more than 1 results for %s, \
expected 0 or 1", steamIDBuffer);
				break;
			}
		}
	}
	// Pugger not yet in database, insert
	else
	{
		Format(sql, sizeof(sql), "INSERT INTO %s (%s, %s, %s) VALUES (?, ?, NOW())",
		g_sqlTable[TABLES_PUGGERS],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_TIMESTAMP]);

		new Handle:insertStmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));

		new paramIndex;
		SQL_BindParamString(insertStmt, paramIndex++, steamIDBuffer, false);
		SQL_BindParamInt(insertStmt, paramIndex++, PUGGER_STATE_QUEUING);

		SQL_Execute(insertStmt);
		CloseHandle(insertStmt);
	}
	CloseHandle(stmt);
	return true;
}

#if defined PLUGIN_PUG
void Database_GiveUpMatch(bool:giveUpEarly = false, const String:quittingSteamID[MAX_STEAMID_LENGTH] = "")
{
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	Format(sql, sizeof(sql), "SELECT * FROM %s", g_sqlTable[TABLES_PUGGERS]);

	new Handle:stmt_SelectPuggers = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt_SelectPuggers == INVALID_HANDLE)
		ThrowError(error);

	SQL_Execute(stmt_SelectPuggers);

	while (SQL_FetchRow(stmt_SelectPuggers))
	{
		new state = SQL_FetchInt(stmt_SelectPuggers, SQL_TABLE_PUGGER_STATE);
		decl String:steamID[MAX_STEAMID_LENGTH];
		SQL_FetchString(stmt_SelectPuggers, SQL_TABLE_PUGGER_STEAMID, steamID, sizeof(steamID));

		PrintDebug("Handling %s with state %i", steamID, state);

		// Someone declined match invite early, we are including players who chose nothing
		if (giveUpEarly)
		{
			PrintDebug("giveUpEarly = true");

			if (state != PUGGER_STATE_ACCEPTED && state != PUGGER_STATE_CONFIRMING)
				continue;

			// This is the player who's declining the match
			if (StrEqual(steamID, quittingSteamID))
			{
				//PrintDebug("Found quitter");
				continue;
			}
		}
		// Invite time ran out, we are excluding players who chose nothing
		else
		{
			PrintDebug("giveUpEarly = false");

			if (state != PUGGER_STATE_ACCEPTED)
				continue;
		}

		PrintDebug("Giveup SteamID: %s", steamID);
		Format(sql, sizeof(sql), "UPDATE %s SET %s = ? WHERE %s = ?",
		g_sqlTable[TABLES_PUGGERS],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID]);

		new Handle:stmt_UpdatePuggers = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
		if (stmt_UpdatePuggers == INVALID_HANDLE)
		{
			CloseHandle(stmt_SelectPuggers);
			ThrowError(error);
		}

		new paramIndex;
		SQL_BindParamInt(stmt_UpdatePuggers, paramIndex++, PUGGER_STATE_QUEUING);
		SQL_BindParamString(stmt_UpdatePuggers, paramIndex++, steamID, false);
		SQL_Execute(stmt_UpdatePuggers);

		CloseHandle(stmt_UpdatePuggers);

		Pugger_ShowMatchFail(steamID);
	}
	CloseHandle(stmt_SelectPuggers);

	Format(sql, sizeof(sql), "UPDATE %s SET %s = ? WHERE %s = ?",
	g_sqlTable[TABLES_PUG_SERVERS],
	g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_STATUS],
	g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_STATUS]);

	PrintDebug("SQL: %s", sql);

	new Handle:stmt_SelectPugServers = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt_SelectPugServers == INVALID_HANDLE)
		ThrowError(error);

	new paramIndex;
	SQL_BindParamInt(stmt_SelectPugServers, paramIndex++, PUG_SERVER_STATUS_AVAILABLE);
	SQL_BindParamInt(stmt_SelectPugServers, paramIndex++, PUG_SERVER_STATUS_RESERVED);
	SQL_Execute(stmt_SelectPugServers);

	CloseHandle(stmt_SelectPugServers);

	Organizers_Update_This();
}
#endif

#if defined PLUGIN_PUG
void Database_LogIgnore(client)
{
	//TODO
	PrintDebug("Database_LogIgnore(%i)", client);
}

void Database_CleanAFKers()
{
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ?",
	g_sqlTable[TABLES_PUGGERS],
	g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE]);

	new Handle:stmt_CleanAfkers = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt_CleanAfkers == INVALID_HANDLE)
		ThrowError(error);

	SQL_BindParamInt(stmt_CleanAfkers, 0, PUGGER_STATE_CONFIRMING);
	SQL_Execute(stmt_CleanAfkers);

	while (SQL_FetchRow(stmt_CleanAfkers))
	{
		decl String:steamID[MAX_STEAMID_LENGTH];
		SQL_FetchString(stmt_CleanAfkers, SQL_TABLE_PUGGER_STEAMID, steamID,
			sizeof(steamID));

		PrintDebug("Cleaning SteamID: %s", steamID);
		Pugger_Remove(_, true, steamID);
	}
	CloseHandle(stmt_CleanAfkers);
}
#endif

#if defined PLUGIN_COMP
bool PugServer_Update_This()
{
	if (g_bIsDatabaseDown)
		return false;

	// Get PUG server IP address
	decl String:sIP[MAX_IP_LENGTH];
	GetCvarValue("ip", VAR_TYPE_STRING, sIP, sizeof(sIP)); /*
	new Handle:hIP = FindConVar("ip");
	if (hIP == INVALID_HANDLE)
		SetFailState("Could not find server cvar \"ip\"");
	decl String:sIP[MAX_IP_LENGTH];
	GetConVarString(hIP, sIP, sizeof(sIP));
	CloseHandle(hIP);*/

	// Get PUG server port number
	new iPort = GetCvarValue("hostport", VAR_TYPE_INT);/*
	new Handle:hPort = FindConVar("hostport");
	if (hPort == INVALID_HANDLE)
		SetFailState("Could not find server cvar \"hostport\"");
	new iPort = GetConVarInt(hPort);
	CloseHandle(hPort);*/

	// Get PUG server password
	decl String:sPassword[MAX_CVAR_LENGTH];
	GetCvarValue("sv_password", VAR_TYPE_STRING, sPassword, sizeof(sPassword)); /*
	new Handle:hPassword = FindConVar("sv_password");
	if (hPassword == INVALID_HANDLE)
		SetFailState("Could not find server cvar \"sv_password\"");
	decl String:sPassword[MAX_CVAR_LENGTH];
	GetConVarString(hPassword, sPassword, sizeof(sPassword));
	CloseHandle(hPassword);*/

	// Get PUG server vanity name
	decl String:sServerName[MAX_CVAR_LENGTH];
	GetCvarValue("hostname", VAR_TYPE_STRING, sServerName, sizeof(sServerName)); /*
	new Handle:hServerName = FindConVar("hostname");
	if (hServerName == INVALID_HANDLE)
		SetFailState("Could not find server cvar \"hostname\"");
	decl String:sServerName[MAX_CVAR_LENGTH];
	GetConVarString(hServerName, sServerName, sizeof(sServerName));
	CloseHandle(hServerName);*/

	new iStatus = PugServer_Get_Status(sIP, iPort);

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ? AND %s = ?",
		g_sqlTable[TABLES_PUG_SERVERS],
		g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_IP],
		g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_PORT]);

	new Handle:stmt_RowCount = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt_RowCount == INVALID_HANDLE)
	{
		LogError("PugServer_Update_This: %s", error);
		LogError("SQL was:\n%s", sql);
		return false;
	}

	new paramIndex;
	SQL_BindParamString(stmt_RowCount, paramIndex++, sIP, false);
	SQL_BindParamInt(stmt_RowCount, paramIndex++, iPort);
	SQL_Execute(stmt_RowCount);

	new rowCount = SQL_GetRowCount(stmt_RowCount);
	CloseHandle(stmt_RowCount);

	new Handle:stmt_ServerUpdate = INVALID_HANDLE;

	// Server is not in database, insert
	if (rowCount == 0)
	{
		Format(sql, sizeof(sql), "INSERT INTO %s (%s, %s, %s, %s, %s)\
			VALUES (?, ?, ?, ?, ?)",
			g_sqlTable[TABLES_PUG_SERVERS],
			g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_IP],
			g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_PORT],
			g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_PASSWORD],
			g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_NAME],
			g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_STATUS]);
	}
	else if (rowCount == 1)
	{
		Format(sql, sizeof(sql), "UPDATE %s SET %s = ?, %s = ?, %s = ?, %s = ?, %s = ?",
			g_sqlTable[TABLES_PUG_SERVERS],
			g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_IP],
			g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_PORT],
			g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_PASSWORD],
			g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_NAME],
			g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_STATUS]);
	}
	else
	{
		LogError("PugServer_Update_This: Found %i rows matching this server \
(%s %s:%i), expected to find 1 or 0.", rowCount, sServerName, sIP, iPort);
		return false;
	}

	stmt_ServerUpdate = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt_ServerUpdate == INVALID_HANDLE)
	{
		LogError("PugServer_Update_This: %s", error);
		LogError("SQL was:\n%s", sql);
		return false;
	}

	paramIndex = 0;
	SQL_BindParamString	(stmt_ServerUpdate, paramIndex++, sIP, false);
	SQL_BindParamInt		(stmt_ServerUpdate, paramIndex++, iPort);
	SQL_BindParamString	(stmt_ServerUpdate, paramIndex++, sPassword, false);
	SQL_BindParamString	(stmt_ServerUpdate, paramIndex++, sServerName, false);
	SQL_BindParamInt		(stmt_ServerUpdate, paramIndex++, iStatus);

	SQL_Execute(stmt_ServerUpdate);
#if DEBUG_SQL
	PrintDebug("PugServer_Update_This: Affected rows: %i",
		SQL_GetAffectedRows(stmt_ServerUpdate));
#endif
	CloseHandle(stmt_ServerUpdate);

	return true;
}

bool PugServer_Set_Status(status, String:sIPAddress[MAX_IP_LENGTH], iPort)
{
	if (status < PUG_SERVER_STATUS_ERROR || status >= PUG_SERVER_STATUS_ENUM_COUNT)
	{
		ThrowError("Invalid enum %i, expected enum between %i - %i",
			status, PUG_SERVER_STATUS_ERROR, PUG_SERVER_STATUS_ENUM_COUNT);
	}

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "UPDATE %s SET %s = ? WHERE %s = ? AND %s = ?",
		g_sqlTable[TABLES_PUG_SERVERS],
		g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_STATUS],
		g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_IP],
		g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_PORT]);

	new Handle:stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == INVALID_HANDLE)
		ThrowError(error);

	new paramIndex;
	SQL_BindParamInt(stmt, paramIndex++, status);
	SQL_BindParamString(stmt, paramIndex++, sIPAddress, false);
	SQL_BindParamInt(stmt, paramIndex++, iPort);
	SQL_Execute(stmt);

	CloseHandle(stmt);
	return true;
}

bool PugServer_MatchState_Set(const int match_id, const int state)
{
	if (state < 0 || state > MATCHMAKE_ENUM_COUNT)
	{
		LogError("Invalid state %i, expected value between 0 - %i",
			MATCHMAKE_ENUM_COUNT);
		return false;
	}

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "UPDATE %s SET %s = ? WHERE %s = ?",
		g_sqlTable[TABLES_MATCHES],
		g_sqlRow_Matches[SQL_TABLE_MATCHES_STATUS],
		g_sqlRow_Matches[SQL_TABLE_MATCHES_ID]
	);

	Handle stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == null)
	{
		LogError("PugServer_MatchState_Set: %s, SQL: %s", error, sql);
		return false;
	}

	SQL_BindParamInt(stmt, 0, state);
	SQL_BindParamInt(stmt, 1, match_id);
	SQL_Execute(stmt);
	delete stmt;

	return true;
}
#endif

bool Database_MatchExists(const int match_id)
{
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ?",
		g_sqlTable[TABLES_MATCHES],
		g_sqlRow_Matches[SQL_TABLE_MATCHES_ID]
	);
	Handle stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == null)
	{
		LogError("Database_MatchExists: %s", error);
		return false;
	}
	SQL_BindParamInt(stmt, 0, match_id);
	SQL_Execute(stmt);
	if (!SQL_HasResultSet(stmt))
	{
		delete stmt;
		return false;
	}
	int rows = SQL_GetRowCount(stmt);
	delete stmt;
	if (rows == 0)
	{
		return false;
	}
	else if (rows > 1)
	{
		LogError("Database_MatchExists: %i matches matched match_id %i, \
expected 0 or 1.", rows, match_id);
	}
	return true;
}

#if defined PLUGIN_COMP
// Purpose: Create a new match, and assign players to it.
// Returns matchid on success, INVALID_MATCH_ID on failure.
int PugServer_CreateMatch(int numPlayers, bool ignoreGlobalDesiredPlayerCount = false)
{
	if (!ignoreGlobalDesiredPlayerCount)
	{
		if (numPlayers != Database_GetDesiredPlayerCount())
			return INVALID_MATCH_ID;
	}

	decl String:ipAddress[MAX_IP_LENGTH];
	int port;
	GetServerConnectionDetails(ipAddress, port);

	int currentStatus = PugServer_Get_Status(ipAddress, port);
	if (currentStatus != PUG_SERVER_STATUS_AVAILABLE)
	{
		LogError("PugServer_CreateMatch: Tried creating new match while server is not free! \
Pug server returns status %i, expected PUG_SERVER_STATUS_AVAILABLE (%i)",
currentStatus, PUG_SERVER_STATUS_AVAILABLE);
		return INVALID_MATCH_ID;
	}

	// Mark this server as reserved
	if (!PugServer_Set_Status(PUG_SERVER_STATUS_RESERVED, ipAddress, port))
	{
		LogError("PugServer_CreateMatch: Failed to set pug server status %i",
			PUG_SERVER_STATUS_RESERVED);
		return INVALID_MATCH_ID;
	}

	// Get all the information needed
	// to create a match entry to db.
	char matchVanityTitle[MAX_CVAR_LENGTH];
	GetConVarString(g_hCompetitionName, matchVanityTitle, sizeof(matchVanityTitle));

	Handle hCvar_Hostname = FindConVar("hostname");
	if (hCvar_Hostname == null)
		ThrowError("Failed to get server cvar \"hostname\"");

	char serverVanityTitle[MAX_CVAR_LENGTH];
	GetConVarString(hCvar_Hostname, serverVanityTitle, sizeof(serverVanityTitle));
	delete hCvar_Hostname;

	char serverPassword[MAX_CVAR_LENGTH];
	GetConVarString(g_hPassword, serverPassword, sizeof(serverPassword));

	// SQL for match insertion
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql),
		"INSERT INTO %s (%s,%s,%s,%s,%s,%s,%s,%s) VALUES (?,?,?,?,?,?,?,?)",
		g_sqlTable[TABLES_MATCHES],
		g_sqlRow_Matches[SQL_TABLE_MATCHES_VANITY_TITLE],
		g_sqlRow_Matches[SQL_TABLE_MATCHES_HOST_IP],
		g_sqlRow_Matches[SQL_TABLE_MATCHES_HOST_PORT],
		g_sqlRow_Matches[SQL_TABLE_MATCHES_HOST_VANITY_NAME],
		g_sqlRow_Matches[SQL_TABLE_MATCHES_MATCH_PASSWORD],
		g_sqlRow_Matches[SQL_TABLE_MATCHES_MATCH_TYPE],
		g_sqlRow_Matches[SQL_TABLE_MATCHES_STATUS],
		g_sqlRow_Matches[SQL_TABLE_MATCHES_PLAYER_COUNT],
		g_sqlRow_Matches[SQL_TABLE_MATCHES_ID]
	);

	Handle stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == null)
		ThrowError("%s, SQL: %s", error, sql);

	int paramIndex;
	SQL_BindParamString(stmt, paramIndex++, matchVanityTitle, false);
	SQL_BindParamString(stmt, paramIndex++, ipAddress, false);
	SQL_BindParamInt(stmt, paramIndex++, port);
	SQL_BindParamString(stmt, paramIndex++, serverVanityTitle, false);
	SQL_BindParamString(stmt, paramIndex++, serverPassword, false);
	SQL_BindParamInt(stmt, paramIndex++, MATCH_TYPE_PUG);
	SQL_BindParamInt(stmt, paramIndex++, MATCHMAKE_INVITING);
	SQL_BindParamInt(stmt, paramIndex++, numPlayers);
	SQL_Execute(stmt);
	delete stmt;

	SetMatchStatus(MATCHMAKE_INVITING);

	DBResultSet result = SQL_Query(g_hDB, "SELECT LAST_INSERT_ID()");
	if (result == null || !SQL_HasResultSet(result))
	{
		if (result != null)
			delete result;
		LogError("PugServer_CreateMatch: SQL statement has no result set.");
		return INVALID_MATCH_ID;
	}
	int rows;
	int match_id = 0;
	while (SQL_FetchRow(result))
	{
		rows++;
		if (rows > 1)
		{
			LogError("PugServer_CreateMatch: \
SQL statement returned multiple results; SQL: %s", sql);
			delete result;
			return INVALID_MATCH_ID;
		}
		match_id = SQL_FetchInt(result, SQL_TABLE_MATCHES_ID);
	}
	delete result;
	// Could not invite players to this match for whatever reason.
	// Mark match as cancelled (TODO) and make this server available again.
	if (!PugServer_InvitePlayers(match_id, numPlayers))
	{
		//CancelMatch(match_id); // TODO
		PugServer_Set_Status(PUG_SERVER_STATUS_AVAILABLE, ipAddress, port);
		return INVALID_MATCH_ID;
	}
	g_iMatchID_cached = match_id;
	return match_id;
}

void Puggers_UpdateStateByMatchID(int matchid, int newState)
{
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "UPDATE %s SET %s = ? WHERE %s = ? AND NOT %s = ?",
		g_sqlTable[TABLES_PUGGERS],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_MATCH_ID],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE]
	);

	Handle stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == null)
		ThrowError(error);

	int paramIndex;
	SQL_BindParamInt(stmt, paramIndex++, newState);
	SQL_BindParamInt(stmt, paramIndex++, matchid);
	SQL_BindParamInt(stmt, paramIndex++, PUGGER_STATE_ABANDONED);
	SQL_Execute(stmt);
	delete stmt;
}

void Match_Cancel(int matchid, bool dequeueInactive = false)
{
	// Got here by trying to find a replacement player for someone
	// who abandoned an already live match. Don't stop the ongoing match.
	if (g_bPugAlreadyPlaying)
		return;

	Handle stmt = null;
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	int paramIndex;
	// Remove puggers who never accepted their invite from the active queue
	if (dequeueInactive)
	{
		Format(sql, sizeof(sql), "UPDATE %s SET %s = ? WHERE %s = ? AND %s = ?",
			g_sqlTable[TABLES_PUGGERS],
			g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE],
			g_sqlRow_Puggers[SQL_TABLE_PUGGER_MATCH_ID],
			g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE]
		);
		stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
		if (stmt == null)
		{
			LogError(error);
			return;
		}
		paramIndex = 0;
		SQL_BindParamInt(stmt, paramIndex++, PUGGER_STATE_INACTIVE);
		SQL_BindParamInt(stmt, paramIndex++, matchid);
		SQL_BindParamInt(stmt, paramIndex++, PUGGER_STATE_CONFIRMING);
		SQL_Execute(stmt);
		delete stmt;
	}
	// Returns match puggers to the queue
	Format(sql, sizeof(sql), "UPDATE %s SET %s = ? WHERE %s = ? AND NOT %s = ?",
		g_sqlTable[TABLES_PUGGERS],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_MATCH_ID],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE]
	);
	stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == null)
	{
		LogError(error);
		return;
	}
	paramIndex = 0;
	SQL_BindParamInt(stmt, paramIndex++, PUGGER_STATE_QUEUING);
	SQL_BindParamInt(stmt, paramIndex++, matchid);
	SQL_BindParamInt(stmt, paramIndex++, PUGGER_STATE_INACTIVE);
	SQL_Execute(stmt);
	delete stmt;

	// Mark the match as cancelled
	SetMatchStatus(MATCHMAKE_CANCELLED);

	Format(sql, sizeof(sql), "UPDATE %s SET %s = ? WHERE %s = ?",
		g_sqlTable[TABLES_MATCHES],
		g_sqlRow_Matches[SQL_TABLE_MATCHES_STATUS],
		g_sqlRow_Matches[SQL_TABLE_MATCHES_ID]
	);
	stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == null)
	{
		LogError(error);
		return;
	}
	SQL_BindParamInt(stmt, 0, MATCHMAKE_CANCELLED);
	SQL_BindParamInt(stmt, 1, matchid);
	SQL_Execute(stmt);
	delete stmt;

	decl String:ipAddress[MAX_IP_LENGTH];
	int port;
	GetServerConnectionDetails(ipAddress, port);
	PugServer_Set_Status(PUG_SERVER_STATUS_AVAILABLE, ipAddress, port);
}
#endif

void Pugger_DisplayDbMessage(int client)
{
	if (!IsValidClient(client) || IsFakeClient(client) || !IsClientAuthorized(client))
		return;

	//PrintToChat(client, "Pugger_DisplayDbMessage");

	decl String:steamid[MAX_STEAMID_LENGTH];
	GetClientAuthId(client, AuthId_Steam2, steamid, sizeof(steamid));

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ? AND %s = 1",
		g_sqlTable[TABLES_PUGGERS],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_HAS_MATCH_MSG]
	);

	Handle stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == null)
		ThrowError(error);

	SQL_BindParamString(stmt, 0, steamid, false);
	SQL_Execute(stmt);

	int hasMsg;
	decl String:dbMsg[512];
	if (SQL_HasResultSet(stmt))
	{
		while (SQL_FetchRow(stmt))
		{
			hasMsg = SQL_FetchInt(stmt, SQL_TABLE_PUGGER_HAS_MATCH_MSG);
			if (hasMsg)
			{
				SQL_FetchString(stmt, SQL_TABLE_PUGGER_MATCH_MSG, dbMsg, sizeof(dbMsg));
			}
		}
	}
	delete stmt;

	if (!hasMsg)
		return;

	PrintToChat(client, "%s System message: %s", g_sTag, dbMsg);
	PrintToConsole(client, "%s System message: %s", g_sTag, dbMsg);

	Format(sql, sizeof(sql), "UPDATE %s SET %s = 0 WHERE %s = ?",
		g_sqlTable[TABLES_PUGGERS],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_HAS_MATCH_MSG],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID]
	);
	stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == null)
		ThrowError(error);

	SQL_BindParamString(stmt, 0, steamid, false);
	SQL_Execute(stmt);
	delete stmt;
}

#if defined PLUGIN_COMP
void Puggers_CommitAbandoned(int matchid)
{
	if (matchid == INVALID_MATCH_ID)
		ThrowError("Invalid match ID %i", INVALID_MATCH_ID);

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "UPDATE %s SET %s = ?, %s = ?, %s = ? \
WHERE %s = ? AND %s = ?",
		g_sqlTable[TABLES_PUGGERS],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_MATCH_MSG],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_HAS_MATCH_MSG],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_MATCH_ID]
	);

	Handle stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == null)
		ThrowError(error);

	new const String:nagMsg[] = "You abandoned your last match. \
Please poke Rain if you think this is an error.";

	int paramIndex;
	SQL_BindParamInt(stmt, paramIndex++, PUGGER_STATE_ABANDONED);
	SQL_BindParamString(stmt, paramIndex++, nagMsg, false);
	SQL_BindParamInt(stmt, paramIndex++, 1);
	SQL_BindParamInt(stmt, paramIndex++, matchid);
	SQL_BindParamInt(stmt, paramIndex++, PUGGER_STATE_MIA);
	SQL_Execute(stmt);
	delete stmt;
}

bool PugServer_InvitePlayers(const int match_id, const int numPlayers)
{
	// Get all players who are queuing
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ?",
		g_sqlTable[TABLES_PUGGERS],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE]
	);

	Handle stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == null)
		ThrowError(error);
	SQL_BindParamInt(stmt, 0, PUGGER_STATE_QUEUING);
	SQL_Execute(stmt);
	// There were no players queuing, this is an error
	if (!SQL_HasResultSet(stmt))
	{
		LogError("AssignPlayers: SQL has no result set; SQL: %s", sql);
		delete stmt;
		return false;
	}
	int results = SQL_GetRowCount(stmt);
	// There aren't enough players queuing, this is an error
	if (results < numPlayers)
	{
		//LogError("AssignPlayers: Not enough players to assign a match for!");
		delete stmt;
		return false;
	}
	// Loop through numPlayers players and grab SteamIDs to invite
	decl String:steamIDs[MAXPLAYERS+1][MAX_STEAMID_LENGTH];
	int i;
	for (i = 0; SQL_FetchRow(stmt); i++)
	{
		// done!
		if (i == numPlayers)
			break;

		SQL_FetchString(stmt, SQL_TABLE_PUGGER_STEAMID,
			steamIDs[i], sizeof(steamIDs[]));
	}
	delete stmt;
	// This should never happen
	if (i != numPlayers)
	{
		LogError("AssignPlayers: Failed fetching enough players for some reason. \
Loop i = %i, numPlayers = %i. SQL was: %s", i, numPlayers, sql);
		return false;
	}

	decl String:ipAddress[MAX_IP_LENGTH];
	int port;
	GetServerConnectionDetails(ipAddress, port);
	decl String:password[MAX_CVAR_LENGTH];
	GetConVarString(g_hPassword, password, sizeof(password));

	// Update players table to send offers for queuing players
	Format(sql, sizeof(sql), "UPDATE %s SET %s = ?, %s = ?, %s = ?, %s = ?, %s = ? \
WHERE %s = ?",
		g_sqlTable[TABLES_PUGGERS],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_MATCH_ID],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_GAMESERVER_CONNECT_IP],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_GAMESERVER_CONNECT_PORT],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_GAMESERVER_PASSWORD],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID]
	);
	for (i = 0; i < numPlayers; i++)
	{
		stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
		if (stmt == null)
			ThrowError(error);

		int paramIndex;
		SQL_BindParamInt(stmt, paramIndex++, PUGGER_STATE_CONFIRMING);
		SQL_BindParamInt(stmt, paramIndex++, match_id);
		SQL_BindParamString(stmt, paramIndex++, ipAddress, false);
		SQL_BindParamInt(stmt, paramIndex++, port);
		SQL_BindParamString(stmt, paramIndex++, password, false);
		SQL_BindParamString(stmt, paramIndex++, steamIDs[i], false);
		SQL_Execute(stmt);
		delete stmt;

		Puggers_LogMatchParticipation(match_id, steamIDs[i]);
	}
	return true;
}

bool Pugger_DoesPlayInMatch(const int match_id, const char[] steamID)
{
	PrintToServer("Does this even run?");
	if (!Database_MatchExists(match_id))
		return false;

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ? AND %s = ?",
		g_sqlTable[TABLES_MATCH_HISTORY],
		g_sqlRow_MatchHistory[SQL_TABLE_MATCH_HISTORY_MATCH_ID],
		g_sqlRow_MatchHistory[SQL_TABLE_MATCH_HISTORY_STEAMID]
	);
	PrintToServer("SQL: %s", sql);
	Handle stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == null)
	{
		LogError(error);
		return false;
	}
	SQL_BindParamInt(stmt, 0, match_id);
	SQL_BindParamString(stmt, 1, steamID, false);
	SQL_Execute(stmt);

	int rows;
	if (SQL_HasResultSet(stmt))
	{
		rows = SQL_GetRowCount(stmt);
	}
	delete stmt;

	if (rows == 0)
	{
		return false;
	}
	if (rows > 1)
	{
		LogError("Pugger_DoesPlayInMatch: \
Found multiple matches for match id %i and steamID %s.", match_id, steamID);
	}
	return true;
}

bool Puggers_LogMatchParticipation(const int match_id, const char[] steamID)
{
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ? AND %s = ?",
		g_sqlTable[TABLES_MATCH_HISTORY],
		g_sqlRow_MatchHistory[SQL_TABLE_MATCH_HISTORY_MATCH_ID],
		g_sqlRow_MatchHistory[SQL_TABLE_MATCH_HISTORY_STEAMID]
	);
	Handle stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == null)
	{
		LogError(error);
		return false;
	}
	SQL_BindParamInt(stmt, 0, match_id);
	SQL_BindParamString(stmt, 1, steamID, false);
	SQL_Execute(stmt);
	int rows;
	if (SQL_HasResultSet(stmt))
		rows = SQL_GetRowCount(stmt);
	delete stmt;

	if (rows == 0)
	{
		Format(sql, sizeof(sql), "INSERT INTO %s (%s, %s) VALUES (?, ?)",
			g_sqlTable[TABLES_MATCH_HISTORY],
			g_sqlRow_MatchHistory[SQL_TABLE_MATCH_HISTORY_MATCH_ID],
			g_sqlRow_MatchHistory[SQL_TABLE_MATCH_HISTORY_STEAMID]
		);
		stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
		if (stmt == null)
		{
			LogError(error);
			return false;
		}
		SQL_BindParamInt(stmt, 0, match_id);
		SQL_BindParamString(stmt, 1, steamID, false);
		SQL_Execute(stmt);
		delete stmt;
	}
	else
	{
		if (rows > 1)
		{
			LogError("Puggers_LogMatchParticipation: \
Found multiple matches for match id %i and steamID %s.", match_id, steamID);
		}
	}
	return true;
}

int PugServer_Get_Status_This()
{
	decl String:ipAddress[MAX_IP_LENGTH];
	int port;
	GetServerConnectionDetails(ipAddress, port);
	return PugServer_Get_Status(ipAddress, port);
}

// Purpose: Get PUG server's status enum
int PugServer_Get_Status(const String:sIP[], iPort)
{
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT %s FROM %s WHERE %s = ? AND %s = ?",
		g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_STATUS],
		g_sqlTable[TABLES_PUG_SERVERS],
		g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_IP],
		g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_PORT]);

	new Handle:stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == INVALID_HANDLE)
		ThrowError(error);

	new paramIndex;
	SQL_BindParamString(stmt, paramIndex++, sIP, false);
	SQL_BindParamInt(stmt, paramIndex++, iPort);
	SQL_Execute(stmt);

	new rows = SQL_GetRowCount(stmt);
	if (rows == 0)
	{
		CloseHandle(stmt);
		return PUG_SERVER_STATUS_ERROR;
	}
	else if (rows > 1)
	{
		LogError("PugServer_Get_Status: Server %s:%i has %i row entries in \
the database, expected 1 or 0.");
		CloseHandle(stmt);
		return PUG_SERVER_STATUS_ERROR;
	}

	new status;
	while (SQL_FetchRow(stmt))
	{
		status = SQL_FetchInt(stmt, 0);
	}
	CloseHandle(stmt);

	return status;
}
#endif

#if defined PLUGIN_COMP
// Purpose: Fetch this pug server's reserve status enum from db
int PugServer_GetReserve_This()
{
	if (g_bIsDatabaseDown)
	{
		ThrowError("Failed to connect to database.");
	}

	char ipAddress[MAX_IP_LENGTH];
	int port;
	if (!GetServerConnectionDetails(ipAddress, port))
	{
		ThrowError("Failed retrieving server IP and port information.");
	}

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ? AND %s = ?",
		g_sqlTable[TABLES_PUG_SERVERS],
		g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_IP],
		g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_PORT]);

	Handle stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == null)
	{
		ThrowError(error);
	}

	SQL_BindParamString(stmt, 0, ipAddress, false);
	SQL_BindParamInt(stmt, 1, port);
	SQL_Execute(stmt);

	int reserveStatus;
	int results;
	while (SQL_FetchRow(stmt))
	{
		results++;
		if (results > 1)
		{
			LogError("PugServer_SetReserve_This(): Found more than 1 db result for \
\"%s:%i\".", ipAddress, port);
			break;
		}
		reserveStatus = SQL_FetchInt(stmt, SQL_TABLE_PUG_SERVER_RESERVING);
	}
	delete stmt;

	return reserveStatus;
}

// Purpose: Update this pug server's reserve status enum in db
bool PugServer_SetReserve_This(int reserveStatus = DB_PUG_INACTIVE)
{
	if (g_bIsDatabaseDown)
		return false;

	// Only allow reserve state edit if releasing reservation
	// or if there is nobody else with a reservation active.
	bool includeMyself = true;
	if (reserveStatus != DB_PUG_INACTIVE &&
			PugServers_Is_Anyone_Busy(!includeMyself))
	{
		return false;
	}

	PrintDebug("PugServer_SetReserve_This(%i): No one else is busy, try set new status.",
		reserveStatus);

	if (reserveStatus < DB_PUG_INACTIVE || reserveStatus >= DB_PUG_ENUM_COUNT)
	{
		ThrowError("Invalid reserve status %i. Expected status between %i and %i",
			reserveStatus, DB_PUG_INACTIVE, DB_PUG_ENUM_COUNT-1);
	}

	char ipAddress[MAX_IP_LENGTH];
	int port;
	if (!GetServerConnectionDetails(ipAddress, port))
	{
		ThrowError("Failed retrieving server IP and port information.");
	}

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ? AND %s = ?",
		g_sqlTable[TABLES_PUG_SERVERS],
		g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_IP],
		g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_PORT]);

	Handle stmt_Select = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	SQL_BindParamString(stmt_Select, 0, ipAddress, false);
	SQL_BindParamInt(stmt_Select, 1, port);
	SQL_Execute(stmt_Select);

	if (stmt_Select == null)
		ThrowError(error);

	int results = SQL_GetRowCount(stmt_Select);
	delete stmt_Select;

	if (results > 1 || results == 0)
	{
		if (results > 1)
		{
			// Delete duplicate records
			LogError("PugServer_SetReserve_This(%i): Found %i results from database for \
			pug server \"%s:%i\", expected 0 or 1.",
				reserveStatus, results, ipAddress, port);

			Format(sql, sizeof(sql), "DELETE FROM %s WHERE %s = ? AND %i = ?",
				g_sqlTable[TABLES_PUG_SERVERS],
				g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_IP],
				g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_PORT]);

			new Handle:stmt_Delete = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
			if (stmt_Delete == INVALID_HANDLE)
				ThrowError(error);

			SQL_BindParamString(stmt_Delete, 0, ipAddress, false);
			SQL_BindParamInt(stmt_Delete, 1, port);
			SQL_Execute(stmt_Delete);
			CloseHandle(stmt_Delete);
		}
		// Insert new record
		Format(sql, sizeof(sql), "INSERT INTO %s (%s, %s, %s) VALUES (?, ?, ?)",
			g_sqlTable[TABLES_PUG_SERVERS],
			g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_IP],
			g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_PORT],
			g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_RESERVING]);

		new Handle:stmt_Insert = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
		if (stmt_Insert == INVALID_HANDLE)
			ThrowError(error);

		new paramIndex;
		SQL_BindParamString(stmt_Insert, paramIndex++, ipAddress, false);
		SQL_BindParamInt(stmt_Insert, paramIndex++, port);
		SQL_BindParamInt(stmt_Insert, paramIndex++, reserveStatus);
		SQL_Execute(stmt_Insert);
		CloseHandle(stmt_Insert);
		return true;
	}
	// Record already exists, just update
	else if (results == 1)
	{
		Format(sql, sizeof(sql), "UPDATE %s SET %s = ? WHERE %s = ? AND %s = ?",
			g_sqlTable[TABLES_PUG_SERVERS],
			g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_RESERVING],
			g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_IP],
			g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_PORT]);

		new Handle:stmt_Update = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
		if (stmt_Update == INVALID_HANDLE)
			ThrowError(error);

		new paramIndex;
		SQL_BindParamInt(stmt_Update, paramIndex++, reserveStatus);
		SQL_BindParamString(stmt_Update, paramIndex++, ipAddress, false);
		SQL_BindParamInt(stmt_Update, paramIndex++, port);
		SQL_Execute(stmt_Update);
		CloseHandle(stmt_Update);
		return true;
	}
	ThrowError("Something went wrong."); // should never happen
	return false;
}
#endif

#if defined PLUGIN_PUG
// Purpose: Update this org server's reserve status enum in db
bool Organizers_Update_This(reserveStatus = DB_ORG_INACTIVE)
{
	if (g_bIsDatabaseDown)
		return false;

	// Cannot set busy reserve status if someone else is already busy.
	// Server is always allowed to mark itself inactive.
	if (reserveStatus != DB_ORG_INACTIVE &&
			Organizers_Is_Anyone_Busy(false))
	{
		return false;
	}

	PrintDebug("Organizers_Update_This(%i): No one else is busy, try set new status.",
		reserveStatus);

	if (reserveStatus < DB_ORG_INACTIVE || reserveStatus >= DB_ORG_ENUM_COUNT)
	{
		ThrowError("Invalid reserve status %i. Expected status between %i and %i",
			reserveStatus, DB_ORG_INACTIVE, DB_ORG_ENUM_COUNT-1);
	}

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ?",
		g_sqlTable[TABLES_ORGANIZERS],
		g_sqlRow_Organizers[SQL_TABLE_ORG_NAME]);

	new Handle:stmt_Select = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	SQL_BindParamString(stmt_Select, 0, g_sIdentifier, false);
	SQL_Execute(stmt_Select);

	if (stmt_Select == INVALID_HANDLE)
		ThrowError(error);

	new results;
	if (SQL_HasResultSet(stmt_Select))
		results = SQL_GetRowCount(stmt_Select);
	CloseHandle(stmt_Select);

	if (results > 1)
	{
		// Delete duplicate records
		LogError("Organizers_Update_This(%i): Found %i results from database for \
		organizer \"%s\", expected 0 or 1.", reserveStatus, results, g_sIdentifier);

		Format(sql, sizeof(sql), "DELETE FROM %s WHERE %s = ?",
		g_sqlTable[TABLES_ORGANIZERS], g_sqlRow_Organizers[SQL_TABLE_ORG_NAME]);

		new Handle:stmt_Delete = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
		if (stmt_Delete == INVALID_HANDLE)
			ThrowError(error);

		SQL_BindParamString(stmt_Delete, 0, g_sIdentifier, false);
		SQL_Execute(stmt_Delete);
		CloseHandle(stmt_Delete);
	}
	if (results > 1 || results == 0)
	{
		// Insert new record
		Format(sql, sizeof(sql), "INSERT INTO %s (%s, %s) VALUES (?, ?)",
		g_sqlTable[TABLES_ORGANIZERS],
		g_sqlRow_Organizers[SQL_TABLE_ORG_NAME],
		g_sqlRow_Organizers[SQL_TABLE_ORG_RESERVING]);

		new Handle:stmt_Insert = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
		if (stmt_Insert == INVALID_HANDLE)
			ThrowError(error);

		new paramIndex;
		SQL_BindParamString(stmt_Insert, paramIndex++, g_sIdentifier, false);
		SQL_BindParamInt(stmt_Insert, paramIndex++, reserveStatus);
		SQL_Execute(stmt_Insert);
		CloseHandle(stmt_Insert);
		return true;
	}
	// Record already exists, just update
	else if (results == 1)
	{
		Format(sql, sizeof(sql), "UPDATE %s SET %s = ? WHERE %s = ?",
		g_sqlTable[TABLES_ORGANIZERS],
		g_sqlRow_Organizers[SQL_TABLE_ORG_RESERVING],
		g_sqlRow_Organizers[SQL_TABLE_ORG_NAME]);

		new Handle:stmt_Update = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
		if (stmt_Update == INVALID_HANDLE)
			ThrowError(error);

		new paramIndex;
		SQL_BindParamInt(stmt_Update, paramIndex++, reserveStatus);
		SQL_BindParamString(stmt_Update, paramIndex++, g_sIdentifier, false);
		SQL_Execute(stmt_Update);
		CloseHandle(stmt_Update);
		return true;
	}
	return false;
}
#endif

#if defined PLUGIN_COMP
bool PugServers_Is_Anyone_Busy(bool includeMyself = true)
{
	char ipAddress[MAX_IP_LENGTH];
	int port;
	if (!GetServerConnectionDetails(ipAddress, port))
	{
		ThrowError("Failed retrieving server IP and port information.");
	}

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s", g_sqlTable[TABLES_PUG_SERVERS]);

	// TODO: Unnecessary prepared statement, replace with error returning query
	Handle stmt_Select = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt_Select == null)
		ThrowError(error);

	SQL_Execute(stmt_Select);

	char ipBuffer[MAX_IP_LENGTH];
	int portBuffer;
	int dbState;
	if (!SQL_HasResultSet(stmt_Select))
	{
		delete stmt_Select;
		return false;
	}
	while (SQL_FetchRow(stmt_Select))
	{
		if (!includeMyself)
		{
			SQL_FetchString(stmt_Select, SQL_TABLE_PUG_SERVER_CONNECT_IP,
				ipBuffer, sizeof(ipBuffer));
			portBuffer = SQL_FetchInt(stmt_Select, SQL_TABLE_PUG_SERVER_CONNECT_PORT);

			if (strlen(ipBuffer) < 1)
			{
				ThrowError("Failed fetching ip address from database to compare against %s",
					ipAddress);
			}
			// Found this server, skip
			if (StrEqual(ipAddress, ipBuffer) && port == portBuffer)
			{
				continue;
			}
		}

		dbState = SQL_FetchInt(stmt_Select, SQL_TABLE_PUG_SERVER_RESERVING);
		if (dbState != DB_PUG_INACTIVE)
			return true;
	}
	delete stmt_Select;
	return false;
}
#endif

#if defined PLUGIN_PUG
bool Organizers_Is_Anyone_Busy(bool includeMyself = true)
{
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s", g_sqlTable[TABLES_ORGANIZERS]);

	// TODO: Unnecessary prepared statement, replace with error returning query
	new Handle:stmt_Select = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt_Select == INVALID_HANDLE)
		ThrowError(error);

	SQL_Execute(stmt_Select);

	decl String:identifier[sizeof(g_sIdentifier)];
	new dbState;
	while (SQL_FetchRow(stmt_Select))
	{
		if (!includeMyself)
		{
			SQL_FetchString(stmt_Select, SQL_TABLE_ORG_NAME, identifier, sizeof(identifier));
			if (StrEqual(identifier, g_sIdentifier))
				continue;
		}

		dbState = SQL_FetchInt(stmt_Select, SQL_TABLE_ORG_RESERVING);
		if (dbState != DB_ORG_INACTIVE)
			return true;
	}
	CloseHandle(stmt_Select);

	return false;
}

int Database_GetInviteTimeRemaining(const String:steamID[MAX_STEAMID_LENGTH])
{
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	Format(sql, sizeof(sql), "SELECT UNIX_TIMESTAMP(%s) FROM %s WHERE %s = ?",
	g_sqlRow_Puggers[SQL_TABLE_PUGGER_INVITE_TIMESTAMP],
	g_sqlTable[TABLES_PUGGERS],
	g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID]);

	new Handle:stmt_Select = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt_Select == INVALID_HANDLE)
		ThrowError(error);

	SQL_BindParamString(stmt_Select, 0, steamID, false);
	SQL_Execute(stmt_Select);

	new inviteEpoch;
	while (SQL_FetchRow(stmt_Select))
	{
		inviteEpoch = SQL_FetchInt(stmt_Select, 0);
	}
	CloseHandle(stmt_Select);

	new currentEpoch = Database_GetEpoch();
	new timeSinceInvite = currentEpoch - inviteEpoch;
	new timeRemaining = PUG_INVITE_TIME - timeSinceInvite;

	/*PrintDebug("Time since invite = %i - %i = %i",
	currentEpoch, inviteEpoch, timeSinceInvite);*/
	return timeRemaining;
}
#endif

#if DEBUG_SQL
// Create all the necessary tables in the database
// TODO: Always log this command to a logfile
public Action:Command_CreateTables(client, args)
{
	Database_CreateTables(client);
	return Plugin_Handled;
}

void Database_CreateTables(int client = 0)
{
	new rows;
	for (int i = 0; i < TABLES_ENUM_COUNT; i++)
	{
		rows += Database_GetRowCountForTableName(g_sqlTable[i], false);
	}
	PrintDebug("Command_CreateTables() rows: %i", rows);

	if (rows > 0)
	{
		if (IsValidClient(client))
		{
			ReplyToCommand(client, "%s Database returned %i already existing PUG rows!",
				g_sTag, rows);
			ReplyToCommand(client, "Make sure no PUG tables exist before running this \
	command.");
			ReplyToCommand(client, "No new tables were created by this command.");
		}
		ThrowError("Attempted to run Command_CreateTables while %i \
PUG rows already exist. Command was aborted. PUG plugin debug level: %i. \
SQL debug level: %i", rows, DEBUG, DEBUG_SQL);
	}

	Database_Initialize(false);
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	// Reversed array index for Format() order of operations
	new arrayIndex = SQL_TABLE_RULES_ENUM_COUNT-1;
	Format(sql, sizeof(sql), "CREATE TABLE IF NOT EXISTS %s ( \
									%s INT NOT NULL) \
									CHARACTER SET=utf8",
									g_sqlTable[TABLES_RULES],
									g_sqlRow_Rules[arrayIndex--]
	);
	if (!SQL_FastQuery(g_hDB, sql))
	{
		if (SQL_GetError(g_hDB, error, sizeof(error)))
			ThrowError(error);
		ThrowError("SQL query failed, but could not fetch error.");
	}

	Format(sql, sizeof(sql), "SELECT * from %s", g_sqlTable[TABLES_RULES]);
	Handle query_SelectRules = SQL_Query(g_hDB, sql);
	if (query_SelectRules == null)
	{
		if (SQL_GetError(g_hDB, error, sizeof(error)))
			ThrowError(error);
		ThrowError("SQL query failed, but could not fetch error.");
	}
	rows = SQL_GetRowCount(query_SelectRules);
	delete query_SelectRules;

	if (rows == 0)
	{
		int desiredPlayerCount = 10;
		Format(sql, sizeof(sql), "INSERT INTO %s (%s) VALUES (%i)",
			g_sqlTable[TABLES_RULES],
			g_sqlRow_Rules[SQL_TABLE_RULES_DESIRED_PLAYERCOUNT],
			desiredPlayerCount
		);
		if (!SQL_FastQuery(g_hDB, sql))
		{
			if (SQL_GetError(g_hDB, error, sizeof(error)))
				ThrowError(error);
			ThrowError("SQL query failed, but could not fetch error.");
		}
	}
	else if (rows > 1)
	{
		ThrowError("Too many rows (%i) in table \"%s\", expected 1 or 0.",
			rows, g_sqlTable[TABLES_RULES]);
	}

	// todo: optimise INT sizes
	// Reversed array index for Format() order of operations
	arrayIndex = SQL_TABLE_PUGGER_ENUM_COUNT-1;
	Format(sql, sizeof(sql), "CREATE TABLE IF NOT EXISTS %s ( \
%s INT NOT NULL AUTO_INCREMENT, \
%s TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, \
%s VARCHAR(%i) NOT NULL, \
%s INT NOT NULL, \
%s VARCHAR(45) NOT NULL, \
%s INT NOT NULL, \
%s VARCHAR(%i) NOT NULL, \
%s INT NOT NULL, \
%s TIMESTAMP NOT NULL, \
%s VARCHAR(128) NOT NULL, \
%s INT NOT NULL, \
%s TIMESTAMP NOT NULL, \
%s TIMESTAMP NOT NULL, \
%s BOOL NOT NULL, \
%s VARCHAR(128) NOT NULL, \
PRIMARY KEY (%s)) CHARACTER SET=utf8",
		g_sqlTable[TABLES_PUGGERS],
		g_sqlRow_Puggers[arrayIndex--],
		g_sqlRow_Puggers[arrayIndex--],
		g_sqlRow_Puggers[arrayIndex--], MAX_STEAMID_LENGTH,
		g_sqlRow_Puggers[arrayIndex--],
		g_sqlRow_Puggers[arrayIndex--],
		g_sqlRow_Puggers[arrayIndex--],
		g_sqlRow_Puggers[arrayIndex--], MAX_CVAR_LENGTH,
		g_sqlRow_Puggers[arrayIndex--],
		g_sqlRow_Puggers[arrayIndex--],
		g_sqlRow_Puggers[arrayIndex--],
		g_sqlRow_Puggers[arrayIndex--],
		g_sqlRow_Puggers[arrayIndex--],
		g_sqlRow_Puggers[arrayIndex--],
		g_sqlRow_Puggers[arrayIndex--],
		g_sqlRow_Puggers[arrayIndex--],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_ID]
	);
	if (!SQL_FastQuery(g_hDB, sql))
	{
		if (SQL_GetError(g_hDB, error, sizeof(error)))
			ThrowError(error);
		ThrowError("SQL query failed, but could not fetch error.");
	}

	// Reversed array index for Format() order of operations
	arrayIndex = SQL_TABLE_ORG_ENUM_COUNT-1;
	Format(sql, sizeof(sql), "CREATE TABLE IF NOT EXISTS %s ( \
%s INT NOT NULL AUTO_INCREMENT, \
%s TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, \
%s VARCHAR(%i) NOT NULL, \
%s INT NOT NULL, \
%s TIMESTAMP NOT NULL, \
PRIMARY KEY (%s)) CHARACTER SET=utf8",
		g_sqlTable[TABLES_ORGANIZERS],
		g_sqlRow_Organizers[arrayIndex--],
		g_sqlRow_Organizers[arrayIndex--],
		g_sqlRow_Organizers[arrayIndex--], MAX_CVAR_LENGTH,
		g_sqlRow_Organizers[arrayIndex--],
		g_sqlRow_Organizers[arrayIndex--],
		g_sqlRow_Organizers[SQL_TABLE_ORG_ID]
	);
	if (!SQL_FastQuery(g_hDB, sql))
	{
		if (SQL_GetError(g_hDB, error, sizeof(error)))
			ThrowError(error);
		ThrowError("SQL query failed, but could not fetch error.");
	}

	// Reversed array index for Format() order of operations
	arrayIndex = SQL_TABLE_PUG_SERVER_ENUM_COUNT-1;
	Format(sql, sizeof(sql), "CREATE TABLE IF NOT EXISTS %s ( \
%s INT NOT NULL AUTO_INCREMENT, \
%s TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, \
%s VARCHAR(%i) NOT NULL, \
%s VARCHAR(%i) NOT NULL, \
%s INT NOT NULL, \
%s VARCHAR(%i) NOT NULL, \
%s INT NOT NULL, \
%s INT NOT NULL, \
%s TIMESTAMP NOT NULL, \
PRIMARY KEY (%s)) CHARACTER SET=utf8",
		g_sqlTable[TABLES_PUG_SERVERS],
		g_sqlRow_PickupServers[arrayIndex--],
		g_sqlRow_PickupServers[arrayIndex--],
		g_sqlRow_PickupServers[arrayIndex--], MAX_CVAR_LENGTH,
		g_sqlRow_PickupServers[arrayIndex--], MAX_IP_LENGTH,
		g_sqlRow_PickupServers[arrayIndex--],
		g_sqlRow_PickupServers[arrayIndex--], MAX_CVAR_LENGTH,
		g_sqlRow_PickupServers[arrayIndex--],
		g_sqlRow_PickupServers[arrayIndex--],
		g_sqlRow_PickupServers[arrayIndex--],
		g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_ID]
	);
	if (!SQL_FastQuery(g_hDB, sql))
	{
		if (SQL_GetError(g_hDB, error, sizeof(error)))
			ThrowError(error);
		ThrowError("SQL query failed, but could not fetch error.");
	}

	// Reversed array index for Format() order of operations
	arrayIndex = SQL_TABLE_MATCHES_ENUM_COUNT-1;
	Format(sql, sizeof(sql), "CREATE TABLE IF NOT EXISTS %s ( \
%s INT NOT NULL AUTO_INCREMENT, \
%s TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, \
%s VARCHAR(%i) NOT NULL, \
%s VARCHAR(%i) NOT NULL, \
%s INT NOT NULL, \
%s VARCHAR(%i) NOT NULL, \
%s VARCHAR(%i) NOT NULL, \
%s INT NOT NULL, \
%s INT NOT NULL, \
%s INT NOT NULL, \
%s INT NOT NULL, \
%s INT NOT NULL, \
%s INT NOT NULL, \
%s INT NOT NULL, \
%s TIMESTAMP NOT NULL, \
PRIMARY KEY (%s)) CHARACTER SET=utf8",
		g_sqlTable[TABLES_MATCHES],
		g_sqlRow_Matches[arrayIndex--],
		g_sqlRow_Matches[arrayIndex--],
		g_sqlRow_Matches[arrayIndex--], MAX_MATCH_TITLE_LENGTH,
		g_sqlRow_Matches[arrayIndex--], MAX_IP_LENGTH,
		g_sqlRow_Matches[arrayIndex--],
		g_sqlRow_Matches[arrayIndex--], MAX_CVAR_LENGTH,
		g_sqlRow_Matches[arrayIndex--], MAX_CVAR_LENGTH,
		g_sqlRow_Matches[arrayIndex--],
		g_sqlRow_Matches[arrayIndex--],
		g_sqlRow_Matches[arrayIndex--],
		g_sqlRow_Matches[arrayIndex--],
		g_sqlRow_Matches[arrayIndex--],
		g_sqlRow_Matches[arrayIndex--],
		g_sqlRow_Matches[arrayIndex--],
		g_sqlRow_Matches[arrayIndex--],
		g_sqlRow_Matches[SQL_TABLE_MATCHES_ID]
	);
	if (!SQL_FastQuery(g_hDB, sql))
	{
		if (SQL_GetError(g_hDB, error, sizeof(error)))
			ThrowError(error);
		ThrowError("SQL query failed, but could not fetch error.");
	}

	// Reversed array index for Format() order of operations
	arrayIndex = SQL_TABLE_MATCH_HISTORY_ENUM_COUNT-1;
	Format(sql, sizeof(sql), "CREATE TABLE IF NOT EXISTS %s ( \
%s INT NOT NULL AUTO_INCREMENT, \
%s TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, \
%s VARCHAR(%i) NOT NULL, \
%s INT NOT NULL, \
PRIMARY KEY (%s)) CHARACTER SET=utf8",
		g_sqlTable[TABLES_MATCH_HISTORY],
		g_sqlRow_MatchHistory[arrayIndex--],
		g_sqlRow_MatchHistory[arrayIndex--],
		g_sqlRow_MatchHistory[arrayIndex--], MAX_STEAMID_LENGTH,
		g_sqlRow_MatchHistory[arrayIndex--],
		g_sqlRow_MatchHistory[SQL_TABLE_MATCH_HISTORY_ID]
	);
	if (!SQL_FastQuery(g_hDB, sql))
	{
		if (SQL_GetError(g_hDB, error, sizeof(error)))
			ThrowError(error);
		ThrowError("SQL query failed, but could not fetch error.");
	}
}
#endif

bool Database_DoTablesExist()
{
	for (new i = 0; i < TABLES_ENUM_COUNT; i++)
	{
		decl String:sql[MAX_SQL_LENGTH];
		decl String:error[MAX_SQL_ERROR_LENGTH];

		Format(sql, sizeof(sql), "SELECT max(CASE WHEN table_name = '%s' \
		THEN 1 ELSE 0 END) AS TableExists FROM information_schema.tables",
		g_sqlTable[i]);

		new Handle:stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
		if (stmt == INVALID_HANDLE)
			ThrowError(error);

		SQL_Execute(stmt);

		new bool:tableExists;
		while (SQL_FetchRow(stmt))
		{
			tableExists = view_as<bool>(SQL_FetchInt(stmt, 0));
		}
		CloseHandle(stmt);

		if (!tableExists)
			return false;
	}
	return true;
}

bool Pugger_GetLastMatchDetails(const char[] steamID, int &matchid, char[] connectIP, int &connectPort, char[] connectPassword)
{
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	Format(sql, sizeof(sql),
		"SELECT * FROM %s WHERE %s = ?",
		g_sqlTable[TABLES_PUGGERS],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID]
	);

	new Handle:stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == null)
		ThrowError(error);

	SQL_BindParamString(stmt, 0, steamID, false);
	SQL_Execute(stmt);

	if (!SQL_HasResultSet(stmt))
	{
		delete stmt;
		LogError("No result set for SQL: %s", sql);
		return false;
	}
	while (SQL_FetchRow(stmt))
	{
		SQL_FetchString(stmt, SQL_TABLE_PUGGER_GAMESERVER_CONNECT_IP,
			connectIP, MAX_IP_LENGTH);
		SQL_FetchString(stmt, SQL_TABLE_PUGGER_GAMESERVER_PASSWORD,
			connectPassword, MAX_CVAR_LENGTH);
		connectPort = SQL_FetchInt(stmt, SQL_TABLE_PUGGER_GAMESERVER_CONNECT_PORT);
		matchid = SQL_FetchInt(stmt, SQL_TABLE_PUGGER_MATCH_ID);
	}
	delete stmt;
	return true;
}

int Pugger_GetState(const char[] steamid)
{
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ?",
		g_sqlTable[TABLES_PUGGERS],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID]
	);

	Handle stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == null)
		ThrowError(error);

	SQL_BindParamString(stmt, 0, steamid, false);
	SQL_Execute(stmt);

	int state;
	if (SQL_HasResultSet(stmt))
	{
		while (SQL_FetchRow(stmt))
		{
			state = SQL_FetchInt(stmt, SQL_TABLE_PUGGER_STATE);
		}
	}
	delete stmt;
	return state;
}

int Pugger_SetState(const char[] steamid, int state)
{
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "UPDATE %s SET %s = ? WHERE %s = ?",
		g_sqlTable[TABLES_PUGGERS],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID]
	);

	Handle stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == null)
		ThrowError(error);

	SQL_BindParamInt(stmt, 0, state);
	SQL_BindParamString(stmt, 1, steamid, false);
	SQL_Execute(stmt);
	delete stmt;
}

int Pugger_GetQueuingState(client = 0, const String:connectIP[MAX_IP_LENGTH] = "", connectPort = 0, bool bySteamID = false, const char[] steamID = "")
{
	if (!bySteamID)
	{
		if (!IsValidClient(client) || IsFakeClient(client) || !IsClientAuthorized(client))
			ThrowError("Invalid client %i", client);
	}

	// %wildcard% the IP for SQL LIKE query.
	// If argument is not passed, it will match anything.
	decl String:wildcardIP[MAX_IP_LENGTH+2];
	Format(wildcardIP, sizeof(wildcardIP), "%%%s%%", connectIP);

	// %wildcard% the port for SQL LIKE query.
	// If argument is not passed, it will match anything.
	decl String:wildcardPort[8];
	if (connectPort > 0)
	{
		Format(wildcardPort, sizeof(wildcardPort), "%%%i%%", connectPort);
	}
	else if (connectPort == 0)
	{
		Format(wildcardPort, sizeof(wildcardPort), "%%%%");
	}
	else
	{
		ThrowError("Invalid server port %i specified.", connectPort);
	}

	decl String:steamIDBuffer[MAX_STEAMID_LENGTH];
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	if (!bySteamID)
		GetClientAuthId(client, AuthId_Steam2, steamIDBuffer, sizeof(steamIDBuffer));
	else
		strcopy(steamIDBuffer, sizeof(steamIDBuffer), steamID);

	Format(sql, sizeof(sql),
		"SELECT * FROM %s WHERE %s = ? AND %s LIKE ? AND %s LIKE ?",
		g_sqlTable[TABLES_PUGGERS],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_GAMESERVER_CONNECT_IP],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_GAMESERVER_CONNECT_PORT]);

	new Handle:stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == null)
	{
		ThrowError(error);
	}

	new paramIndex;
	SQL_BindParamString(stmt, paramIndex++, steamIDBuffer, false);
	SQL_BindParamString(stmt, paramIndex++, wildcardIP, false);
	SQL_BindParamString(stmt, paramIndex++, wildcardPort, false);
	SQL_Execute(stmt);

	new state = PUGGER_STATE_INACTIVE;
	if (SQL_HasResultSet(stmt))
	{
		while (SQL_FetchRow(stmt))
		{
			state = SQL_FetchInt(stmt, SQL_TABLE_PUGGER_STATE);

			if (SQL_MoreRows(stmt))
			{
				LogError("Pugger_GetQueuingState(%i): Found more than 1 results, \
				expected 0 or 1", client);
				break;
			}
		}
	}
	CloseHandle(stmt);
	return state;
}

#if defined PLUGIN_PUG || defined PLUGIN_COMP
int Puggers_GetCountPerState(state)
{
	if (0 > state || state > PUGGER_STATE_ENUM_COUNT)
	{
		ThrowError("Invalid state %i, expected state between 0 and %i",
		state, PUGGER_STATE_ENUM_COUNT);
	}

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ?",
	g_sqlTable[TABLES_PUGGERS], g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE]);

	new Handle:stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == null)
	{
		ThrowError(error);
	}

	SQL_BindParamInt(stmt, 0, state);
	SQL_Execute(stmt);

	new results = SQL_GetRowCount(stmt);
	CloseHandle(stmt);

	return results;
}
#endif

#if defined PLUGIN_PUG
void CheckSQLConstants()
{
	CheckForSpookiness(g_sIdentifier);
	CheckForSpookiness(g_sqlTable[TABLES_ORGANIZERS]);
	CheckForSpookiness(g_sqlTable[TABLES_PUG_SERVERS]);
	CheckForSpookiness(g_sqlTable[TABLES_PUGGERS]);

	for (new i = 0; i < sizeof(g_sqlRow_Puggers); i++)
		CheckForSpookiness(g_sqlRow_Puggers[i]);
}
#endif

int Database_GetDesiredPlayerCount()
{
	decl String:sql[MAX_SQL_LENGTH];

	Format(sql, sizeof(sql), "SELECT %s FROM %s",
	g_sqlRow_Rules[SQL_TABLE_RULES_DESIRED_PLAYERCOUNT], g_sqlTable[TABLES_RULES]);

	new Handle:query = SQL_Query(g_hDB, sql);
	if (SQL_GetAffectedRows(query) == 0)
	{
		CloseHandle(query);
		ThrowError("No playercount found from database.");
	}

	new playerCount;
	while (SQL_FetchRow(query))
	{
		playerCount = SQL_FetchInt(query, SQL_TABLE_RULES_DESIRED_PLAYERCOUNT);
	}
	CloseHandle(query);

	return playerCount;
}

#if defined PLUGIN_PUG
int Database_GetEpoch()
{
	decl String:sql[MAX_SQL_LENGTH];
	Format(sql, sizeof(sql), "SELECT UNIX_TIMESTAMP()");

	new Handle:query = SQL_Query(g_hDB, sql);

	new epoch;
	while (SQL_FetchRow(query))
	{
		epoch = SQL_FetchInt(query, 0);
	}
	CloseHandle(query);

	return epoch;
}
#endif

bool Pugger_SetQueuingState(client = 0, state, bool:bySteamID = false, const char[] steamID = "")
{
	if (!bySteamID && !IsValidClient(client))
		ThrowError("Invalid client %i", client);

	if (state < 0 || state >= PUGGER_STATE_ENUM_COUNT)
	{
		ThrowError("Invalid state %i, expected value between 0 and %i.",
		state, PUGGER_STATE_ENUM_COUNT-1);
	}

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	decl String:steamIDBuffer[MAX_STEAMID_LENGTH];
	if (!bySteamID)
		GetClientAuthId(client, AuthId_Steam2, steamIDBuffer, sizeof(steamIDBuffer));
	else
		strcopy(steamIDBuffer, sizeof(steamIDBuffer), steamID);

	Format(sql, sizeof(sql), "UPDATE %s SET %s = ? WHERE %s = ?",
	g_sqlTable[TABLES_PUGGERS],
	g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE],
	g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID]);

	new Handle:stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == INVALID_HANDLE)
		ThrowError(error);

	new paramIndex;
	SQL_BindParamInt(stmt, paramIndex++, state);
	SQL_BindParamString(stmt, paramIndex++, steamIDBuffer, false);
	SQL_Execute(stmt);
	CloseHandle(stmt);
	return true;
}

bool Match_SetPreparingForLive(int match_id)
{
	if (!Database_MatchExists(match_id))
		return false;

	// Make sure we're still allowed to do this. This should never fail.
	if (PugServer_GetReserve_This() != DB_PUG_RESERVED)
	{
		LogError("Match_SetPreparingForLive: Not reserved for db! Trying to reserve again.");
		if (!PugServer_SetReserve_This(DB_PUG_RESERVED))
		{
			LogError("Failed to reserve db while assuming we had reservation. Stopping.");
			return false;
		}
	}

	// Set puggers' live states
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "UPDATE %s SET %s = ? WHERE %s = ?",
		g_sqlTable[TABLES_PUGGERS],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_MATCH_ID]
	);
	Handle stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == null)
	{
		LogError(error);
		PugServer_SetReserve_This(DB_PUG_INACTIVE);
		return false;
	}
	SQL_BindParamInt(stmt, 0, PUGGER_STATE_LIVE);
	SQL_BindParamInt(stmt, 1, match_id);
	SQL_Execute(stmt);
	delete stmt;

	// Set the pug server's live state
	decl String:ipAddress[MAX_IP_LENGTH];
	int port;
	GetServerConnectionDetails(ipAddress, port);
	PugServer_Set_Status(
		PUG_SERVER_STATUS_AWAITING_PLAYERS, ipAddress, port);

	Format(sql, sizeof(sql), "UPDATE %s SET %s = ? WHERE %s = ?",
		g_sqlTable[TABLES_MATCHES],
		g_sqlRow_Matches[SQL_TABLE_MATCHES_STATUS],
		g_sqlRow_Matches[SQL_TABLE_MATCHES_ID]
	);
	stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == null)
	{
		LogError(error);
		PugServer_SetReserve_This(DB_PUG_INACTIVE);
		return false;
	}
	int paramIndex;
	SQL_BindParamInt(stmt, paramIndex++, MATCHMAKE_WARMUP);
	SQL_BindParamInt(stmt, paramIndex++, match_id);
	SQL_Execute(stmt);
	delete stmt;

	SetMatchStatus(MATCHMAKE_WARMUP);

	// Successfully went live. Release pug side of db.
	PugServer_SetReserve_This(DB_PUG_INACTIVE);
	return true;
}

int Match_GetDesiredPlayers(int match_id)
{
	if (!Database_MatchExists(match_id))
	{
		ThrowError("Couldn't find match with id %i", match_id);
	}

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ?",
		g_sqlTable[TABLES_MATCHES],
		g_sqlRow_Matches[SQL_TABLE_MATCHES_ID]
	);
	Handle stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == null)
	{
		ThrowError(error);
	}
	SQL_BindParamInt(stmt, 0, match_id);
	SQL_Execute(stmt);

	if (!SQL_HasResultSet(stmt) || SQL_GetRowCount(stmt) == 0)
	{
		ThrowError("Query returned 0 results for match id %i.", match_id);
	}
	int playercount;
	while (SQL_FetchRow(stmt))
	{
		playercount = SQL_FetchInt(stmt, SQL_TABLE_MATCHES_PLAYER_COUNT);
	}
	delete stmt;
	return playercount;
}

bool Database_SetMatchStatus(int matchid, int status)
{
	if (!Database_MatchExists(matchid))
	{
		ThrowError("Match with ID %i does not exist.", matchid);
	}

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "UPDATE %s SET %s = ? WHERE %s = ?",
		g_sqlTable[TABLES_MATCHES],
		g_sqlRow_Matches[SQL_TABLE_MATCHES_STATUS],
		g_sqlRow_Matches[SQL_TABLE_MATCHES_ID]
	);

	Handle stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == null)
		ThrowError(error);

	SQL_BindParamInt(stmt, 0, status);
	SQL_BindParamInt(stmt, 1, matchid);
	SQL_Execute(stmt);
	delete stmt;
	return true;
}

int Database_GetMatchStatus(int matchid)
{
	if (!Database_MatchExists(matchid))
	{
		ThrowError("Match with ID %i does not exist.", matchid);
	}

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ?",
		g_sqlTable[TABLES_MATCHES],
		g_sqlRow_Matches[SQL_TABLE_MATCHES_ID]
	);

	Handle stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == null)
		ThrowError(error);

	SQL_BindParamInt(stmt, 0, matchid);
	SQL_Execute(stmt);

	if (!SQL_HasResultSet(stmt))
	{
		delete stmt;
		ThrowError("Failed to fetch status for match id %i", matchid);
	}

	int status = MATCHMAKE_ERROR;
	while (SQL_FetchRow(stmt))
	{
		status = SQL_FetchInt(stmt, SQL_TABLE_MATCHES_STATUS);
	}
	delete stmt;
	return status;
}

int PugServer_GetMatchID_This()
{
	decl String:ipAddress[MAX_IP_LENGTH];
	int port;
	GetServerConnectionDetails(ipAddress, port);

	// Get the latest match ID (IDs are auto incremented)
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ? AND %s = ? \
ORDER BY %s DESC",
		g_sqlTable[TABLES_MATCHES],
		g_sqlRow_Matches[SQL_TABLE_MATCHES_HOST_IP],
		g_sqlRow_Matches[SQL_TABLE_MATCHES_HOST_PORT],
		g_sqlRow_Matches[SQL_TABLE_MATCHES_ID]
	);
	Handle stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == null)
	{
		LogError(error);
		return INVALID_MATCH_ID;
	}

	int paramIndex;
	SQL_BindParamString(stmt, paramIndex++, ipAddress, false);
	SQL_BindParamInt(stmt, paramIndex++, port);
	SQL_Execute(stmt);

	int match_id = INVALID_MATCH_ID;
	if (SQL_HasResultSet(stmt))
	{
		while (SQL_FetchRow(stmt))
		{
			match_id = SQL_FetchInt(stmt, SQL_TABLE_MATCHES_ID);
			break;
		}
	}
	delete stmt;
	return match_id;
}
