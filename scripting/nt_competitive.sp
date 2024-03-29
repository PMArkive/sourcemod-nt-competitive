/*
	GPLv3
		- Fade-to-black function borrowed from Agiel's nt_fadetoblack plugin.
		- SourceTV recording functions borrowed from Stevo.TVR's Auto Recorder plugin: http://forums.alliedmods.net/showthread.php?t=92072
*/

#pragma semicolon 1

//#define DEBUG 0 // Release
//#define DEBUG 1 // Basic debug
#define DEBUG 2 // Extended debug

//#define KV_DEBUG 1 // Don't enable outside dev testing

#include <sourcemod>
#include <sdktools>
#include <neotokyo>

//#define FLATTEN_INCLUDE_PATHS 1

#if defined(FLATTEN_INCLUDE_PATHS)
#include "nt_competitive_base"
#include "nt_competitive_panel"
#include "nt_competitive_parser"
#else
// If you're compiling using Spider or other in-browser compiler,
// and these include paths are failing, un-comment the FLATTEN_INCLUDE_PATHS compile flag above.
#include "nt_competitive/nt_competitive_base"
#include "nt_competitive/nt_competitive_panel"
#include "nt_competitive/nt_competitive_parser"
#endif

public Plugin:myinfo = {
	name		=	"Neotokyo Competitive Plugin",
	description	=	"Count score, announce winner, perform other competitive tasks",
	author		=	"Rain",
	version		=	PLUGIN_VERSION,
	url			=	"https://github.com/Rainyan/sourcemod-nt-competitive"
};

public APLRes:AskPluginLoad2(Handle:myself, bool:late, String:error[], err_max)
{
	CreateNative("Competitive_IsLive",			Competitive_IsLive);
	CreateNative("Competitive_IsPaused",		Competitive_IsPaused);
	CreateNative("Competitive_GetTeamScore",	Competitive_GetTeamScore);
	CreateNative("Competitive_GetWinner",		Competitive_GetWinner);

	return APLRes_Success;
}

