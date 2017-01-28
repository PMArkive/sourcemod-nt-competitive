#if !defined TESTS_INCLUDED_MATCHMAKE || defined _tests_matchmake_included_
  #endinput
#endif
#define _tests_matchmake_included_

public Action Command_RunTest_Matchmake(int client, int args)
{
  Test_Matchmake_Main();
  return Plugin_Handled;
}

bool Assert(bool assertion, int &failCount, const char[] description, any ...)
{
  decl String:formattedDesc[1024];
  if (VFormat(formattedDesc, sizeof(formattedDesc), description, 4) == 0)
    ThrowError("0 bytes description message.");

  if (assertion == false)
  {
    failCount++;
    PrintToServer("-- %s : failed! <---", formattedDesc);
    return false;
  }
  PrintToServer("-- %s : passed.", formattedDesc);
  return true;
}

bool DidWePass_SubTest(const int failCount)
{
  if (failCount == 0)
  {
    PrintToServer("- Sub test passed.\n");
    return true;
  }
  PrintToServer("- Sub test failed %i times!", failCount);
  return false;
}

void Test_Matchmake_Main()
{
  PrintToServer("\n- - - - - - - - - -\nStarting testing...\n");
  /* Test needed (match initialisation)
    - Get accepted players, and handle them in cases:
      - accepted == desired
      - more accepted than desired
      - less accepted than desired
    - while
      - is idle
      - has game
    - while
      - organizers are idle/busy
      - pug servers are idle/busy
      - combinations of these
      - unexpected states where multiple places claim db write
  */
  int tests = 0;
  int passed = 0;
  int failed = 0;

  /*Tests start, format:
      tests++; if (Test_Function()) { passed++; } else { failed++; }*/
  tests++; if (Test_AlwaysPass())                       { passed++; } else { failed++; }
  tests++; if (Test_Matchmake_DatabaseConnection())     { passed++; } else { failed++; }
  tests++; if (Test_Matchmake_DatabaseOperations())     { passed++; } else { failed++; }
  tests++; if (Test_Matchmake_PugServer_Reservations()) { passed++; } else { failed++; }
  tests++; if (Test_Matchmake_PugServer_Matchmake())    { passed++; } else { failed++; }
  // Tests end.

  // Results
  PrintToServer("Main tests:\n- Passed %i tests.\n\
- Failed %i tests.\n- Main tests total: %i.\n", passed, failed, tests);
  if (failed + passed != tests)
  {
    ThrowError("Test error: Something went wrong with test counting.");
  }
  else if (tests == 0)
  {
    PrintToServer("No tests were found!");
  }
  else if (failed == 0)
  {
    PrintToServer("All tests passed.");
  }
  else
  {
    PrintToServer("Some tests failed!");
  }
  PrintToServer("\nTesting complete.\n- - - - - - - - - -\n");
}

bool Test_AlwaysPass()
{
  PrintToServer("- Sub test: Test_AlwaysPass...");
  int failCount;

  Assert(1 == 1, failCount, "One equals one.");
  Assert(true, failCount, "True.");

  return DidWePass_SubTest(failCount);
}

bool Test_Matchmake_DatabaseConnection()
{
  PrintToServer("- Sub test: Test_Matchmake_DatabaseConnection...");
  int failCount;

  Assert(
    g_hDB != null, failCount,
    "Global db handle is not null."
  );

  if (Database_DoTablesExist() == false)
  {
    Database_CreateTables();
  }
  Assert(
    Database_Initialize(), failCount,
    "Calling Database_Initialize() returns true."
  );

  Assert(
    Database_DoTablesExist(), failCount,
    "Calling Database_DoTablesExist() returns true."
  );

  return DidWePass_SubTest(failCount);
}


bool Test_Matchmake_DatabaseOperations()
{
  PrintToServer("- Sub test: Test_Matchmake_DatabaseOperations...");
  int failCount;

  new const String:steamID[] = "STEAMID_TEST:0:123";
  Assert(
    Database_AddPugger(_, true, steamID), failCount,
    "Calling Database_AddPugger to add SteamID to pugger db by string returns true."
  );

  const int state_initial = -1;
  int state = state_initial;
  Assert(
    state == state_initial, failCount,
    "The variable \"state\" has been initialised with the correct value %i.",
      state_initial
  );

  state = Pugger_GetQueuingState(_, _, _, true, steamID);

  Assert(
    state != state_initial, failCount,
    "The retrieved pugger state has been stored in the variable \
initialised with a value that is an invalid pugger state enum."
  );

  Assert(
    state != PUGGER_STATE_LIVE, failCount,
    "The state variable doesn't already contain the PUGGER_STATE_LIVE enum."
  );

  int countPerState = Puggers_GetCountPerState(PUGGER_STATE_LIVE);
  Assert(
    Pugger_SetQueuingState(_, PUGGER_STATE_LIVE, true, steamID), failCount,
    "Calling Pugger_SetQueuingState() to set the pugger's queuing state \
to PUGGER_STATE_LIVE by SteamID returns true."
  );

  Assert(
    Puggers_GetCountPerState(PUGGER_STATE_LIVE) == countPerState + 1,
    failCount,
    "The count of puggers with state  PUGGER_STATE_LIVE has gone up by one \
after the insertion of the test pugger."
  );

  Assert(
    Pugger_GetQueuingState(_, _, _, true, steamID) == PUGGER_STATE_LIVE,
    failCount,
    "The result of calling Pugger_GetQueuingState() to fetch the pugger's \
state returns PUGGER_STATE_LIVE according to the previous assertion."
  );

  Assert(
    Database_RemovePugger(steamID), failCount,
    "Calling Database_RemovePugger() to remove the pugger from the \
database returns true."
  );

  Assert(
    Pugger_GetQueuingState(_, _, _, true, steamID) == PUGGER_STATE_INACTIVE,
    failCount,
    "Calling Pugger_GetQueuingState() in an attempt to retrieve \
the removed pugger's state from the db returns PUGGER_STATE_INACTIVE."
  );

  return DidWePass_SubTest(failCount);
}

