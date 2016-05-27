#pragma semicolon 1

#include <sourcemod>
#include <smlib>
#include "nt_competitive/nt_competitive_sql"

#define DEBUG 1
#define DEBUG_SQL 1
#define PLUGIN_VERSION "0.1"

#define MAX_CVAR_LENGTH 64
#define MAX_STEAMID_LENGTH 44

new Handle:g_hCvar_DbConfig;

new bool:g_isDatabaseDown;

new const String:g_tag[] = "[PUG]";

public Plugin:myinfo = {
	name = "Neotokyo competitive, PUG Module",
	description =  "",
	author = "",
	version = PLUGIN_VERSION,
	url = ""
};

public OnPluginStart()
{
	CheckSQLConstants();
	
	RegConsoleCmd("sm_pug", Command_Pug);
	
#if DEBUG_SQL
	RegAdminCmd("sm_pug_createdb", Command_CreateTables, ADMFLAG_GENERIC, "Create PUG tables in database. Debug command.");
#endif
	
	g_hCvar_DbConfig = CreateConVar("sm_pug_db_cfg", "pug", "Database config entry name", FCVAR_PROTECTED);
}

public OnConfigsExecuted()
{
	Database_Initialize();
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
		ReplyToCommand(client, "This command cannot be executed from server console.");
		return Plugin_Stop;
	}
	
	Database_AddPugger(client);
	LookForMatch();
	
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
									%s VARCHAR(%i), \
									%s INT, \
									%s VARCHAR(45), \
									%s INT, \
									%s INT, \
									%s TIMESTAMP, \
									%s VARCHAR(128), \
									%s INT, \
									%s TIMESTAMP, \
									PRIMARY KEY (%s)) CHARACTER SET=utf8",
									g_sqlTable_Puggers,
									g_sqlRow_Puggers[arrayIndex--],
									g_sqlRow_Puggers[arrayIndex--],
									g_sqlRow_Puggers[arrayIndex--], MAX_STEAMID_LENGTH,
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
	
	arrayIndex = SQL_TABLE_ORG_ENUM_COUNT-1; // Reverse array index for Format()
	Format(sql, sizeof(sql), "CREATE TABLE IF NOT EXISTS %s ( \
									%s INT NOT NULL AUTO_INCREMENT, \
									%s TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, \
									%s VARCHAR(128), \
									%s BOOL, \
									%s TIMESTAMP, \
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
									%s VARCHAR(128), \
									%s VARCHAR (45), \
									%s INT, \
									%s VARCHAR(%i), \
									%s INT, \
									%s VARCHAR(128), \
									%s TIMESTAMP, \
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
	
	new puggerState = Pugger_GetQueuingState(client);
	
	if (puggerState == PUGGER_STATE_QUEUING)
	{
		ReplyToCommand(client, "%s You are already queuing. Use !unpug to leave the queue.", g_tag);
		return;
	}
	else if (puggerState == PUGGER_STATE_LIVE)
	{
		ReplyToCommand(client, "%s You already have a match live. Use !join to rejoin your match.", g_tag);
		return;
	}
	
	Database_Initialize();
	
	decl String:steamID[MAX_STEAMID_LENGTH];
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	
	GetClientAuthId(client, AuthId_Steam2, steamID, sizeof(steamID));
	
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE steamid = ?", g_sqlTable_Puggers);
	
	new Handle:stmt = SQL_PrepareQuery(db, sql, error, sizeof(error));
	
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
	
	new state = PUGGER_STATE_NEW;
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

void LookForMatch()
{
	PrintDebug("Puggers queued: %i", Puggers_GetCountPerState(PUGGER_STATE_QUEUING));
	
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
	//Format(sql, sizeof(sql), "SELECT * FROM %s", g_sqlTable_Organizers);
	Format(sql, sizeof(sql), "SELECT * FROM %s", g_sqlTable_PickupServers);
	
	new Handle:query = SQL_Query(db, sql);
	
	PrintDebug("LookForMatch: Found %i PUG server(s)", SQL_GetRowCount(query));
	
	decl String:name[128];
	decl String:ip[128];
	decl String:password[128];
	decl String:reservee[128];
	decl String:reservation_timestamp[128];
	new port;
	new status;
	
	// Loop PUG servers info
	while (SQL_FetchRow(query))
	{	
		SQL_FetchString(query, SQL_TABLE_PUG_SERVER_NAME, name, sizeof(name));
		SQL_FetchString(query, SQL_TABLE_PUG_SERVER_CONNECT_IP, ip, sizeof(ip));
		SQL_FetchString(query, SQL_TABLE_PUG_SERVER_CONNECT_PASSWORD, password, sizeof(password));
		SQL_FetchString(query, SQL_TABLE_PUG_SERVER_RESERVEE, reservee, sizeof(reservee));
		SQL_FetchString(query, SQL_TABLE_PUG_SERVER_RESERVATION_TIMESTAMP, reservation_timestamp, sizeof(reservation_timestamp));
		
		port = SQL_FetchInt(query, SQL_TABLE_PUG_SERVER_CONNECT_PORT);
		status = SQL_FetchInt(query, SQL_TABLE_PUG_SERVER_STATUS);
		
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
	}
	
	CloseHandle(query);
}

void Database_Initialize()
{
	PrintDebug("Database_Initialize()");
	
	decl String:error[MAX_SQL_ERROR_LENGTH];
	decl String:configName[MAX_CVAR_LENGTH];
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

void PrintDebug(const String:message[], any ...)
{
#if DEBUG
	decl String:formatMsg[512];
	VFormat(formatMsg, sizeof(formatMsg), message, 2);
	
	PrintToServer(formatMsg);
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