public OnPluginStart()
{
	RegConsoleCmd("sm_ready",		Command_Ready,				"Mark yourself as ready for a competitive match.");

	RegConsoleCmd("sm_unready",		Command_UnReady,			"Mark yourself as not ready for a competitive match.");
	RegConsoleCmd("sm_notready",	Command_UnReady,			"Mark yourself as not ready for a competitive match. Alternative for sm_unready.");

	RegConsoleCmd("sm_start",		Command_OverrideStart,		"Force a competitive match start when using an unexpected setup.");
	RegConsoleCmd("sm_unstart",		Command_UnOverrideStart,	"Cancel sm_start.");

	RegConsoleCmd("sm_pause",		Command_Pause,				"Request a pause or timeout in a competitive match.");
	RegConsoleCmd("sm_unpause",		Command_Pause,				"Request a pause or timeout in a competitive match.");
	RegConsoleCmd("sm_timeout",		Command_Pause,				"Request a pause or timeout in a competitive match. Alternative for sm_pause.");

	RegConsoleCmd("sm_readylist",	Command_ReadyList,			"List everyone who has or hasn't readied up.");

	RegConsoleCmd("jointeam",		Command_JoinTeam); // There's no pick team event for NT, so we do this instead

	RegAdminCmd("sm_referee",			Command_RefereeMenu, ADMFLAG_GENERIC, "Competitive match referee/admin panel.");
	RegAdminCmd("sm_ref",			Command_RefereeMenu, ADMFLAG_GENERIC, "Competitive match referee/admin panel. Alternative for sm_referee.");
	RegAdminCmd("sm_forcelive",			Command_ForceLive,			ADMFLAG_GENERIC,	"Force the competitive match to start.");

#if DEBUG
	RegAdminCmd("sm_pause_resetbool",	Command_ResetPauseBool,		ADMFLAG_GENERIC,	"Reset g_isPaused to FALSE. Debug command.");
	RegAdminCmd("sm_logtest",			Command_LoggingTest,		ADMFLAG_GENERIC,	"Test competitive file logging. Logs the cmd argument. Debug command.");
	RegAdminCmd("sm_unpause_other",		Command_UnpauseOther,		ADMFLAG_GENERIC,	"Pretend the other team requested unpause. Debug command.");
	RegAdminCmd("sm_start_other",		Command_OverrideStartOther,	ADMFLAG_GENERIC,	"Pretend the other team requested force start. Debug command.");
	RegAdminCmd("sm_manual_round_edit", Command_ManualRoundEdit, ADMFLAG_GENERIC, "Manually edit round int. Debug command.");
#endif

	HookEvent("game_round_start",	Event_RoundStart);
	HookEvent("player_death",		Event_PlayerDeath);
	HookEvent("player_hurt",			Event_PlayerHurt);
	HookEvent("player_spawn",		Event_PlayerSpawn);

	CreateConVar("sm_competitive_version", PLUGIN_VERSION, "Competitive plugin version.", FCVAR_DONTRECORD);

	g_hRoundStyle						= CreateConVar("sm_competitive_round_style",						"1",					"How a match win is determined. 1 = best of X rounds, 2 = first to X points", _, true, 1.0, true, 2.0);
	g_hRoundLimit						= CreateConVar("sm_competitive_round_limit",						"15",					"If sm_competitive_round_style equals 1, this is the best of X rounds. If it equals 2, this is the score required to win.", _, true, 1.0);
	g_hMatchSize						= CreateConVar("sm_competitive_players_total",						"10",					"How many players total are expected to ready up before starting a competitive match.");
	g_hMaxTimeouts						= CreateConVar("sm_competitive_max_timeouts",						"1",					"How many time-outs are allowed per match per team.", _, true, 0.0);
	g_hMaxPauseLength					= CreateConVar("sm_competitive_max_pause_length",					"60",					"How long can a competitive time-out last, in seconds.", _, true, 0.0);
	g_hMaxPauseLength_Technical		= CreateConVar("sm_competitive_max_pause_length_technical",	"300",				"How long can a pause last when team experiences technical difficulties.", _, true, 0.0);
	g_hSourceTVEnabled					= CreateConVar("sm_competitive_sourcetv_enabled",					"1",					"Should the competitive plugin automatically record SourceTV demos.", _, true, 0.0, true, 1.0);
	g_hSourceTVPath						= CreateConVar("sm_competitive_sourcetv_path",						"replays_competitive",	"Directory to save SourceTV demos into. Relative to NeotokyoSource folder. Will be created if possible.");
	g_hJinraiName						= CreateConVar("sm_competitive_jinrai_name",						"Jinrai",				"Jinrai team's name. Will use \"Jinrai\" if left empty.");
	g_hNSFName							= CreateConVar("sm_competitive_nsf_name",							"NSF",					"NSF team's name. Will use \"NSF\" if left empty.");
	g_hCompetitionName					= CreateConVar("sm_competitive_title",								"",						"Name of the tournament/competition. Also used for replay filenames. 32 characters max. Use only alphanumerics and spaces.");
	g_hCommsBehaviour					= CreateConVar("sm_competitive_comms_behaviour",					"0",					"Voice comms behaviour when live. 0 = no alltalk, 1 = enable alltalk, 2 = check sv_alltalk value before live state", _, true, 0.0, true, 2.0);
	g_hLogMode							= CreateConVar("sm_competitive_log_mode",							"1",					"Competitive logging mode. 1 = enabled, 0 = disabled.", _, true, 0.0, true, 1.0);
	g_hKillVersobity					= CreateConVar("sm_competitive_killverbosity",						"1",					"How much info is given to players upon death. 0 = disabled, 1 = print amount of players remaining to everyone, 2 = only show the victim how much damage they dealt to their killer, 3 = only show the victim their killer's remaining health", _, true, 0.0, true, 3.0);
	g_hVerbosityDelay			= CreateConVar("sm_competitive_killverbosity_delay",				"0",					"0 = display kill info instantly, 1 = display kill info nextround", _, true, 0.0, true, 1.0);
	g_hClientRecording					= CreateConVar("sm_competitive_record_clients",						"0",					"Should clients automatically record when going live.", _, true, 0.0, true, 1.0);
	g_hLimitLiveTeams					= CreateConVar("sm_competitive_limit_live_teams",								"0",					"Team restrictions when game is live. 0 = players can join any team, 1 = only players present when going live can play in their teams 2 = new players can join teams midgame", _, true, 0.0, true, 2.0);
	g_hLimitTeams						= CreateConVar("sm_competitive_limit_teams",									"1",					"Are teams enforced to use set numbers (5v5 for example).", _, true, 0.0, true, 1.0);
	g_hPauseMode						= CreateConVar("sm_competitive_pause_mode",				"2",					"Pausing mode. 0 = no pausing allowed, 1 = use Source engine pause feature, 2 = stop round timer", _, true, 0.0, true, 2.0);
	g_hCollectiveReady					= CreateConVar("sm_competitive_readymode_collective",	"0",					"Can a team collectively ready up by anyone of the players. Can be useful for more organized events.", _, true, 0.0, true, 1.0);
	g_hPreventZanshiStrats			= CreateConVar("sm_competitive_nozanshi",						"1",					"Whether or not to disable timeout wins.", _, true, 0.0, true, 1.0);
	g_hJinraiScore							= CreateConVar("sm_competitive_jinrai_score",					"0",					"Competitive plugin's internal score cvar. Editing this will directly affect comp team scores.", _, true, 0.0);
	g_hNSFScore							= CreateConVar("sm_competitive_nsf_score",						"0",					"Competitive plugin's internal score cvar. Editing this will directly affect comp team scores.", _, true, 0.0);
	g_hSuddenDeath						= CreateConVar("sm_competitive_sudden_death",				"1",					"Whether or not to allow match to end in a tie. Otherwise, game proceeds to sudden death until one team scores a point.", _, true, 0.0, true, 1.0);
	g_hCenteredDisplayRemaining	= CreateConVar("sm_competitive_display_remaining_players_centered",	"2", "How the number of remaining players is displayed to clients in a competitive game. 0 = disabled, 1 = show remaining player numbers, 2 = show team names and remaining player numbers", _, true, 0.0, true, 2.0);
	g_hCenteredDisplayTarget			= CreateConVar("sm_competitive_display_remaining_players_target",	"2", "Who to center display remaining players to. 1 = spectators only, 2 = spectators and dead players, 3 = everyone", _, true, 1.0, true, 3.0);
	g_hCenteredDisplayDivider	= CreateConVar("sm_competitive_display_remaining_players_divider", "—", "What kind of divider to use between the scores (eg. 3 vs 2, 3 v 2, 3--2)");
	g_hCompForceCamera				= CreateConVar("sm_competitive_force_camera",				"1",				"Should fade to black be forced on death when live. Can be useful to disable on pugs etc.", _, true, 0.0, true, 1.0);
	g_hGhostOvertimeDecay			= CreateConVar("sm_competitive_ghost_overtime",				"45",					"Add up to this many seconds to the round time while the ghost is held.", _, true, 0.0, true, 120.0);
	g_hGhostOvertimeGrace			= CreateConVar("sm_competitive_ghost_overtime_grace",		"15",					"Freeze the round timer at this many seconds while the ghost is held. Will decay and end at 0 when the overtime runs out. 0 = disabled", _, true, 0.0, true, 30.0);
	g_hGhostOvertimeDecayExp		= CreateConVar("sm_competitive_ghost_overtime_decay_exp",	"0",					"Whether ghost overtime decay should be exponential or linear. Exponential requires grace reset to be enabled. 0 = linear, 1 = exponential", _, true, 0.0, true, 1.0);
	g_hGhostOvertimeGraceReset		= CreateConVar("sm_competitive_ghost_overtime_grace_reset", "1", 					"When the ghost is picked up, reset the timer to where it would be on the decay curve if the ghost was never dropped. This means the full overtime can be used even when juggling.", _, true, 0.0, true, 1.0);
#if defined KV_DEBUG
	g_hDebugKeyValues				= CreateConVar("sm_competitive_keyvalues_test",				"1",					"Store match data into KeyValues file. Debug cvar.", _, true, 0.0, true, 1.0);
#endif

	g_hAlltalk			= FindConVar("sv_alltalk");
	g_hForceCamera		= FindConVar("mp_forcecamera");
	g_hNeoRestartThis	= FindConVar("neo_restart_this");
	g_hPausable			= FindConVar("sv_pausable");
	g_hRoundTime		= FindConVar("neo_round_timelimit");
	g_hNeoScoreLimit	= FindConVar("neo_score_limit");

	HookConVarChange(g_hNeoRestartThis,					Event_Restart);
	HookConVarChange(g_hSourceTVEnabled,				Event_SourceTVEnabled);
	HookConVarChange(g_hSourceTVPath,					Event_SourceTVPath);
	HookConVarChange(g_hJinraiName,						Event_TeamNameJinrai);
	HookConVarChange(g_hNSFName,						Event_TeamNameNSF);
	HookConVarChange(g_hCommsBehaviour,					Event_CommsBehaviour);
	HookConVarChange(g_hLogMode,						Event_LogMode);
	HookConVarChange(g_hPreventZanshiStrats,			Event_ZanshiStrats);
	HookConVarChange(g_hJinraiScore,						Event_JinraiScore);
	HookConVarChange(g_hNSFScore,						Event_NSFScore);

	HookUserMessage(GetUserMessageId("Fade"), Hook_Fade, true); // Hook fade to black (on death)

	// Initialize SourceTV path
	new String:sourceTVPath[PLATFORM_MAX_PATH];
	GetConVarString(g_hSourceTVPath, sourceTVPath, sizeof(sourceTVPath));
	if (!DirExists(sourceTVPath))
		InitDirectory(sourceTVPath);

	// Initialize logs path
	decl String:loggingPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, loggingPath, sizeof(loggingPath), "logs/competitive");
	if (!DirExists(loggingPath))
		InitDirectory(loggingPath);

