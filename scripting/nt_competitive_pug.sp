//TODO: Abstract more sql operations

#pragma semicolon 1

#include <sourcemod>
#include <smlib>
#include "nt_competitive/nt_competitive_sql"

#define DEBUG 1
#define DEBUG_SQL 1 // Make sure this is set to 0 unless you really want to debug the SQL as it disables some safety checks
#define PLUGIN_VERSION "0.1"

#define MAX_IDENTIFIER_LENGTH 52
#define MAX_IP_LENGTH 46
#define MAX_CVAR_LENGTH 64
#define MAX_STEAMID_LENGTH 44
#define PUG_INVITE_TIME 60
#define QUEUE_CHECK_TIMER 30

#define DESIRED_PLAYERCOUNT 2 // TODO: Move to database

new Handle:g_hCvar_DbConfig;

new Handle:g_hTimer_CheckQueue = INVALID_HANDLE;

new bool:g_bIsDatabaseDown;
new bool:g_bIsJustLoaded = true;
new bool:g_bIsQueueActive;

new g_iInviteTimerDisplay[MAXPLAYERS+1];

new Float:g_fQueueTimer_Interval = 1.0;
new Float:g_fQueueTimer_DeltaTime;

new const String:g_sTag[] = "[PUG]";

new String:g_sIdentifier[MAX_IDENTIFIER_LENGTH]; // Set this to something uniquely identifying if the plugin fails to retrieve your external IP.

public Plugin:myinfo = {
	name = "Neotokyo competitive, PUG Module",
	description =  "",
	author = "Rain",
	version = PLUGIN_VERSION,
	url = "https://github.com/Rainyan/sourcemod-nt-competitive"
};

public OnPluginStart()
{
	RegConsoleCmd("sm_pug", Command_Pug);
	RegConsoleCmd("sm_unpug", Command_UnPug);
	RegConsoleCmd("sm_join", Command_Accept);

#if DEBUG_SQL
	RegAdminCmd("sm_pug_createdb", Command_CreateTables, ADMFLAG_RCON, "Create PUG tables in database. Debug command.");
#endif

	g_hCvar_DbConfig = CreateConVar("sm_pug_db_cfg", "pug", "Database config entry name", FCVAR_PROTECTED);

	g_hTimer_CheckQueue = CreateTimer(g_fQueueTimer_Interval, Timer_CheckQueue, _, TIMER_REPEAT);
	g_fQueueTimer_DeltaTime = IntToFloat(QUEUE_CHECK_TIMER);
}

public OnConfigsExecuted()
{
	// Just do this once
	if (g_bIsJustLoaded)
	{
		Database_Initialize();
		GenerateIdentifier_This();
		Organizers_Update_This();
#if DEBUG_SQL
		CheckSQLConstants();
#endif
		g_bIsJustLoaded = false;
	}
}

// Purpose: Check if any puggers are marked "confirming", and display the invite panel for those connected to this server
public Action:Timer_CheckQueue(Handle:timer)
{
	// This is called once per interval, so it represents time elapsed
	g_fQueueTimer_DeltaTime -= g_fQueueTimer_Interval;

	if (!g_bIsQueueActive)
	{
		// Loop timer's inactive period isn't over yet, stop here.
		// We do this to avoid database spam when there is no active match preparations.
		if (g_fQueueTimer_DeltaTime > 0)
		{
			return Plugin_Continue;
		}
		// Inactive period has elapsed, reset delta variable and continue execution.
		else
		{
			g_fQueueTimer_DeltaTime = IntToFloat(QUEUE_CHECK_TIMER);
		}
	}

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ?", g_sqlTable_Puggers, g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE]);

	new Handle:stmt_Select = SQL_PrepareQuery(db, sql, error, sizeof(error));
	if (stmt_Select == INVALID_HANDLE)
		ThrowError(error);

	SQL_BindParamInt(stmt_Select, 0, PUGGER_STATE_CONFIRMING);
	SQL_Execute(stmt_Select);

	new rows;
	while (SQL_FetchRow(stmt_Select))
	{
		rows++;
		decl String:steamID[MAX_STEAMID_LENGTH];
		SQL_FetchString(stmt_Select, SQL_TABLE_PUGGER_STEAMID, steamID, sizeof(steamID));

		new client = GetClientOfAuthId(steamID);
		Pugger_ShowMatchOfferMenu(client);
	}
	CloseHandle(stmt_Select);

	// There are puggers waiting to confirm their match, mark queue as active
	if (rows > 0)
		g_bIsQueueActive = true;
	// Pugger queue is not active right now
	else
		g_bIsQueueActive = false;

	return Plugin_Continue;
}

