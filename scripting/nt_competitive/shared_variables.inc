#if defined _shared_variables_included_
  #endinput
#endif
#define _shared_variables_included_

#define MAX_IP_LENGTH 46
#define MAX_IDENTIFIER_LENGTH 52
#define MAX_CVAR_LENGTH 64
#define MAX_STEAMID_LENGTH 44
#define PUG_INVITE_TIME 60
#define QUEUE_CHECK_TIMER 30
#define MAX_ROUNDS_PLAYED 255 // This is just a random large number used for 1d int arrays because it's cheap and simple. A single comp game should never have more rounds than this to avoid weirdness.

#if defined PLUGIN_COMP
#define KV_IDENTIFIER "compdata"

new String:g_teamName[][64] = {
	"Unassigned",
	"Spectator",
	"Jinrai",
	"NSF"
};
#endif

#if defined PLUGIN_PUG
// Set this to something uniquely identifying if the plugin fails to
// retrieve your external IP.
new String:g_sIdentifier[MAX_IDENTIFIER_LENGTH];
#endif

#if defined PLUGIN_COMP
new String:g_livePlayers[MAXPLAYERS+1][MAX_STEAMID_LENGTH]; // Array for storing SteamIDs to allow disconnected players rejoining when live
new String:g_killInfoBuffer[MAXPLAYERS+1][512];
new String:g_convarBeingEdited[128];

new const String:g_menuSoundOk[] = "buttons/button14.wav";
new const String:g_menuSoundCancel[] = "buttons/combine_button7.wav";
new const String:g_soundLive[] = "buttons/button17.wav";
#endif

#if defined PLUGIN_COMP && DEBUG
new String:g_path_logDebug[PLATFORM_MAX_PATH] = "logs/competitive";
new String:g_kvPath[PLATFORM_MAX_PATH] = "data/competitive/matches";
new String:g_kvName[128];
new String:g_kvName_Temp[MAXPLAYERS+1][sizeof(g_kvName)];
#endif

#if defined PLUGIN_COMP
new const String:g_kvKey_jinraiName[] = "jinrai_name";
new const String:g_kvKey_nsfName[] = "nsf_name";
new const String:g_kvKey_competitionName[] = "competition_name";
new const String:g_kvKey_sourceTVPath[] = "sourcetv_path";
new const String:g_kvKey_roundLimit[] = "round_limit";
new const String:g_kvKey_matchSize[] = "match_size";
new const String:g_kvKey_maxTimeouts[] = "max_timeouts";
new const String:g_kvKey_maxPauseLength[] = "max_pause_length";
new const String:g_kvKey_maxPauseLengthTechnical[] = "max_pause_length_technical";
new const String:g_kvKey_commsBehaviour[] = "comms_behaviour";
new const String:g_kvKey_logMode[] = "log_mode";
new const String:g_kvKey_killVerbosity[] = "kill_verbosity";
new const String:g_kvKey_killVerbosityDelay[] = "kill_verbosity_delay";
new const String:g_kvKey_clientRecording[] = "client_recording";
new const String:g_kvKey_limitLiveTeams[] = "limit_live_teams";
new const String:g_kvKey_limitTeams[] = "limit_teams";
new const String:g_kvKey_pauseMode[] = "pause_mode";
new const String:g_kvKey_collectiveReady[] = "collective_ready";
new const String:g_kvKey_noZanshi[] = "no_zanshi";
new const String:g_kvKey_jinraiScore[] = "jinrai_score";
new const String:g_kvKey_nsfScore[] = "nfs_score";
new const String:g_kvKey_suddenDeath[] = "sudden_death";
new const String:g_kvKey_centered_displayRemaining[] = "centered_display_remaining";
new const String:g_kvKey_centered_displayTarget[] = "centered_display_target";
new const String:g_kvKey_natives_alltalk[] = "natives_alltalk";
new const String:g_kvKey_natives_forceCamera[] = "natives_forcecamera";
new const String:g_kvKey_natives_pausable[] = "natives_pausable";
new const String:g_kvKey_natives_roundTime[] = "natives_round_time";
new const String:g_kvKey_natives_scoreLimit[] = "natives_scorelimit";
new const String:g_kvKey_jinraiPauses[] = "jinrai_pauses_used";
new const String:g_kvKey_nsfPauses[] = "nsf_pauses_used";

