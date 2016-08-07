// Double-include prevention
#if defined _sql_included_
	#endinput
#endif
#define _sql_included_

#define MAX_SQL_LENGTH 768
#define MAX_SQL_ERROR_LENGTH 512
#define MAX_SQL_TIMESTAMP_LENGTH 20

Database db = null;

// This table holds pugger information
enum {
	SQL_TABLE_PUGGER_ID = 0,									// Auto incremented database id
	SQL_TABLE_PUGGER_TIMESTAMP,							// Timestamp of last update
	SQL_TABLE_PUGGER_STEAMID,								// Player SteamID in AuthId_Steam2 format
	SQL_TABLE_PUGGER_STATE,									// Current state of pugger, eg. queuing, confirming, playing a match
	SQL_TABLE_PUGGER_GAMESERVER_CONNECT_IP,		// If playing, which server IP is player currently invited to play on
	SQL_TABLE_PUGGER_GAMESERVER_CONNECT_PORT,	// If playing, which server port is player currently invited to play on
	SQL_TABLE_PUGGER_GAMESERVER_PASSWORD,
	SQL_TABLE_PUGGER_MATCH_ID,								// If playing, what's the match id of the current match
	SQL_TABLE_PUGGER_MATCH_TIMESTAMP,				// If playing, when did the match begin
	SQL_TABLE_PUGGER_MATCH_ORGANIZER,					// If playing, who created the match (unique string id of a pub server, chat bot etc. for example their ip)
	SQL_TABLE_PUGGER_IGNORED_INVITES,					// How many match invites has the player ignored? Used to determine placing in match queue.
	SQL_TABLE_PUGGER_IGNORED_TIMESTAMP,				// When did the player last ignore a match invite? Ignores reset after set time, or after accepting a match.
	SQL_TABLE_PUGGER_INVITE_TIMESTAMP,				// When was this player last invited to a PUG. Used for invite expiration.
	SQL_TABLE_PUGGER_ENUM_COUNT
};
// This table holds global rules PUG servers should follow
enum {
	SQL_TABLE_RULES_DESIRED_PLAYERCOUNT = 0,
	SQL_TABLE_RULES_ENUM_COUNT
};
// This table holds PUG organizer (public gameserver, chatbot, etc.) information
enum {
	SQL_TABLE_ORG_ID = 0,										// Auto incremented database id
	SQL_TABLE_ORG_TIMESTAMP,								// Timestamp of last update
	SQL_TABLE_ORG_NAME,										// Unique string identifier for this organizer, for example their IP address
	SQL_TABLE_ORG_RESERVING,									// Only one organizer is allowed to reserve a match at a time to avoid double-booking. This int determines who is currently allowed to edit.
	SQL_TABLE_ORG_RESERVING_TIMESTAMP,				// When did this organizer last gain permission to reserve a match
	SQL_TABLE_ORG_ENUM_COUNT
};
// This table holds PUG game server information
enum {
	SQL_TABLE_PUG_SERVER_ID = 0,							// Auto incremented database id
	SQL_TABLE_PUG_SERVER_TIMESTAMP,					// Timestamp of last update
	SQL_TABLE_PUG_SERVER_NAME,								// Human friendly call name. Not used for identification so it doesn't have to be unique.
	SQL_TABLE_PUG_SERVER_CONNECT_IP,					// Server connect IP. Used for identification together with port.
	SQL_TABLE_PUG_SERVER_CONNECT_PORT,				// Server connect port.
	SQL_TABLE_PUG_SERVER_CONNECT_PASSWORD,		// Server connect password, if any.
	SQL_TABLE_PUG_SERVER_STATUS,							// Server status (available, waiting for players, match live etc.)
	SQL_TABLE_PUG_SERVER_RESERVEE,						// Which organizer last reserved this server
	SQL_TABLE_PUG_SERVER_RESERVATION_TIMESTAMP,// When was this server last reserved
	SQL_TABLE_PUG_SERVER_ENUM_COUNT
};

enum {
	PUGGER_STATE_INACTIVE = 0,								// This pugger is not currently queuing or playing at all
	PUGGER_STATE_QUEUING = 1,										// Queuing for a match
	PUGGER_STATE_CONFIRMING = 2,								// Match has been offered, waiting for this pugger to accept
	PUGGER_STATE_ACCEPTED = 3,									// Pugger has accepted a match, preparing to go live
	PUGGER_STATE_LIVE = 4,											// Currently playing
	PUGGER_STATE_ENUM_COUNT = 5
};

enum {
	PUG_SERVER_STATUS_ERROR = 0,							// Something is wrong with this server, unavailable for PUG
	PUG_SERVER_STATUS_BUSY = 1,									// Server is preoccupied by some organized event etc.
	PUG_SERVER_STATUS_AVAILABLE = 2,							// Server is available for pugging
	PUG_SERVER_STATUS_RESERVED = 3,							// An organizer has reserved this server for a pug match
	PUG_SERVER_STATUS_AWAITING_PLAYERS = 4,				// All puggers accepted, waiting for players to join to start a match
	PUG_SERVER_STATUS_LIVE = 5									// Match is live
};
// Avoid double booking games and other conflicts
enum {
	SERVER_DB_INACTIVE = 0,									// This server is not editing the SQL database
	SERVER_DB_RESERVED = 1,											// This server has reserved the right to edit the SQL database
	SERVER_DB_PASSING_ON = 2,										// This server has finished editing the SQL database, but wants to pass on that right to a specific other server
	SERVER_DB_ENUM_COUNT = 3
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
	"invite_timestamp"
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
