/+ dub.sdl:
    name "benchmark"
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
    // We benchmark on valid files (y_) to ensure reliable workload
    // and avoid edge-case files that cause Segment Faults (Stack Overflows).
    auto files = dirEntries("JSONTestSuite/test_parsing", "y_*.json", SpanMode.shallow);
    string[] contents;
    foreach(f; files) {
        contents ~= cast(string) read(f.name);
    }
    
    // Warmup passes
    foreach(text; contents) {
        version(UseStdJson) {
            try { auto j = std.json.parseJSON(text); } catch(Exception e) {}
        } else {
            try { auto j = djson.parseJSONComplete(text); } catch(Exception e) {}
        }
    }
    
    GC.collect();
    GC.disable();
    auto sw = StopWatch(AutoStart.yes);
    
    int iterations = 1000;
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
