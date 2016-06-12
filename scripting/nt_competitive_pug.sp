#pragma semicolon 1

#include <sourcemod>
#include <smlib>
#include "nt_competitive/nt_competitive_sql"

#define DEBUG 1
#define DEBUG_SQL 1 // Make sure this is set to 0 unless you really want to debug the SQL as it disables some safety checks
#define PLUGIN_VERSION "0.1"

#define MAX_CVAR_LENGTH 64
#define MAX_STEAMID_LENGTH 44
#define PUG_INVITE_TIME 60

#define DESIRED_PLAYERCOUNT 2 // This could be non-hardcoded later

new Handle:g_hCvar_DbConfig;

new Handle:g_hTimer_FindMatch = INVALID_HANDLE;
new Handle:g_hTimer_InviteExpiration = INVALID_HANDLE;

new bool:g_isDatabaseDown;

new const String:g_tag[] = "[PUG]";

new String:g_identifier[52]; // Set this to something uniquely identifying if the plugin fails to retrieve your IP.

public Plugin:myinfo = {
	name = "Neotokyo competitive, PUG Module",
	description =  "",
	author = "Rain",
	version = PLUGIN_VERSION,
	url = "https://github.com/Rainyan/sourcemod-nt-competitive"
};

public OnPluginStart()
{
	CheckSQLConstants();
	
	RegConsoleCmd("sm_pug", Command_Pug);
	RegConsoleCmd("sm_unpug", Command_UnPug);
	
#if DEBUG_SQL
	RegAdminCmd("sm_pug_createdb", Command_CreateTables, ADMFLAG_GENERIC, "Create PUG tables in database. Debug command.");
#endif
	
	g_hCvar_DbConfig = CreateConVar("sm_pug_db_cfg", "pug", "Database config entry name", FCVAR_PROTECTED);
}

public OnConfigsExecuted()
{
	Database_Initialize();
	GenerateIdentifier_This();
	Organizers_Update_This();
	
	/*
	if (g_hTimer_FindMatch == INVALID_HANDLE)
		CreateTimer(30.0, Timer_FindMatch, _, TIMER_REPEAT);
	*/
}

public Action:Timer_FindMatch(Handle:timer)
{
	FindMatch();
	return Plugin_Continue;
}

// Purpose: Add this server into the organizers database table
void Organizers_Update_This()
{
	PrintDebug("Organizers_Update_This()");
	
	Database_Initialize();
	
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ?", g_sqlTable_Organizers, g_sqlRow_Organizers[SQL_TABLE_ORG_NAME]);
	
	//PrintDebug(sql);
	
	new Handle:stmt_Select = SQL_PrepareQuery(db, sql, error, sizeof(error));
	SQL_BindParamString(stmt_Select, 0, g_identifier, false);
	SQL_Execute(stmt_Select);
	
	if (stmt_Select == INVALID_HANDLE)
		ThrowError(error);
	
	new results = SQL_GetRowCount(stmt_Select);
	PrintDebug("Results: %i", results);
	
	CloseHandle(stmt_Select);
	
	// Delete duplicate records
	if (results > 1)
	{
		Format(sql, sizeof(sql), "DELETE FROM %s WHERE %s = ?", g_sqlTable_Organizers, g_sqlRow_Organizers[SQL_TABLE_ORG_NAME]);
		
		//PrintDebug("SQL: \n%s", sql);
		
		new Handle:stmt_Delete = SQL_PrepareQuery(db, sql, error, sizeof(error));
		if (stmt_Delete == INVALID_HANDLE)
			ThrowError(error);
		
		SQL_BindParamString(stmt_Delete, 0, g_identifier, false);
		SQL_Execute(stmt_Delete);
		CloseHandle(stmt_Delete);
	}
	// No record, insert new one
	if (results > 1 || results == 0)
	{
		Format(sql, sizeof(sql), "INSERT INTO %s (%s, %s) VALUES (?, false)", g_sqlTable_Organizers, g_sqlRow_Organizers[SQL_TABLE_ORG_NAME], g_sqlRow_Organizers[SQL_TABLE_ORG_RESERVING]);
		
		//PrintDebug("SQL: \n%s", sql);
		
		new Handle:stmt_Insert = SQL_PrepareQuery(db, sql, error, sizeof(error));
		if (stmt_Insert == INVALID_HANDLE)
			ThrowError(error);
		
		SQL_BindParamString(stmt_Insert, 0, g_identifier, false);
		SQL_Execute(stmt_Insert);
		CloseHandle(stmt_Insert);
	}
	// Record already exists, just update
	else
	{
		Format(sql, sizeof(sql), "UPDATE %s SET %s = false WHERE %s = ?", g_sqlTable_Organizers, g_sqlRow_Organizers[SQL_TABLE_ORG_RESERVING], g_sqlRow_Organizers[SQL_TABLE_ORG_NAME]);
		
		//PrintDebug("SQL: \n%s", sql);
		
		new Handle:stmt_Update = SQL_PrepareQuery(db, sql, error, sizeof(error));
		if (stmt_Update == INVALID_HANDLE)
			ThrowError(error);
		
		SQL_BindParamString(stmt_Update, 0, g_identifier, false);
		SQL_Execute(stmt_Update);
		CloseHandle(stmt_Update);
	}
}

