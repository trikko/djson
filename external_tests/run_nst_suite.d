#!/usr/bin/env dub
/+ dub.sdl:
    name "run_nst_suite"
+/
import std.stdio;
import std.process;
import std.file;
import std.path;
import std.string;

void main() {
    if (!exists("JSONTestSuite")) {
        writeln("Cloning JSONTestSuite...");
        executeShell("git clone https://github.com/nst/JSONTestSuite.git");
    }

    writeln("Compiling test runner...");
    // Pre-build once to speed up loop
    auto buildResult = executeShell("dub build --single test_nst_runner.d --combined --quiet");
    if (buildResult.status != 0) {
        writeln("Failed to build test runner: ", buildResult.output);
        return;
    }

    int passed = 0;
    int failed = 0;
    int iAccepted = 0;
    int iRejected = 0;

    writeln("Running tests...");
    auto files = dirEntries("JSONTestSuite/test_parsing", "*.json", SpanMode.shallow);
    foreach (f; files) {
        string base = baseName(f.name);
        char prefix = base[0];

        // Use the built executable directly for speed
        auto runResult = execute(["./test_nst_runner", f.name]);
        int res = runResult.status;

        if (prefix == 'y') {
            if (res == 0) passed++;
            else {
                writeln("FAILED (Expected Pass): ", f.name);
                failed++;
            }
        } else if (prefix == 'n') {
            if (res != 0) passed++;
            else {
                writeln("FAILED (Expected Fail - Accepted erroneously): ", f.name);
                failed++;
            }
        } else if (prefix == 'i') {
            if (res == 0) iAccepted++;
            else iRejected++;
        }
    }

    writeln("-----------------");
    writeln("Strict Compliant Passed: ", passed);
    writeln("Failed: ", failed);
    writeln("Implementation Accepted: ", iAccepted);
    writeln("Implementation Rejected: ", iRejected);

    if (failed > 0) {
        import core.stdc.stdlib : exit;
        exit(1);
    }
}
