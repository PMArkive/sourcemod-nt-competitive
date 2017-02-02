// Double-include prevention
#if defined _parser_included_
	#endinput
#endif
#define _parser_included_

public Action:Event_PlayerSpawn(Handle:event, const String:name[], bool:dontBroadcast)
{
	new client = GetClientOfUserId(GetEventInt(event, "userid"));

	if ( DidPlayerReallySpawn(client) )
	{
		g_isSpawned[client] = true;
		// This will be checked on next round event, thus the variable name
		g_survivedLastRound[client] = true;
	}
#if DEBUG
	else
	{
		if ( IsValidClient(client) )
		{
			decl String:clientName[MAX_NAME_LENGTH];
			GetClientName( client, clientName, sizeof(clientName) );
			new team = GetClientTeam(client);
			LogDebug("Client %i \"%s\" (team %i) triggered Event_PlayerSpawn without \
actually spawning. g_isSpawned[client] = %b, g_survivedLastRound[client] = %b",
client, clientName, team, g_isSpawned[client], g_survivedLastRound[client]);
		}
		else
		{
			LogDebug("Invalid client %i triggered Event_PlayerSpawn", client);
		}
	}
#endif
}

public Action:Event_PlayerDeath(Handle:event, const String:name[], bool:dontBroadcast)
{
	new victim = GetClientOfUserId(GetEventInt(event, "userid"));

	// Did the death happen after round time ran out?
	new Float:roundTimeSecs = GetConVarFloat(g_hRoundTime) * 60;
	new Float:currentTime = GetGameTime();

	if (currentTime - g_fRoundTime < roundTimeSecs)
		g_survivedLastRound[victim] = false;

	if ( GetConVarInt(g_hKillVersobity) == 0 ) // Do nothing
		return Plugin_Continue;

	new victimTeam = GetClientTeam(victim);

	new attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	decl String:attackerName[MAX_NAME_LENGTH];
	GetClientName( attacker, attackerName, sizeof(attackerName) );

	switch ( GetConVarInt(g_hKillVersobity) )
	{
		// Print remaining playercount of both teams to everyone's console
		case 1:
		{
			UpdatePlayersAlive();

			// This hook is fired too soon for UpdatePlayersAlive()
			// to consider the victim dead, so we manually subtract 1 here
			g_playersAlive[victimTeam]--;

			PrintToConsoleAll("%s %s (%i) -- vs -- %s (%i)",
				g_sTag, g_teamName[TEAM_JINRAI], g_playersAlive[TEAM_JINRAI],
				g_teamName[TEAM_NSF], g_playersAlive[TEAM_NSF]);
		}
		// Only show the victim how much damage they dealt to their killer (CSGO style)
		case 2:
		{
			decl String:msgBuffer[sizeof(g_sTag) + MAX_NAME_LENGTH + 53];
			Format(msgBuffer, sizeof(msgBuffer), "%s Player \"%s\" killed you. \
Damage dealt: %i", g_sTag, attackerName, g_damageDealt[victim][attacker]);

			if ( GetConVarBool(g_hVerbosityDelay) )
				ShowKillInfoNextRound(victim, msgBuffer);
			else
				PrintToConsole(victim, msgBuffer);
		}
		// Only show the victim their killer's remaining health
		case 3:
		{
			decl String:msgBuffer[sizeof(g_sTag) + MAX_NAME_LENGTH + 53];
			Format(msgBuffer, sizeof(msgBuffer), "%s Player \"%s\" killed you \
with %i health remaining.", g_sTag, attackerName, g_health[attacker]);

			if ( GetConVarBool(g_hVerbosityDelay) )
				ShowKillInfoNextRound(victim, msgBuffer);
			else
				PrintToConsole(victim, msgBuffer);
		}
	}

	CenterText_DisplayRemaining();

	return Plugin_Handled;
}