public Action:Command_Pug(client, args)
{
	if (g_isDatabaseDown)
	{
			ReplyToCommand(client, "%s Command failed due to database error.", g_tag);
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
		ReplyToCommand(client, "%s You are already queuing. Use !unpug to leave the queue.", g_tag);
		return Plugin_Stop;
	}
	else if (puggerState == PUGGER_STATE_LIVE)
	{
		ReplyToCommand(client, "%s You already have a match live. Use !join to rejoin your match.", g_tag);
		return Plugin_Stop;
	}
	
	Database_AddPugger(client);
	ReplyToCommand(client, "%s You have joined the PUG queue.", g_tag);
	
	FindMatch();
	
	return Plugin_Handled;
}

public Action:Command_UnPug(client, args)
{
	if (g_isDatabaseDown)
	{
			ReplyToCommand(client, "%s Command failed due to database error.", g_tag);
			ReplyToCommand(client, "Please contact server admins for help.");
			return Plugin_Stop;
	}
	
	if (client == 0)
	{
		ReplyToCommand(client, "This command cannot be executed from the server console.");
		return Plugin_Stop;
	}
	
	Database_RemovePugger(client);
	ReplyToCommand(client, "%s You have left the PUG queue.", g_tag);
	
	return Plugin_Handled;
}