// Purpose: Add this server into the organizers database table, and set its reserve status.
// FIXME: Need to take others' status into consideration when setting status other than default
void Organizers_Update_This(reserveStatus = SERVER_DB_INACTIVE)
{
	PrintDebug("Organizers_Update_This()");

	if (SERVER_DB_INACTIVE > reserveStatus > SERVER_DB_ENUM_COUNT)
		ThrowError("Invalid reserve status %i. Expected status between %i and %i", reserveStatus, SERVER_DB_INACTIVE, SERVER_DB_ENUM_COUNT-1);

	Database_Initialize();

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ?", g_sqlTable_Organizers, g_sqlRow_Organizers[SQL_TABLE_ORG_NAME]);

	new Handle:stmt_Select = SQL_PrepareQuery(db, sql, error, sizeof(error));
	SQL_BindParamString(stmt_Select, 0, g_sIdentifier, false);
	SQL_Execute(stmt_Select);

	if (stmt_Select == INVALID_HANDLE)
		ThrowError(error);

	new results = SQL_GetRowCount(stmt_Select);
	PrintDebug("Results: %i", results);

	CloseHandle(stmt_Select);

	// Delete duplicate records
	if (results > 1)
	{
		//FIXME: Maybe should not expect 0 rows (Command_CreateTables)
		LogError("Organizers_Update_This(): Found %i results from database for organizer \"%s\", expected 0 or 1.", results, g_sIdentifier);

		Format(sql, sizeof(sql), "DELETE FROM %s WHERE %s = ?", g_sqlTable_Organizers, g_sqlRow_Organizers[SQL_TABLE_ORG_NAME]);

		new Handle:stmt_Delete = SQL_PrepareQuery(db, sql, error, sizeof(error));
		if (stmt_Delete == INVALID_HANDLE)
			ThrowError(error);

		SQL_BindParamString(stmt_Delete, 0, g_sIdentifier, false);
		SQL_Execute(stmt_Delete);
		CloseHandle(stmt_Delete);
	}
	// No record, insert new one
	if (results > 1 || results == 0)
	{
		Format(sql, sizeof(sql), "INSERT INTO %s (%s, %s) VALUES (?, ?)", g_sqlTable_Organizers, g_sqlRow_Organizers[SQL_TABLE_ORG_NAME], g_sqlRow_Organizers[SQL_TABLE_ORG_RESERVING]);

		new Handle:stmt_Insert = SQL_PrepareQuery(db, sql, error, sizeof(error));
		if (stmt_Insert == INVALID_HANDLE)
			ThrowError(error);

		new paramIndex;
		SQL_BindParamString(stmt_Insert, paramIndex++, g_sIdentifier, false);
		SQL_BindParamInt(stmt_Insert, paramIndex++, reserveStatus);
		SQL_Execute(stmt_Insert);
		CloseHandle(stmt_Insert);
	}
	// Record already exists, just update
	else
	{
		Format(sql, sizeof(sql), "UPDATE %s SET %s = ? WHERE %s = ?", g_sqlTable_Organizers, g_sqlRow_Organizers[SQL_TABLE_ORG_RESERVING], g_sqlRow_Organizers[SQL_TABLE_ORG_NAME]);

		new Handle:stmt_Update = SQL_PrepareQuery(db, sql, error, sizeof(error));
		if (stmt_Update == INVALID_HANDLE)
			ThrowError(error);

		new paramIndex;
		SQL_BindParamInt(stmt_Update, paramIndex++, reserveStatus);
		SQL_BindParamString(stmt_Update, paramIndex++, g_sIdentifier, false);
		SQL_Execute(stmt_Update);
		CloseHandle(stmt_Update);
	}
}

// Purpose: Return reserve status int enum of this org server
int Organizers_Get_Status_This()
{
	PrintDebug("Organizers_Get_Status_This()");
	Database_Initialize();

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ?", g_sqlTable_Organizers, g_sqlRow_Organizers[SQL_TABLE_ORG_NAME]);

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
		ThrowError("Found %i results for identifier %s, expected 1.", results, g_sIdentifier);
	}
	CloseHandle(stmt_Select);

	if (SERVER_DB_INACTIVE > status >= SERVER_DB_ENUM_COUNT)
		ThrowError("Status %i is out of enum bounds %i - %i", status, SERVER_DB_INACTIVE, SERVER_DB_ENUM_COUNT-1);

	return status;
}

