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
		if (Organizers_Update_This())
			SetFailState("Failed to join database");
#if DEBUG_SQL
		CheckSQLConstants();
#endif
		g_bIsJustLoaded = false;
	}

	RegConsoleCmd("sm_pug", Command_Pug);
}

public Action Command_Pug(int client, int args)
{

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
