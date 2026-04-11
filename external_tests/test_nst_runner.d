/+ dub.sdl:
    name "test_nst_runner"
    targetType "executable"
    dependency "djson" path=".."
+/
import djson;

import djson.parser : skipValue, stripJSONWhitespace;
import std.file;
import std.stdio;
import std.string;
import core.stdc.stdlib : exit;

void main(string[] args) {
    if (args.length < 2) return;
    try {
        string text = cast(string) std.file.read(args[1]);
        auto val = parseJSON(text);
        val.parseAll();
        val.toJSON(); 

        // Also check for trailing garbage strictly
        string s = text;
        skipValue(s);
        s = stripJSONWhitespace(s);
        if (s.length > 0) {
            throw new Exception("Trailing garbage detected");
        }
    } catch (Throwable e) {
        exit(1);
    }
}
