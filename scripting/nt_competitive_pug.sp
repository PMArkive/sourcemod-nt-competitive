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

new g_iInviteTimerDisplay[MAXPLAYERS+1];

new Float:g_fQueueTimer_Interval = 1.0;
new Float:g_fQueueTimer_DeltaTime;

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
	RegConsoleCmd("sm_pug", Command_Pug);
	RegConsoleCmd("sm_unpug", Command_UnPug);
	RegConsoleCmd("sm_join", Command_Accept);

#if DEBUG_SQL
	RegAdminCmd("sm_pug_createdb", Command_CreateTables, ADMFLAG_RCON,
		"Create PUG tables in database. Debug command.");
#endif

	g_hCvar_DbConfig = CreateConVar("sm_pug_db_cfg", "pug",
		"Database config entry name", FCVAR_PROTECTED);

	CreateTimer(g_fQueueTimer_Interval, Timer_CheckQueue, _, TIMER_REPEAT);
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

// Purpose: Check if it's possible to offer a match to puggers
public Action:Timer_CheckQueue(Handle:timer)
{
	// This is called once per interval, so it represents time elapsed.
	// We only want to rapidly connect to the db if there seem to be
	// some match preparations underway, to avoid spamming it needlessly.
	g_fQueueTimer_DeltaTime -= g_fQueueTimer_Interval;

	if (!g_bIsQueueActive)
	{
		// Loop timer's inactive period isn't over yet, stop here.
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

	Database_Initialize();

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s", g_sqlTable[TABLES_PUGGERS]);

	new Handle:stmt_Select = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt_Select == INVALID_HANDLE)
		ThrowError(error);

	SQL_Execute(stmt_Select);

	new rowsConfirming;
	while (SQL_FetchRow(stmt_Select))
	{
		decl String:steamID[MAX_STEAMID_LENGTH];
		SQL_FetchString(stmt_Select, SQL_TABLE_PUGGER_STEAMID, steamID,
			sizeof(steamID));

		new bool:hasMessage = view_as<bool>
			(SQL_FetchInt(stmt_Select, SQL_TABLE_PUGGER_HAS_MATCH_MSG));

		if (hasMessage)
			Pugger_DisplayMessage(steamID);

		new state = SQL_FetchInt(stmt_Select, SQL_TABLE_PUGGER_STATE);
		if (state == PUGGER_STATE_CONFIRMING)
		{
			new inviteTimeRemaining = Database_GetInviteTimeRemaining(steamID);
			if (inviteTimeRemaining < 0)
			{
				PrintDebug("Invite time has elapsed, un-confirm not readied players.");
				// Remove afkers from queue
				Database_CleanAFKers();
				// Give up current invite, move accepted players back in queue
				Database_GiveUpMatch();
				// Try to find a new match
				OfferMatch();
			}
			rowsConfirming++;

			new client = GetClientOfAuthId(steamID);
			// Client validity checked by function
			Pugger_ShowMatchOfferMenu(client);
		}
	}
	CloseHandle(stmt_Select);

	if (rowsConfirming > 0)
	{
		g_bIsQueueActive = true;
	}
	else
	{
		g_bIsQueueActive = Puggers_Reserve();
	}

	return Plugin_Continue;
}