#if DEBUG_SQL
// Create all the necessary tables in the database
public Action:Command_CreateTables(client, args)
{
	Database_Initialize();
	
	decl String:sql[MAX_SQL_LENGTH];
	
	// todo: optimise INT sizes
	new arrayIndex = SQL_TABLE_PUGGER_ENUM_COUNT-1; // Reverse array index for Format()
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
	
	PrintDebug("SQL: %s", sql);
	
	new Handle:query_CreatePuggers = SQL_Query(db, sql);
	CloseHandle(query_CreatePuggers);
	
	arrayIndex = SQL_TABLE_ORG_ENUM_COUNT-1; // Reverse array index for Format()
	Format(sql, sizeof(sql), "CREATE TABLE IF NOT EXISTS %s ( \
									%s INT NOT NULL AUTO_INCREMENT, \
									%s TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, \
									%s VARCHAR(128) NOT NULL, \
									%s BOOL NOT NULL, \
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
	
	arrayIndex = SQL_TABLE_PUG_SERVER_ENUM_COUNT-1; // Reverse array index for Format()
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
	
	new results = SQL_GetRowCount(stmt);
	CloseHandle(stmt);
	
	if (results > 1)
	{
		LogError("Database_RemovePugger(%i): Found %i results for SteamID \"%s\" in database, expected to find 1. Deleting duplicates.", client, results, steamID);
		
		Format(sql, sizeof(sql), "DELETE FROM %s WHERE %s = ?", g_sqlTable_Puggers, g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID]);
		
		new Handle:stmt_Delete = SQL_PrepareQuery(db, sql, error, sizeof(error));
		if (stmt_Delete == INVALID_HANDLE)
			ThrowError(error);
		
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
			ThrowError(error);
		
		new paramIndex;
		SQL_BindParamString(stmt_Insert, paramIndex++, steamID, false);
		SQL_BindParamInt(stmt_Insert, paramIndex++, PUGGER_STATE_INACTIVE);
		SQL_Execute(stmt_Insert);
		CloseHandle(stmt_Insert);
	}
	else if (results == 1)
	{
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

void FindMatch()
{
	PrintDebug("FindMatch()");
	
	PrintDebug("Puggers queued: %i (%i wanted per match)", Puggers_GetCountPerState(PUGGER_STATE_QUEUING), DESIRED_PLAYERCOUNT);
	
	// Offer match if enough players available
	
	/*
		- Is match creation currently open?
		- Are there pug servers currently available?
		- Reserve match creation
		- Who have queued for longest?
		- Are they not afk?
		- Prepare game server
		- Set states in pugger table
		- Release match creation
	*/
	
	Database_Initialize();
	
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	
	decl String:name[128];
	decl String:ip[128];
	decl String:password[128];
	decl String:reservee[128];
	decl String:reservation_timestamp[128];
	new port;
	new status;
	
	// Loop organizers info
	Format(sql, sizeof(sql), "SELECT * FROM %s", g_sqlTable_Organizers);
	
	new Handle:query_Organizers = SQL_Query(db, sql);
	
	PrintDebug("FindMatch: Found %i organizer(s)", SQL_GetRowCount(query_Organizers));
	
	decl String:timestamp[128];
	decl String:reserving_timestamp[128];
	new isReserving;
	
	// First query pass, make sure nobody else is already reserving a match
	while (SQL_FetchRow(query_Organizers))
	{
		// todo: proper error handling
		if (isReserving)
			ThrowError("Multiple organizers report themselves reserving match simultaneously.");
		
		SQL_FetchString(query_Organizers, SQL_TABLE_ORG_NAME, name, sizeof(name));
		SQL_FetchString(query_Organizers, SQL_TABLE_ORG_TIMESTAMP, timestamp, sizeof(timestamp));
		SQL_FetchString(query_Organizers, SQL_TABLE_ORG_RESERVING_TIMESTAMP, reserving_timestamp, sizeof(reserving_timestamp));
		
		isReserving = SQL_FetchInt(query_Organizers, SQL_TABLE_ORG_RESERVING);
		
		PrintDebug("\n- - -\n\
						Organizer info: %s\n\
						timestamp: %s\n\
						reserving: %i\n\
						reserving timestamp: %s\n\
						- - -",
						name, timestamp, isReserving, reserving_timestamp
		);
		
		if (isReserving)
		{
			// Someone else is currently reserving a match, stop and try again later.
			if (!StrEqual(name, g_identifier))
			{
				PrintDebug("Another server with identifier %s is currently reserving a match.", name);
				return;
			}
			else
			{
				// todo: proper error handling
				LogError("This organizer had already been set to reserving status at %s without clearing it.", timestamp);
			}
		}
	}
	CloseHandle(query_Organizers);
	
	// Reserve match organizing
	Format(sql, sizeof(sql), "UPDATE %s SET %s = true WHERE %s = ?", g_sqlTable_Organizers, g_sqlRow_Organizers[SQL_TABLE_ORG_RESERVING], g_sqlRow_Organizers[SQL_TABLE_ORG_NAME]);
	
	new Handle:stmt_Reserve = SQL_PrepareQuery(db, sql, error, sizeof(error));
	SQL_BindParamString(stmt_Reserve, 0, g_identifier, false);
	SQL_Execute(stmt_Reserve);
	CloseHandle(stmt_Reserve);
	
	// Loop PUG servers info
	Format(sql, sizeof(sql), "SELECT * FROM %s", g_sqlTable_PickupServers);
	
	new Handle:query_Pugs = SQL_Query(db, sql);
	
	PrintDebug("FindMatch: Found %i PUG server(s)", SQL_GetRowCount(query_Pugs));
	
	new serversAvailable;
	
	decl String:reservedServer_Name[128];
	decl String:reservedServer_IP[46];
	decl String:reservedServer_Password[MAX_CVAR_LENGTH];
	new reservedServer_Port;
	
	while (SQL_FetchRow(query_Pugs))
	{
		SQL_FetchString(query_Pugs, SQL_TABLE_PUG_SERVER_NAME, name, sizeof(name));
		SQL_FetchString(query_Pugs, SQL_TABLE_PUG_SERVER_CONNECT_IP, ip, sizeof(ip));
		SQL_FetchString(query_Pugs, SQL_TABLE_PUG_SERVER_CONNECT_PASSWORD, password, sizeof(password));
		SQL_FetchString(query_Pugs, SQL_TABLE_PUG_SERVER_RESERVEE, reservee, sizeof(reservee));
		SQL_FetchString(query_Pugs, SQL_TABLE_PUG_SERVER_RESERVATION_TIMESTAMP, reservation_timestamp, sizeof(reservation_timestamp));
		
		port = SQL_FetchInt(query_Pugs, SQL_TABLE_PUG_SERVER_CONNECT_PORT);
		status = SQL_FetchInt(query_Pugs, SQL_TABLE_PUG_SERVER_STATUS);
		
		PrintDebug("\n- - -\n\
						Server info: %s\n\
						%s:%i\n\
						password: %s\n\
						status: %i\n\
						reservee: %s\n\
						reservation timestamp: %s\n\
						- - -",
						name, ip, port, password, status, reservee, reservation_timestamp
		);
		
		if (status == PUG_SERVER_STATUS_AVAILABLE)
		{
			serversAvailable++;
			
			strcopy(reservedServer_Name, sizeof(reservedServer_Name), name);
			strcopy(reservedServer_IP, sizeof(reservedServer_IP), ip);
			strcopy(reservedServer_Password, sizeof(reservedServer_Password), password);
			reservedServer_Port = port;
		}
	}
	CloseHandle(query_Pugs);
	
	// There are no PUG servers available right now, try again later
	if (serversAvailable == 0)
	{
		PrintDebug("No PUG servers available right now");
		
		// Release match organizing
		Format(sql, sizeof(sql), "UPDATE %s SET %s = false WHERE %s = ?", g_sqlTable_Organizers, g_sqlRow_Organizers[SQL_TABLE_ORG_RESERVING], g_sqlRow_Organizers[SQL_TABLE_ORG_NAME]);
		
		new Handle:stmt_Release = SQL_PrepareQuery(db, sql, error, sizeof(error));
		if (stmt_Release == INVALID_HANDLE)
			ThrowError(error);
		
		//PrintDebug("SQL is: %s", sql);
		//PrintDebug("My identifier is: %s", g_identifier);
		
		SQL_BindParamString(stmt_Release, 0, g_identifier, false);
		SQL_Execute(stmt_Release);
		CloseHandle(stmt_Release);
		
		return;
	}
	
	Format(sql, sizeof(sql), "UPDATE %s SET %s=? WHERE %s=? AND %s=?", g_sqlTable_PickupServers, g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_STATUS], g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_IP], g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_PORT]);
	
	new Handle:stmt_UpdateState = SQL_PrepareQuery(db, sql, error, sizeof(error));
	if (stmt_UpdateState == INVALID_HANDLE)
		ThrowError(error);
	
	new paramIndex;
	SQL_BindParamInt(stmt_UpdateState, paramIndex++, PUG_SERVER_STATUS_RESERVED);
	SQL_BindParamString(stmt_UpdateState, paramIndex++, reservedServer_IP, false);
	SQL_BindParamInt(stmt_UpdateState, paramIndex++, reservedServer_Port);
	SQL_Execute(stmt_UpdateState);
	CloseHandle(stmt_UpdateState);
	
	// Passed all checks, can offer a PUG match to the players in queue
	OfferMatch(reservedServer_Name, reservedServer_IP, reservedServer_Port, reservedServer_Password);
}

