/+ dub.sdl:
    name "real_benchmark_detail"
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
import std.path;
import core.memory;
version(UseStdJson) {} else { import djson; }

void main() {
    string[] files = ["bench_data/canada.json", "bench_data/citm_catalog.json", "bench_data/twitter.json"];
    
    foreach(f; files) {
        if (!exists(f)) {
            stderr.writeln("Missing: ", f);
            continue;
        }
        string text = cast(string) read(f);
        
        // Warmup
        version(UseStdJson) {
            try { auto j = std.json.parseJSON(text); } catch(Exception e) {}
        } else {
            try { auto j = djson.parseJSON(text); j.parseAll(); } catch(Exception e) {}
        }
        
        GC.collect();
        GC.disable();
        auto sw = StopWatch(AutoStart.yes);
        
        foreach(i; 0..100) {
            version(UseStdJson) {
                try { auto j = std.json.parseJSON(text); } catch(Exception e) {}
            } else {
                try { auto j = djson.parseJSON(text); j.parseAll(); } catch(Exception e) {}
            }
        }
        sw.stop();
        GC.enable();
        
        writefln("%s\t%d", baseName(f), sw.peek().total!"msecs");
    }
}