bool Test_Matchmake_PugServer_Reservations()
{
  PrintToServer("- Sub test: Test_Matchmake_PugServer_Reservations...");
  int failCount;

  if (GetConVarInt(g_hPugEnabled) != 1)
  {
    SetConVarInt(g_hPugEnabled, 1);
  }
  Assert(
    GetConVarInt(g_hPugEnabled) == 1, failCount,
    "Cvar handle g_hPugEnabled has value 1."
  );

  Assert(
    PugServer_SetReserve_This(DB_PUG_INACTIVE), failCount,
    "Calling PugServer_SetReserve_This with DB_PUG_INACTIVE returns true."
  );

  Assert(
    PugServer_GetReserve_This() == DB_PUG_INACTIVE, failCount,
    "PugServer_GetReserve_This returns DB_PUG_RESERVED in accordance \
with the previous assertion."
  );

  Assert(
    PugServers_Is_Anyone_Busy(true) == false, failCount,
    "PugServers_Is_Anyone_Busy(including myself) returns false. \
Assuming that there are no live pug servers in this test case."
  );

  Assert(
    PugServer_SetReserve_This(DB_PUG_RESERVED), failCount,
    "Calling PugServer_SetReserve_This with DB_PUG_RESERVED returns true. \
Assuming that there are no live pug servers in this test case."
  );

  Assert(
    PugServer_GetReserve_This() == DB_PUG_RESERVED, failCount,
    "PugServer_GetReserve_This returns DB_PUG_RESERVED in accordance \
with the previous assertion."
  );

  Assert(
    PugServers_Is_Anyone_Busy(false) == false, failCount,
    "PugServers_Is_Anyone_Busy(excluding myself) returns false. \
Assuming that there are no live pug servers in this test case."
  );

  Assert(
    PugServers_Is_Anyone_Busy(true) == true, failCount,
    "PugServers_Is_Anyone_Busy(including myself) returns true. \
Assuming that there are no live pug servers in this test case."
  );
  PugServer_SetReserve_This(DB_PUG_INACTIVE);


  return DidWePass_SubTest(failCount);
}

bool Test_Matchmake_PugServer_Matchmake()
{
  PrintToServer("- Sub test: Test_Matchmake_PugServer_Matchmake...");
  int failCount;

  // Set up fake players whose match invitations to handle
  #define FAKE_PLAYERS 3
  decl String:steamID[FAKE_PLAYERS][MAX_STEAMID_LENGTH];
  bool AddPuggerPassed = true;
  bool SetPuggerStatePassed = true;
  for (int i = 0; i < sizeof(steamID); i++)
  {
    // Add players to table
    Format(steamID[i], sizeof(steamID[]), "STEAMID_%i", i);
    if (!Database_AddPugger(_, true, steamID[i]))
      AddPuggerPassed = false;
    // Set players state
    if (!Pugger_SetQueuingState(_, PUGGER_STATE_READY, true, steamID[i]))
      SetPuggerStatePassed = false;
  }

  Assert(AddPuggerPassed, failCount,
    "All Database_AddPugger() calls returned true."
  );

  Assert(SetPuggerStatePassed, failCount,
    "All Pugger_SetQueuingState() calls returned true."
  );

  Assert(PugServer_SetReserve_This(DB_PUG_RESERVED), failCount,
    "Reserving db with PugServer_SetReserve_This() returns true."
  );

  int acceptedPlayersOld = Puggers_GetCountPerState(PUGGER_STATE_ACCEPTED);
  Assert(
    AcceptPlayers(FAKE_PLAYERS), failCount,
    "Accepting invitees with AcceptPlayers() returns true."
  );

  Assert(
    CreateMatch(FAKE_PLAYERS), failCount,
    "Match creation with CreateMatch() returns true."
  );

  int acceptedPlayers = Puggers_GetCountPerState(PUGGER_STATE_ACCEPTED);
  Assert(
    acceptedPlayers == acceptedPlayersOld + FAKE_PLAYERS,
    failCount,
    "Amount of puggers with PUGGER_STATE_READY is %i, and equals \
the previous amount %i plus the amount of invitees from before %i.",
      acceptedPlayers, acceptedPlayersOld, FAKE_PLAYERS
  );

  bool removeLoopPassed = true;
  for (int i = 0; i < sizeof(steamID); i++)
  {
    if (!Database_RemovePugger(steamID[i]))
      removeLoopPassed = false;
  }

  Assert(
    removeLoopPassed, failCount,
    "All calls to Database_RemovePugger() returned true."
  );

  return DidWePass_SubTest(failCount);
}