new g_assignedTeamWhenLive[MAXPLAYERS+1];
new g_jinraiScore[MAX_ROUNDS_PLAYED];
new g_liveTimer = 5;
new g_liveTimer_OriginalValue;
new g_loggingEnabled;
new g_nsfScore[MAX_ROUNDS_PLAYED];
new g_pauseReason;
new g_pausingTeam;
new g_roundNumber;
new g_spamTimerCount;
new g_unpauseTimer = 10;
new g_unpauseTimer_OriginalValue;
new g_usedTimeouts[sizeof(g_teamName)];
new g_playersAlive[sizeof(g_teamName)];
new g_winner;
new g_health[MAXPLAYERS+1];
new g_damageDealt[MAXPLAYERS+1][MAXPLAYERS+1];
new g_playerDeaths[MAXPLAYERS+1][MAX_ROUNDS_PLAYED]; // Players' deaths for each round
new g_playerXP[MAXPLAYERS+1][MAX_ROUNDS_PLAYED]; // Players' XP for each round
new g_targetRound;
new g_furthestPlayedRound;
new g_penalizedTeam;
new g_ghostCapturingTeam;
new g_epoch;

new Float:g_fRoundTime;

new bool:g_isAlltalkByDefault;
new bool:g_isExpectingOverride;
new bool:g_isExpectingUnPauseTimer;
new bool:g_isLive;
new bool:g_isPaused;
new bool:g_isReady[MAXPLAYERS+1];
new bool:g_isSourceTVRecording;
new bool:g_isSpawned[MAXPLAYERS+1];
new bool:g_isTeamReadyForUnPause[sizeof(g_teamName)]; // Unassigned, spec, jinrai, nsf
new bool:g_isWantingOverride[sizeof(g_teamName)]; // Unassigned, spec, jinrai, nsf
new bool:g_shouldPause;
new bool:g_shouldShowKillInfo[MAXPLAYERS+1];
new bool:g_isLiveCountdown;
new bool:g_isEditingSetting[MAXPLAYERS+1];
new bool:g_confirmLiveEnd;
new bool:g_isGamedataOutdated;
new bool:g_isCurrentlyUnPausing;
new bool:g_confirmRoundChange;
new bool:g_isCurrentlyRestoringRound;
new bool:g_isCurrentlyEditingClients[MAXPLAYERS+1];
new bool:g_isCurrentlyGivingPenalty[MAXPLAYERS+1];
new bool:g_survivedLastRound[MAXPLAYERS+1];
new bool:g_isSuddenDeathRound;
new bool:g_goLiveAfterKvRestore[MAXPLAYERS+1] = true;

new Handle:g_hAlltalk;
new Handle:g_hCommsBehaviour;
new Handle:g_hCompetitionName;
new Handle:g_hForceCamera;
new Handle:g_hLogMode;
new Handle:g_hMatchSize;
new Handle:g_hMaxPauseLength;
new Handle:g_hMaxPauseLength_Technical;
new Handle:g_hMaxTimeouts;
new Handle:g_hNeoScoreLimit;
new Handle:g_hNeoRestartThis;
new Handle:g_hPausable;
new Handle:g_hRoundLimit;
new Handle:g_hSourceTVEnabled;
new Handle:g_hSourceTVPath;
new Handle:g_hJinraiName;
new Handle:g_hNSFName;
new Handle:g_hKillVersobity;
new Handle:g_hClientRecording;
new Handle:g_hLimitLiveTeams;
new Handle:g_hLimitTeams;
new Handle:g_hVerbosityDelay;
new Handle:g_hPauseMode;
new Handle:g_hCollectiveReady;
new Handle:g_hPreventZanshiStrats;
new Handle:g_hRoundTime;
new Handle:g_hJinraiScore;
new Handle:g_hNSFScore;
new Handle:g_hSuddenDeath;
new Handle:g_hCenteredDisplayRemaining;
new Handle:g_hCenteredDisplayTarget;
new Handle:g_hCompForceCamera;
new Handle:g_hPugEnabled;
new Handle:g_hPassword;
new Handle:g_hCvar_UnloadScoreLimit;
#endif

new Handle:g_hCvar_DbConfig;

