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
	db = SQL_Connect(configName, true, error, sizeof(error));

	if (db == null)
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
	new Handle:query = SQL_Query(db, sql);
	new rows = SQL_GetRowCount(query);

	CloseHandle(query);
	return rows;
}

#if defined PLUGIN_PUG
void Database_RemovePugger(client = 0, bool bySteamID = false, String:steamID[MAX_STEAMID_LENGTH] = "")
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

	Database_Initialize();

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE steamid = ?",
	g_sqlTable[TABLES_PUGGERS]);

	new Handle:stmt = SQL_PrepareQuery(db, sql, error, sizeof(error));
	if (stmt == INVALID_HANDLE)
		ThrowError(error);

	PrintDebug("Perceived SteamID: %s", steamID);

	SQL_BindParamString(stmt, 0, steamID, false);
	SQL_Execute(stmt);

	new results = SQL_GetRowCount(stmt);
	new state;

	if (results > 1)
	{
		LogError("Database_RemovePugger: Found %i results for SteamID \"%s\" \
		in database, expected to find 1. Deleting duplicates.", results, steamID);

		Format(sql, sizeof(sql), "DELETE FROM %s WHERE %s = ?",
		g_sqlTable[TABLES_PUGGERS], g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID]);

		new Handle:stmt_Delete = SQL_PrepareQuery(db, sql, error, sizeof(error));
		if (stmt_Delete == INVALID_HANDLE)
		{
			CloseHandle(stmt);
			ThrowError(error);
		}

		SQL_BindParamString(stmt_Delete, 0, steamID, false);
		SQL_Execute(stmt_Delete);
		CloseHandle(stmt_Delete);
	}
	if (results > 1 || results == 0)
	{
		if (results == 0)
		{
			LogError("Database_RemovePugger: Found 0 results for SteamID \"%s\" \
in database, inserting a row with PUGGER_STATE_INACTIVE", steamID);
		}

		Format(sql, sizeof(sql), "INSERT INTO %s (%s, %s) VALUES (?, ?)",
		g_sqlTable[TABLES_PUGGERS],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE]);

		new Handle:stmt_Insert = SQL_PrepareQuery(db, sql, error, sizeof(error));
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
					LogError("Database_RemovePugger(): Pugger state for \"%s\" returned %i. \
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

void Database_AddPugger(client)
{
	if (!IsValidClient(client) || IsFakeClient(client))
		ThrowError("Invalid client %i", client);

	Database_Initialize();

	decl String:steamID[MAX_STEAMID_LENGTH];
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	GetClientAuthId(client, AuthId_Steam2, steamID, sizeof(steamID));

	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE steamid = ?",
	g_sqlTable[TABLES_PUGGERS]);

	new Handle:stmt = SQL_PrepareQuery(db, sql, error, sizeof(error));
	if (stmt == INVALID_HANDLE)
		ThrowError(error);

	SQL_BindParamString(stmt, 0, steamID, false);
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

			new Handle:updateStmt = SQL_PrepareQuery(db, sql, error, sizeof(error));

			new paramIndex;
			SQL_BindParamInt(updateStmt, paramIndex++, PUGGER_STATE_QUEUING);
			SQL_BindParamString(updateStmt, paramIndex++, steamID, false);

			SQL_Execute(updateStmt);
			CloseHandle(updateStmt);

			if (SQL_MoreRows(stmt))
			{
				LogError("Database_AddPugger(%i): Found more than 1 results, \
expected 0 or 1", client);
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

		new Handle:insertStmt = SQL_PrepareQuery(db, sql, error, sizeof(error));

		new paramIndex;
		SQL_BindParamString(insertStmt, paramIndex++, steamID, false);
		SQL_BindParamInt(insertStmt, paramIndex++, PUGGER_STATE_QUEUING);

		SQL_Execute(insertStmt);
		CloseHandle(insertStmt);
	}

	CloseHandle(stmt);
}