void OfferMatch(const String:serverName[], const String:serverIP[], serverPort, const String:serverPassword[])
{
	PrintDebug("OfferMatch(%s, %s, %i, %s)", serverName, serverIP, serverPort, serverPassword);
	
	/*
		- Get players info, determine priority, offer match
		- Release organizers reservation
	*/
	
	Database_Initialize();
	
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = %i ORDER BY %s", g_sqlTable_Puggers, g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE], PUGGER_STATE_QUEUING, g_sqlRow_Puggers[SQL_TABLE_PUGGER_ID]);
	
	new Handle:query = SQL_Query(db, sql);
	
	new results = SQL_GetRowCount(query);
	PrintDebug("Results: %i", results);
	
	if (results < DESIRED_PLAYERCOUNT)
	{
		CloseHandle(query);
		PrintToServer("There are not enough queuing players to offer a match.");
		PrintToChatAll("There are not enough queuing players to offer a match.");
		return;
	}
	
	// Declare 2D arrays of current PUG queuers
	new String:puggers_SteamID[results][MAX_STEAMID_LENGTH];
	new String:puggers_Timestamp[results][MAX_SQL_TIMESTAMP_LENGTH];
	new String:puggers_ignoredTimestamp[results][MAX_SQL_TIMESTAMP_LENGTH];
	new puggers_ignoredInvites[results];
	
	// Populate queuer arrays
	new i;
	while (SQL_FetchRow(query))
	{
		SQL_FetchString(query, SQL_TABLE_PUGGER_STEAMID, puggers_SteamID[i], MAX_STEAMID_LENGTH);
		SQL_FetchString(query, SQL_TABLE_PUGGER_TIMESTAMP, puggers_Timestamp[i], MAX_SQL_TIMESTAMP_LENGTH);
		SQL_FetchString(query, SQL_TABLE_PUGGER_IGNORED_TIMESTAMP, puggers_ignoredTimestamp[i], MAX_SQL_TIMESTAMP_LENGTH);
		puggers_ignoredInvites[i] = SQL_FetchInt(query, SQL_TABLE_PUGGER_IGNORED_INVITES);
		i++;
	}
	CloseHandle(query);
	
	// Loop of viable puggers to offer match for.
	
	// Todo 1: Set up basic match announce system based on who queued first
	// Todo 2: Set up logic to take queueing time and player's "afk-ness" into account determining their priority in PUG queue (basically avoid offering matches to AFK players over and over without excluding them altogether)
	if (results < DESIRED_PLAYERCOUNT)
		ThrowError("results (%i) < DESIRED_PLAYERCOUNT (%i)", results, DESIRED_PLAYERCOUNT);
	
	for (i = 0; i < DESIRED_PLAYERCOUNT; i++)
	{
		PrintDebug("Pugger info %i: %s, %s, %s, %i", i, puggers_SteamID[i], puggers_Timestamp[i], puggers_ignoredTimestamp[i], puggers_ignoredInvites[i]);
		
		// Set pugger's invite rows in database
		Format(sql, sizeof(sql), "UPDATE %s SET %s = ?, %s = ?, %s = ?, %s = ?",
		g_sqlTable_Puggers,
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_GAMESERVER_CONNECT_IP],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_GAMESERVER_CONNECT_PORT],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_GAMESERVER_PASSWORD]
		);
		
		PrintDebug("UPDATE SQL:\n%s", sql);
		
		new Handle:stmt = SQL_PrepareQuery(db, sql, error, sizeof(error));
		if (stmt == INVALID_HANDLE)
			ThrowError(error);
		
		new paramIndex;
		SQL_BindParamInt(stmt, paramIndex++, PUGGER_STATE_CONFIRMING);
		PrintDebug("Param %i: %i", paramIndex, PUGGER_STATE_CONFIRMING);
		
		SQL_BindParamString(stmt, paramIndex++, serverIP, false);
		PrintDebug("Param %i: %s", paramIndex, serverIP);
		
		SQL_BindParamInt(stmt, paramIndex++, serverPort);
		PrintDebug("Param %i: %i", paramIndex, serverPort);
		
		SQL_BindParamString(stmt, paramIndex++, serverPassword, false);
		PrintDebug("Param %i: %s", paramIndex, serverPassword);
		
		SQL_Execute(stmt);
		CloseHandle(stmt);
		
		new client = GetClientOfAuthId(puggers_SteamID[i]);
		// Client is not present on this server
		if (client == 0)
			continue;
		
		Pugger_SendMatchOffer(client);
	}
		
	DataPack serverData = new DataPack();
	serverData.WriteString(serverName);
	serverData.WriteString(serverIP);
	serverData.WriteString(serverPassword);
	serverData.WriteCell(serverPort);
	
	g_hTimer_InviteExpiration = CreateTimer(IntToFloat(PUG_INVITE_TIME), Timer_InviteExpiration, serverData);
}