#if defined PLUGIN_COMP && DEBUG
new Handle:g_hDebugKeyValues;
#endif

#if defined PLUGIN_COMP
new Handle:g_hTimer_LiveCountdown = INVALID_HANDLE;
new Handle:g_hTimer_GoLive = INVALID_HANDLE;
new Handle:g_hTimer_UnPause = INVALID_HANDLE;
new Handle:g_hTimer_UnPause_Countdown = INVALID_HANDLE;
new Handle:g_hTimer_UnPause_HalfLeft = INVALID_HANDLE;

KeyValues g_kv;

Menu g_clientMenu = null;
#endif

enum {
	CVAR_NONE = 0,
	CVAR_COMPETITION_NAME,
	CVAR_JINRAI_NAME,
	CVAR_NSF_NAME,
	CVAR_MAX_ROUNDS,
	CVAR_PAUSE_AMOUNT
};

enum {
	GAMESTATE_WARMUP = 1,
	GAMESTATE_NORMAL
};

enum {
	PAUSEMODE_FORBIDDEN = 0,
	PAUSEMODE_NORMAL,
	PAUSEMODE_STOP_CLOCK
};

enum {
	REASON_TECHNICAL = 0,
	REASON_TIMEOUT
};

enum cvarReturnType {
	TYPE_INT = 0,
	TYPE_FLOAT,
	TYPE_STRING
}

Database db = null;

#define MAX_SQL_LENGTH 768
#define MAX_SQL_ERROR_LENGTH 512
#define MAX_SQL_TIMESTAMP_LENGTH 20

// This table holds pugger information
enum {
	SQL_TABLE_PUGGER_ID = 0,									// Auto incremented database id
	SQL_TABLE_PUGGER_TIMESTAMP,				  			// Timestamp of last update
	SQL_TABLE_PUGGER_STEAMID,						  		// Player SteamID in AuthId_Steam2 format
	SQL_TABLE_PUGGER_STATE,							   		// Current state of pugger, eg. queuing, confirming, playing a match
	SQL_TABLE_PUGGER_GAMESERVER_CONNECT_IP,		// If playing, which server IP is player currently invited to play on
	SQL_TABLE_PUGGER_GAMESERVER_CONNECT_PORT,	// If playing, which server port is player currently invited to play on
	SQL_TABLE_PUGGER_GAMESERVER_PASSWORD,
	SQL_TABLE_PUGGER_MATCH_ID,								// If playing, what's the match id of the current match
	SQL_TABLE_PUGGER_MATCH_TIMESTAMP,			   	// If playing, when did the match begin
	SQL_TABLE_PUGGER_MATCH_ORGANIZER,					// If playing, who created the match (unique string id of a pub server, chat bot etc. for example their ip)
	SQL_TABLE_PUGGER_IGNORED_INVITES,					// How many match invites has the player ignored? Used to determine placing in match queue.
	SQL_TABLE_PUGGER_IGNORED_TIMESTAMP,				// When did the player last ignore a match invite? Ignores reset after set time, or after accepting a match.
	SQL_TABLE_PUGGER_INVITE_TIMESTAMP,				// When was this player last invited to a PUG. Used for invite expiration.
	SQL_TABLE_PUGGER_HAS_MATCH_MSG,						// This player has an unseen message regarding their match invitation.
	SQL_TABLE_PUGGER_MATCH_MSG,								// Match message string for this player.
	SQL_TABLE_PUGGER_ENUM_COUNT
};
// This table holds global rules PUG servers should follow
enum {
	SQL_TABLE_RULES_DESIRED_PLAYERCOUNT = 0,
	SQL_TABLE_RULES_ENUM_COUNT
};
// This table holds PUG organizer (public gameserver, chatbot, etc.) information
enum {
	SQL_TABLE_ORG_ID = 0,								// Auto incremented database id
	SQL_TABLE_ORG_TIMESTAMP,						// Timestamp of last update
	SQL_TABLE_ORG_NAME,								 	// Unique string identifier for this organizer, for example their IP address
	SQL_TABLE_ORG_RESERVING,						// Only one organizer is allowed to reserve a match at a time to avoid double-booking. This int determines who is currently allowed to edit.
	SQL_TABLE_ORG_RESERVING_TIMESTAMP,	// When did this organizer last gain permission to reserve a match
	SQL_TABLE_ORG_ENUM_COUNT
};
// This table holds PUG game server information
enum {
	SQL_TABLE_PUG_SERVER_ID = 0,                 // Auto incremented database id
	SQL_TABLE_PUG_SERVER_TIMESTAMP,              // Timestamp of last update
	SQL_TABLE_PUG_SERVER_NAME,                   // Human friendly call name. Not used for identification so it doesn't have to be unique.
	SQL_TABLE_PUG_SERVER_CONNECT_IP,             // Server connect IP. Used for identification together with port.
	SQL_TABLE_PUG_SERVER_CONNECT_PORT,           // Server connect port.
	SQL_TABLE_PUG_SERVER_CONNECT_PASSWORD,       // Server connect password, if any.
	SQL_TABLE_PUG_SERVER_STATUS,                 // Server status (available, waiting for players, match live etc.)
	SQL_TABLE_PUG_SERVER_RESERVEE,               // Which organizer last reserved this server
	SQL_TABLE_PUG_SERVER_RESERVATION_TIMESTAMP,  // When was this server last reserved
	SQL_TABLE_PUG_SERVER_ENUM_COUNT
};