void Database_GiveUpMatch(bool:giveUpEarly = false, const String:quittingSteamID[MAX_STEAMID_LENGTH] = "")
{
	Database_Initialize();

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	Format(sql, sizeof(sql), "SELECT * FROM %s", g_sqlTable[TABLES_PUGGERS]);

	new Handle:stmt_SelectPuggers = SQL_PrepareQuery(db, sql, error, sizeof(error));
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

		new Handle:stmt_UpdatePuggers = SQL_PrepareQuery(db, sql, error, sizeof(error));
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

	new Handle:stmt_SelectPugServers = SQL_PrepareQuery(db, sql, error, sizeof(error));
	if (stmt_SelectPugServers == INVALID_HANDLE)
		ThrowError(error);

	new paramIndex;
	SQL_BindParamInt(stmt_SelectPugServers, paramIndex++, PUG_SERVER_STATUS_AVAILABLE);
	SQL_BindParamInt(stmt_SelectPugServers, paramIndex++, PUG_SERVER_STATUS_RESERVED);
	SQL_Execute(stmt_SelectPugServers);

	CloseHandle(stmt_SelectPugServers);

	Organizers_Update_This();
}

void Database_LogIgnore(client)
{
	//TODO
	PrintDebug("Database_LogIgnore(%i)", client);
}

