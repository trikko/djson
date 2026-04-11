import std.stdio;
import djson;
import djson.value;

void main() {
    auto j = parseJSON(`{"hello": "world", "partial" :`);
    
    writeln(j.safe!string("hello").value);
    
    bool failed = false;
    try {
        string p = j.get!string("partial");
        writeln(p);
    } catch(JSONException e) {
        failed = true;
    }
    writeln("Failed as expected: ", failed);
    
    j.appendData(`"world"}`);
    
    writeln(j.get!string("hello"));
    writeln(j.get!string("partial"));
}