public Action:Event_PlayerHurt(Handle:event, const String:name[], bool:dontBroadcast)
{
	// Kill verbosity cvar doesn't require any health info - do nothing
	if ( GetConVarInt(g_hKillVersobity) < 2 )
		return Plugin_Continue;

	new attacker = GetClientOfUserId(GetEventInt(event, "attacker"));
	new victim = GetClientOfUserId(GetEventInt(event, "userid"));

	new damage;
	new health;

	// TODO: is this called too fast for IsPlayerAlive to be reliable?
	if ( !IsPlayerAlive(victim) )
	{
		health = 0;
	}
	else
	{
		health = GetClientOfUserId(GetEventInt(event, "health"));

		if (!g_survivedLastRound[victim])
		{
			LogError("g_survivedLastRound has player %i incorrectly marked \
as dead (health remaining: %i)", victim, health);
		}
	}

	damage = g_health[victim] - health;

	g_health[victim] = health;
	g_damageDealt[attacker][victim] = damage;

	return Plugin_Handled;
}

public Action:Event_RoundStart(Handle:event, const String:name[], bool:dontBroadcast)
{
	new bool:verbosityDelay = GetConVarBool(g_hVerbosityDelay);
	new i;
	for (i = 1; i <= MaxClients; i++)
	{
		g_isSpawned[i] = false;
		g_health[i] = 100;

		for (new j = 1; j <= MaxClients; j++)
		{
			g_damageDealt[i][j] = 0;
		}

		// Display last round's kill info
		if (verbosityDelay && g_shouldShowKillInfo[i])
		{
			PrintToConsole(i, g_killInfoBuffer[i]);
		}

		g_shouldShowKillInfo[i] = false;
	}

	CreateTimer(5.0, Timer_ClearGhostCapper);

	// Game is not live. Stop here.
	if (!g_isLive)
		return Plugin_Continue;

	// Game is paused. Stop here.
	if (g_isPaused)
		return Plugin_Continue;

	// Game is currently being unpaused (points being recovered etc). Stop here.
	if (g_isCurrentlyUnPausing)
	{
		g_fRoundTime	= GetGameTime();

		RestoreRound(g_roundNumber);
		PrintToChatAll( "%s Round %i/%i", g_sTag, g_roundNumber, GetConVarInt(g_hRoundLimit) );
		SpamTimer();

		// Finished restoring score and announcing match live again
		g_isCurrentlyUnPausing = false;

		return Plugin_Continue;
	}

	// Increment round number, unless we just came back from a pause
	else if (!g_isCurrentlyRestoringRound)
	{
		g_roundNumber++;
		g_targetRound				= g_roundNumber;
		g_furthestPlayedRound	= g_roundNumber;
	}

	// Round is being edited, stop here.
	else if (g_isCurrentlyRestoringRound)
	{
		g_fRoundTime	= GetGameTime();
		g_isCurrentlyRestoringRound = false;

		PrintToChatAll("%s Round %i/%i",
			g_sTag, g_roundNumber, GetConVarInt(g_hRoundLimit));

		return Plugin_Continue;
	}

	// Should we disallow wins by timeout?
	if ( g_roundNumber > 1 && GetConVarBool(g_hPreventZanshiStrats) )
	{
#if DEBUG
		LogDebug("Anti-Zanshi strats mode is enabled!");
#endif
		// Nobody captured the ghost last round
		if (g_ghostCapturingTeam != TEAM_JINRAI && g_ghostCapturingTeam != TEAM_NSF)
		{
#if DEBUG
			LogDebug("Nobody captured the ghost last round");
#endif
			new survivors[sizeof(g_teamName)];

			// Get amount of survivors on both teams
			for (i = 1; i <= MaxClients; i++)
			{
				if ( !IsValidClient(i) || !IsClientInGame(i) )
					continue;

				new team = GetClientTeam(i);
				if (team != TEAM_JINRAI && team != TEAM_NSF)
					continue;

				if (g_survivedLastRound[i])
					survivors[team]++;
			}

			// Both teams had players still alive when the time ran out
			if (survivors[TEAM_JINRAI] > 0 && survivors[TEAM_NSF] > 0)
			{
#if DEBUG
				LogDebug("Both teams had players still alive when the time ran out");
				LogDebug("Rolling back to scores: Jin %i -- NSF %i",
					g_jinraiScore[g_roundNumber - 1], g_nsfScore[g_roundNumber - 1]);
#endif
				// Roll back team scores to previous round's state
				RestoreRound(g_roundNumber - 1, _, _, true);
				PrintToChatAll("%s Round timed out. No team point awarded.", g_sTag);
			}
		}
	}

	g_fRoundTime	= GetGameTime();
//	PrintToServer("# # # NEW ROUND Game Time: %f", g_fRoundTime);

	if (g_roundNumber > MAX_ROUNDS_PLAYED)
	{
		LogError("Current round number %i is larger than MAX_ROUNDS_PLAYED %i – \
round info array is too small to store current round. This should never happen.",
g_roundNumber, MAX_ROUNDS_PLAYED);
	}
	else
	{
		g_jinraiScore[g_roundNumber]	= GetTeamScore(TEAM_JINRAI);
		g_nsfScore[g_roundNumber]	= GetTeamScore(TEAM_NSF);

		for (i = 1; i <= MaxClients; i++)
		{
			if ( !IsValidClient(i) || IsFakeClient(i) )
				continue;

			// Save everyone's death count for this round
			g_playerDeaths[i][g_roundNumber] = GetEntProp(i, Prop_Data, "m_iDeaths");
			// Save everyone's XP for this round
			g_playerXP[i][g_roundNumber] = GetEntProp(i, Prop_Data, "m_iFrags");

#if DEBUG
			LogDebug("Client %i has %i XP and %i deaths for round %i.",
				i, g_playerXP[i][g_roundNumber],
				g_playerDeaths[i][g_roundNumber], g_roundNumber);
#endif
		}
	}

	// Reset global count of living players. Used for kill feeds etc.
	ResetPlayersAlive();

	if (g_roundNumber == 1)
	{
		decl String:msgBuffer[256];
		decl String:tournamentName[128];
		GetConVarString(g_hCompetitionName, tournamentName, sizeof(tournamentName));

		if (strlen(tournamentName) > 0)
			LogCompetitive(tournamentName); // Log tournament name, if any

		Format(msgBuffer, sizeof(msgBuffer), "Competitive match started: %s vs %s",
			g_teamName[TEAM_JINRAI], g_teamName[TEAM_NSF]);

		LogCompetitive(msgBuffer);
	}

	decl String:roundBuffer[64];
	Format(roundBuffer, sizeof(roundBuffer), "***** Round %i *****", g_roundNumber);
	LogCompetitive(roundBuffer);
#if DEBUG
	LogDebug(roundBuffer);
#endif
	if (g_shouldPause)
	{
		g_shouldPause = false;

		new Float:pauseTime = 5.0;
		CreateTimer(pauseTime, Timer_TogglePause);
		PrintToChatAll("%s Pausing the game...", g_sTag);
		LogCompetitive("Game is PAUSED.");
	}

	CheckMatchState();

	return Plugin_Handled;
}

