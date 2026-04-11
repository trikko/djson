/+ dub.sdl:
    name "compare_std_json"
    targetType "executable"
    dependency "djson" path=".."
+/
import djson;

import std.json;
import std.file;
import std.stdio;
import std.string;
import std.math : isClose;
import core.stdc.stdlib : exit;

bool compareJSONValue(JSONValue a, JSONValue b) {
    if (a.type != b.type) {
        if ((a.type == JSONType.integer || a.type == JSONType.uinteger || a.type == JSONType.float_) &&
            (b.type == JSONType.integer || b.type == JSONType.uinteger || b.type == JSONType.float_)) {
            
            double numA = a.type == JSONType.float_ ? a.floating : (a.type == JSONType.integer ? a.integer : a.uinteger);
            double numB = b.type == JSONType.float_ ? b.floating : (b.type == JSONType.integer ? b.integer : b.uinteger);
            return numA == numB || isClose(numA, numB, 1e-9);
        }
        return false;
    }
    
    switch (a.type) {
        case JSONType.null_: return true;
        case JSONType.string: return a.str == b.str;
        case JSONType.integer: return a.integer == b.integer;
        case JSONType.uinteger: return a.uinteger == b.uinteger;
        case JSONType.float_: return a.floating == b.floating || isClose(a.floating, b.floating, 1e-9);
        case JSONType.true_: return true;
        case JSONType.false_: return true;
        case JSONType.object:
            auto objA = a.object;
            auto objB = b.object;
            if (objA.length != objB.length) return false;
            foreach (k, v; objA) {
                if (k !in objB) return false;
                if (!compareJSONValue(v, objB[k])) return false;
            }
            return true;
        case JSONType.array:
            auto arrA = a.array;
            auto arrB = b.array;
            if (arrA.length != arrB.length) return false;
            foreach (i; 0 .. arrA.length) {
                if (!compareJSONValue(arrA[i], arrB[i])) return false;
            }
            return true;
        default: return false;
    }
}

void main(string[] args) {
    if (args.length < 2) return;
    string file = args[1];
    string text = cast(string) std.file.read(file);
    
    JSONValue stdVal;
    try {
        stdVal = std.json.parseJSON(text);
    } catch (Exception e) {
        exit(4); // std.json fails
    }

    JValue dVal;
    try {
        dVal = djson.parseJSON(text);
        dVal.parseAll();
    } catch (Exception e) {
        writeln("djson failed on: ", file, " but std.json passed!");
        exit(1);
    }
    
    try {
        JSONValue converted = dVal.toStdJSON();
        if (!compareJSONValue(stdVal, converted)) {
            writeln("Mismatch on: ", file);
            writeln("  std.json: ", stdVal.toString());
            writeln("  djson   : ", converted.toString());
            exit(2);
        }
    } catch (Exception e) {
        writeln("Conversion error on: ", file);
        exit(3);
    }
}
