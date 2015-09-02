#define MAX_SQL_LENGTH 2048

#define SQL_CONFIG "nt_competitive_matchmaking"
#define SQL_TABLE_QUEUED "queued"
#define SQL_TABLE_OFFER_MATCH "match_offers"

new bool:g_isSQLInitialized;

new Handle:db = INVALID_HANDLE;

void InitSQL()
{
	// Connection already initialised
	if (db != INVALID_HANDLE)
		return;
	
	new String:sqlError[256];
	db = SQL_Connect(SQL_CONFIG, true, sqlError, sizeof(sqlError));
	
	if (db == INVALID_HANDLE)
	{
		LogError("SQL error: %s", sqlError);
		return;
	}
	
	decl String:sql[MAX_SQL_LENGTH];
	Format(sql, sizeof(sql), "CREATE TABLE IF NOT EXISTS %s( \
		id INT(5) NOT NULL AUTO_INCREMENT, \
		players_queued INT(2), \
		Timestamp TIMESTAMP, \
		PRIMARY KEY (id)) CHARACTER SET=utf8;", SQL_TABLE_QUEUED);
	
	if (!SQL_FastQuery(db, sql))
	{
		LogError("SQL error: query error");
		return;
	}
	
	Format(sql, sizeof(sql), "CREATE TABLE IF NOT EXISTS %s( \
		id INT(5) NOT NULL AUTO_INCREMENT, \
		server_ip VARCHAR(16), \
		server_port INT(5), \
		server_password VARCHAR(32), \
		server_name VARCHAR(128), \
		Timestamp TIMESTAMP, \
		PRIMARY KEY (id)) CHARACTER SET=utf8;", SQL_TABLE_OFFER_MATCH);
	
	if (!SQL_FastQuery(db, sql))
	{
		LogError("SQL error: query error");
		return;
	}
	
	g_isSQLInitialized = true;
	
	return;
}