public Action:Command_JoinTeam(client, args)
{
	decl String:clientName[MAX_NAME_LENGTH];
	GetClientName(client, clientName, sizeof(clientName));

	if (!g_isLive || !GetConVarBool(g_hLimitTeams) )
	{
		if (g_isReady[client])
		{
			g_isReady[client] = false;
			PrintToChatAll("%s Player %s is NOT READY.", g_sTag, clientName);
		}

		return Plugin_Continue;
	}

	new String:steamID[MAX_STEAMID_LENGTH];
	if (!GetClientAuthId(client, AuthId_Steam2, steamID, sizeof(steamID)))
		LogError("Failed fetching auth string for %s (client %i)", clientName, client);

	decl String:team[10];
	GetCmdArg(1, team, sizeof(team));
	new iTeam = StringToInt(team);

	decl String:msgBuffer[512];

	// Team joining is not restricted by cvar, allow and log the team change
	if ( GetConVarInt(g_hLimitLiveTeams) == 0 )
	{
		Format(msgBuffer, sizeof(msgBuffer), "Player \"%s\" <%s> joined team %s",
			clientName, steamID, g_teamName[g_assignedTeamWhenLive[client]]);

		LogCompetitive(msgBuffer);
		return Plugin_Continue;
	}

	// Team not explicitly restricted for this player,
	// let them join (substitutes after going live etc.)
	if (g_assignedTeamWhenLive[client] == TEAM_NONE)
	{
		Format(msgBuffer, sizeof(msgBuffer), "Player \"%s\" <%s> joined team %s",
			clientName, steamID, g_teamName[g_assignedTeamWhenLive[client]]);

		LogCompetitive(msgBuffer);

		return Plugin_Continue;
	}

	// Player attempts to join their correct team, let them
	else if (iTeam == g_assignedTeamWhenLive[client])
	{
		Format(msgBuffer, sizeof(msgBuffer), "Player \"%s\" <%s> joined team %s",
			clientName, steamID, g_teamName[g_assignedTeamWhenLive[client]]);

		LogCompetitive(msgBuffer);

		return Plugin_Continue;
	}

	// We use this variable here for clarity, since teams can rename themselves
	new String:tempTeamName[13];
	switch (g_assignedTeamWhenLive[client])
	{
		case TEAM_JINRAI:
			strcopy(tempTeamName, sizeof(tempTeamName), "Jinrai");

		case TEAM_NSF:
			strcopy(tempTeamName, sizeof(tempTeamName), "NSF");

		case TEAM_SPECTATOR:
			strcopy(tempTeamName, sizeof(tempTeamName), "as spectator");
	}

	Format(msgBuffer, sizeof(msgBuffer), "Player \"%s\" <%s> attempted to join \
team %s instead of their assigned team %s. Blocked.",
clientName, steamID, g_teamName[iTeam], g_teamName[g_assignedTeamWhenLive[client]]);
	LogCompetitive(msgBuffer);

	PrintToChat(client, "%s Game is live! You can only join %s.",
		g_sTag, tempTeamName);
	PrintToConsole(client, "%s Game is live! You can only join %s.",
		g_sTag, tempTeamName);

	// ChangeClientTeam glitches respawn, so we use client command instead
	ClientCommand(client, "jointeam %i", g_assignedTeamWhenLive[client]);

	return Plugin_Stop;
}