#if defined KV_DEBUG
	if (!DirExists(g_kvPath))
		InitDirectory(g_kvPath);
#endif

#if DEBUG
	PrepareDebugLogFolder();
#endif

	g_liveTimer_OriginalValue = g_liveTimer;
	g_unpauseTimer_OriginalValue = g_unpauseTimer;

	CheckGamedataFiles();

	AutoExecConfig(true);
}

public OnAllPluginsLoaded()
{
	CheckGhostcapPlugin();
}

public OnMapStart()
{
	SetGameState(GAMESTATE_WARMUP);
	ResetGlobalVariables(); // Make sure all global variables are reset properly
}

public OnConfigsExecuted()
{
	g_isAlltalkByDefault = GetConVarBool(g_hAlltalk);
	SetConVarInt(g_hNeoScoreLimit, 99); // Set Neotokyo's own round max round count to highest value
}

public OnClientAuthorized(client, const String:authID[])
{
	if (!g_isLive)
		return;

	if ( IsValidClient(client) && IsFakeClient(client) )
	{
		g_assignedTeamWhenLive[client] = TEAM_NONE; // This is a bot, let them join whichever team they like
		return;
	}

	// ** Check for competitor status below **
	new bool:isPlayerCompeting;
	new earlierUserid;

	for (new i = 0; i < sizeof(g_livePlayers); i++)
	{
#if DEBUG > 1
		LogDebug("Checking array index %i, array size %i", i, sizeof(g_livePlayers));
		LogDebug("Contents: %s", g_livePlayers[i]);
#endif
		if ( StrEqual(authID, g_livePlayers[i]) )
		{
			isPlayerCompeting = true;
			earlierUserid = i;
			break;
		}
	}

	if (!isPlayerCompeting)
	{
		// Teams are limited, allow joining only spectator team
		if (GetConVarInt(g_hLimitLiveTeams) == 1)
		{
			g_assignedTeamWhenLive[client] = TEAM_SPECTATOR;
		}

		// Either teams are unlimited (g_hLimitLiveTeams 0), or new joiners are allowed to join any team (g_hLimitLiveTeams 2)
		else
		{
			g_assignedTeamWhenLive[client] = TEAM_NONE;
		}
	}

	else
	{
		g_assignedTeamWhenLive[client] = g_assignedTeamWhenLive[earlierUserid];
	}

#if DEBUG
	LogDebug("Client connected when live. Assigned to team %s", g_teamName[g_assignedTeamWhenLive[client]]);
#endif
}