public Action:Command_Pug(client, args)
{
	if (g_bIsDatabaseDown)
	{
			ReplyToCommand(client, "%s Command failed due to database error.", g_sTag);
			ReplyToCommand(client, "Please contact server admins for help.");
			return Plugin_Stop;
	}

	if (client == 0)
	{
		ReplyToCommand(client, "This command cannot be executed from the server console.");
		return Plugin_Stop;
	}

	new puggerState = Pugger_GetQueuingState(client);

	if (puggerState == PUGGER_STATE_QUEUING)
	{
		ReplyToCommand(client, "%s You are already queuing. Use !unpug to leave the queue.", g_sTag);
		return Plugin_Stop;
	}
	else if (puggerState == PUGGER_STATE_LIVE)
	{
		ReplyToCommand(client, "%s You already have a match live. Use !join to rejoin your match.", g_sTag); // TODO: Use function to display pug server info instead (helps with mapload crashing)
		//Pugger_ShowJoinInfo(client);
		return Plugin_Stop;
	}

	Database_AddPugger(client);
	ReplyToCommand(client, "%s You have joined the PUG queue.", g_sTag);

	FindNewMatch();

	return Plugin_Handled;
}

bool Organizers_Is_Anyone_Busy(bool includeMyself = true)
{
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s", g_sqlTable_Organizers);

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
		if (dbState != SERVER_DB_INACTIVE)
			return true;
	}
	CloseHandle(stmt_Select);

	return false;
}

void FindNewMatch()
{
	// Is anyone (including myself) busy organizing a match with the DB right now?
	if (Organizers_Is_Anyone_Busy())
		return;

	// Are there any available PUG servers?
	if (Database_GetRowCountForTableName(g_sqlTable_PickupServers) < 1) // BUG / FIXME: This is row count regardless of state, need PUG_SERVER_STATUS_AVAILABLE specifically!
		return;

	// Are there enough queued puggers available?
	if (Puggers_GetCountPerState(PUGGER_STATE_QUEUING) < DESIRED_PLAYERCOUNT)
		return;

	OfferMatch();
}

void OfferMatch()
{
	Organizers_Update_This(SERVER_DB_RESERVED);	// Reserve database
	PugServer_Reserve();												// Reserve a PUG server
	Puggers_Reserve();													// Reserve puggers to offer match for
	Organizers_Update_This();										// Release database reservation
}

public Action:Command_UnPug(client, args)
{
	if (g_bIsDatabaseDown)
	{
			ReplyToCommand(client, "%s Command failed due to database error.", g_sTag);
			ReplyToCommand(client, "Please contact server admins for help.");
			return Plugin_Stop;
	}

	Database_RemovePugger(client);
	return Plugin_Handled;
}

public Action:Command_Accept(client, args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "This command cannot be executed from the server console.");
		return Plugin_Stop;
	}

	switch (Pugger_GetQueuingState(client))
	{
		case PUGGER_STATE_INACTIVE:
		{
			ReplyToCommand(client, "%s You are not in the PUG queue!", g_sTag);
		}
		case PUGGER_STATE_QUEUING:
		{
			ReplyToCommand(client, "%s You are currently not invited to a match.", g_sTag);
		}
		case PUGGER_STATE_CONFIRMING:
		{
			AcceptMatch(client);
		}
		case PUGGER_STATE_ACCEPTED:
		{
			ReplyToCommand(client, "%s You've already accepted the match. Check your console for join details.", g_sTag);
			// TODO: join details
			//Pugger_ShowJoinInfo(client);
		}
		case PUGGER_STATE_LIVE:
		{
			ReplyToCommand(client, "%s You already have a match live! Check your console for join details.", g_sTag);
			// TODO: join details
			//Pugger_ShowJoinInfo(client);
		}
	}
	return Plugin_Handled;
}

void AcceptMatch(client)
{
	PrintDebug("AcceptMatch()");

	if (!Client_IsValid(client) || IsFakeClient(client))
		ThrowError("Invalid or fake client %i", client);

	g_iInviteTimerDisplay[client] = 0;

	// FIXME: Add check to avoid this accidentally failing whilst calling Organizers_Update_This() and preparing match accept
	if (Organizers_Get_Status_This() != SERVER_DB_RESERVED)
	{
		ReplyToCommand(client, "%s Joining time has ended.", g_sTag);
		return;
	}

	ReplyToCommand(client, "AcceptMatch passed.");
}