float IntToFloat(integer)
{
	return integer * 1.0;
}

public Action:Timer_InviteExpiration(Handle:timer, DataPack:serverData)
{
	// Max invite time has passed, cancel current invitation if it hasn't passed
	PrintDebug("Max invite time has passed, cancel current invitation if it hasn't passed");
	
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s", g_sqlTable_Puggers);
	
	new Handle:query = SQL_Query(db, sql);
	if (query == INVALID_HANDLE)
	{
		LogError("Timer_InviteExpiration(): SQL error while executing: \"%s\"", sql);
		CloseHandle(serverData);
		return Plugin_Stop;
	}
	
	new results_AcceptedMatch;			// How many players accepted match invite
	new results_IgnoredMatch;			// How many players ignored match invite
	new results_AvailableAlternatives;	// How many extra players are available in case some didn't accept
	new results_Total;						// How many players were found total, with any state
	
	while (SQL_FetchRow(query))
	{
		switch (SQL_FetchInt(query, SQL_TABLE_PUGGER_STATE))
		{
			case PUGGER_STATE_ACCEPTED:
				results_AcceptedMatch++;
			
			case PUGGER_STATE_IGNORED:
				results_IgnoredMatch++;
			
			case PUGGER_STATE_QUEUING:
				results_AvailableAlternatives++;
		}
		results_Total++;
	}
	CloseHandle(query);
	
	PrintDebug("Invite results:\nAccepted: %i\nIgnored: %i\nAvailable extras: %i\nTotal amount: %i", results_AcceptedMatch, results_IgnoredMatch, results_AvailableAlternatives, results_Total);
	
	new String:serverName[128];
	new String:serverIP[46];
	new String:serverPassword[MAX_CVAR_LENGTH];
	new serverPort;
	
	// Retrieve PUG server info from datapack
	serverData.Reset();
	serverData.ReadString(serverName, sizeof(serverName));
	serverData.ReadString(serverIP, sizeof(serverIP));
	serverData.ReadString(serverPassword, sizeof(serverPassword));
	serverPort = serverData.ReadCell();
	CloseHandle(serverData);
	// TODO: confirm variables are properly populated
	
	PrintDebug("Server data: %s %s : %i : %s", serverName, serverIP, serverPort, serverPassword);
	
	// Everyone accepted the match.
	if (results_AcceptedMatch == DESIRED_PLAYERCOUNT)
	{
		// Find the PUG server in database
		Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s=? AND %s=?", g_sqlTable_PickupServers, g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_IP], g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_PORT]);
		
		new Handle:stmt = SQL_PrepareQuery(db, sql, error, sizeof(error));
		if (stmt == INVALID_HANDLE)
		{
			LogError("Timer_InviteExpiration(): %s", error);
			return Plugin_Stop;
		}
		
		new paramIndex;
		SQL_BindParamString(stmt, paramIndex++, serverIP, false);
		SQL_BindParamInt(stmt, paramIndex++, serverPort);
		SQL_Execute(stmt);
		PrintDebug("SQL: %s", sql);
		PrintDebug("Params: %s, %i", serverIP, serverPort);
		
		new rows = SQL_GetRowCount(stmt);
		if (rows < 1)
		{
			LogError("Timer_InviteExpiration(): Could not find the PUG server %s:%i that was supposed to be reserved for this match.", serverIP, serverPort);
			CloseHandle(stmt);
			return Plugin_Stop;
		}
		if (rows > 1)
		{
			LogError("Timer_InviteExpiration(): Found %i results for PUG server %s:%i that was supposed to be reserved for this match, expected to find 1 result.", rows, serverIP, serverPort);
			CloseHandle(stmt);
			return Plugin_Stop;
		}
		
		new status;
		new String:serverPassword_Db[MAX_CVAR_LENGTH];
		while (SQL_FetchRow(stmt))
		{
			status = SQL_FetchInt(stmt, SQL_TABLE_PUG_SERVER_STATUS);
			//SQL_FetchString(stmt, SQL_TABLE_PUG_SERVER_CONNECT_PASSWORD, serverPassword_Db, sizeof(serverPassword_Db));
		}
		
		// TODO: Make sure this never happens
		if (!StrEqual(serverPassword, serverPassword_Db))
		{
			LogError("Timer_InviteExpiration(): Current server password (\"%s\") is different from the one offered to the PUG players (\"%s\")", serverPassword_Db, serverPassword);
			
			PrintDebug("serverPassword length: %i, serverPassword_Db length: %i", strlen(serverPassword), strlen(serverPassword_Db));
			
			CloseHandle(stmt);
			return Plugin_Stop;
		}
		
		if (status == PUG_SERVER_STATUS_ERROR || status == PUG_SERVER_STATUS_BUSY)
		{
			LogError("Timer_InviteExpiration(): Expected PUG server is returning an incompatible status %i. Expected PUG_SERVER_STATUS_RESERVED (%i), PUG_SERVER_STATUS_AWAITING_PLAYERS(%i) or PUG_SERVER_STATUS_LIVE(%i)", status, PUG_SERVER_STATUS_RESERVED, PUG_SERVER_STATUS_AWAITING_PLAYERS, PUG_SERVER_STATUS_LIVE);
			CloseHandle(stmt);
			return Plugin_Stop;
		}
		// Update server status to "awaiting players" if it isn't already and the match isn't live yet
		if (status == PUG_SERVER_STATUS_RESERVED)
		{
			Format(sql, sizeof(sql), "UPDATE %s SET %s = ? WHERE %s = ? AND %s = ?", g_sqlTable_PickupServers, g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_STATUS], g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_IP], g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_CONNECT_PORT]);
			
			new Handle:stmt_UpdateState = SQL_PrepareQuery(db, sql, error, sizeof(error));
			if (stmt_UpdateState == INVALID_HANDLE)
			{
				LogError("Timer_InviteExpiration(): %s", error);
				CloseHandle(stmt);
				return Plugin_Stop;
			}
			
			paramIndex = 0;
			SQL_BindParamInt(stmt_UpdateState, paramIndex++, PUG_SERVER_STATUS_AWAITING_PLAYERS);
			SQL_BindParamString(stmt_UpdateState, paramIndex++, serverIP, false);
			SQL_BindParamInt(stmt_UpdateState, paramIndex++, serverPort);
			SQL_Execute(stmt_UpdateState);
			
			CloseHandle(stmt_UpdateState);
		}
	}
	// Everyone didn't accept, however there are enough replacement players.
	else if (results_IgnoredMatch <= results_AvailableAlternatives)
	{
		// TODO: Offer this match to others queued as required and try again.
	}
	// Everyone didn't accept, and there aren't enough replacements.
	else
	{
		// TODO: Give up, and release organizing again.
	}
	
	// This should never happen.
	if (results_AcceptedMatch > DESIRED_PLAYERCOUNT)
	{
		LogError("Timer_InviteExpiration(): results_AcceptedMatch (%i) > DESIRED_PLAYERCOUNT (%i)", results_AcceptedMatch, DESIRED_PLAYERCOUNT);
	}
	
	return Plugin_Stop;
}