public bool OnClientConnect(client)
{
	if ( g_isPaused && GetConVarInt(g_hPauseMode) == PAUSEMODE_NORMAL )
	{
		decl String:clientName[MAX_NAME_LENGTH];
		GetClientName(client, clientName, sizeof(clientName));
#if DEBUG
		LogDebug("[COMP] Pause join detected!");
#endif
		PrintToChatAll("%s Player \"%s\" is attempting to join.", g_tag, clientName);
		PrintToChatAll("The server needs to be unpaused for joining to finish.");
		PrintToChatAll("If you wish to unpause now, type !pause in chat.");
	}

	return true;
}

public OnClientDisconnect(client)
{
	g_isReady[client] = false;
	g_survivedLastRound[client] = false;
	g_isSpawned[client] = false;
	g_isRecording[client] = false;
}

public OnGhostCapture(client)
{
	if ( !IsValidClient(client) )
	{
		LogError("Returned invalid client %i", client);
		g_ghostCapturingTeam = TEAM_NONE;
		return;
	}

	new team = GetClientTeam(client);
	if (team != TEAM_JINRAI && team != TEAM_NSF)
	{
		LogError("Returned client %i does not belong to team Jinrai or NSF, returned team id %i", client, team);
		g_ghostCapturingTeam = TEAM_NONE;
		return;
	}

	g_ghostCapturingTeam = team;
}

public OnGhostPickUp(client)
{
	int gameState = GameRules_GetProp("m_iGameState");
	if (gameState == 2 && g_isLive && !g_isPaused && GetConVarInt(g_hGhostOvertimeDecay) > 0)
	{
		bool graceReset = GetConVarBool(g_hGhostOvertimeGraceReset);
		if (!graceReset)
		{
			float timeLeft = GameRules_GetPropFloat("m_fRoundTimeLeft");
			if (timeLeft < g_fGhostOvertime)
			{
				g_fGhostOvertime = g_fGhostOvertimeTick = timeLeft;
			}
		}
		g_bGhostOvertimeFirstTick = true;
		// Inverval of 0.5 to tick before the second flips over to prevent HUD flicker
		g_hTimer_GhostOvertime = CreateTimer(0.5, CheckGhostOvertime, _, TIMER_REPEAT);
		CheckGhostOvertime(g_hTimer_GhostOvertime);
	}
}

public OnGhostDrop(client)
{
	if (g_hTimer_GhostOvertime != INVALID_HANDLE)
	{
		CloseHandle(g_hTimer_GhostOvertime);
		g_hTimer_GhostOvertime = INVALID_HANDLE;
	}
}