#if DEBUG_SQL
// Create all the necessary tables in the database
// TODO: Always log this command to a logfile
public Action:Command_CreateTables(client, args)
{
	new rows;
	rows += Database_GetRowCountForTableName(g_sqlTable_Puggers);
	rows += Database_GetRowCountForTableName(g_sqlTable_Organizers);
	rows += Database_GetRowCountForTableName(g_sqlTable_PickupServers);

	if (rows > 0)
	{
		ReplyToCommand(client, "%s Database returned %i already existing PUG rows!", g_sTag, rows);
		ReplyToCommand(client, "Make sure no PUG tables exist before running this command.");
		ReplyToCommand(client, "No new tables were created by this command.");

		decl String:clientName[MAX_NAME_LENGTH];
		GetClientName(client, clientName, sizeof(clientName));
		LogError("Client %i (\"%s\") attempted to run Command_CreateTables while %i PUG rows already exist. Command was aborted. PUG plugin debug level: %i. SQL debug level: %i", client, clientName, rows, DEBUG, DEBUG_SQL);
		return Plugin_Stop;
	}

	Database_Initialize();
	decl String:sql[MAX_SQL_LENGTH];

	// todo: optimise INT sizes
	new arrayIndex = SQL_TABLE_PUGGER_ENUM_COUNT-1; // Reversed array index for Format() order of operations
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
									PRIMARY KEY (%s)) CHARACTER SET=utf8",
									g_sqlTable_Puggers,
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
									g_sqlRow_Puggers[SQL_TABLE_PUGGER_ID]
	);

	//PrintDebug("SQL: %s", sql);

	new Handle:query_CreatePuggers = SQL_Query(db, sql);
	CloseHandle(query_CreatePuggers);

	arrayIndex = SQL_TABLE_ORG_ENUM_COUNT-1; // Reversed array index for Format() order of operations
	Format(sql, sizeof(sql), "CREATE TABLE IF NOT EXISTS %s ( \
									%s INT NOT NULL AUTO_INCREMENT, \
									%s TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, \
									%s VARCHAR(128) NOT NULL, \
									%s INT NOT NULL, \
									%s TIMESTAMP NOT NULL, \
									PRIMARY KEY (%s)) CHARACTER SET=utf8",
									g_sqlTable_Organizers,
									g_sqlRow_Organizers[arrayIndex--],
									g_sqlRow_Organizers[arrayIndex--],
									g_sqlRow_Organizers[arrayIndex--],
									g_sqlRow_Organizers[arrayIndex--],
									g_sqlRow_Organizers[arrayIndex--],
									g_sqlRow_Organizers[SQL_TABLE_ORG_ID]
	);
	new Handle:query_CreateOrganizers = SQL_Query(db, sql);
	CloseHandle(query_CreateOrganizers);

	arrayIndex = SQL_TABLE_PUG_SERVER_ENUM_COUNT-1; // Reversed array index for Format() order of operations
	Format(sql, sizeof(sql), "CREATE TABLE IF NOT EXISTS %s ( \
									%s INT NOT NULL AUTO_INCREMENT, \
									%s TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, \
									%s VARCHAR(128) NOT NULL, \
									%s VARCHAR (45) NOT NULL, \
									%s INT NOT NULL, \
									%s VARCHAR(%i) NOT NULL, \
									%s INT NOT NULL, \
									%s VARCHAR(128) NOT NULL, \
									%s TIMESTAMP NOT NULL, \
									PRIMARY KEY (%s)) CHARACTER SET=utf8",
									g_sqlTable_PickupServers,
									g_sqlRow_PickupServers[arrayIndex--],
									g_sqlRow_PickupServers[arrayIndex--],
									g_sqlRow_PickupServers[arrayIndex--],
									g_sqlRow_PickupServers[arrayIndex--],
									g_sqlRow_PickupServers[arrayIndex--],
									g_sqlRow_PickupServers[arrayIndex--], MAX_CVAR_LENGTH,
									g_sqlRow_PickupServers[arrayIndex--],
									g_sqlRow_PickupServers[arrayIndex--],
									g_sqlRow_PickupServers[arrayIndex--],
									g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_ID]
	);

	new Handle:query_CreatePugServers = SQL_Query(db, sql);
	CloseHandle(query_CreatePugServers);

	//PrintDebug("SQL:\n%s", sql);

	return Plugin_Handled;
}