public Event_JinraiScore(Handle:cvar, const String:oldVal[], const String:newVal[])
{
	if (g_isLive)
	{
		if (g_roundNumber > 0)
		{
			g_jinraiScore[g_roundNumber] = StringToInt(newVal);
			SetTeamScore(TEAM_JINRAI, g_jinraiScore[g_roundNumber]);
		}
		else
		{
			LogError("Tried to edit unexpected round number %i, \
expected round 1 or larger", g_roundNumber);
		}
	}
}

public Event_NSFScore(Handle:cvar, const String:oldVal[], const String:newVal[])
{
	if (g_isLive)
	{
		if (g_roundNumber > 0)
		{
			g_nsfScore[g_roundNumber] = StringToInt(newVal);
			SetTeamScore(TEAM_NSF, g_nsfScore[g_roundNumber]);
		}
		else
		{
			LogError("Tried to edit unexpected round number %i, \
expected round 1 or larger", g_roundNumber);
		}
	}
}

public Event_CommsBehaviour(Handle:cvar, const String:oldVal[], const String:newVal[])
{
	if (g_isLive)
		SetConVarInt(g_hAlltalk, GetDesiredCommsBehaviour());
}

public Event_LogMode(Handle:cvar, const String:oldVal[], const String:newVal[])
{
	if (g_isLive)
	{
		// We won't toggle logging whilst live
		PrintToChatAll("Logging mode changed. \
Changes will become active once the game isn't live anymore.");
	}
}

public Event_Restart(Handle:cvar, const String:oldVal[], const String:newVal[])
{
	if (StringToInt(newVal)) // If nonzero, we have a restart
	{
		g_roundNumber = 0; // Reset round count
		g_ghostCapturingTeam = TEAM_NONE; // Reset last round capper

		if (g_isLive)
			LogCompetitive("Match restarted.");
	}
}

public Event_ZanshiStrats(Handle:cvar, const String:oldVal[], const String:newVal[])
{
	if (StringToInt(newVal))
		CheckGhostcapPlugin();
}