void Database_CleanAFKers()
{
	Database_Initialize();

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ?",
	g_sqlTable[TABLES_PUGGERS],
	g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE]);

	new Handle:stmt_CleanAfkers = SQL_PrepareQuery(db, sql, error, sizeof(error));
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
		Database_RemovePugger(_, true, steamID);
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
	GetCvarValue("ip", TYPE_STRING, sIP, sizeof(sIP)); /*
	new Handle:hIP = FindConVar("ip");
	if (hIP == INVALID_HANDLE)
		SetFailState("Could not find server cvar \"ip\"");
	decl String:sIP[MAX_IP_LENGTH];
	GetConVarString(hIP, sIP, sizeof(sIP));
	CloseHandle(hIP);*/

	// Get PUG server port number
	new iPort = GetCvarValue("hostport", TYPE_INT);/*
	new Handle:hPort = FindConVar("hostport");
	if (hPort == INVALID_HANDLE)
		SetFailState("Could not find server cvar \"hostport\"");
	new iPort = GetConVarInt(hPort);
	CloseHandle(hPort);*/

	// Get PUG server password
	decl String:sPassword[MAX_CVAR_LENGTH];
	GetCvarValue("sv_password", TYPE_STRING, sPassword, sizeof(sPassword)); /*
	new Handle:hPassword = FindConVar("sv_password");
	if (hPassword == INVALID_HANDLE)
		SetFailState("Could not find server cvar \"sv_password\"");
	decl String:sPassword[MAX_CVAR_LENGTH];
	GetConVarString(hPassword, sPassword, sizeof(sPassword));
	CloseHandle(hPassword);*/

	// Get PUG server vanity name
	decl String:sServerName[MAX_CVAR_LENGTH];
	GetCvarValue("hostname", TYPE_STRING, sServerName, sizeof(sServerName)); /*
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

	new Handle:stmt_RowCount = SQL_PrepareQuery(db, sql, error, sizeof(error));
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

	stmt_ServerUpdate = SQL_PrepareQuery(db, sql, error, sizeof(error));
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

void PugServer_Set_Status(status, String:sIP[MAX_IP_LENGTH] = "", iPort = 0)
{
	if ((strlen(sIP) != 0 && iPort == 0) || (strlen(sIP) == 0 && iPort != 0))
		ThrowError("Invalid IP \"%s\" and/or port %i", sIP, iPort);

	if (status < PUG_SERVER_STATUS_ERROR || status >= PUG_SERVER_STATUS_ENUM_COUNT)
	{
		ThrowError("Invalid enum %i, expected enum between %i - %i",
			status, PUG_SERVER_STATUS_ERROR, PUG_SERVER_STATUS_ENUM_COUNT);
	}
	Database_Initialize();

	if (strlen(sIP) == 0)
		strcopy(sIP, sizeof(sIP), g_ipAddress);

	if (iPort == 0)
		iPort = g_serverPort;

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "UPDATE %s SET %s = ? WHERE %s = ? AND %s = ?",
		g_sqlTable[TABLES_PUG_SERVERS],
		g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_STATUS],
		g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_IP],
		g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_PORT]);

	new Handle:stmt = SQL_PrepareQuery(db, sql, error, sizeof(error));
	if (stmt == INVALID_HANDLE)
		ThrowError(error);

	new paramIndex;
	SQL_BindParamInt(stmt, paramIndex++, status);
	SQL_BindParamString(stmt, paramIndex++, sIP, false);
	SQL_BindParamInt(stmt, paramIndex++, iPort);
	SQL_Execute(stmt);

	CloseHandle(stmt);
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

	new Handle:stmt = SQL_PrepareQuery(db, sql, error, sizeof(error));
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
// Purpose: Update this pug server's reserve status enum in db
bool PugServer_SetReserve(int reserveStatus = DB_PUG_INACTIVE)
{
	if (g_bIsDatabaseDown)
		return false;

	bool includeMyself = true;
	if (reserveStatus != DB_PUG_INACTIVE &&
			PugServers_Is_Anyone_Busy(!includeMyself))
	{
		return false;
	}

	PrintDebug("PugServer_SetReserve(%i): No one else is busy, try set new status.",
		reserveStatus);

	if (reserveStatus < DB_PUG_INACTIVE || reserveStatus >= DB_PUG_ENUM_COUNT)
	{
		ThrowError("Invalid reserve status %i. Expected status between %i and %i",
			reserveStatus, DB_PUG_INACTIVE, DB_PUG_ENUM_COUNT-1);
	}

	Database_Initialize();

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

	Handle stmt_Select = SQL_PrepareQuery(db, sql, error, sizeof(error));
	SQL_BindParamString(stmt_Select, 0, ipAddress, false);
	SQL_BindParamInt(stmt_Select, 1, port);
	SQL_Execute(stmt_Select);

	if (stmt_Select == null)
		ThrowError(error);

	int results = SQL_GetRowCount(stmt_Select);
	delete stmt_Select;

	if (results > 1)
	{
		// Delete duplicate records
		LogError("PugServer_SetReserve(%i): Found %i results from database for \
		pug server \"%s:%i\", expected 0 or 1.",
			reserveStatus, results, ipAddress, port);

		Format(sql, sizeof(sql), "DELETE FROM %s WHERE %s = ? AND %i = ?",
			g_sqlTable[TABLES_PUG_SERVERS],
			g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_IP],
			g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_PORT]);

		new Handle:stmt_Delete = SQL_PrepareQuery(db, sql, error, sizeof(error));
		if (stmt_Delete == INVALID_HANDLE)
			ThrowError(error);

		SQL_BindParamString(stmt_Delete, 0, ipAddress, false);
		SQL_BindParamInt(stmt_Delete, 1, port);
		SQL_Execute(stmt_Delete);
		CloseHandle(stmt_Delete);

		// Insert new record
		Format(sql, sizeof(sql), "INSERT INTO %s (%s, %s, %s) VALUES (?, ?, ?)",
			g_sqlTable[TABLES_PUG_SERVERS],
			g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_IP],
			g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_PORT],
			g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_RESERVING]);

		new Handle:stmt_Insert = SQL_PrepareQuery(db, sql, error, sizeof(error));
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

		new Handle:stmt_Update = SQL_PrepareQuery(db, sql, error, sizeof(error));
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
	// No record was found at all, this is an error!
	LogError("PugServer_SetReserve(%i): \
Found no database entry for pug server \"%s:%i\". This should never happen.",
		reserveStatus, ipAddress, port);

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
	bool includeMyself = true;
	if (reserveStatus != DB_ORG_INACTIVE &&
			Organizers_Is_Anyone_Busy(!includeMyself))
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

	Database_Initialize();

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ?",
		g_sqlTable[TABLES_ORGANIZERS],
		g_sqlRow_Organizers[SQL_TABLE_ORG_NAME]);

	new Handle:stmt_Select = SQL_PrepareQuery(db, sql, error, sizeof(error));
	SQL_BindParamString(stmt_Select, 0, g_sIdentifier, false);
	SQL_Execute(stmt_Select);

	if (stmt_Select == INVALID_HANDLE)
		ThrowError(error);

	new results = SQL_GetRowCount(stmt_Select);
	//PrintDebug("Results: %i", results);
	CloseHandle(stmt_Select);

	if (results > 1)
	{
		// Delete duplicate records
		LogError("Organizers_Update_This(%i): Found %i results from database for \
		organizer \"%s\", expected 0 or 1.", reserveStatus, results, g_sIdentifier);

		Format(sql, sizeof(sql), "DELETE FROM %s WHERE %s = ?",
		g_sqlTable[TABLES_ORGANIZERS], g_sqlRow_Organizers[SQL_TABLE_ORG_NAME]);

		new Handle:stmt_Delete = SQL_PrepareQuery(db, sql, error, sizeof(error));
		if (stmt_Delete == INVALID_HANDLE)
			ThrowError(error);

		SQL_BindParamString(stmt_Delete, 0, g_sIdentifier, false);
		SQL_Execute(stmt_Delete);
		CloseHandle(stmt_Delete);

		// Insert new record
		Format(sql, sizeof(sql), "INSERT INTO %s (%s, %s) VALUES (?, ?)",
		g_sqlTable[TABLES_ORGANIZERS],
		g_sqlRow_Organizers[SQL_TABLE_ORG_NAME],
		g_sqlRow_Organizers[SQL_TABLE_ORG_RESERVING]);

		new Handle:stmt_Insert = SQL_PrepareQuery(db, sql, error, sizeof(error));
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

		new Handle:stmt_Update = SQL_PrepareQuery(db, sql, error, sizeof(error));
		if (stmt_Update == INVALID_HANDLE)
			ThrowError(error);

		new paramIndex;
		SQL_BindParamInt(stmt_Update, paramIndex++, reserveStatus);
		SQL_BindParamString(stmt_Update, paramIndex++, g_sIdentifier, false);
		SQL_Execute(stmt_Update);
		CloseHandle(stmt_Update);
		return true;
	}
	// No record was found at all, this is an error!
	LogError("Organizers_Update_This(%i): \
Found no database entry for organizer \"%s\". This should never happen.",
		reserveStatus, g_sIdentifier);

	return false;
}

/*
// Purpose: Return reserve status int enum of this org server
int Organizers_Get_Status_This()
{
	PrintDebug("Organizers_Get_Status_This()");
	Database_Initialize();

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ?",
	g_sqlTable[TABLES_ORGANIZERS], g_sqlRow_Organizers[SQL_TABLE_ORG_NAME]);

	new Handle:stmt_Select = SQL_PrepareQuery(db, sql, error, sizeof(error));
	SQL_BindParamString(stmt_Select, 0, g_sIdentifier, false);
	SQL_Execute(stmt_Select);

	if (stmt_Select == INVALID_HANDLE)
		ThrowError(error);

	new results;
	new status;
	while (SQL_FetchRow(stmt_Select))
	{
		status = SQL_FetchInt(stmt_Select, SQL_TABLE_ORG_RESERVING);
		results++;
	}
	if (results != 1)
	{
		CloseHandle(stmt_Select);
		ThrowError("Found %i results for identifier %s, expected 1.",
			results, g_sIdentifier);
	}
	CloseHandle(stmt_Select);

	if (DB_ORG_INACTIVE > status >= SERVER_DB_ENUM_COUNT)
		ThrowError("Status %i is out of enum bounds %i - %i",
		status, DB_ORG_INACTIVE, SERVER_DB_ENUM_COUNT-1);

	return status;
}
*/
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
	else if (IsLocalhostString(ipAddress))
	{
		ThrowError("Retrieved localhost address %s instead of external address.",
			ipAddress);
	}

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s", g_sqlTable[TABLES_PUG_SERVERS]);

	// TODO: Unnecessary prepared statement, replace with error returning query
	Handle stmt_Select = SQL_PrepareQuery(db, sql, error, sizeof(error));
	if (stmt_Select == null)
		ThrowError(error);

	SQL_Execute(stmt_Select);

	char ipBuffer[MAX_IP_LENGTH];
	int portBuffer;
	int dbState;
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
	new Handle:stmt_Select = SQL_PrepareQuery(db, sql, error, sizeof(error));
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

	new Handle:stmt_Select = SQL_PrepareQuery(db, sql, error, sizeof(error));
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
	new rows;
	rows += Database_GetRowCountForTableName(g_sqlTable[TABLES_PUGGERS], false);
	rows += Database_GetRowCountForTableName(g_sqlTable[TABLES_ORGANIZERS], false);
	rows += Database_GetRowCountForTableName(g_sqlTable[TABLES_PUG_SERVERS], false);
	rows += Database_GetRowCountForTableName(g_sqlTable[TABLES_RULES], false);

	PrintDebug("Command_CreateTables() rows: %i", rows);

	if (rows > 0)
	{
		ReplyToCommand(client, "%s Database returned %i already existing PUG rows!",
			g_sTag, rows);
		ReplyToCommand(client, "Make sure no PUG tables exist before running this \
command.");
		ReplyToCommand(client, "No new tables were created by this command.");

		decl String:clientName[MAX_NAME_LENGTH];
		GetClientName(client, clientName, sizeof(clientName));
		LogError("Client %i (\"%s\") attempted to run Command_CreateTables while %i \
		PUG rows already exist. Command was aborted. PUG plugin debug level: %i. \
		SQL debug level: %i", client, clientName, rows, DEBUG, DEBUG_SQL);

		return Plugin_Stop;
	}

	Database_Initialize(false);
	decl String:sql[MAX_SQL_LENGTH];

	// Reversed array index for Format() order of operations
	new arrayIndex = SQL_TABLE_RULES_ENUM_COUNT-1;
	Format(sql, sizeof(sql), "CREATE TABLE IF NOT EXISTS %s ( \
									%s INT NOT NULL) \
									CHARACTER SET=utf8",
									g_sqlTable[TABLES_RULES],
									g_sqlRow_Rules[arrayIndex--]
	);
	PrintDebug("SQL: %s", sql);

	new Handle:query_CreateRules = SQL_Query(db, sql);
	CloseHandle(query_CreateRules);

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

	new Handle:query_CreatePuggers = SQL_Query(db, sql);
	CloseHandle(query_CreatePuggers);

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
	new Handle:query_CreateOrganizers = SQL_Query(db, sql);
	CloseHandle(query_CreateOrganizers);

	// Reversed array index for Format() order of operations
	arrayIndex = SQL_TABLE_PUG_SERVER_ENUM_COUNT-1;
	Format(sql, sizeof(sql), "CREATE TABLE IF NOT EXISTS %s ( \
					%s INT NOT NULL AUTO_INCREMENT, \
					%s TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, \
					%s VARCHAR(%i) NOT NULL, \
					%s VARCHAR (45) NOT NULL, \
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
					g_sqlRow_PickupServers[arrayIndex--],
					g_sqlRow_PickupServers[arrayIndex--],
					g_sqlRow_PickupServers[arrayIndex--], MAX_CVAR_LENGTH,
					g_sqlRow_PickupServers[arrayIndex--],
					g_sqlRow_PickupServers[arrayIndex--], MAX_CVAR_LENGTH,
					g_sqlRow_PickupServers[arrayIndex--],
					g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_ID]
	);

	new Handle:query_CreatePugServers = SQL_Query(db, sql);
	CloseHandle(query_CreatePugServers);

	return Plugin_Handled;
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

		new Handle:stmt = SQL_PrepareQuery(db, sql, error, sizeof(error));
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

