#!/usr/bin/env dub
/+ dub.sdl:
    name "run_real_bench"
+/
import std.stdio;
import std.process;
import std.conv;
import std.string;

import std.file;
import std.path;

void main() {
    writeln("\n=============================================");
    writeln("   Real-World Benchmarks (NativeJSON Data)");
    writeln("=============================================");

    // Ensure benchmark data is present
    string dataDir = "bench_data";
    if (!exists(dataDir)) mkdirRecurse(dataDir);

    string[string] files = [
        "canada.json": "https://raw.githubusercontent.com/miloyip/nativejson-benchmark/master/data/canada.json",
        "citm_catalog.json": "https://raw.githubusercontent.com/miloyip/nativejson-benchmark/master/data/citm_catalog.json",
        "twitter.json": "https://raw.githubusercontent.com/miloyip/nativejson-benchmark/master/data/twitter.json"
    ];

    foreach (name, url; files) {
        string path = buildPath(dataDir, name);
        if (!exists(path)) {
            writef("Downloading %s... ", name);
            stdout.flush();
            auto dl = executeShell("curl -L " ~ url ~ " -o " ~ path);
            if (dl.status != 0) {
                writeln("FAILED");
                stderr.writeln(dl.output);
                return;
            }
            writeln("Done");
        }
    }

    auto runBench(string config) {
        writef("Running %-14s... ", config);
        stdout.flush();
        // Use ldc2 for production-grade representative results
        auto res = executeShell("dub run --single real_benchmark.d --compiler=ldc2 --combined --quiet --build=release --config=" ~ config);
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