public Event_TeamNameJinrai(Handle:cvar, const String:oldVal[], const String:newVal[])
{
	decl String:nsfName[sizeof(g_teamName[])];
	GetConVarString(g_hNSFName, nsfName, sizeof(nsfName));

	// Make sure we don't use the other team's default name
	if (StrEqual(newVal, "NSF", false))
	{
		SetConVarString(g_hJinraiName, oldVal);

#if DEBUG
		LogDebug("Jinrai tried using \"NSF\" as their name. \
This is blocked because it's reserved as NSF's fallback default name.");
#endif
	}
	// No cvar value, use default name "Jinrai"
	else if (strlen(newVal) == 0 || StrEqual(newVal, oldVal))
	{
		strcopy(g_teamName[TEAM_JINRAI], sizeof(g_teamName[]), "Jinrai");

#if DEBUG
		LogDebug("Jinrai to default name.");
#endif
	}
	// Jinrai tried using NSF's current name
	else if (StrEqual(newVal, nsfName))
	{
		SetConVarString(g_hJinraiName, oldVal);

#if DEBUG
		LogDebug("Jinrai tried using NSF's current name, blocked.");
#endif
	}

	else // Name change ok
	{
		strcopy(g_teamName[TEAM_JINRAI], sizeof(g_teamName[]), newVal);

		if (g_isLive)
		{
			decl String:msgBuffer[256];
			Format(msgBuffer, sizeof(msgBuffer), "Jinrai changed team name to: %s",
				newVal);

			LogCompetitive(msgBuffer);
		}

#if DEBUG
		LogDebug("Jinrai name: %s", newVal);
#endif
	}
}

public Event_TeamNameNSF(Handle:cvar, const String:oldVal[], const String:newVal[])
{
	decl String:jinraiName[sizeof(g_teamName[])];
	GetConVarString(g_hJinraiName, jinraiName, sizeof(jinraiName));

	// Make sure we don't use the other team's default name
	if (StrEqual(newVal, "Jinrai", false))
	{
		SetConVarString(g_hJinraiName, oldVal);

#if DEBUG
		LogDebug("NSF tried using \"Jinrai\" as their name. \
This is blocked because it's reserved as Jinrai's fallback default name.");
#endif
	}
	// No cvar value, use default name "NSF"
	else if (strlen(newVal) == 0 || StrEqual(newVal, oldVal))
	{
		strcopy(g_teamName[TEAM_NSF], sizeof(g_teamName[]), "NSF");

#if DEBUG
		LogDebug("NSF to default name.");
#endif
	}
	// NSF tried using Jinrai's current name
	else if (StrEqual(newVal, jinraiName))
	{
		SetConVarString(g_hNSFName, oldVal);

#if DEBUG
		LogDebug("NSF tried using Jinrai's current name, blocked.");
#endif
	}

	else // Name change ok
	{
		strcopy(g_teamName[TEAM_NSF], sizeof(g_teamName[]), newVal);

		if (g_isLive)
		{
			decl String:msgBuffer[256];
			Format(msgBuffer, sizeof(msgBuffer), "NSF changed team name to: %s",
				newVal);

			LogCompetitive(msgBuffer);
		}

#if DEBUG
		LogDebug("NSF name: %s", newVal);
#endif
	}
}

public Event_SourceTVEnabled(Handle:cvar, const String:oldVal[], const String:newVal[])
{
	if (StringToInt(newVal) && !IsSourceTVBotConnected())
	{
#if DEBUG
		LogDebug("Event_SourceTVEnabled: No SourceTV bot found.");
#endif
		PrintToChatAll("%s SourceTV bot doesn't appear to be connected. \
Global replay won't be recorded.", g_sTag);
	}
	// SourceTV disabled while recording a demo
	else if (!StringToInt(newVal) && g_isSourceTVRecording)
		ToggleSourceTV();
}

public Event_SourceTVPath(Handle:cvar, const String:oldVal[], const String:newVal[])
{
	if (!DirExists(newVal))
		InitDirectory(newVal);
}

#if defined PLUGIN_COMP
public Event_PugEnabled(Handle:cvar, const String:oldVal[], const String:newVal[])
{
	new bool:enabled = view_as<bool>(StringToInt(newVal));
	new bool:canPug = PugMode_Initialize();

	// Attempted to enable PUG mode but initialization failed. Cancel cvar change.
	if (enabled && !canPug)
	{
		SetConVarBool(g_hPugEnabled, false);
		return;
	}
	// Enabled PUG mode but a game is happening.
	else if (enabled && canPug && g_isLive)
	{
		PrintToAdmins(true, true, "%s Cannot enable pug mode while a match is live.", g_sTag);
		SetConVarBool(g_hPugEnabled, false);
		return;
	}
	PugMode_Initialize();
}
#endif

public Action:Hook_Fade(UserMsg:msg_id, Handle:bf, const players[], playersNum, bool:reliable, bool:init)
{
	if (GetConVarInt(g_hForceCamera))
	{
		if (BfReadShort(bf) == 640 && !IsPlayerAlive(players[0]))
			return Plugin_Stop;
	}

	return Plugin_Continue;
}

