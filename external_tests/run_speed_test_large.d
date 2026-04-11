#!/usr/bin/env dub
/+ dub.sdl:
    name "run_speed_test_large"
+/
import std.stdio;
import std.process;
import std.conv;
import std.string;

void main() {
    writeln("\n=============================================");
    writeln("   Large JSON Benchmark (Long Strings)");
    writeln("=============================================");

    auto runBench(string config) {
        writef("Running %-14s... ", config);
        stdout.flush();
        auto res = executeShell("dub run --single speed_test_large.d --compiler=ldc2 --combined --quiet --build=release --config=" ~ config);
        if (res.status != 0) {
            writeln("FAILED: ", res.output);
            return 0.0;
        }
        string output = res.output.strip();
        try {
            double time = output.to!double;
            writefln("%g ms", time);
            return time;
        } catch (Exception e) {
            writeln("FAILED to parse result: '", output, "'");
            return 0.0;
        }
    }

    double timeStd = runBench("stdjson");
    double timeDjson = runBench("djson");

    writeln("\n=============================================");
    if (timeStd > 0 && timeDjson > 0) {
        if (timeDjson < timeStd) {
            writefln("DJSON is \033[1;32m%.2fx FASTER\033[0m than std.json", timeStd / timeDjson);
        } else {
            writefln("std.json is \033[1;31m%.2fx FASTER\033[0m than djson", timeDjson / timeStd);
        }
    }
    writeln("=============================================");
    writeln("");
}