enum {
	PUGGER_STATE_INACTIVE = 0,						   		// This pugger is not currently queuing or playing at all
	PUGGER_STATE_QUEUING = 1,										// Queuing for a match
	PUGGER_STATE_CONFIRMING = 2,								// Match has been offered, waiting for this pugger to accept
	PUGGER_STATE_ACCEPTED = 3,									// Pugger has accepted a match invite
	PUGGER_STATE_READY = 4,											// Pugger is expected to go live soon
	PUGGER_STATE_LIVE = 5,											// Currently playing
	PUGGER_STATE_ENUM_COUNT = 6
};

enum {
	PUG_SERVER_STATUS_ERROR = 0,					  		// Something is wrong with this server, unavailable for PUG
	PUG_SERVER_STATUS_BUSY = 1,									// Server is preoccupied by some organized event etc.
	PUG_SERVER_STATUS_AVAILABLE = 2,						// Server is available for pugging
	PUG_SERVER_STATUS_RESERVED = 3,							// An organizer has reserved this server for a pug match
	PUG_SERVER_STATUS_AWAITING_PLAYERS = 4,			// All puggers accepted, waiting for players to join to start a match
	PUG_SERVER_STATUS_LIVE = 5									// Match is live
};
// Avoid double booking games and other conflicts
enum {
	SERVER_DB_INACTIVE = 0,								    	// This server is not editing the SQL database
	SERVER_DB_RESERVED = 1,									   	// This server has reserved the right to edit the SQL database
	SERVER_DB_ENUM_COUNT = 2
};

enum {
	TABLES_RULES = 0,
	TABLES_ORGANIZERS,
	TABLES_PUG_SERVERS,
	TABLES_PUGGERS,
	TABLES_ENUM_COUNT
}

new const String:g_sqlTable[TABLES_ENUM_COUNT][] = {
	"global_rules",
	"organizers",
	"pickup_servers",
	"puggers",
};

new const String:g_sqlRow_Rules[SQL_TABLE_RULES_ENUM_COUNT][] = {
	"desired_playercount"
};

new const String:g_sqlRow_Organizers[SQL_TABLE_ORG_ENUM_COUNT][] = {
	"id",
	"timestamp",
	"unique_name",
	"is_reserving",
	"reserving_timestamp",
};

new const String:g_sqlRow_Puggers[SQL_TABLE_PUGGER_ENUM_COUNT][] = {
	"id",
	"timestamp",
	"steamid",
	"state",
	"server_connect_ip",
	"server_connect_port",
	"server_connect_password", // todo: add server's "vanity name"
	"match_id",
	"match_timestamp",
	"match_organizer_id",
	"invites_ignored",
	"invites_ignored_timestamp",
	"invite_timestamp",
	"has_pending_match_message",
	"match_message"
};

new const String:g_sqlRow_PickupServers[SQL_TABLE_PUG_SERVER_ENUM_COUNT][] = {
	"id",
	"timestamp",
	"vanity_name",
	"connect_ip",
	"connect_port",
	"connect_password",
	"status",
	"reservee",
	"reservation_timestamp"
};