int Database_GetRowCountForTableName(const String:tableName[])
{
	CheckForSpookiness(tableName);
	Database_Initialize();

	decl String:sql[MAX_SQL_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s", tableName);

	new Handle:query = SQL_Query(db, sql);
	new rows = SQL_GetRowCount(query);

	CloseHandle(query);
	return rows;
}
#endif

void Database_AddPugger(client)
{
	if (!Client_IsValid(client) || IsFakeClient(client))
		ThrowError("Invalid client %i", client);

	Database_Initialize();

	decl String:steamID[MAX_STEAMID_LENGTH];
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	GetClientAuthId(client, AuthId_Steam2, steamID, sizeof(steamID));

	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE steamid = ?", g_sqlTable_Puggers);

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
			Format(sql, sizeof(sql), "UPDATE %s SET %s = ?, %s = NOW() WHERE %s = ?", g_sqlTable_Puggers, g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE], g_sqlRow_Puggers[SQL_TABLE_PUGGER_TIMESTAMP], g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID]);

			new Handle:updateStmt = SQL_PrepareQuery(db, sql, error, sizeof(error));

			new paramIndex;
			SQL_BindParamInt(updateStmt, paramIndex++, PUGGER_STATE_QUEUING);
			SQL_BindParamString(updateStmt, paramIndex++, steamID, false);

			SQL_Execute(updateStmt);
			CloseHandle(updateStmt);

			if (SQL_MoreRows(stmt))
			{
				LogError("Database_AddPugger(%i): Found more than 1 results, expected 0 or 1", client);
				break;
			}
		}
	}
	// Pugger not yet in database, insert
	else
	{
		Format(sql, sizeof(sql), "INSERT INTO %s (%s, %s, %s) VALUES (?, ?, NOW())", g_sqlTable_Puggers, g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID], g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE], g_sqlRow_Puggers[SQL_TABLE_PUGGER_TIMESTAMP]);

		new Handle:insertStmt = SQL_PrepareQuery(db, sql, error, sizeof(error));

		new paramIndex;
		SQL_BindParamString(insertStmt, paramIndex++, steamID, false);
		SQL_BindParamInt(insertStmt, paramIndex++, PUGGER_STATE_QUEUING);

		SQL_Execute(insertStmt);
		CloseHandle(insertStmt);
	}

	CloseHandle(stmt);
}

void Database_RemovePugger(client)
{
	if (client == 0)
	{
		ReplyToCommand(client, "This command cannot be executed from the server console.");
		return;
	}
	if (!Client_IsValid(client) || IsFakeClient(client))
	{
		ThrowError("Invalid client %i", client);
	}

	g_iInviteTimerDisplay[client] = 0;

	Database_Initialize();

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE steamid = ?", g_sqlTable_Puggers);

	new Handle:stmt = SQL_PrepareQuery(db, sql, error, sizeof(error));
	if (stmt == INVALID_HANDLE)
		ThrowError(error);

	decl String:steamID[MAX_STEAMID_LENGTH];
	GetClientAuthId(client, AuthId_Steam2, steamID, sizeof(steamID));

	SQL_BindParamString(stmt, 0, steamID, false);
	SQL_Execute(stmt);

	new results = SQL_GetRowCount(stmt);

	if (results > 1)
	{
		LogError("Database_RemovePugger(%i): Found %i results for SteamID \"%s\" in database, expected to find 1. Deleting duplicates.", client, results, steamID);

		Format(sql, sizeof(sql), "DELETE FROM %s WHERE %s = ?", g_sqlTable_Puggers, g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID]);

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
			LogError("Database_RemovePugger(%i): Found 0 results for SteamID \"%s\" in database, inserting a row with PUGGER_STATE_INACTIVE", client, steamID);
		}

		Format(sql, sizeof(sql), "INSERT INTO %s (%s, %s) VALUES (?, ?)", g_sqlTable_Puggers, g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID], g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE]);

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
		while (SQL_FetchRow(stmt))
		{
			new state = SQL_FetchInt(stmt, SQL_TABLE_PUGGER_STATE);

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
				ReplyToCommand(client, "%s You have left the PUG queue. Declining offered match.", g_sTag);

				Database_LogIgnore(client);
				Pugger_CloseMatchOfferMenu(client);
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
				LogError("Database_RemovePugger(): Pugger state for \"%s\" returned %i. This should never happen.", steamID, state);
			}
		}
		CloseHandle(stmt);

		// Remove player from active PUG queue
		Format(sql, sizeof(sql), "UPDATE %s SET %s = ? WHERE %s = ?", g_sqlTable_Puggers, g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE], g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID]);

		new Handle:stmt_Update = SQL_PrepareQuery(db, sql, error, sizeof(error));
		if (stmt_Update == INVALID_HANDLE)
			ThrowError(error);

		new paramIndex;
		SQL_BindParamInt(stmt_Update, paramIndex++, PUGGER_STATE_INACTIVE);
		SQL_BindParamString(stmt_Update, paramIndex++, steamID, false);
		SQL_Execute(stmt_Update);
		CloseHandle(stmt_Update);
	}
}

