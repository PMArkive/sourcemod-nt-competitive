// Double-include prevention
#if defined _shared_functions_included_
	#endinput
#endif
#define _shared_functions_included_

// TODO: Split this in plugin specific files when it's clear which parts
// need to be shared and which don't.
int GetClientOfAuthId(const char[] steamID)
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

bool GetServerConnectionDetails(char[] sIPAddress, int &iPort)
{
	Handle hIP = FindConVar("ip");
	if (hIP == null)
	{
		return false;
	}
	Handle hPort = FindConVar("hostport");
	if (hPort == null)
	{
		delete hIP;
		return false;
	}

	decl String:ipBuffer[MAX_IP_LENGTH];
	GetConVarString(hIP, ipBuffer, sizeof(ipBuffer));
	iPort = GetConVarInt(hPort);

	delete hIP;
	delete hPort;

// Check for localhost addresses. These can occur with routers etc.
// SQL debug flag will skip this for easier local testing.
#if !defined DEBUG_SQL || DEBUG_SQL == 0
	if (IsLocalhostString(ipBuffer))
	{
	#if defined PLUGIN_PUG
		ThrowError("Returned a local address %s:%i, expected to find a public address. \
This can't be used for uniquely identifying the server. \
You can declare a unique g_sIdentifier value near the beginning \
of the plugin source code to manually circumvent this problem.",
			ipBuffer, iPort);
	#else
		ThrowError("Returned a local address %s:%i, expected to find a public address.",
			ipBuffer, iPort);
	#endif
	}
#endif
	// Not a localhost address, can safely serve IP and return true.
	strcopy(sIPAddress, MAX_IP_LENGTH, ipBuffer);
	return true;
}

#if !defined DEBUG_SQL || DEBUG_SQL == 0
#if defined PLUGIN_PUG
bool IsLocalhostString(const char[] ipAddress)
{
	if (StrEqual(ipAddress, "localhost") ||
			StrEqual(ipAddress, "127.0.0.1") ||
			StrContains(ipAddress, "192.168.") == 0)
	{
		return true;
	}
	return false;
}
#endif
#endif

void PrintDebug(const String:message[], any ...)
{
#if DEBUG
	decl String:formatMsg[768];
	VFormat(formatMsg, sizeof(formatMsg), message, 2);

	// Todo: Print to debug logfile
	PrintToServer(formatMsg);
#endif
}

#if defined PLUGIN_COMP
void PrintToAdmins(bool toChat = true, bool toConsole = false, const String:message[], any ...)
{
	decl String:formatMsg[512];
	VFormat(formatMsg, sizeof(formatMsg), message, 4);

	for (new i = 1; i <= MaxClients; i++)
	{
		if ( !IsValidClient(i) || !IsAdmin(i) )
			continue;

		if (toChat)
			PrintToChat(i, formatMsg);

		if (toConsole)
			PrintToConsole(i, formatMsg);
	}
}
#endif

#if defined PLUGIN_COMP
// Purpose: Return the contents of a server cvar.
// Will return int and float as any, strings by reference.
any GetCvarValue(const String:sCvar[], returnType, String:sBuffer[] = "", iMaxStrLen = 0, bool:doFatalFail = true)
{
	//PrintDebug("GetCvarValue()");

	new Handle:hCvar = FindConVar(sCvar);
	if (hCvar == INVALID_HANDLE && doFatalFail)
		SetFailState("Could not find cvar \"%s\", cvar");

	any value;

	//PrintDebug("Entering the switch statement");
	switch(returnType)
	{
		case VAR_TYPE_INT:
		{
			//PrintDebug("Type INT");
			value = GetConVarInt(hCvar);
		}
		case VAR_TYPE_FLOAT:
		{
			//PrintDebug("Type FLOAT");
			value = GetConVarFloat(hCvar);
		}
		case VAR_TYPE_STRING:
		{
			//PrintDebug("Type STRING");
			GetConVarString(hCvar, sBuffer, iMaxStrLen);
		}
		default:
		{
			PrintDebug("Entered switch default (error!)");
			decl String:error[40];

			Format(error, sizeof(error), "Unexpected cvar return type enum %i",
				returnType);

			if (doFatalFail)
				SetFailState(error);

			CloseHandle(hCvar);
			ThrowError(error);
		}
	}
	CloseHandle(hCvar);
	return value;
}

// Purpose: Return whether client is a generic admin.
// Function basic structure borrowed from smlib library's Client_IsAdmin
// as per GPLv3 license: https://github.com/bcserv/smlib
bool IsAdmin(client)
{
	if (!IsValidClient(client, true))
	{
		LogError("IsAdmin: Client %i is not valid. This shouldn't happen.", client);
		return false;
	}
	if (!IsClientAuthorized(client))
	{
		return false;
	}

	new AdminId:adminId = GetUserAdmin(client);
	if (adminId == INVALID_ADMIN_ID)
	{
		return false;
	}

	return GetAdminFlag(adminId, Admin_Generic);
}
#endif