void Pugger_SendMatchOffer(client)
{
	if (!Client_IsValid(client) || IsFakeClient(client))
		ThrowError("Invalid client %i", client);
	
	Database_Initialize();
	
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	
	decl String:steamID[MAX_STEAMID_LENGTH];
	GetClientAuthId(client, AuthId_Steam2, steamID, sizeof(steamID));
	
	decl String:offer_ServerIP[45];
	decl String:offer_ServerPassword[MAX_CVAR_LENGTH];
	new id;
	new offer_ServerPort;
	
	// Get info of server this player is being invited into
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ?", g_sqlTable_Puggers, g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID]);
	
	new Handle:stmt = SQL_PrepareQuery(db, sql, error, sizeof(error));
	if (stmt == INVALID_HANDLE)
		ThrowError(error);
	
	SQL_BindParamString(stmt, 0, steamID, false);
	SQL_Execute(stmt);
	
	new results;
	while (SQL_FetchRow(stmt))
	{
		results++;
		if (results > 1)
		{	
			LogError("Pugger_SendMatchOffer(%i): Found multiple pugger records from database for SteamID %s, expected to find 1.", client, steamID);
			break;
		}
		
		SQL_FetchString(stmt, SQL_TABLE_PUGGER_GAMESERVER_CONNECT_IP, offer_ServerIP, sizeof(offer_ServerIP));
		SQL_FetchString(stmt, SQL_TABLE_PUGGER_GAMESERVER_PASSWORD, offer_ServerPassword, sizeof(offer_ServerPassword));
		id = SQL_FetchInt(stmt, SQL_TABLE_PUGGER_ID);
		offer_ServerPort = SQL_FetchInt(stmt, SQL_TABLE_PUGGER_GAMESERVER_CONNECT_PORT);
	}
	
	if (results == 0)
	{
		CloseHandle(stmt);
		ThrowError("Pugger_SendMatchOffer(%i): Found 0 pugger records from database for SteamID %s, expected to find 1.", client, steamID);
	}
	
	CloseHandle(stmt);
	
	// Return Unix timestamp of when the player queued
	Format(sql, sizeof(sql), "SELECT UNIX_TIMESTAMP(%s) FROM %s WHERE %s = ?", g_sqlRow_Puggers[SQL_TABLE_PUGGER_TIMESTAMP], g_sqlTable_Puggers, g_sqlRow_Puggers[SQL_TABLE_PUGGER_ID]);
	
	new Handle:stmt_Epoch_Queued = SQL_PrepareQuery(db, sql, error, sizeof(error));
	if (stmt_Epoch_Queued == INVALID_HANDLE)
		ThrowError(error);
	
	SQL_BindParamInt(stmt_Epoch_Queued, 0, id);
	SQL_Execute(stmt_Epoch_Queued);
	
	PrintDebug("SQL: %s", sql);
	PrintDebug("ID: %i", id);
	
	new epoch_PlayerQueuedTime;
	while (SQL_FetchRow(stmt_Epoch_Queued))
	{
		epoch_PlayerQueuedTime = SQL_FetchInt(stmt_Epoch_Queued, 0);
		PrintDebug("Epoch: %i", epoch_PlayerQueuedTime);
	}
	CloseHandle(stmt_Epoch_Queued);
	
	PrintToChat(client, "Invite: %s:%i:%s", offer_ServerIP, offer_ServerPort, offer_ServerPassword);
	PrintToConsole(client, "Invite: %s:%i:%s", offer_ServerIP, offer_ServerPort, offer_ServerPassword);
	PrintDebug("Client %i Invite: %s:%i:%s", client, offer_ServerIP, offer_ServerPort, offer_ServerPassword);
	
	new Handle:panel = CreatePanel();
	
	SetPanelTitle(panel, "Match is ready");
	DrawPanelText(panel, " ");
	
	DrawPanelText(panel, "Timer here");
	DrawPanelText(panel, "X/10 players ready");
	
	DrawPanelText(panel, " ");
	DrawPanelText(panel, "Type !join to accept and join the match, or");
	DrawPanelText(panel, "type !unpug to leave the queue.");
	
	SendPanelToClient(panel, client, PanelHandler_Pugger_SendMatchOffer, PUG_INVITE_TIME);
	CloseHandle(panel);	
}