void Database_LogIgnore(client)
{
	//TODO
	PrintDebug("Database_LogIgnore(%i)", client);
}

int Pugger_GetQueuingState(client)
{
	if (!Client_IsValid(client) || IsFakeClient(client))
		ThrowError("Invalid client %i", client);

	Database_Initialize();

	decl String:steamID[MAX_STEAMID_LENGTH];
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	GetClientAuthId(client, AuthId_Steam2, steamID, sizeof(steamID));

	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE steamid = ?", g_sqlTable_Puggers);

	new Handle:stmt = SQL_PrepareQuery(db, sql, error, sizeof(error));

	SQL_BindParamString(stmt, 0, steamID, false);
	SQL_Execute(stmt);

	new state = PUGGER_STATE_INACTIVE;
	while (SQL_FetchRow(stmt))
	{
		state = SQL_FetchInt(stmt, SQL_TABLE_PUGGER_STATE);

		if (SQL_MoreRows(stmt))
		{
			LogError("Pugger_GetQueuingState(%i): Found more than 1 results, expected 0 or 1", client);
			break;
		}
	}
	CloseHandle(stmt);

	return state;
}

int Puggers_GetCountPerState(state)
{
	if (0 > state > PUGGER_STATE_ENUM_COUNT)
	{
		ThrowError("Invalid state %i, expected state between 0 and %i", state, PUGGER_STATE_ENUM_COUNT);
	}

	Database_Initialize();

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ?", g_sqlTable_Puggers, g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE]);

	new Handle:stmt = SQL_PrepareQuery(db, sql, error, sizeof(error));

	SQL_BindParamInt(stmt, 0, state);
	SQL_Execute(stmt);

	new results = SQL_GetRowCount(stmt);
	CloseHandle(stmt);

	return results;
}

void PugServer_Reserve()
{
	Database_Initialize();

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s", g_sqlTable_PickupServers);

	new Handle:query_Pugs = SQL_Query(db, sql);

	new bool:foundServer;
	new status;
	while (SQL_FetchRow(query_Pugs))
	{
		status = SQL_FetchInt(query_Pugs, SQL_TABLE_PUG_SERVER_STATUS);
		if (status == PUG_SERVER_STATUS_AVAILABLE)
		{
			foundServer = true;

			decl String:identifier[MAX_IDENTIFIER_LENGTH];
			SQL_FetchString(query_Pugs, SQL_TABLE_PUG_SERVER_NAME, identifier, sizeof(identifier));

			Format(sql, sizeof(sql), "UPDATE %s SET %s = ? WHERE %s = ?", g_sqlTable_PickupServers, g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_STATUS], g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_NAME]);
			new Handle:stmt_Update = SQL_PrepareQuery(db, sql, error, sizeof(error));
			if (stmt_Update == INVALID_HANDLE)
				ThrowError(error);

			new paramIndex;
			SQL_BindParamInt(stmt_Update, paramIndex++, PUG_SERVER_STATUS_RESERVED);
			SQL_BindParamString(stmt_Update, paramIndex++, identifier, false);
			SQL_Execute(stmt_Update);
			CloseHandle(stmt_Update);

			break;
		}
	}
	CloseHandle(query_Pugs);

	if (!foundServer)
	{
		Organizers_Update_This();
		ThrowError("Could not find a PUG server to reserve although one was found earlier. This should never happen.");
	}
}

