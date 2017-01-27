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
  /*
  Test format:
    if (Test_Function()) { passed++; } else { failed++; }
    tests++;
  */

  // Tests start.
  if (Test_AlwaysPass()) { passed++; } else { failed++; }
  tests++;
  if (Test_Matchmake_DatabaseConnection()) { passed++; } else { failed++; }
  tests++;
  if (Test_Matchmake_DatabaseOperations()) { passed++; } else { failed++; }
  tests++;
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

  Assert(Database_Initialize(), failCount,
    "Database initialisation function returns true.");
  // Implied by successful Database_Initialize() in the above assertion
  Assert(g_hDB != null, failCount, "Global db handle is not null.");

  return DidWePass_SubTest(failCount);
}


bool Test_Matchmake_DatabaseOperations()
{
  PrintToServer("- Sub test: Test_Matchmake_DatabaseConnection...");
  int failCount;

  const int state_initial = -1;
  int state = state_initial;
  new const String:steamID[] = "STEAMID_TEST:0:123";

  Assert(
    Database_AddPugger(_, true, steamID),
    failCount,
    "Adding SteamID to pugger db by string returns true."
  );

  Assert(
    state == state_initial,
    failCount,
    "The variable \"state\" has been initialised with the correct value %i.",
    state_initial
  );

  state = Pugger_GetQueuingState(_, _, _, true, steamID);

  Assert(
    state != state_initial,
    failCount,
    "The retrieved pugger state has been stored in the variable \
initialised with a value that is an invalid pugger state enum."
  );

  Assert(
    state != PUGGER_STATE_LIVE,
    failCount,
    "The state variable doesn't already contain the PUGGER_STATE_LIVE enum."
  );

  Assert(
    Pugger_SetQueuingState(_, PUGGER_STATE_LIVE, true, steamID),
    failCount,
    "Setting the pugger's queuing state to PUGGER_STATE_LIVE by SteamID \
returns true."
  );

  Assert(
    Pugger_GetQueuingState(_, _, _, true, steamID) == PUGGER_STATE_LIVE,
    failCount,
    "The pugger's state has been changed to PUGGER_STATE_LIVE \
according to the previous assertion.");

  return DidWePass_SubTest(failCount);
}