void Pugger_DisplayMessage(const String:steamID[MAX_STEAMID_LENGTH])
{
	new client = GetClientOfAuthId(steamID);
	if (!IsValidClient(client) || IsFakeClient(client))
		return;

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	// Get message from db
	Format(sql, sizeof(sql), "SELECT %s FROM %s WHERE %s = ? AND %s = ?",
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_MATCH_MSG],
		g_sqlTable[TABLES_PUGGERS],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_HAS_MATCH_MSG]);

	Database_Initialize();
	new Handle:stmt_GetMessage = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt_GetMessage == INVALID_HANDLE)
		ThrowError(error);

	new paramIndex;
	SQL_BindParamString(stmt_GetMessage, paramIndex++, steamID, false);
	SQL_BindParamInt(stmt_GetMessage, paramIndex++, view_as<int>(true));
	SQL_Execute(stmt_GetMessage);

	if (SQL_GetRowCount(stmt_GetMessage) == 0)
		ThrowError("Message not found");

	decl String:message[128];
	while (SQL_FetchRow(stmt_GetMessage))
	{
		SQL_FetchString(stmt_GetMessage, 0, message, sizeof(message));
	}
	CloseHandle(stmt_GetMessage);

	// Display message to player
	PrintToChat(client, message);
	PrintToConsole(client, message);

	// Message is now seen by player, remove it from db
	Format(sql, sizeof(sql), "UPDATE %s SET %s = ?, %s = ? WHERE %s = ?",
		g_sqlTable[TABLES_PUGGERS],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_HAS_MATCH_MSG],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_MATCH_MSG],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID]);

	new Handle:stmt_clearMsg = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt_clearMsg == INVALID_HANDLE)
		ThrowError(error);

	paramIndex = 0;
	SQL_BindParamInt(stmt_clearMsg, paramIndex++, view_as<int>(false));
	SQL_BindParamString(stmt_clearMsg, paramIndex++, "", false);
	SQL_BindParamString(stmt_clearMsg, paramIndex++, steamID, false);
	SQL_Execute(stmt_clearMsg);
	CloseHandle(stmt_clearMsg);
}

void Pugger_ShowMatchFail(const String:steamID[MAX_STEAMID_LENGTH])
{
	new client = GetClientOfAuthId(steamID);

	// Player is on this server, notify them of failed match
	if (IsValidClient(client) && !IsFakeClient(client))
	{
		PrintToChat(client, "%s Match failed as everyone didn't accept. \
Returning to PUG queue.", g_sTag);
		return;
	}

	// Player is not on this server, leave a notification to db for them to read
	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	Format(sql, sizeof(sql), "UPDATE %s SET %s = ?, %s = ? WHERE %s = ?",
	g_sqlTable[TABLES_PUGGERS],
	g_sqlRow_Puggers[SQL_TABLE_PUGGER_HAS_MATCH_MSG],
	g_sqlRow_Puggers[SQL_TABLE_PUGGER_MATCH_MSG],
	g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID]);

	Database_Initialize();
	new Handle:stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == INVALID_HANDLE)
		ThrowError(error);

	new paramIndex;
	SQL_BindParamInt(stmt, paramIndex++, 1);
	SQL_BindParamString(stmt, paramIndex++, "Match failed as everyone didn't \
accept.", false);
	SQL_BindParamString(stmt, paramIndex++, steamID, false);
	SQL_Execute(stmt);

	CloseHandle(stmt);
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
		ReplyToCommand(client, "This command cannot be executed from \
the server console.");
		return Plugin_Stop;
	}

	new puggerState = Pugger_GetQueuingState(client);

	if (puggerState == PUGGER_STATE_QUEUING)
	{
		ReplyToCommand(client, "%s You are already queuing. Use !unpug to leave \
the queue.", g_sTag);
		return Plugin_Stop;
	}
	else if (puggerState == PUGGER_STATE_CONFIRMING)
	{
		ReplyToCommand(client, "%s You are already queuing. Use !join to accept \
the PUG, or !unpug to leave the queue.", g_sTag);
		return Plugin_Stop;
	}
	else if (puggerState == PUGGER_STATE_LIVE)
	{
		// TODO: Use function to display pug server info instead (helps with mapload crashing)
		ReplyToCommand(client, "%s You already have a match live. Use !join to \
rejoin your match.", g_sTag);
		//Pugger_ShowJoinInfo(client);
		return Plugin_Stop;
	}

	Database_AddPugger(client);
	ReplyToCommand(client, "%s You have joined the PUG queue.", g_sTag);

	FindNewMatch();

	return Plugin_Handled;
}