public PanelHandler_Pugger_SendMatchOffer(Handle:menu, MenuAction:action, client, choice)
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
	
	decl String:error[MAX_SQL_ERROR_LENGTH];
	decl String:configName[MAX_CVAR_LENGTH];
	GetConVarString(g_hCvar_DbConfig, configName, sizeof(configName));
	
	db = SQL_Connect(configName, true, error, sizeof(error)); // Persistent connection
	
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
	if (!StrEqual(g_identifier, ""))
		return;
	
	decl String:ipAddress[46];
	new Handle:cvarIP = FindConVar("ip");
	GetConVarString(cvarIP, ipAddress, sizeof(ipAddress));
	CloseHandle(cvarIP);
	
#if DEBUG_SQL < 1
	if (StrEqual(ipAddress, "localhost") || StrEqual(ipAddress, "127.0.0.1") || StrContains(ipAddress, "192.168.") == 0)
		SetFailState("Could not get real IP address, returned \"%s\" instead. This can't be used for uniquely identifying the server. You can declare g_identifier value at the beginning of source code to manually circumvent this problem.", ipAddress);
#endif
	
	new Handle:cvarPort = FindConVar("hostport");
	new port = GetConVarInt(cvarPort);
	CloseHandle(cvarPort);
	
	Format(g_identifier, sizeof(g_identifier), "%s:%i", ipAddress, port);
	
#if DEBUG
	PrintDebug("GenerateIdentifier_This(): %s", g_identifier);
#endif
}

void CheckSQLConstants()
{
	CheckForSpookiness(g_sqlTable_Organizers);
	CheckForSpookiness(g_sqlTable_PickupServers);
	CheckForSpookiness(g_sqlTable_Puggers);
	
	for (new i = 0; i < sizeof(g_sqlRow_Puggers); i++)
		CheckForSpookiness(g_sqlRow_Puggers[i]);
}

void CheckForSpookiness(const String:haystack[])
{
	if (StrContains(haystack, "\"") != -1 || StrContains(haystack, ";") != -1)
		SetFailState("Found potentially dangerous characters \" or ; inside the plugin's SQL string constants, which could result to incorrect SQL statements. Check your plugin source code for errors.");
}