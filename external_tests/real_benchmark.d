/+ dub.sdl:
    name "real_benchmark"
    targetType "executable"
    dependency "djson" path=".."
    configuration "stdjson" {
        versions "UseStdJson"
    }
    configuration "djson" {
    }
+/
import std.stdio;
import std.file;
import std.datetime.stopwatch;
import std.json;
import core.memory;
version(UseStdJson) {} else { import djson; }

void main() {
    string[] files = ["bench_data/canada.json", "bench_data/citm_catalog.json", "bench_data/twitter.json"];
    string[] contents;
    foreach(f; files) {
        if (!exists(f)) {
            stderr.writeln("Missing benchmark file: ", f);
            return;
        }
        contents ~= cast(string) read(f);
    }
    
    // Warmup passes
    foreach(text; contents) {
        version(UseStdJson) {
            try { auto j = std.json.parseJSON(text); } catch(Exception e) {}
        } else {
            try { auto j = djson.parseJSON(text); j.parseAll(); } catch(Exception e) {}
        }
    }
    
    GC.collect();
    GC.disable();
    auto sw = StopWatch(AutoStart.yes);
    
    int iterations = 100;
    foreach(i; 0..iterations) {
        foreach(text; contents) {
            version(UseStdJson) {
                try {
                    auto j = std.json.parseJSON(text);
                } catch(Exception e) {}
            } else {
                try {
                    auto j = djson.parseJSONComplete(text);
                } catch(Exception e) {}
            }
        }
    }
    sw.stop();
    writeln(sw.peek().total!"msecs");
}