void FindNewMatch()
{
	// Is anyone (including myself) busy organizing a match with the DB right now?
	if (Organizers_Is_Anyone_Busy())
		return;

	// Are there any available PUG servers?
	// BUG / FIXME: This is row count regardless of state,
	// need PUG_SERVER_STATUS_AVAILABLE specifically!
	if (Database_GetRowCountForTableName(g_sqlTable[TABLES_PUG_SERVERS]) < 1)
		return;

	// Are there enough queued puggers available?
	if (Puggers_GetCountPerState(PUGGER_STATE_QUEUING) < Database_GetDesiredPlayerCount())
		return;

	OfferMatch();
}

void OfferMatch()
{
	// Attempt database reservation
	if (!Organizers_Update_This(DB_ORG_RESERVED))
		return;

	// Reserve a PUG server
	if (!ReservePugServer())
	{
		Database_GiveUpMatch();
		return;
	}
	// Reserve puggers
	if (!Puggers_Reserve())
	{
		Database_GiveUpMatch();
		return;
	}
	// Release database reservation
	Organizers_Update_This();
}

public Action:Command_UnPug(client, args)
{
	if (g_bIsDatabaseDown)
	{
		ReplyToCommand(client, "%s Command failed due to database error.", g_sTag);
		ReplyToCommand(client, "Please contact server admins for help.");
		return Plugin_Stop;
	}

	Pugger_Remove(client);
	return Plugin_Handled;
}

public Action:Command_Accept(client, args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "This command cannot be executed from \
the server console.");
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
			ReplyToCommand(client, "%s You are currently not invited to a match.",
				g_sTag);
		}
		case PUGGER_STATE_CONFIRMING:
		{
			AcceptMatch(client);
		}
		case PUGGER_STATE_ACCEPTED:
		{
			ReplyToCommand(client, "%s You've already accepted the match. Check your \
console for join details.", g_sTag);
			// TODO: join details
			//Pugger_ShowJoinInfo(client);
		}
		case PUGGER_STATE_LIVE:
		{
			ReplyToCommand(client, "%s You already have a match live! Check your \
console for join details.", g_sTag);
			// TODO: join details
			//Pugger_ShowJoinInfo(client);
		}
	}
	return Plugin_Handled;
}

void AcceptMatch(client)
{
	PrintDebug("AcceptMatch()");

	if (!IsValidClient(client) || IsFakeClient(client))
		ThrowError("Invalid or fake client %i", client);

	g_iInviteTimerDisplay[client] = 0;

	decl String:steamID[MAX_STEAMID_LENGTH];
	GetClientAuthId(client, AuthId_Steam2, steamID, sizeof(steamID));

	if (Database_GetInviteTimeRemaining(steamID) > PUG_INVITE_TIME)
	{
		ReplyToCommand(client, "%s Joining time has ended.", g_sTag);
		return;
	}
	else if (Pugger_GetQueuingState(client) == PUGGER_STATE_ACCEPTED)
	{
		ReplyToCommand(client, "%s You have already accepted the match.", g_sTag);
		return;
	}

	Pugger_SetQueuingState(client, PUGGER_STATE_ACCEPTED);

	new Handle:panel = CreatePanel();
	SetPanelTitle(panel, "Match accepted. Waiting for others to accept...");
	DrawPanelText(panel, " ");
	DrawPanelItem(panel, "OK");

	new displayTime = 5;
	SendPanelToClient(panel, client, PanelHandler_AcceptMatch, displayTime);
	CloseHandle(panel);
}

bool ReservePugServer()
{
	Database_Initialize();

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s", g_sqlTable[TABLES_PUG_SERVERS]);

	new Handle:query_Pugs = SQL_Query(g_hDB, sql);

	new bool:foundServer;
	new status;
	while (SQL_FetchRow(query_Pugs))
	{
		status = SQL_FetchInt(query_Pugs, SQL_TABLE_PUG_SERVER_STATUS);
		if (status == PUG_SERVER_STATUS_AVAILABLE)
		{
			foundServer = true;

			decl String:identifier[MAX_IDENTIFIER_LENGTH];
			SQL_FetchString(query_Pugs, SQL_TABLE_PUG_SERVER_NAME,
			identifier, sizeof(identifier));

			Format(sql, sizeof(sql), "UPDATE %s SET %s = ? WHERE %s = ?",
				g_sqlTable[TABLES_PUG_SERVERS],
				g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_STATUS],
				g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_NAME]);

			new Handle:stmt_Update = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
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
		/*	Someone not accepting their invite triggers this,
				pretty sure this will fail gracefully instead of
				us needing to throw an error.
		LogError("Could not find a PUG server to reserve \
although one was found earlier. This should never happen.");
		*/
		return false;
	}

	return true;
}