int Pugger_GetQueuingState(client, const String:connectIP[MAX_IP_LENGTH] = "", connectPort = 0)
{
	if (!IsValidClient(client) || IsFakeClient(client))
		ThrowError("Invalid client %i", client);

	Database_Initialize();

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

	decl String:steamID[MAX_STEAMID_LENGTH];
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	GetClientAuthId(client, AuthId_Steam2, steamID, sizeof(steamID));

	Format(sql, sizeof(sql),
		"SELECT * FROM %s WHERE %s = ? AND %s LIKE ? AND %s LIKE ?",
		g_sqlTable[TABLES_PUGGERS],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_GAMESERVER_CONNECT_IP],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_GAMESERVER_CONNECT_PORT]);

	new Handle:stmt = SQL_PrepareQuery(db, sql, error, sizeof(error));

	new paramIndex;
	SQL_BindParamString(stmt, paramIndex++, steamID, false);
	SQL_BindParamString(stmt, paramIndex++, wildcardIP, false);
	SQL_BindParamString(stmt, paramIndex++, wildcardPort, false);
	SQL_Execute(stmt);

	new state = PUGGER_STATE_INACTIVE;
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
	CloseHandle(stmt);

	return state;
}

#if defined PLUGIN_PUG || defined PLUGIN_COMP
int Puggers_GetCountPerState(state)
{
	if (0 > state > PUGGER_STATE_ENUM_COUNT)
	{
		ThrowError("Invalid state %i, expected state between 0 and %i",
		state, PUGGER_STATE_ENUM_COUNT);
	}

	Database_Initialize();

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ?",
	g_sqlTable[TABLES_PUGGERS], g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE]);

	new Handle:stmt = SQL_PrepareQuery(db, sql, error, sizeof(error));

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
	Database_Initialize();

	decl String:sql[MAX_SQL_LENGTH];

	Format(sql, sizeof(sql), "SELECT %s FROM %s",
	g_sqlRow_Rules[SQL_TABLE_RULES_DESIRED_PLAYERCOUNT], g_sqlTable[TABLES_RULES]);

	new Handle:query = SQL_Query(db, sql);
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
	Database_Initialize();

	decl String:sql[MAX_SQL_LENGTH];
	Format(sql, sizeof(sql), "SELECT UNIX_TIMESTAMP()");

	new Handle:query = SQL_Query(db, sql);

	new epoch;
	while (SQL_FetchRow(query))
	{
		epoch = SQL_FetchInt(query, 0);
	}
	CloseHandle(query);

	return epoch;
}
#endif