public Action:CheckGhostOvertime(Handle:timer)
{
	int gameState = GameRules_GetProp("m_iGameState");
	if (gameState != 2)
	{
		g_hTimer_GhostOvertime = INVALID_HANDLE;
		return Plugin_Stop;
	}

	float timeLeft = GameRules_GetPropFloat("m_fRoundTimeLeft");
	float graceTime = GetConVarFloat(g_hGhostOvertimeGrace);
	if (timeLeft < graceTime)
	{
		float realTimeLeft;
		float decayTime = GetConVarFloat(g_hGhostOvertimeDecay) + graceTime;
		bool graceReset = GetConVarBool(g_hGhostOvertimeGraceReset);
		if (graceReset)
		{
			float roundTime = GetConVarFloat(g_hRoundTime) * 60;
			float overtime = GetGameTime() - (g_fRoundTime + roundTime - graceTime);
			bool decayExp = GetConVarBool(g_hGhostOvertimeDecayExp);
			if (decayExp)
			{
				g_fGhostOvertime = graceTime + 1 - Pow(graceTime + 1, overtime / decayTime);
			}
			else
			{
				g_fGhostOvertime = graceTime - graceTime * overtime / decayTime;
			}
			realTimeLeft = decayTime - overtime;
		}
		else
		{
			float timePassed = g_fGhostOvertimeTick - timeLeft;
			g_fGhostOvertime -= timePassed * graceTime / decayTime;
			g_fGhostOvertimeTick = float(RoundToCeil(g_fGhostOvertime));
			realTimeLeft = g_fGhostOvertime * decayTime / graceTime;
		}
		// Round up to nearest int to prevent HUD flicker
		GameRules_SetPropFloat("m_fRoundTimeLeft", float(RoundToCeil(g_fGhostOvertime)));

		// Everything's multiplied by 2 because we want to tick every second, but the interval is 0.5
		bool printTick = g_bGhostOvertimeFirstTick
			|| (RoundToCeil(realTimeLeft * 2) % RoundToCeil(graceTime * 2) == 0) // Divisible by graceTime
			|| (realTimeLeft < graceTime && RoundToCeil(realTimeLeft * 2) % 10 == 0) // Divisible by 5
			|| (realTimeLeft < 5 && RoundToCeil(realTimeLeft * 2) % 2 == 0); // Every second for the last 5
		if (printTick) {
			PrintToChatAll("Ghost overtime engaged. %d seconds remaining.", RoundToCeil(realTimeLeft));
			g_bGhostOvertimeFirstTick = false;
		}
	}

	return Plugin_Continue;
}

public Action:Command_RefereeMenu(client, args)
{
	new Handle:panel = CreatePanel();
	SetPanelTitle(panel, "Comp Admin Menu");

	DrawPanelItem(panel, "Game information");
	DrawPanelItem(panel, "Team penalties");
	DrawPanelItem(panel, "Rollback rounds");

	if (g_isLiveCountdown)
	{
		DrawPanelItem(panel, "Cancel live countdown");
	}
	else if (!g_isLive)
	{
		DrawPanelItem(panel, "Force live");
	}
	else
	{
		if (!g_confirmLiveEnd)
		{
			DrawPanelItem(panel, "Force end match");
		}
		else
		{
			DrawPanelItem(panel, "Force end match (are you sure?)");
		}
	}

	DrawPanelItem(panel, "Manually edit team score");
	DrawPanelItem(panel, "Manually edit player score (does not work yet)");
#if defined KV_DEBUG
	DrawPanelItem(panel, "Load previous match");
#else
	DrawPanelItem(panel, "Load previous match (experimental, disabled)");
#endif
	DrawPanelItem(panel, "Exit");

	SendPanelToClient(panel, client, PanelHandler_RefereeMenu_Main, MENU_TIME_FOREVER);

	CloseHandle(panel);

	return Plugin_Handled;
}

#if DEBUG
public Action:Command_ResetPauseBool(client, args)
{
	g_isPaused = false;
	ReplyToCommand(client, "g_isPaused reset to FALSE");

	return Plugin_Handled;
}
#endif

public Action:Command_ForceLive(client, args)
{
	if (!g_isLive)
	{
		// There's no live countdown happening, it's safe to make one
		if (!g_isLiveCountdown)
		{
			PrintToChatAll("Match manually started by admin.");
			LiveCountDown();
		}

		// There already is a live countdown! Cancel it.
		else
		{
			CancelLiveCountdown();
		}
	}

	else
	{
		if (!g_confirmLiveEnd)
		{
			ReplyToCommand(client, "%s Stopping a competitive match, are you sure?", g_tag);
			ReplyToCommand(client, "Please repeat the command to confirm.");
			g_confirmLiveEnd = true;

			CreateTimer(10.0, Timer_CancelLiveEndConfirmation); // Flip the bool back if force end isn't confirmed in 10 seconds
		}
		else
		{
			PrintToChatAll("Match manually ended by admin.");
			g_confirmLiveEnd = false;
			ToggleLive();
		}
	}

	return Plugin_Handled;
}