void Puggers_Reserve()
{
	Database_Initialize();

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = %i ORDER BY %s", g_sqlTable_Puggers, g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE], PUGGER_STATE_QUEUING, g_sqlRow_Puggers[SQL_TABLE_PUGGER_ID]);

	new Handle:query_Puggers = SQL_Query(db, sql);

	new i;
	new state;
	while (SQL_FetchRow(query_Puggers))
	{
		if (i >= DESIRED_PLAYERCOUNT)
			break;

		state = SQL_FetchInt(query_Puggers, SQL_TABLE_PUGGER_STATE);
		if (state != PUGGER_STATE_QUEUING)
			continue;

		Format(sql, sizeof(sql), "UPDATE %s SET %s = ? WHERE %s = ?", g_sqlTable_Puggers, g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE], g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID]);
		new Handle:stmt_Update = SQL_PrepareQuery(db, sql, error, sizeof(error));
		if (stmt_Update == INVALID_HANDLE)
			ThrowError(error);

		decl String:steamID[MAX_STEAMID_LENGTH];
		SQL_FetchString(query_Puggers, SQL_TABLE_PUGGER_STEAMID, steamID, sizeof(steamID));

		new paramIndex;
		SQL_BindParamInt(stmt_Update, paramIndex++, PUGGER_STATE_CONFIRMING);
		SQL_BindParamString(stmt_Update, paramIndex++, steamID, false);
		SQL_Execute(stmt_Update);

		if (SQL_GetAffectedRows(stmt_Update) != 1)
		{
			CloseHandle(stmt_Update);
			CloseHandle(query_Puggers);
			Organizers_Update_This();
			ThrowError("SQL query affected %i rows, expected 1. This shouldn't happen.", SQL_GetAffectedRows(stmt_Update));
		}
		CloseHandle(stmt_Update);

		i++;
	}
	CloseHandle(query_Puggers);

	if (i != DESIRED_PLAYERCOUNT)
		ThrowError("Could not find %i desired players, found %i instead. This should never happen.", DESIRED_PLAYERCOUNT, i);
}

float IntToFloat(integer)
{
	return integer * 1.0;
}

void Pugger_ShowMatchOfferMenu(client)
{
	if (!Client_IsValid(client) || IsFakeClient(client))
		return;

	if (g_iInviteTimerDisplay[client] <= 0)
		g_iInviteTimerDisplay[client] = PUG_INVITE_TIME;

	decl String:offer_ServerIP[45];
	decl String:offer_ServerPassword[MAX_CVAR_LENGTH];
	new offer_ServerPort;

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ?", g_sqlTable_PickupServers, g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_STATUS]);

	new Handle:stmt_Select = SQL_PrepareQuery(db, sql, error, sizeof(error));
	if (stmt_Select == INVALID_HANDLE)
		ThrowError(error);

	SQL_BindParamInt(stmt_Select, 0, PUG_SERVER_STATUS_RESERVED);
	SQL_Execute(stmt_Select);

	while (SQL_FetchRow(stmt_Select))
	{
		SQL_FetchString(stmt_Select, SQL_TABLE_PUG_SERVER_CONNECT_IP, offer_ServerIP, sizeof(offer_ServerIP));
		SQL_FetchString(stmt_Select, SQL_TABLE_PUG_SERVER_CONNECT_PASSWORD, offer_ServerPassword, sizeof(offer_ServerPassword));
		offer_ServerPort = SQL_FetchInt(stmt_Select, SQL_TABLE_PUG_SERVER_CONNECT_PORT);
	}
	CloseHandle(stmt_Select);
/*
	PrintToChat(client, "Invite: %s:%i:%s", offer_ServerIP, offer_ServerPort, offer_ServerPassword);
	PrintToConsole(client, "Invite: %s:%i:%s", offer_ServerIP, offer_ServerPort, offer_ServerPassword);
	PrintDebug("Client %i Invite: %s:%i:%s", client, offer_ServerIP, offer_ServerPort, offer_ServerPassword);
*/
	new Handle:panel = CreatePanel();

	SetPanelTitle(panel, "Match is ready");
	DrawPanelText(panel, " ");

	decl String:text_TimeToAccept[24];
	Format(text_TimeToAccept, sizeof(text_TimeToAccept), "Time to accept: %i", g_iInviteTimerDisplay[client]);
	DrawPanelText(panel, text_TimeToAccept);

	decl String:text_PlayersReady[24];
	Format(text_PlayersReady, sizeof(text_PlayersReady), "%i / %i players accepted", Puggers_GetCountPerState(PUGGER_STATE_ACCEPTED), DESIRED_PLAYERCOUNT);
	DrawPanelText(panel, text_PlayersReady);

	DrawPanelText(panel, " ");
	DrawPanelText(panel, "Type !join to accept the match, or");
	DrawPanelText(panel, "type !unpug to leave the queue.");

	SendPanelToClient(panel, client, PanelHandler_Pugger_SendMatchOffer, PUG_INVITE_TIME);
	CloseHandle(panel);

	g_iInviteTimerDisplay[client]--;
}

