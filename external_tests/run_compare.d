#!/usr/bin/env dub
/+ dub.sdl:
    name "run_compare"
+/
import std.stdio;
import std.process;
import std.file;
import std.path;
import std.string;

void main() {
    writeln("\n=============================================");
    writeln("   Starting Value Comparison: djson vs std.json");
    writeln("=============================================");

    writeln("Compiling comparison runner...");
    auto buildResult = executeShell("dub build --single compare_std_json.d --combined --quiet");
    if (buildResult.status != 0) {
        writeln("Failed to build comparison runner: ", buildResult.output);
        return;
    }

    int matches = 0;
    int mismatches = 0;
    int stdFail = 0;
    int djsonFailedStdPassed = 0;
    int crashes = 0;

    auto files = dirEntries("JSONTestSuite/test_parsing", "*.json", SpanMode.shallow);
    foreach (f; files) {
        auto runResult = execute(["./compare_std_json", f.name]);
        int res = runResult.status;

        if (res == 0) {
            matches++;
        } else if (res == 1) {
            djsonFailedStdPassed++;
            writeln("\033[0;33m[STRICT]\033[0m djson correctly rejected but std.json accepted: ", f.name);
        } else if (res == 2) {
            mismatches++;
            writeln("\033[0;31m[MISMATCH]\033[0m Value mismatch on: ", f.name);
        } else if (res == 4) {
            stdFail++;
        } else {
            crashes++;
            writeln("\033[1;30m[CRASH]\033[0m Process crashed (Stack overflow limit) on: ", f.name);
        }
    }

    writeln("");
    writeln("=============================================");
    writeln("               FINAL SUMMARY");
    writeln("=============================================");
    writefln("Total Files Tested: \033[1;36m%d\033[0m", matches + mismatches + stdFail + djsonFailedStdPassed + crashes);
    writefln("Perfect Matches: \033[1;32m%d\033[0m (Extracted values match 100%%)", matches);
    writefln("Value Mismatches: \033[1;31m%d\033[0m", mismatches);
    writefln("Broken files strictly rejected by djson only: \033[1;33m%d\033[0m", djsonFailedStdPassed);
    writefln("Files bypassed because std.json failed to parse: \033[0;37m%d\033[0m", stdFail);
    writefln("Crashes (OS stack limits during extreme nesting): \033[1;30m%d\033[0m", crashes);
    writeln("=============================================");
    writeln("");
}