public Action:Command_Pause(client, args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "%s Server cannot execute this command.", g_tag);
		return Plugin_Stop;
	}

	if ( !IsValidClient(client) )
		return Plugin_Stop;

	if (!g_isLive)
	{
		ReplyToCommand(client, "%s Game is not live.", g_tag);
		return Plugin_Stop;
	}

	new team = GetClientTeam(client);

	if (team != TEAM_JINRAI && team != TEAM_NSF) // Not in a team, ignore
		return Plugin_Stop;

	if (!g_isPaused && g_shouldPause)
	{
		if (team != g_pausingTeam)
		{
			ReplyToCommand(client, "%s The other team has already requested a pause for the next freezetime.", g_tag);
			return Plugin_Stop;
		}

		else
		{
			new Handle:panel = CreatePanel();
			SetPanelTitle(panel, "Cancel pause request?");

			DrawPanelItem(panel, "Yes, cancel");
			DrawPanelItem(panel, "Exit");

			SendPanelToClient(panel, client, PanelHandler_CancelPause, MENU_TIME_FOREVER);

			CloseHandle(panel);

			return Plugin_Handled;
		}
	}

	else if (g_isPaused)
	{
		new otherTeam = GetOtherTeam(team);

		if (!g_isTeamReadyForUnPause[g_pausingTeam] && team != g_pausingTeam)
		{
			ReplyToCommand(client, "%s Cannot unpause − the pause was initiated by %s", g_tag, g_teamName[otherTeam]);
			return Plugin_Stop;
		}

		if (!g_isTeamReadyForUnPause[team])
		{
			new Handle:panel = CreatePanel();
			SetPanelTitle(panel, "Unpause?");

			DrawPanelItem(panel, "Team is ready, request unpause");
			DrawPanelItem(panel, "Exit");

			SendPanelToClient(panel, client, PanelHandler_UnPause, MENU_TIME_FOREVER);

			CloseHandle(panel);

			return Plugin_Handled;
		}

		g_isTeamReadyForUnPause[team] = false;
		PrintToChatAll("%s Team %s cancelled being ready for unpause", g_tag, g_teamName[team]);

		return Plugin_Handled;
	}

	new Handle:panel = CreatePanel();
	SetPanelTitle(panel, "Request pause");

	DrawPanelText(panel, "Please select pause reason");

	if (!g_isPaused && !g_shouldPause)
	{
		// Check if this team has tactical time-outs available
		if (g_usedTimeouts[team] >= GetConVarInt(g_hMaxTimeouts))
		{
			if (GetConVarInt(g_hMaxTimeouts) == 0)
				DrawPanelItem(panel, "Time-outs are not allowed.");

			else if (GetConVarInt(g_hMaxTimeouts) == 1)
				DrawPanelItem(panel, "Team has already used their timeout.");

			else if (GetConVarInt(g_hMaxTimeouts) > 1)
				DrawPanelItem(panel, "Team has already used all their %i timeouts.", GetConVarInt(g_hMaxTimeouts));

			else // Some sort of error happened, we presume time-outs are not allowed
			{
				DrawPanelItem(panel, "Time-outs are not allowed.");

				decl String:cvarValue[128];
				GetConVarString( g_hMaxTimeouts, cvarValue, sizeof(cvarValue) );

				new tempFixValue = 0;
				SetConVarInt( g_hMaxTimeouts, tempFixValue );

				LogError("sm_competitive_max_timeouts had invalid value: %s. Value has been changed to: %i", cvarValue, tempFixValue);
			}
		}

		else // Team is allowed to call a time-out
		{
			DrawPanelItem(panel, "Time-out");
		}
	}

	DrawPanelItem(panel, "Technical difficulties"); // Team is always allowed to call a pause for technical issues
	DrawPanelItem(panel, "Exit");

	SendPanelToClient(panel, client, PanelHandler_Pause, MENU_TIME_FOREVER);

	CloseHandle(panel);

	return Plugin_Handled;
}

void PauseRequest(client, reason)
{
	// Gamedata is outdated, fall back to normal pausemode as stop clock mode would cause an error
	if (g_isGamedataOutdated && ( GetConVarInt(g_hPauseMode) == PAUSEMODE_STOP_CLOCK) )
	{
		SetConVarInt(g_hPauseMode, PAUSEMODE_NORMAL);
		PrintToAdmins(true, true, "Admins: Server gamedata is outdated. Falling back to default pause mode to avoid errors.");
		PrintToAdmins(true, true, "See SM error logs for more info.");
	}

	new team = GetClientTeam(client);

	if (g_shouldPause)
	{
		if (team == g_pausingTeam)
			PrintToChat(client, "%s Your team has already requested a pause for the next freezetime.", g_tag);
		else
			PrintToChat(client, "%s Team \"%s\" has already requested a pause during next freezetime.", g_tag, g_teamName[g_pausingTeam]);

		return;
	}

	g_pausingTeam = team;
	g_pauseReason = reason;

	switch (reason)
	{
		case REASON_TECHNICAL:
			PrintToChatAll("%s Team %s wants to pause for a technical issue.", g_tag, g_teamName[team]);

		case REASON_TIMEOUT:
		{
			g_usedTimeouts[g_pausingTeam]++;
			PrintToChatAll("%s Team %s wants a time-out.", g_tag, g_teamName[team]);
		}
	}

	new Float:currentTime = GetGameTime();

	if (currentTime - g_fRoundTime < 15) // We are in a freezetime, it's safe to pause
		TogglePause();

	else
	{
		PrintToChatAll("Match will be paused during the next freezetime.");
		g_shouldPause = true;
	}
}

void CancelPauseRequest(client)
{
	// Already cancelled, nothing to do
	if (!g_shouldPause)
		return;

	// We check for client & team validity in Command_Pause already before calling this
	g_shouldPause = false;

	new team = GetClientTeam(client);
	PrintToChatAll("%s %s have cancelled their pause request for the next freezetime.", g_tag, g_teamName[team]);
}

