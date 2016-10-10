// Double-include prevention
#if defined _shared_functions_included_
	#endinput
#endif
#define _shared_functions_included_

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
	PrintDebug("GetCvarValue()");

	new Handle:hCvar = FindConVar(sCvar);
	if (hCvar == INVALID_HANDLE && doFatalFail)
		SetFailState("Could not find cvar \"%s\", cvar");

	any value;

	PrintDebug("Entering the switch statement");
	switch(returnType)
	{
		case TYPE_INT:
		{
			PrintDebug("Type INT");
			value = GetConVarInt(hCvar);
		}
		case TYPE_FLOAT:
		{
			PrintDebug("Type FLOAT");
			value = GetConVarFloat(hCvar);
		}
		case TYPE_STRING:
		{
			PrintDebug("Type STRING");
			GetConVarString(hCvar, sBuffer, iMaxStrLen);
		}
		default:
		{
			PrintDebug("Entered switch default (error!)");
			decl String:error[40];

			Format(error, sizeof(error), "Unexpected cvar return type enum %i",
				returnType);

			if (doFatalFail)
			{
				SetFailState(error);
			}
			else
			{
				CloseHandle(hCvar);
				ThrowError(error);
			}
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
#if DEBUG
	if (!IsValidClient(client))
	{
		LogError("IsAdmin: Client %i is not valid. This shouldn't happen.", client);
		return false;
	}
#endif
	new AdminId:adminId = GetUserAdmin(client);
	if (adminId == INVALID_ADMIN_ID)
		return false;

	return GetAdminFlag(adminId, Admin_Generic);
}
#endif
