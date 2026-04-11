/+ dub.sdl:
    name "speed_test_large"
    dependency "djson" path=".."
    targetType "executable"
    configuration "stdjson" {
        versions "UseStdJson"
    }
    configuration "djson" {
    }
+/
import std.stdio;
import std.conv : to;
import std.file;
import std.datetime.stopwatch;
import std.json;
import core.memory;
import std.array;
import djson;

void main() {
    auto app = appender!string();
    app.put("[");
    for(int i=0; i<1000; i++) {
        if (i > 0) app.put(",");
        app.put(`{"id":`); app.put(i.to!string);
        app.put(`,"name":"`);
        for(int j=0; j<100; j++) app.put("Some very long text to skip... ");
        app.put(`"}`);
    }
    app.put("]");
    string text = app.data;
    
    version(UseStdJson) {
        // Warmup
        { auto j = std.json.parseJSON(text); }
        GC.collect(); GC.disable();
        auto sw = StopWatch(AutoStart.yes);
        foreach(i; 0..100) {
            auto j = std.json.parseJSON(text);
        }
        sw.stop();
        writeln(sw.peek().total!"msecs");
    } else {
        // Warmup
        { auto j = djson.parseJSONComplete(text); }
        GC.collect(); GC.disable();
        auto sw = StopWatch(AutoStart.yes);
        foreach(i; 0..100) {
            auto j = djson.parseJSONComplete(text);
        }
        sw.stop();
        writeln(sw.peek().total!"msecs");
    }
}