void UnPauseRequest(client)
{
	if ( client == 0 || !IsValidClient(client) || !IsClientInGame(client) )
	{
		LogError("Invalid client %i called UnPauseRequest", client);
#if DEBUG
		PrintToAdmins(true, true, "Comp plugin error: Invalid client %i called UnPauseRequest", client);
#endif
		return;
	}

	new team = GetClientTeam(client);
	if (team != TEAM_JINRAI && team != TEAM_NSF)
	{
		LogError("Client %i with invalid team %i attempted calling UnPauseRequest", client, team);
		return;
	}

	// Already did this, stop here
	if (g_isTeamReadyForUnPause[team])
		return;

	g_isTeamReadyForUnPause[team] = true;
	PrintToChatAll("%s %s are ready, and want to unpause.", g_tag, g_teamName[team]);

	if (g_isTeamReadyForUnPause[TEAM_JINRAI] && g_isTeamReadyForUnPause[TEAM_NSF])
	{
		TogglePause();
	}
	else
	{
		new otherTeam = GetOtherTeam(team);
		PrintToChatAll("Waiting for %s to confirm unpause.", g_teamName[otherTeam]);
	}
}

public Action:Command_OverrideStart(client, args)
{
	if (g_isLive)
		return Plugin_Stop;

	if (client == 0)
	{
		ReplyToCommand(client, "%s Server cannot execute this command.", g_tag);
		return Plugin_Stop;
	}

	new team = GetClientTeam(client);

	if (team != TEAM_JINRAI && team != TEAM_NSF)
	{
		ReplyToCommand(client, "%s You are not in a team.", g_tag);
		return Plugin_Stop;
	}

	if (!g_isExpectingOverride)
	{
		ReplyToCommand(client, "%s Not expecting any !start override currently.", g_tag);
		return Plugin_Stop;
	}

	new bool:bothTeamsWantOverride;

	// Check if everyone in the team is still ready
	new playersInTeam;
	new playersInTeamReady;
	for (new i = 1; i <= MaxClients; i++)
	{
		if (!IsValidClient(i))
			continue;

		if (GetClientTeam(i) == team)
			playersInTeam++;

		if (GetClientTeam(i) == team && g_isReady[i])
			playersInTeamReady++;
	}

	if (playersInTeam < playersInTeamReady)
	{
		LogError("There are more players marked ready than there are players in the team!");
	}

	if (playersInTeam != playersInTeamReady)
	{
		ReplyToCommand(client, "%s Only %i of %i players in your team are marked !ready.", g_tag, playersInTeamReady, playersInTeam);
		ReplyToCommand(client, "Everyone in your team needs to be ready to force a start.");

		return Plugin_Stop;
	}

	if (g_isWantingOverride[team])
	{
		ReplyToCommand(client, "%s Your team already wants to start. If you wish to revert this, use !unstart instead.", g_tag);
		return Plugin_Stop;
	}

	if (team == TEAM_JINRAI)
		bothTeamsWantOverride = g_isWantingOverride[TEAM_NSF];

	else if (team == TEAM_NSF)
		bothTeamsWantOverride = g_isWantingOverride[TEAM_JINRAI];

	g_isWantingOverride[team] = true;
	PrintToChatAll("%s Team %s wishes to start the match with current players.", g_tag, g_teamName[team]);

	if (bothTeamsWantOverride)
		LiveCountDown();

	return Plugin_Handled;
}

public Action:Command_UnOverrideStart(client, args)
{
	if (g_isLive)
		return Plugin_Stop;

	if (client == 0)
	{
		ReplyToCommand(client, "%s Server cannot execute this command.", g_tag);
		return Plugin_Stop;
	}

	new team = GetClientTeam(client);

	if (team != TEAM_JINRAI && team != TEAM_NSF)
	{
		ReplyToCommand(client, "%s You are not in a team.", g_tag);
		return Plugin_Stop;
	}

	if (!g_isExpectingOverride)
	{
		ReplyToCommand(client, "%s Not expecting any !start override currently.", g_tag);
		return Plugin_Stop;
	}

	if (!g_isWantingOverride[team])
	{
		ReplyToCommand(client, "%s Your team already does not wish to force a start!", g_tag);
		return Plugin_Stop;
	}

	if (g_isLiveCountdown)
		CancelLiveCountdown();

	g_isWantingOverride[team] = false;
	PrintToChatAll("%s Team %s has cancelled wanting to force start the match.", g_tag, g_teamName[team]);

	return Plugin_Handled;
}