bool Puggers_Reserve()
{
	Database_Initialize();

	PrintDebug("Puggers_Reserve()");

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = %i ORDER BY %s",
		g_sqlTable[TABLES_PUGGERS],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE],
		PUGGER_STATE_QUEUING, g_sqlRow_Puggers[SQL_TABLE_PUGGER_ID]);

	new Handle:query_Puggers = SQL_Query(g_hDB, sql);

	new rows = SQL_GetRowCount(query_Puggers);
	if (rows < Database_GetDesiredPlayerCount())
	{
		PrintDebug("Not enough players in queue");
		CloseHandle(query_Puggers);
		return false;
	}

	new i;
	while (SQL_FetchRow(query_Puggers))
	{
		PrintDebug("While loop");
		if (i >= Database_GetDesiredPlayerCount())
		{
			PrintDebug("Desired playercount: %i", Database_GetDesiredPlayerCount());
			break;
		}

		Format(sql, sizeof(sql), "UPDATE %s SET %s = ?, %s = CURRENT_TIMESTAMP \
WHERE %s = ?",
			g_sqlTable[TABLES_PUGGERS],
			g_sqlRow_Puggers[SQL_TABLE_PUGGER_STATE],
			g_sqlRow_Puggers[SQL_TABLE_PUGGER_INVITE_TIMESTAMP],
			g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID]);

		new Handle:stmt_Update = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
		if (stmt_Update == INVALID_HANDLE)
			ThrowError(error);

		decl String:steamID[MAX_STEAMID_LENGTH];
		SQL_FetchString(query_Puggers, SQL_TABLE_PUGGER_STEAMID, steamID,
			sizeof(steamID));

		new paramIndex;
		SQL_BindParamInt(stmt_Update, paramIndex++, PUGGER_STATE_CONFIRMING);
		SQL_BindParamString(stmt_Update, paramIndex++, steamID, false);
		SQL_Execute(stmt_Update);

		new affectedRows = SQL_GetAffectedRows(stmt_Update);
		if (affectedRows != 1)
		{
			CloseHandle(stmt_Update);
			CloseHandle(query_Puggers);
			Organizers_Update_This();
			ThrowError("SQL query affected %i rows, expected 1. \
This shouldn't happen.", affectedRows);
		}
		CloseHandle(stmt_Update);

		i++;
	}
	CloseHandle(query_Puggers);

	if (i != Database_GetDesiredPlayerCount())
	{
		ThrowError("Could not find %i desired players, found %i instead. \
This should never happen.", Database_GetDesiredPlayerCount(), i);
	}

	return true;
}

float IntToFloat(integer)
{
	return integer * 1.0;
}

void Pugger_ShowMatchOfferMenu(client)
{
	if (!IsValidClient(client) || IsFakeClient(client))
		return;

	decl String:offer_ServerIP[45];
	decl String:offer_ServerPassword[MAX_CVAR_LENGTH];
	//new offer_ServerPort;

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];

	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ?",
	g_sqlTable[TABLES_PUG_SERVERS],
	g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_STATUS]);

	new Handle:stmt_Select = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt_Select == INVALID_HANDLE)
		ThrowError(error);

	SQL_BindParamInt(stmt_Select, 0, PUG_SERVER_STATUS_RESERVED);
	SQL_Execute(stmt_Select);

	while (SQL_FetchRow(stmt_Select))
	{
		SQL_FetchString(stmt_Select, SQL_TABLE_PUG_SERVER_CONNECT_IP,
		offer_ServerIP, sizeof(offer_ServerIP));

		SQL_FetchString(stmt_Select, SQL_TABLE_PUG_SERVER_CONNECT_PASSWORD,
		offer_ServerPassword, sizeof(offer_ServerPassword));

		/*offer_ServerPort = SQL_FetchInt(stmt_Select,
			SQL_TABLE_PUG_SERVER_CONNECT_PORT);*/
	}
	CloseHandle(stmt_Select);