void Pugger_CloseMatchOfferMenu(client)
{
	if (!Client_IsValid(client) || IsFakeClient(client))
		return;

	new Handle:panel = CreatePanel();
	SetPanelTitle(panel, "Your PUG invite has expired...");

	new displayTime = 2;
	SendPanelToClient(panel, client, PanelHandler_Pugger_CloseMatchOfferMenu, displayTime);
	CloseHandle(panel);
}

public PanelHandler_Pugger_SendMatchOffer(Handle:menu, MenuAction:action, client, choice)
{
	return;
}

public PanelHandler_Pugger_CloseMatchOfferMenu(Handle:menu, MenuAction:action, client, choice)
{
	return;
}

int GetClientOfAuthId(const String:steamID[])
{
	decl String:buffer_SteamID[MAX_STEAMID_LENGTH];
	for (new i = 1; i <= MaxClients; i++)
	{
		if (!Client_IsValid(i) || IsFakeClient(i))
			continue;

		GetClientAuthId(i, AuthId_Steam2, buffer_SteamID, sizeof(buffer_SteamID));

		if (StrEqual(steamID, buffer_SteamID))
			return i;
	}
	return 0;
}


void Database_Initialize()
{
	PrintDebug("Database_Initialize()");

	decl String:configName[MAX_CVAR_LENGTH];
	GetConVarString(g_hCvar_DbConfig, configName, sizeof(configName));
	if (!SQL_CheckConfig(configName))
	{
		g_bIsDatabaseDown = true;
		ThrowError("Could not find a config named \"%s\". Please check your databases.cfg", configName);
	}

	decl String:error[MAX_SQL_ERROR_LENGTH];
	db = SQL_Connect(configName, true, error, sizeof(error)); // Persistent connection

	if (db == null)
	{
		g_bIsDatabaseDown = true;
		ThrowError(error);
	}
	else
	{
		g_bIsDatabaseDown = false;
	}
}

void PrintDebug(const String:message[], any ...)
{
#if DEBUG
	decl String:formatMsg[768];
	VFormat(formatMsg, sizeof(formatMsg), message, 2);

	// Todo: Print to debug logfile
	PrintToServer(formatMsg);
#endif
}

// Purpose: Generate a unique identifier for recognizing this server in the database, based on ip:port
void GenerateIdentifier_This()
{
	// The identifier has been manually set before compiling, no need to generate one
	if (!StrEqual(g_sIdentifier, ""))
		return;

	new Handle:cvarIP = FindConVar("ip");
	if (cvarIP == INVALID_HANDLE)
		SetFailState("Could not find cvar \"ip\"");

	decl String:ipAddress[MAX_IP_LENGTH];
	GetConVarString(cvarIP, ipAddress, sizeof(ipAddress));
	CloseHandle(cvarIP);

#if DEBUG_SQL == 0 // Skip this check when debugging
	if (StrEqual(ipAddress, "localhost") || StrEqual(ipAddress, "127.0.0.1") || StrContains(ipAddress, "192.168.") == 0)
		SetFailState("Could not get real external IP address, returned a local address \"%s\" instead. This can't be used for uniquely identifying the server. You can declare a unique g_sIdentifier value near the beginning of the plugin source code to manually circumvent this problem.", ipAddress);
#endif

	new Handle:cvarPort = FindConVar("hostport");
	if (cvarPort == INVALID_HANDLE)
		SetFailState("Could not find cvar \"hostport\"");

	new port = GetConVarInt(cvarPort);
	CloseHandle(cvarPort);

	Format(g_sIdentifier, sizeof(g_sIdentifier), "%s:%i", ipAddress, port);

#if DEBUG
	PrintDebug("GenerateIdentifier_This(): %s", g_sIdentifier);
#endif
}

#if DEBUG_SQL
void CheckSQLConstants()
{
	CheckForSpookiness(g_sIdentifier);
	CheckForSpookiness(g_sqlTable_Organizers);
	CheckForSpookiness(g_sqlTable_PickupServers);
	CheckForSpookiness(g_sqlTable_Puggers);

	for (new i = 0; i < sizeof(g_sqlRow_Puggers); i++)
		CheckForSpookiness(g_sqlRow_Puggers[i]);
}

void CheckForSpookiness(const String:haystack[])
{
	if (StrContains(haystack, "\"") != -1 || StrContains(haystack, ";") != -1)
		SetFailState("Found potentially dangerous characters \" or ; inside the plugin's SQL string, which could result to incorrect SQL statements. Check your plugin source code for errors. String contents: \"%s\"", haystack);
}
#endif