public Action:Command_Ready(client, args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "%s Server cannot execute this command.", g_tag);
		return Plugin_Stop;
	}

	new team = GetClientTeam(client);
	if (team != TEAM_JINRAI && team != TEAM_NSF)
	{
		ReplyToCommand(client, "%s You are not in a team.", g_tag);
		return Plugin_Stop;
	}

	if (g_isLive)
	{
		ReplyToCommand(client, "%s Game is live, cannot change ready state!", g_tag);
		return Plugin_Continue;
	}

	switch ( GetConVarBool(g_hCollectiveReady) )
	{
		case false: // Individual readying
		{
			if (g_isReady[client])
			{
				ReplyToCommand(client, "%s You are already marked as ready. Use !unready to revert this.", g_tag);
				return Plugin_Continue;
			}

			g_isReady[client] = true;

			decl String:clientName[MAX_NAME_LENGTH];
			GetClientName(client, clientName, sizeof(clientName));
			PrintToChatAll("%s Player %s is READY.", g_tag, clientName);
		}

		case true: // Collective readying
		{
			new teamPlayers;
			new teamPlayersReady;

			for (new i = 1; i <= MaxClients; i++)
			{
				if ( !IsValidClient(i) )
					continue;

				if ( team != GetClientTeam(i) )
					continue;

				teamPlayers++;

				if (g_isReady[i])
					teamPlayersReady++;
				else
					g_isReady[i] = true;
			}

			if (teamPlayers == teamPlayersReady)
			{
				ReplyToCommand(client, "%s Your team is already marked as ready. Use !unready to revert this.", g_tag);
				return Plugin_Handled;
			}

			else if (teamPlayers < teamPlayersReady)
				LogError("Found more team members (%i) for team %i than there are members ready (%i).", teamPlayers, team, teamPlayersReady);

			else
				PrintToChatAll("%s Team %s is READY.", g_tag, g_teamName[team]);
		}
	}

	CheckIfEveryoneIsReady();

	return Plugin_Handled;
}

public Action:Command_UnReady(client, args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "%s Server cannot execute this command.", g_tag);
		return Plugin_Stop;
	}

	new team = GetClientTeam(client);
	if (team != TEAM_JINRAI && team != TEAM_NSF)
	{
		g_isReady[client] = false;
		ReplyToCommand(client, "%s You are not in a team.", g_tag);
		return Plugin_Stop;
	}

	if (g_isLive)
	{
		ReplyToCommand(client, "%s Game is live, cannot change ready state!", g_tag);
		return Plugin_Continue;
	}

	switch ( GetConVarBool(g_hCollectiveReady) )
	{
		case false: // Individual readying
		{
			if (!g_isReady[client])
			{
				ReplyToCommand(client, "%s You are already marked not ready. Use !ready when ready.", g_tag);
				return Plugin_Continue;
			}

			g_isReady[client] = false;

			decl String:clientName[MAX_NAME_LENGTH];
			GetClientName(client, clientName, sizeof(clientName));
			PrintToChatAll("%s Player %s is NOT READY.", g_tag, clientName);

			if (g_isExpectingOverride && g_isWantingOverride[team])
			{
				g_isWantingOverride[team] = false;
				PrintToChatAll("Cancelled %s's force start vote.", g_teamName[team]);
			}
		}

		case true: // Collective readying
		{
			for (new i = 1; i <= MaxClients; i++)
			{
				if ( !IsValidClient(i) )
					continue;

				if ( team != GetClientTeam(i) )
					continue;

				g_isReady[i] = false;
			}

			PrintToChatAll("%s Team %s is NOT READY.", g_tag, g_teamName[team]);
		}
	}

	if (g_isLiveCountdown)
		CancelLiveCountdown();

	return Plugin_Handled;
}

#if DEBUG
public Action:Command_LoggingTest(client, args)
{
	if (args != 1)
	{
		ReplyToCommand(client, "Expected 1 argument.");

		return Plugin_Stop;
	}

	new String:message[128];
	GetCmdArg(1, message, sizeof(message));
	LogCompetitive(message);

	ReplyToCommand(client, "Debug log message sent.");

	return Plugin_Handled;
}

public Action:Command_ManualRoundEdit(client, args)
{
	if (GetCmdArgs() != 1)
	{
		ReplyToCommand(client, "Usage: <round int>");
		return Plugin_Stop;
	}

	decl String:sBuffer[6];
	GetCmdArg( 1, sBuffer, sizeof(sBuffer) );

	new round = StringToInt(sBuffer);
	if (round < 1 || round > MAX_ROUNDS_PLAYED)
	{
		ReplyToCommand(client, "Invalid target round");
		return Plugin_Stop;
	}

	g_roundNumber = round;
	GameRules_SetProp("m_iRoundNumber", g_roundNumber - 1);

	ReplyToCommand(client, "Set round int to %i", round);

	return Plugin_Handled;
}
#endif

public Competitive_IsLive(Handle:plugin, numParams)
{
	return g_isLive;
}

public Competitive_IsPaused(Handle:plugin, numParams)
{
	return g_isPaused;
}

public Competitive_GetTeamScore(Handle:plugin, numParams)
{
	if (numParams != 1)
		return -1;

	new team = GetNativeCell(1);

	if (team == TEAM_JINRAI)
		return g_jinraiScore[g_roundNumber];

	else if (team == TEAM_NSF)
		return g_nsfScore[g_roundNumber];

	return -1;
}

public Competitive_GetWinner(Handle:plugin, numParams)
{
	return g_winner;
}
