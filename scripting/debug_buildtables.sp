/*
	NOTE: If you get the "Exception reported: Script execution timed out"
	error message during the SQL processing, you can temporarily adjust
	the timeout threshold at SourceMod's core.cfg value "SlowScriptTimeout".
*/

#pragma semicolon 1

#define DEBUG 1
#define DEBUG_SQL 1

new const String:g_sTag[] = "[COMP-SQL-BUILDER]";

#include <sourcemod>
#include <neotokyo>
#include "nt_competitive/shared_variables"
#include "nt_competitive/shared_functions"
#include "nt_competitive/nt_competitive_sql"

public Plugin myinfo = {
	name = "Neotokyo Competitive, SQL Table Build Helper",
	description = "Build all the NT SQL tables from enumerations",
	author = "Rain",
	version = "0.1",
	url = "https://github.com/Rainyan/sourcemod-nt-competitive"
};

public void OnPluginStart()
{
	g_hCvar_DbConfig = CreateConVar(
		"sm_pug_db_cfg",
		"pug",
		"Database config entry name",
		FCVAR_PROTECTED
	);

	RegAdminCmd("sm_pug_createdb", Command_CreateTables, ADMFLAG_RCON,
		"Create PUG tables in database. Debug/dev command.");
}

public void OnConfigsExecuted()
{
	if (!Database_Initialize(false)) {
		SetFailState("SQL initialisation failed.");
	}
}

public Action Command_CreateTables(int client, int args)
{
	if (g_bIsDatabaseDown) {
		ReplyToCommand(client, "Database connection is down.");
		return Plugin_Stop;
	}
	DatabaseHelper_CreateTables(client);
	return Plugin_Handled;
}

void DatabaseHelper_CreateTables(int client)
{
	PrintDebug("Database_CreateTables initiated by client %i", client);

	int rows;
	for (int i = 0; i < TABLES_ENUM_COUNT; i++)
	{
		rows += Database_GetRowCountForTableName(g_sqlTable[i], false);
	}
	PrintDebug("Command_CreateTables() rows: %i", rows);

	if (rows > 0)
	{
		ThrowError("Attempted to run Command_CreateTables while %i \
PUG rows already exist. Command was aborted.", rows);
	}

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	// Build global rules table
	// Reversed array index for Format() order of operations
	int arrayIndex = SQL_TABLE_RULES_ENUM_COUNT-1;
	Format(sql, sizeof(sql), "CREATE TABLE IF NOT EXISTS %s ( \
%s INT NOT NULL AUTO_INCREMENT, \
%s INT NOT NULL, \
PRIMARY KEY (%s)) CHARACTER SET=utf8",
		g_sqlTable[TABLES_RULES],
		g_sqlRow_Rules[arrayIndex--],
		g_sqlRow_Rules[arrayIndex--],
		g_sqlRow_Rules[SQL_TABLE_RULES_ID]
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

	// Build puggers table
	// TODO: optimise INT sizes
	// Reversed array index for Format() order of operations
	arrayIndex = SQL_TABLE_PUGGER_ENUM_COUNT-1;
	Format(sql, sizeof(sql), "CREATE TABLE IF NOT EXISTS %s ( \
%s INT NOT NULL AUTO_INCREMENT, \
%s TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, \
%s VARCHAR(%i) NOT NULL, \
%s VARCHAR(%i), \
%s VARCHAR(%i), \
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
		g_sqlRow_Puggers[arrayIndex--], MAX_SNOWFLAKE_LENGTH,
		g_sqlRow_Puggers[arrayIndex--], MAX_DISCORD_SECRET_LENGTH,
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
		{
			new const String:helper[] = "(If this error is about a timestamp, \
you probably need to disable NO_ZERO_DATE from your SQL setup.) Error msg was: ";
			decl String:errorBuffer[sizeof(error) + sizeof(helper) + 1];
			StrCat(errorBuffer, sizeof(errorBuffer), helper);
			StrCat(errorBuffer, sizeof(errorBuffer), error);
		
			ThrowError(errorBuffer);
		}
		else
		{
			ThrowError("SQL query failed, but could not fetch error.");
		}
	}

	// Build organizers table
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

	// Build pickup servers table
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

	// Build matches table
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

	// Build match history table
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

	// Build Discord "secret" auth table
	arrayIndex = SQL_TABLE_DISCORD_AUTH_ENUM_COUNT-1;
	Format(sql, sizeof(sql), "CREATE TABLE IF NOT EXISTS %s ( \
%s INT NOT NULL AUTO_INCREMENT, \
%s TIMESTAMP DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP, \
%s VARCHAR(%i) NOT NULL, \
%s VARCHAR(%i) NOT NULL, \
%s VARCHAR(%i) NOT NULL, \
PRIMARY KEY (%s)) CHARACTER SET=utf8",
		g_sqlTable[TABLES_DISCORD_AUTHENTICATION],
		g_sqlRow_DiscordAuth[arrayIndex--],
		g_sqlRow_DiscordAuth[arrayIndex--],
		g_sqlRow_DiscordAuth[arrayIndex--], MAX_STEAMID_LENGTH,
		g_sqlRow_DiscordAuth[arrayIndex--], MAX_DISCORD_SECRET_LENGTH,
		g_sqlRow_DiscordAuth[arrayIndex--], MAX_SNOWFLAKE_LENGTH,
		g_sqlRow_DiscordAuth[SQL_TABLE_DISCORD_AUTH_ID]
	);
	if (!SQL_FastQuery(g_hDB, sql))
	{
		if (SQL_GetError(g_hDB, error, sizeof(error)))
			ThrowError(error);
		ThrowError("SQL query failed, but could not fetch error.");
	}

	PrintDebug("%s SQL build completed.", g_sTag);
}