#if defined PLUGIN_COMP
bool Database_IsPlayerCompeting(const String:steamID[])
{
	new bool:isCompeting;

	// Prepare array for player SteamIDs
	new playerCount = Database_GetDesiredPlayerCount();
	decl String:playerSteamID[playerCount][MAX_STEAMID_LENGTH];

	// Look up SteamIDs marked as players on this server currently
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ? AND %s = ?",
		g_sqlTable[TABLES_PUGGERS],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_GAMESERVER_CONNECT_IP],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_GAMESERVER_CONNECT_PORT]);

	decl String:sIP[MAX_IP_LENGTH];
	GetCvarValue("ip", TYPE_STRING, sIP, sizeof(sIP));
	new iPort = GetCvarValue("hostport", TYPE_INT);

	new Handle:stmt = SQL_PrepareQuery(db, sql, error, sizeof(error));
	if (stmt == INVALID_HANDLE)
		ThrowError(error);

	new paramIndex;
	SQL_BindParamString(stmt, paramIndex++, sIP, false);
	SQL_BindParamInt(stmt, paramIndex++, iPort);
	SQL_Execute(stmt);

	// Fill SteamID array with current players
	new i;
	while (SQL_FetchRow(stmt))
	{
		if (i > playerCount)
			ThrowError("SQL loop count %i > playerCount %i", i, playerCount);

		if (SQL_IsFieldNull(stmt, SQL_TABLE_PUGGER_STEAMID))
			continue;

		SQL_FetchString(stmt, SQL_TABLE_PUGGER_STEAMID,
			playerSteamID[i++], MAX_STEAMID_LENGTH);
	}
	CloseHandle(stmt);
	// Check if player is competing
	for (i = 0; i < playerCount; i++)
	{
		if (strlen(playerSteamID[i]) == 0)
		{
			LogError("Database_IsPlayerCompeting: Zero length SteamID in array");
			continue;
		}

		if (StrEqual(steamID, playerSteamID[i]))
		{
			isCompeting = true;
			break;
		}
	}

	return isCompeting;
}
#endif

void Pugger_SetQueuingState(client = 0, state, bool:bySteamID = false, String:steamID[MAX_STEAMID_LENGTH] = "")
{
	if (!bySteamID && !IsValidClient(client))
		ThrowError("Invalid client %i", client);

	if (state < 0 || state >= PUGGER_STATE_ENUM_COUNT)
	{
		ThrowError("Invalid state %i, expected value between 0 and %i.",
		state, PUGGER_STATE_ENUM_COUNT-1);
	}

	Database_Initialize();

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	if (!bySteamID)
	{
		GetClientAuthId(client, AuthId_Steam2, steamID, sizeof(steamID));
	}

	Format(sql, sizeof(sql), "UPDATE %s SET %s = ? WHERE %s = ?",
	g_sqlTable[TABLES_PUGGERS],
	g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE],
	g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID]);

	new Handle:stmt = SQL_PrepareQuery(db, sql, error, sizeof(error));
	if (stmt == INVALID_HANDLE)
		ThrowError(error);

	new paramIndex;
	SQL_BindParamInt(stmt, paramIndex++, state);
	SQL_BindParamString(stmt, paramIndex++, steamID, false);
	SQL_Execute(stmt);
	CloseHandle(stmt);
}