public Action:SayCallback(client, const String:command[], argc)
{
	// This player is not editing a cvar via chat,
	// let the chat message through normally.
	if (!g_isEditingSetting[client])
		return Plugin_Continue;

	new Handle:cvar = FindConVar(g_convarBeingEdited);
	if (cvar == INVALID_HANDLE)
	{
		LogError("Attempted to edit an invalid cvar handle.");
		PrintToChat(client, "%s Error editing the value. See error logs.", g_sTag);

		RemoveCommandListener(SayCallback, "say");
		RemoveCommandListener(SayCallback, "say_team");

		g_isEditingSetting[client] = false;

		RefereeMenu_GameInfo(client);

		return Plugin_Stop;
	}

	decl String:message[256];
	GetCmdArgString( message, sizeof(message) );

	StripQuotes(message);
	TrimString(message);

	// Player wishes to cancel editing cvar via chat hook
	if ( StrEqual(message, "cancel") )
	{
		PrintToChat(client, "%s Cancelled editing the value.", g_sTag);
	}
	// Player wishes to empty a text var
	// TODO: Run a default values config instead,
	// so this works for all types of cvars without fancy tricks
	else if (
		StrEqual(message, "default") ||
		strlen(message) < 1 ||
		StrEqual(message, " ")
	)
	{
		SetConVarString(cvar, "");
		PrintToChat(client, "%s Reset the value back to defaults.", g_sTag);
	}
	// Player entered a valid chat message, changing cvar value accordingly
	else
	{
		SetConVarString(cvar, message);
		PrintToChat(client, "%s Set the value of \"%s\" to \"%s\"",
			g_sTag, g_convarBeingEdited, message);
	}

	RemoveCommandListener(SayCallback, "say");
	RemoveCommandListener(SayCallback, "say_team");

	CloseHandle(cvar);

	g_isEditingSetting[client] = false;

	Command_RefereeMenu(client, 1);

	return Plugin_Handled;
}

#if defined PLUGIN_COMP
public Action Timer_Pug_SendInvites(Handle timer)
{
	PrintToServer("Timer_Pug_SendInvites");
	int desiredPlayers = Database_GetDesiredPlayerCount();
	if (desiredPlayers <= 0 ||desiredPlayers > MaxClients)
	{
		// Fail to avoid error log spam if this were to ever happen
		SetFailState("Desired players count is %i, expected value within MaxClients. \
This should never happen.", desiredPlayers);
	}

	int queuingPlayers = Puggers_GetCountPerState(PUGGER_STATE_QUEUING);
	// Not enough accepted players to make a match
	if (queuingPlayers < desiredPlayers)
	{
		PrintToServer("Not enough queued");
		return Plugin_Continue;
	}
	// Try to reserve the database to handle queued up players.
	// This will return false if another pug server served the players already.
	if (!PugServer_SetReserve_This(DB_PUG_RESERVED))
		return Plugin_Continue;

	// Get my IP and port
	char ipAddress[MAX_IP_LENGTH];
	int port;
	if (!GetServerConnectionDetails(ipAddress, port))
	{
		PugServer_SetReserve_This(DB_PUG_INACTIVE);
		SetFailState("Failed to fetch own server details.");
		return Plugin_Stop;
	}
	// Try to create a match
	int matchid = PugServer_CreateMatch(desiredPlayers);
	if (matchid == INVALID_MATCH_ID)
	{
		PrintToServer("Failed to create match");
		PugServer_SetReserve_This(DB_PUG_INACTIVE);
		return Plugin_Continue;
	}
	PrintToServer("Match created!");
	// New timer for invitation handling.
	// The call will kill this timer, so we don't return Plugin_Stop here.
	CreateAcceptTimer(matchid);
	return Plugin_Stop;
}

