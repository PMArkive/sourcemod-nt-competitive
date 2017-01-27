#if !defined TESTS_INCLUDED_MATCHMAKE || defined _tests_matchmake_included_
  #endinput
#endif
#define _tests_matchmake_included_

public Action Command_RunTest_Matchmake(int client, int args)
{
  Test_Matchmake_Main();
  return Plugin_Handled;
}

bool Assert(bool assertion, const char[] description, int &fails)
{
  if (assertion == false)
  {
    fails++;
    PrintToServer("-- %s : failed! <---", description);
    return false;
  }
  PrintToServer("-- %s : passed.", description);
  return true;
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
  if (Test_Matchmake_InitialiseMatch()) { passed++; } else { failed++; }
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

bool Test_Matchmake_InitialiseMatch()
{
  PrintToServer("- Sub test: Test_Matchmake_InitialiseMatch...");
  int failCount;

  Assert(Database_Initialize(), "Database initialisation function returns true.", failCount);
  // Implied by successful Database_Initialize() in the above assertion
  Assert(g_hDB != null,         "Global db handle is not null.", failCount);

  if (failCount == 0)
  {
    PrintToServer("- Sub test passed.\n");
    return true;
  }
  PrintToServer("- Sub test failed %i times!", failCount);
  return false;
}

bool Test_AlwaysPass()
{
  PrintToServer("- Sub test: Test_AlwaysPass...");
  int failCount;

  Assert(1 == 1, "One equals one.", failCount);
  Assert(true, "True.", failCount);

  if (failCount == 0)
  {
    PrintToServer("- Sub test passed.\n");
    return true;
  }
  PrintToServer("- Sub test failed %i times!", failCount);
  return false;
}