/*
	PrintToChat(client, "Invite: %s:%i:%s",
	offer_ServerIP, offer_ServerPort, offer_ServerPassword);

	PrintToConsole(client, "Invite: %s:%i:%s",
	offer_ServerIP, offer_ServerPort, offer_ServerPassword);

	PrintDebug("Client %i Invite: %s:%i:%s",
	client, offer_ServerIP, offer_ServerPort, offer_ServerPassword);
*/
	decl String:steamID[MAX_STEAMID_LENGTH];
	GetClientAuthId(client, AuthId_Steam2, steamID, sizeof(steamID));

	new timeRemaining = Database_GetInviteTimeRemaining(steamID);
	if (timeRemaining <= 0)
	{
		Pugger_CloseMatchOfferMenu(client);
		return;
	}

	decl String:text_TimeToAccept[24];
	Format(text_TimeToAccept, sizeof(text_TimeToAccept), "Time to accept: %i",
	timeRemaining);

	new Handle:panel = CreatePanel();
	SetPanelTitle(panel, "Match is ready");
	DrawPanelText(panel, " ");
	DrawPanelText(panel, text_TimeToAccept);

	decl String:text_PlayersReady[24];

	Format(text_PlayersReady, sizeof(text_PlayersReady), "%i / %i players accepted",
	Puggers_GetCountPerState(PUGGER_STATE_ACCEPTED), Database_GetDesiredPlayerCount());

	DrawPanelText(panel, text_PlayersReady);

	DrawPanelText(panel, " ");
	DrawPanelText(panel, "Type !join to accept the match, or");
	DrawPanelText(panel, "type !unpug to leave the queue.");

	SendPanelToClient(panel, client, PanelHandler_Pugger_SendMatchOffer,
		PUG_INVITE_TIME);
	CloseHandle(panel);
}

void Pugger_CloseMatchOfferMenu(client)
{
	if (!IsValidClient(client) || IsFakeClient(client))
		return;

	new Handle:panel = CreatePanel();
	SetPanelTitle(panel, "Your PUG invite has expired...");

	new displayTime = 2;
	SendPanelToClient(panel, client, PanelHandler_Pugger_CloseMatchOfferMenu,
		displayTime);
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

public PanelHandler_AcceptMatch(Handle:menu, MenuAction:action, client, choice)
{
	return;
}

int GetClientOfAuthId(const String:steamID[MAX_STEAMID_LENGTH])
{
	decl String:buffer_SteamID[MAX_STEAMID_LENGTH];
	for (new i = 1; i <= MaxClients; i++)
	{
		if (!IsValidClient(i) || IsFakeClient(i))
			continue;

		GetClientAuthId(i, AuthId_Steam2, buffer_SteamID, sizeof(buffer_SteamID));

		if (StrEqual(steamID, buffer_SteamID))
			return i;
	}
	return 0;
}

// Purpose: Generate a unique identifier for
// recognizing this server in the database, based on ip:port
void GenerateIdentifier_This()
{
	// The identifier has been manually set before compiling,
	// no need to generate one
	if (!StrEqual(g_sIdentifier, ""))
		return;

	char ipAddress[MAX_IP_LENGTH];
	int port;
	if (!GetServerConnectionDetails(ipAddress, port))
	{
		SetFailState("Failed retrieving server IP and port information.");
	}

	Format(g_sIdentifier, sizeof(g_sIdentifier), "%s:%i", ipAddress, port);

#if DEBUG
	PrintDebug("GenerateIdentifier_This(): %s", g_sIdentifier);
#endif
}