public Action Timer_Checkaccepts(Handle timer, int matchid)
{
	g_iTimerLoops++;
	PrintToServer("Timer_Checkaccepts");
	// Something went wrong, give up the accept check timer and go back for invites
	if (!Database_MatchExists(matchid))
	{
		LogError("Timer_Checkaccepts: Couldn't find match with ID %i",
			g_iMatchID_cached);
		CreateInviteTimer();
		return Plugin_Stop;
	}

	decl String:sql[MAX_SQL_LENGTH];
	decl String:error[MAX_SQL_ERROR_LENGTH];
	Format(sql, sizeof(sql), "SELECT * FROM %s WHERE %s = ?",
		g_sqlTable[TABLES_PUGGERS],
		g_sqlRow_Puggers[SQL_TABLE_PUGGER_MATCH_ID]
	);
	Handle stmt = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
	if (stmt == null)
		ThrowError(error);

	SQL_BindParamInt(stmt, 0, matchid);
	SQL_Execute(stmt);

	if (!SQL_HasResultSet(stmt))
	{
		delete stmt;
		LogError("Timer_Checkaccepts: Match ID %i has no SQL result set.", matchid);
		CreateInviteTimer();
		return Plugin_Stop;
	}
	int alreadyPlaying;
	int accepts;
	int declines;
	while (SQL_FetchRow(stmt))
	{
		int puggerState = SQL_FetchInt(stmt, SQL_TABLE_PUGGER_STATE);
		// Player has accepted
		if (puggerState == PUGGER_STATE_ACCEPTED)
		{
			accepts++;
		}
		// Player has declined
		else if (puggerState == PUGGER_STATE_INACTIVE)
		{
			declines++;
			// Clear player's match ID
			decl String:steamid[MAX_STEAMID_LENGTH];
			SQL_FetchString(stmt, SQL_TABLE_PUGGER_STEAMID, steamid, sizeof(steamid));
			Format(sql, sizeof(sql), "UPDATE %s SET %s = ? WHERE %s = ?",
				g_sqlTable[TABLES_PUGGERS],
				g_sqlRow_Puggers[SQL_TABLE_PUGGER_MATCH_ID],
				g_sqlRow_Puggers[SQL_TABLE_PUGGER_STEAMID]
			);

			Handle stmt_Update = SQL_PrepareQuery(g_hDB, sql, error, sizeof(error));
			if (stmt_Update == null)
			{
				LogError(error);
				continue;
			}
			SQL_BindParamInt(stmt_Update, 0, INVALID_MATCH_ID);
			SQL_BindParamString(stmt_Update, 1, steamid, false);
			SQL_Execute(stmt_Update);
			delete stmt_Update;
		}
		else if (puggerState == PUGGER_STATE_READY ||
			puggerState == PUGGER_STATE_LIVE)
		{
			alreadyPlaying++;
		}
	}
	delete stmt;

	if (declines > 0)
	{
		if (!PugServer_InvitePlayers(matchid, declines))
		{
			// not enough people to invite, give up the match
			Match_Cancel(matchid);
			CreateInviteTimer();
			return Plugin_Stop;
		}
		return Plugin_Continue;
	}

	int desiredPlayers = Match_GetDesiredPlayers(matchid);
	if (alreadyPlaying + accepts < desiredPlayers)
	{
		if (g_iTimerLoops < 3)
		{
			PrintToServer("Not enough accepted");
			return Plugin_Continue;
		}
		// looped for g_iTimerLoops * MATCHMAKE_LOOKUP_TIMER seconds. give up.
		PrintToServer("Give up the match");
		Match_Cancel(matchid, true);
		// There are players waiting for substitutes in the server,
		// kick them before starting to look for the next match.
		if (alreadyPlaying > 0)
		{
			PrintToChatAll("%s The new players didn't accept the invitation. \
Match has been cancelled.", g_sTag);
			KickPuggers(MATCHMAKE_CANCELLED);
		}
		// Nobody's on the server yet, can start to look for a new match right away
		else
		{
			CreateInviteTimer();
		}
		return Plugin_Stop;
	}
	else if (alreadyPlaying + accepts == desiredPlayers)
	{
		if (!Match_SetPreparingForLive(matchid))
		{
			SetMatchStatus(MATCHMAKE_ERROR);
			CreateInviteTimer();
			return Plugin_Stop;
		}

		PrintToServer("This means game should happen.");
		if (g_hTimer_Pug_WaitingForPlayers != null)
		{
			KillTimer(g_hTimer_Pug_WaitingForPlayers);
			g_hTimer_Pug_WaitingForPlayers = null;
		}
		g_hTimer_Pug_WaitingForPlayers = CreateTimer(TIMER_WAITINGFORPLAYERS,
			Timer_Pug_WaitingForPlayers, matchid);

		return Plugin_Stop;
	}

	LogError("Timer_Checkaccepts: Found %i already playing + %i accepts for \
matchid %i where desired playercount was %i. This line should never run.",
		alreadyPlaying, accepts, matchid, desiredPlayers);
	CreateInviteTimer();
	return Plugin_Continue;
}

public Action Timer_Pug_WaitingForPlayers(Handle timer, int matchid)
{
	if (matchid == INVALID_MATCH_ID || !Database_MatchExists(matchid))
	{
		LogError("Timer_Pug_WaitingForPlayers: Invalid match %i", matchid);
		SetMatchStatus(MATCHMAKE_ERROR);

		decl String:ipAddress[MAX_IP_LENGTH];
		int port;
		GetServerConnectionDetails(ipAddress, port);

		PugServer_Set_Status(PUG_SERVER_STATUS_ERROR, ipAddress, port);
		g_hTimer_Pug_WaitingForPlayers = null;
		return Plugin_Stop;
	}

	if (g_isLive)
	{
		LogError("Timer_Pug_WaitingForPlayers: \
Match %i went live before this timer was destroyed. This should never happen.",
			matchid);
		g_hTimer_Pug_WaitingForPlayers = null;
		return Plugin_Stop;
	}

	int desiredPlayers = Match_GetDesiredPlayers(matchid);
	int presentPlayers;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsValidClient(i) || IsFakeClient(i) || !IsClientAuthorized(i))
			continue;

		decl String:steamid[MAX_STEAMID_LENGTH];
		GetClientAuthId(i, AuthId_Steam2, steamid, sizeof(steamid));
		if (Pugger_DoesPlayInMatch(matchid, steamid))
			presentPlayers++;
	}

	// This should never happen
	if (presentPlayers > desiredPlayers)
	{
		ThrowError("More match assigned players present (%i) than desired (%i)",
			presentPlayers, desiredPlayers);
	}
	// Everyone has joined, we can go live
	else if (presentPlayers == desiredPlayers)
	{
		PrintToChatAll("%s Warmup time has ended, going live.", g_sTag);
		LiveCountDown();
	}
	else
	{
		// Time has expired for disconnected clients to rejoin, mark as abandoned
		Puggers_CommitAbandoned(matchid);

		PrintToChatAll("%s Everyone didn't join in time. Looking for more players...",
			g_sTag);
		int neededPlayers = desiredPlayers - presentPlayers;
		if (!PugServer_InvitePlayers(matchid, neededPlayers))
		{
			PrintToChatAll("%s Couldn't find enough players. Match has been cancelled.",
				g_sTag);
			// Remove match's active puggers from queue
			Puggers_UpdateStateByMatchID(matchid, PUGGER_STATE_INACTIVE);
			PrintToChatAll("%s You have been removed from the PUG queue.", g_sTag);
			KickPuggers(MATCHMAKE_CANCELLED);
		}
		else
		{
			PrintToChatAll("%s Found new players to invite. Please wait...", g_sTag);
			CreateAcceptTimer(matchid);
		}
	}
	g_hTimer_Pug_WaitingForPlayers = null;
	return Plugin_Stop;
}

void CreateInviteTimer()
{
	g_iTimerLoops = 0;
	PugServer_SetReserve_This(DB_PUG_INACTIVE);
	g_hTimer_Pug_SendInvites =
		CreateTimer(MATCHMAKE_LOOKUP_TIMER, Timer_Pug_SendInvites, _, TIMER_REPEAT
	);
}
void CreateAcceptTimer(int matchid)
{
	g_iTimerLoops = 0;
	g_hTimer_Pug_CheckAccepts = CreateTimer(
		MATCHMAKE_LOOKUP_TIMER, Timer_Checkaccepts, matchid, TIMER_REPEAT
	);
}

public Action Timer_AdminNag(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (!IsValidClient(client))
		return Plugin_Stop;
	// Nag to admin about ongoing PUG match
	PrintToChat(client, "%s This is a private PUG match.", g_sTag);
	PrintToChat(client, "Please don't join the teams.");
	// Notify puggers of the non-competing admin join
	decl String:clientName[MAX_NAME_LENGTH];
	GetClientName(client, clientName, sizeof(clientName));
	PrintToChatAll("%s Admin %s has joined the server.", g_sTag);
	return Plugin_Stop;
}
