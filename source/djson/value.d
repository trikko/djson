/*
MIT License

Copyright (c) 2026 Andrea Fontana

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
*/

/++  Core data structures and API for djson.
     This module defines JValue, JObject, and JArray types. ++/
module djson.value;

import std.exception;
import std.format;
import std.conv;
import std.traits;
import std.string : split;
import std.array : Appender, appender;
import std.json : JSONValue, JSONType;
import djson.parser;

/++ Exception thrown on JSON parsing or traversal errors. ++/
class JSONException : Exception {
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure @safe {
        super(msg, file, line);
    }
}

/++ Exception thrown specifically when the JSON parser requires more data
    from an ongoing stream to complete the current operation. ++/
class JSONPartialException : JSONException {
    this(string msg = "Pending stream: value might be incomplete", string file = __FILE__, size_t line = __LINE__) pure @safe {
        super(msg, file, line);
    }
}

/++ Exception thrown specifically for syntax errors where the JSON format 
    is natively invalid or corrupted. ++/
class JSONSyntaxException : JSONException {
    this(string msg, string file = __FILE__, size_t line = __LINE__) pure @safe {
        super(msg, file, line);
    }
}

/++ Represents the type of a JSON value. ++/
enum JType {
    Unparsed, /++ Node has not been evaluated yet (lazy) ++/
    Null,     /++ JSON null ++/
    Bool,     /++ true or false ++/
    Number,   /++ Numeric value (stored as double) ++/
    String,   /++ String value ++/
    Object,   /++ JSON object (ordered mapping) ++/
    Array     /++ JSON array ++/
}

/++  Wrapper for a result that might not exist.
     Used by the `.safe!T()` methods to avoid throwing exceptions. ++/
struct SafeResult(T) {
    T value;   /++ The value if found, otherwise T.init ++/
    bool found; /++ True if the value was successfully found and cast to T ++/

    /++ Returns the value if found, otherwise returns the provided fallback. ++/
    T or(T fallback) pure const @safe {
        return found ? value : fallback;
    }

    alias getThis this;
    /++ Implicit conversion to T. ++/
    @property T getThis() pure const @safe {
        return found ? value : T.init;
    }
}

/++ Represents a JSON Object (ordered mapping of keys to values). ++/
struct JObject {
    /++ Internal representation of a key-value pair. ++/
    struct Pair {
        string key;
        JValue value;
    }
    Pair[] pairs;       /++ Storage for key-value pairs ++/
    string unparsedData; /++ Remaining unparsed string data (lazy) ++/
    bool isFullyParsed;  /++ True if all fields have been evaluated ++/

    /++ Cast to string (JSON representation) or std.json.JSONValue. ++/
    T opCast(T)() {
        static if (is(T == string)) {
            return JValue(this).toJSON();
        } else static if (is(T == JSONValue)) {
            return JValue(this).toStdJSON();
        } else {
            static assert(0, "Cannot cast JObject to " ~ T.stringof);
        }
    }

    /++ Enables `std.stdio.writeln` and string formatting. ++/
    string toString() {
        return JValue(this).toJSON();
    }
}

/++ Represents a JSON Array (ordered list of values). ++/
struct JArray {
    JValue[] elements;   /++ Storage for array elements ++/
    string unparsedData; /++ Remaining unparsed string data (lazy) ++/
    bool isFullyParsed;  /++ True if all elements have been evaluated ++/

    /++ Cast to string (JSON representation) or std.json.JSONValue. ++/
    T opCast(T)() {
        static if (is(T == string)) {
            return JValue(this).toJSON();
        } else static if (is(T == JSONValue)) {
            return JValue(this).toStdJSON();
        } else {
            static assert(0, "Cannot cast JArray to " ~ T.stringof);
        }
    }

    /++ Enables `std.stdio.writeln` and string formatting. ++/
    string toString() {
        return JValue(this).toJSON();
    }
}

/++  Represents a single JSON value.
     Uses a union to store different types efficiently and supports lazy evaluation. ++/
struct JValue {
    JType type = JType.Null; /++ Current type of the node ++/
    union {
        bool boolean;        /++ Value if type is JType.Bool ++/
        double number;       /++ Value if type is JType.Number ++/
        string str;          /++ Value if type is JType.String ++/
        JObject obj;         /++ Container if type is JType.Object ++/
        JArray arr;          /++ Container if type is JType.Array ++/
        struct UnparsedData {
            string raw;
        }
        UnparsedData unparsed; /++ Raw JSON string if type is JType.Unparsed ++/
    }

    /++ Construct a JSON null value. ++/
    this(typeof(null)) pure @safe { type = JType.Null; }
    /++ Construct a JSON boolean value. ++/
    this(bool b) pure @safe { type = JType.Bool; boolean = b; }
    /++ Construct a JSON numeric value. ++/
    this(double d) pure @safe { type = JType.Number; number = d; }
    /++ Construct a JSON numeric value from long. ++/
    this(long d) pure @safe { type = JType.Number; number = cast(double)d; }
    /++ Construct a JSON numeric value from int. ++/
    this(int d) pure @safe { type = JType.Number; number = cast(double)d; }
    /++ Construct a JSON string value. ++/
    this(string s) pure @safe { type = JType.String; str = s; }
    /++ Construct a JSON object. ++/
    this(JObject o) pure @safe { type = JType.Object; obj = o; }
    /++ Construct a JSON array. ++/
    this(JArray a) pure @safe { type = JType.Array; arr = a; }
    
    /++ Internal helper to create a lazy node that will be parsed on demand. ++/
    static JValue mkUnparsed(string s) pure @trusted {
        JValue v;
        v.type = JType.Unparsed;
        v.unparsed.raw = s;
        return v;
    }

    /++  Appends additional JSON data to handle partial stream parsing.
         This safely allows resuming parsing by updating all unresolved 
         lazy portions of the JSON tree with the provided string. ++/
    void appendData(string moreData) @trusted {
        if (type == JType.Unparsed) {
            unparsed.raw ~= moreData;
        } else if (type == JType.Object) {
            if (!obj.isFullyParsed) {
                obj.unparsedData ~= moreData;
            }
            foreach(ref p; obj.pairs) {
                p.value.appendData(moreData);
            }
        } else if (type == JType.Array) {
            if (!arr.isFullyParsed) {
                arr.unparsedData ~= moreData;
            }
            foreach(ref el; arr.elements) {
                el.appendData(moreData);
            }
        }
    }

    /++ Evaluates current node if it is currently in Unparsed (lazy) state. ++/
    void evaluateSelf() {
        if (type == JType.Unparsed) {
            djson.parser.evaluateNode(&this);
        }
    }

    /++ Returns true if this value represents JSON null. ++/
    @property bool isNull() {
        evaluateSelf();
        return type == JType.Null;
    }

    /++  Remove a key from a JSON object.
         Does nothing and returns false if the node is not an object or the key is not found.
         Returns true if the key was successfully removed. ++/
    bool remove(string key) {
        evaluateSelf();
        if (type != JType.Object) return false;
        while(!obj.isFullyParsed) djson.parser.parseNextPair(&this);
        
        foreach(i, ref p; obj.pairs) {
            if (p.key == key) {
                // Remove by reconstructing without the element
                obj.pairs = obj.pairs[0..i] ~ obj.pairs[i+1..$];
                return true;
            }
        }
        return false;
    }

    /++  Remove an element from a JSON array by its index.
         Does nothing and returns false if the node is not an array or the index is out of bounds.
         Returns true if the element was successfully removed. ++/
    bool remove(size_t index) {
        evaluateSelf();
        if (type != JType.Array) return false;
        while(!arr.isFullyParsed) djson.parser.parseNextElement(&this);
        
        if (index >= arr.elements.length) return false;
        arr.elements = arr.elements[0..index] ~ arr.elements[index+1..$];
        return true;
    }

    /++  Recursively evaluates all nested nodes.
         After this call, the entire structure is fully parsed and no longer lazy. ++/
    void parseAll() {
        if (type == JType.Unparsed) {
            // Eager one-pass parsing: avoids the lazy skip+re-parse double work
            string s = unparsed.raw;
            auto result = djson.parser.parseValueFull(s);
            this = result;
            return;
        }
        // Partially parsed nodes: finish lazy parsing
        if (type == JType.Object) {
            while(!obj.isFullyParsed) {
                djson.parser.parseNextPair(&this);
            }
            foreach(ref p; obj.pairs) {
                p.value.parseAll();
            }
        } else if (type == JType.Array) {
            while(!arr.isFullyParsed) {
                djson.parser.parseNextElement(&this);
            }
            foreach(ref el; arr.elements) {
                el.parseAll();
            }
        }
    }

    /++  Returns the number of elements in a JSON array or fields in a JSON object.
         Returns 0 for all other types. ++/
    @property size_t length() {
        evaluateSelf();
        if (type == JType.Array) {
            while(!arr.isFullyParsed) djson.parser.parseNextElement(&this);
            return arr.elements.length;
        } else if (type == JType.Object) {
            while(!obj.isFullyParsed) djson.parser.parseNextPair(&this);
            return obj.pairs.length;
        }
        return 0;
    }

    /++  Enables foreach iteration over array elements or object values.
         Example: `foreach(ref el; jsonArray) { ... }` ++/
    int opApply(scope int delegate(ref JValue) dg) {
        evaluateSelf();
        if (type == JType.Array) {
            while(!arr.isFullyParsed) djson.parser.parseNextElement(&this);
            foreach(ref el; arr.elements) {
                if (auto r = dg(el)) return r;
            }
        } else if (type == JType.Object) {
            while(!obj.isFullyParsed) djson.parser.parseNextPair(&this);
            foreach(ref p; obj.pairs) {
                if (auto r = dg(p.value)) return r;
            }
        }
        return 0;
    }

    /++  Enables foreach iteration over array elements with index.
         Example: `foreach(size_t i, ref el; jsonArray) { ... }` ++/
    int opApply(scope int delegate(size_t, ref JValue) dg) {
        evaluateSelf();
        if (type == JType.Array) {
            while(!arr.isFullyParsed) djson.parser.parseNextElement(&this);
            foreach(i, ref el; arr.elements) {
                if (auto r = dg(i, el)) return r;
            }
        } else if (type == JType.Object) {
            while(!obj.isFullyParsed) djson.parser.parseNextPair(&this);
            foreach(i, ref p; obj.pairs) {
                if (auto r = dg(i, p.value)) return r;
            }
        }
        return 0;
    }

    /++  Enables foreach iteration over object key-value pairs in insertion order.
         Example: `foreach(string key, ref val; jsonObject) { ... }` ++/
    int opApply(scope int delegate(string, ref JValue) dg) {
        evaluateSelf();
        if (type == JType.Object) {
            while(!obj.isFullyParsed) djson.parser.parseNextPair(&this);
            foreach(ref p; obj.pairs) {
                if (auto r = dg(p.key, p.value)) return r;
            }
        }
        return 0;
    }

    /++  Returns a pointer to a value in an object by its key.
         Returns null if not found or if the node is not an object. ++/
    JValue* getPtr(string key) {
        evaluateSelf();
        if (type != JType.Object) return null;
        
        foreach(ref p; obj.pairs) {
            if (p.key == key) return &p.value;
        }
        
        while(!obj.isFullyParsed) {
            if (djson.parser.parseNextPair(&this, key)) {
                if (obj.pairs[$-1].key == key) {
                    return &obj.pairs[$-1].value;
                }
            } else {
                break;
            }
        }
        return null;
    }

    /++  Returns a pointer to an element in an array by its index.
         Returns null if out of bounds or if the node is not an array. ++/
    JValue* getPtr(size_t index) {
        evaluateSelf();
        if (type != JType.Array) return null;
        if (index < arr.elements.length) return &arr.elements[index];
        
        while(!arr.isFullyParsed && arr.elements.length <= index) {
            djson.parser.parseNextElement(&this);
        }
        
        if (index < arr.elements.length) return &arr.elements[index];
        return null;
    }
    
    /++  Array-like access to array elements.
         Throws JSONException if index is out of bounds. ++/
    ref JValue opIndex(size_t index) {
        JValue* p = getPtr(index);
        if (!p) throw new JSONException(format("Array index %d out of bounds", index));
        return *p;
    }

    /++  Array-like access to object fields.
         Throws JSONException if key is not found. ++/
    ref JValue opIndex(string key) {
        JValue* p = getPtr(key);
        if (!p) throw new JSONException("Key not found: " ~ key);
        return *p;
    }

    /++  Mutation via operator [] for objects.
         Converts a Null node to an Object if necessary. ++/
    void opIndexAssign(T)(T value, string key) {
        evaluateSelf();
        if (type == JType.Null) {
            type = JType.Object;
            obj.isFullyParsed = true;
        } else if (type != JType.Object) {
            throw new JSONException("Cannot assign string key to non-object node");
        }
        
        while(!obj.isFullyParsed) {
            djson.parser.parseNextPair(&this);
        }
        
        foreach(ref p; obj.pairs) {
            if (p.key == key) {
                static if (is(T == JValue)) p.value = value;
                else p.value = JValue(value);
                return;
            }
        }
        static if (is(T == JValue)) obj.pairs ~= JObject.Pair(key, value);
        else obj.pairs ~= JObject.Pair(key, JValue(value));
    }

    /++  Mutation via operator [] for arrays.
         Converts a Null node to an Array if necessary. ++/
    void opIndexAssign(T)(T value, size_t index) {
        evaluateSelf();
        if (type == JType.Null) {
            type = JType.Array;
            arr.isFullyParsed = true;
        } else if (type != JType.Array) {
            throw new JSONException("Cannot assign index to non-array node");
        }
        
        while(!arr.isFullyParsed && arr.elements.length <= index) {
            djson.parser.parseNextElement(&this);
        }
        
        if (arr.elements.length <= index) {
            arr.elements.length = index + 1;
        }
        static if (is(T == JValue)) arr.elements[index] = value;
        else arr.elements[index] = JValue(value);
    }

    /++  Appends a value to a JSON array.
         If the node is Null, it becomes an Array with the value.
         If the node is already an Array, the value is added to it.
         If the node is a primitive or object, it is promoted to an Array containing [oldValue, newValue]. ++/
    void opOpAssign(string op, T)(T value) if (op == "~") {
        evaluateSelf();
        if (type == JType.Null) {
            type = JType.Array;
            arr.isFullyParsed = true;
            static if (is(T == JValue)) arr.elements = [value];
            else arr.elements = [JValue(value)];
        } else if (type == JType.Array) {
            while(!arr.isFullyParsed) djson.parser.parseNextElement(&this);
            static if (is(T == JValue)) arr.elements ~= value;
            else arr.elements ~= JValue(value);
        } else {
            // Promotion: primitive or object -> array
            JValue old = this;
            type = JType.Array;
            arr.isFullyParsed = true;
            static if (is(T == JValue)) arr.elements = [old, value];
            else arr.elements = [old, JValue(value)];
        }
    }

    private T as(T)() {
        evaluateSelf();
        static if (is(T == string)) {
            if (type != JType.String) throw new JSONException("Expected String, got " ~ type.to!string );
            return str;
        } else static if (is(T == bool)) {
            if (type != JType.Bool) throw new JSONException("Expected Bool, got " ~ type.to!string );
            return boolean;
        } else static if (is(T : double) || is(T : long)) {
            if (type != JType.Number) throw new JSONException("Expected Number got " ~ type.to!string );
            return cast(T)number;
        } else static if (is(T == JObject)) {
            if (type != JType.Object) throw new JSONException("Expected Object got " ~ type.to!string );
            while(!obj.isFullyParsed) djson.parser.parseNextPair(&this);
            return obj;
        } else static if (is(T == JArray)) {
            if (type != JType.Array) throw new JSONException("Expected Array got " ~ type.to!string );
            while(!arr.isFullyParsed) djson.parser.parseNextElement(&this);
            return arr;
        } else static if (is(T == JValue)) {
            return this;
        } else {
            static assert(0, "Unsupported type " ~ T.stringof);
        }
    }

    /++  Fluent access to nested values via variadic arguments or JSON pointer paths.
         Examples: `json.get!int("a", "b", 0)`, `json.get!string("/user/name")` ++/
    T get(T, Args...)(Args args) if (Args.length > 0) {
        static if (Args.length == 1 && is(Args[0] == string)) {
            string path = args[0];
            if (path.length > 0 && path[0] == '/') {
                return getByPath!T(path);
            }
        }
        
        JValue* current = &this;
        foreach(arg; args) {
            static if (is(typeof(arg) == string)) {
                current = current.getPtr(arg);
            } else static if (isIntegral!(typeof(arg))) {
                current = current.getPtr(cast(size_t)arg);
            } else {
                static assert(0, "Invalid argument type for get!T");
            }
            if (!current) throw new JSONException(format("Path segment '%s' not found", arg));
        }
        return current.as!T();
    }
    
    /++ Returns the current node cast to type T. ++/
    T get(T)() {
        return as!T();
    }

    private T getByPath(T)(string path) {
        if (path == "/" || path.length == 0) return as!T();
        string[] parts = path[1..$].split("/");
        JValue* current = &this;
        foreach(part; parts) {
            string key = decodePointerToken(part);
            current.evaluateSelf();
            if (current.type == JType.Object) {
                current = current.getPtr(key);
            } else if (current.type == JType.Array) {
                // Try to parse array index
                try {
                    size_t idx = to!size_t(key);
                    current = current.getPtr(idx);
                } catch (Exception) {
                    throw new JSONException("Expected numeric index for array, got '" ~ key ~ "'");
                }
            } else {
                throw new JSONException("Cannot traverse primitive value at " ~ key);
            }
            if (!current) throw new JSONException("Path not found: " ~ key);
        }
        return current.as!T();
    }

    /++ Safe version of `.get!T()` that returns a `SafeResult!T` instead of throwing. ++/
    SafeResult!T safe(T, Args...)(Args args) if (Args.length > 0) {
        try {
            return SafeResult!T(get!T(args), true);
        } catch (JSONPartialException e) {
            throw e;
        } catch (Exception e) {
            return SafeResult!T(T.init, false);
        }
    }
    
    /++ Safe version of `.get!T()` that returns a `SafeResult!T` instead of throwing. ++/
    SafeResult!T safe(T)() {
        try {
            return SafeResult!T(as!T(), true);
        } catch (JSONPartialException e) {
            throw e;
        } catch (Exception e) {
            return SafeResult!T(T.init, false);
        }
    }

    /++  Check if a specific key, index, or nested path exists.
         Examples: `json.has("user", "id")`, `json.has("/tags/0")`. ++/
    bool has(Args...)(Args args) if (Args.length > 0) {
        return safe!JValue(args).found;
    }


    /++  Traverse a JValue following a runtime array of JSONKeySegment (from djson.binding).
         Returns null if any segment is not found. Used internally by the binding system. ++/
    JValue* getPtrBySegments(S)(S[] segments) {
        JValue* current = &this;
        foreach (seg; segments) {
            if (!current) return null;
            current.evaluateSelf();
            if (seg.isIndex) {
                current = current.getPtr(seg.index);
            } else {
                if (current.type == JType.Array) {
                    try {
                        import std.conv : to;
                        size_t idx = to!size_t(seg.key);
                        current = current.getPtr(idx);
                    } catch (Exception) {
                        return null; // Not a valid index for an array
                    }
                } else {
                    current = current.getPtr(seg.key);
                }
            }
        }
        return current;
    }

    /++  Sets a value at a nested path using variadic keys/indices or a JSON pointer.
         Automatically creates (auto-vivifies) intermediate objects and arrays. ++/
    void set(T, Args...)(T value, Args args) if (Args.length > 0) {
        static if (Args.length == 1 && is(Args[0] == string)) {
            string path = args[0];
            if (path.length > 0 && path[0] == '/') {
                setByPath(value, path);
                return;
            }
        }
        
        JValue* current = &this;
        foreach(i, arg; args) {
            static if (i == Args.length - 1) {
                (*current)[arg] = value;
            } else {
                static if (is(typeof(arg) == string)) {
                    if (current.type == JType.Null) {
                        current.type = JType.Object;
                        current.obj.isFullyParsed = true;
                    }
                    if (current.type != JType.Object) throw new JSONException("Cannot traverse non-object node");
                    current.evaluateSelf();
                    while(!current.obj.isFullyParsed) djson.parser.parseNextPair(current);
                    
                    bool found = false;
                    foreach(ref p; current.obj.pairs) {
                        if (p.key == arg) { current = &p.value; found = true; break; }
                    }
                    if (!found) {
                        current.obj.pairs ~= JObject.Pair(arg, JValue(null));
                        current = &current.obj.pairs[$-1].value;
                    }
                } else static if (isIntegral!(typeof(arg))) {
                    if (current.type == JType.Null) {
                        current.type = JType.Array;
                        current.arr.isFullyParsed = true;
                    }
                    if (current.type != JType.Array) throw new JSONException("Cannot traverse non-array node");
                    current.evaluateSelf();
                    size_t idx = cast(size_t)arg;
                    while(!current.arr.isFullyParsed && current.arr.elements.length <= idx) djson.parser.parseNextElement(current);
                    if (current.arr.elements.length <= idx) current.arr.elements.length = idx + 1;
                    current = &current.arr.elements[idx];
                }
            }
        }
    }
    
    private void setByPath(T)(T value, string path) {
        if (path == "/" || path.length == 0) { 
            this = JValue(value); 
            return; 
        }
        string[] parts = path[1..$].split("/");
        
        JValue* current = &this;
        for(size_t i = 0; i < parts.length; i++) {
            string part = decodePointerToken(parts[i]);
            if (i == parts.length - 1) {
                if (current.type == JType.Array || current.type == JType.Null) {
                    try {
                        import std.conv : to;
                        size_t idx = to!size_t(part);
                        (*current)[idx] = value; // forces array if null
                        return;
                    } catch (Exception e) {}
                }
                (*current)[part] = value; // fallback to object string key
            } else {
                current.evaluateSelf();
                
                if (current.type == JType.Null) {
                    bool isNextNum = false;
                    try { import std.conv : to; to!size_t(decodePointerToken(parts[i+1])); isNextNum = true; } catch(Exception e) {}
                    if (isNextNum) {
                        current.type = JType.Array;
                        current.arr.isFullyParsed = true;
                    } else {
                        current.type = JType.Object;
                        current.obj.isFullyParsed = true;
                    }
                }
                
                if (current.type == JType.Object) {
                    while(!current.obj.isFullyParsed) djson.parser.parseNextPair(current);
                    bool found = false;
                    foreach(ref p; current.obj.pairs) {
                        if (p.key == part) { current = &p.value; found = true; break; }
                    }
                    if (!found) {
                        current.obj.pairs ~= JObject.Pair(part, JValue(null));
                        current = &current.obj.pairs[$-1].value;
                    }
                } else if (current.type == JType.Array) {
                    try {
                        size_t idx = to!size_t(part);
                        while(!current.arr.isFullyParsed && current.arr.elements.length <= idx) djson.parser.parseNextElement(current);
                        if (current.arr.elements.length <= idx) current.arr.elements.length = idx + 1;
                        current = &current.arr.elements[idx];
                    } catch (Exception e) {
                        throw new JSONException("Expected numeric index for array, got '" ~ part ~ "'");
                    }
                } else {
                    throw new JSONException("Cannot traverse primitive value at " ~ part);
                }
            }
        }
    }

    /++  Appends a value to a nested path using variadic keys/indices or a JSON pointer.
         Automatically creates intermediate structures and promotes non-array target nodes. ++/
    void append(T, Args...)(T value, Args args) if (Args.length > 0) {
        static if (Args.length == 1 && is(Args[0] == string)) {
            string path = args[0];
            if (path.length > 0 && path[0] == '/') {
                appendByPath(value, path);
                return;
            }
        }
        
        JValue* current = &this;
        foreach(i, arg; args) {
            if (i == Args.length - 1) {
                // For the last segment, we need to get the pointer to the target node
                // If it doesn't exist, we create a Null node which will be turned into an Array by ~=
                JValue* target = current.getPtrMutable(arg);
                if (!target) {
                    (*current)[arg] = JValue(null);
                    target = current.getPtrMutable(arg);
                }
                (*target) ~= value;
            } else {
                current = current.getPtrMutableOrCreate(arg);
            }
        }
    }

    private void appendByPath(T)(T value, string path) {
        if (path == "/" || path.length == 0) { 
            this ~= value;
            return; 
        }
        string[] parts = path[1..$].split("/");
        
        JValue* current = &this;
        for(size_t i = 0; i < parts.length; i++) {
            string part = decodePointerToken(parts[i]);
            if (i == parts.length - 1) {
                JValue* target = current.getPtrMutable(part);
                if (!target) {
                    // Try to see if it should be an array index or object key
                    bool isNum = false;
                    try { import std.conv : to; to!size_t(part); isNum = true; } catch(Exception e) {}
                    if (isNum) (*current)[to!size_t(part)] = JValue(null);
                    else (*current)[part] = JValue(null);
                    target = current.getPtrMutable(part);
                }
                (*target) ~= value;
            } else {
                current = current.getPtrMutableOrCreate(part);
            }
        }
    }

    // Helper to get a mutable pointer to a field/index, or null if not found
    private JValue* getPtrMutable(K)(K key) {
        evaluateSelf();
        static if (is(K == string)) {
            if (type != JType.Object) return null;
            foreach(ref p; obj.pairs) if (p.key == key) return &p.value;
            while(!obj.isFullyParsed) {
                if (djson.parser.parseNextPair(&this, key)) {
                    if (obj.pairs[$-1].key == key) return &obj.pairs[$-1].value;
                } else break;
            }
        } else {
            if (type != JType.Array) return null;
            size_t idx = cast(size_t)key;
            if (idx < arr.elements.length) return &arr.elements[idx];
            while(!arr.isFullyParsed && arr.elements.length <= idx) djson.parser.parseNextElement(&this);
            if (idx < arr.elements.length) return &arr.elements[idx];
        }
        return null;
    }

    // Helper to get a mutable pointer or create a structure if needed
    private JValue* getPtrMutableOrCreate(K)(K key) {
        evaluateSelf();
        static if (is(K == string)) {
            if (type == JType.Null) {
                type = JType.Object;
                obj.isFullyParsed = true;
            }
            if (type != JType.Object) throw new JSONException("Cannot traverse non-object node");
            JValue* p = getPtrMutable(key);
            if (p) return p;
            obj.pairs ~= JObject.Pair(key, JValue(null));
            return &obj.pairs[$-1].value;
        } else {
            if (type == JType.Null) {
                type = JType.Array;
                arr.isFullyParsed = true;
            }
            if (type != JType.Array) throw new JSONException("Cannot traverse non-array node");
            size_t idx = cast(size_t)key;
            JValue* p = getPtrMutable(idx);
            if (p) return p;
            if (arr.elements.length <= idx) arr.elements.length = idx + 1;
            return &arr.elements[idx];
        }
    }

    /++ Decodes a single JSON Pointer reference token per RFC 6901.
        Replaces `~1` with `/` and `~0` with `~` in a single pass.
        The order is significant: `~01` decodes to `~1`, not `/`. ++/
    package static string decodePointerToken(string token) pure @safe {
        // Fast path: no escapes present
        bool hasEscape = false;
        foreach(c; token) { if (c == '~') { hasEscape = true; break; } }
        if (!hasEscape) return token;

        import std.array : Appender, appender;
        auto app = appender!string();
        app.reserve(token.length);
        size_t i = 0;
        while (i < token.length) {
            if (token[i] == '~' && i + 1 < token.length) {
                if (token[i+1] == '1') { app.put('/'); i += 2; }
                else if (token[i+1] == '0') { app.put('~'); i += 2; }
                else { app.put(token[i]); i++; } // invalid escape: pass through
            } else {
                app.put(token[i]); i++;
            }
        }
        return app.data;
    }

    /++  Serializes the JSON structure into a string.
         Params:
           pretty = If true, generates formatted JSON with newlines and indentation.
           indentLevel = Initial indentation level (used internally). ++/
    string toJSON(bool pretty = false, uint indentLevel = 0) {
        parseAll();
        import std.array : Appender, appender;
        Appender!string app = appender!string();
        toJSONImpl(app, pretty, indentLevel);
        return app.data;
    }

    /++ Enables `std.stdio.writeln` and string formatting. ++/
    string toString() {
        return toJSON();
    }

    private void toJSONImpl(ref Appender!string app, bool pretty, uint indentLevel) {
        switch(type) {
            case JType.Null: app.put("null"); break;
            case JType.Bool: app.put(boolean ? "true" : "false"); break;
            case JType.Number:
                import std.format : formattedWrite;
                if (cast(long)number == number) {
                    formattedWrite(app, "%d", cast(long)number);
                } else {
                    formattedWrite(app, "%g", number);
                }
                break;
            case JType.String:
                app.put('"');
                writeEscaped(app, str);
                app.put('"');
                break;
            case JType.Object:
                app.put('{');
                if (pretty && obj.pairs.length > 0) app.put('\n');
                foreach(size_t i, ref p; obj.pairs) {
                    if (pretty) emitIndent(app, indentLevel + 1);
                    app.put('"');
                    writeEscaped(app, p.key);
                    app.put(pretty ? "\": " : "\":");
                    p.value.toJSONImpl(app, pretty, indentLevel + 1);
                    if (i < obj.pairs.length - 1) app.put(',');
                    if (pretty) app.put('\n');
                }
                if (pretty && obj.pairs.length > 0) emitIndent(app, indentLevel);
                app.put('}');
                break;
            case JType.Array:
                app.put('[');
                if (pretty && arr.elements.length > 0) app.put('\n');
                foreach(size_t i, ref el; arr.elements) {
                    if (pretty) emitIndent(app, indentLevel + 1);
                    el.toJSONImpl(app, pretty, indentLevel + 1);
                    if (i < arr.elements.length - 1) app.put(',');
                    if (pretty) app.put('\n');
                }
                if (pretty && arr.elements.length > 0) emitIndent(app, indentLevel);
                app.put(']');
                break;
            case JType.Unparsed:
                app.put(unparsed.raw);
                break;
            default: break;
        }
    }

    /++ Converts this `JValue` structure into a standard `std.json.JSONValue`. ++/
    JSONValue toStdJSON() {
        parseAll();
        JSONValue jv;
        switch(type) {
            case JType.Null: jv = JSONValue(null); break;
            case JType.Bool: jv = JSONValue(boolean); break;
            case JType.Number: 
                if (cast(long)number == number) jv = JSONValue(cast(long)number);
                else jv = JSONValue(number); 
                break;
            case JType.String: jv = JSONValue(str); break;
            case JType.Object:
                JSONValue[string] jobj;
                foreach(ref p; obj.pairs) {
                    jobj[p.key] = p.value.toStdJSON();
                }
                jv = JSONValue(jobj);
                break;
            case JType.Array:
                JSONValue[] jarr;
                foreach(ref el; arr.elements) {
                    jarr ~= el.toStdJSON();
                }
                jv = JSONValue(jarr);
                break;
            default: break;
        }
        return jv;
    }
}

private void writeEscaped(ref Appender!string app, string s) pure @safe {
    foreach(dchar c; s) {
        switch(c) {
            case '"': app.put("\\\""); break;
            case '\\': app.put("\\\\"); break;
            case '\b': app.put("\\b"); break;
            case '\f': app.put("\\f"); break;
            case '\n': app.put("\\n"); break;
            case '\r': app.put("\\r"); break;
            case '\t': app.put("\\t"); break;
            default:
                if (c < 0x20) {
                    import std.format : formattedWrite;
                    formattedWrite(app, "\\u%04X", cast(uint)c);
                } else {
                    app.put(c);
                }
        }
    }
}

private void emitIndent(ref Appender!string app, uint levels) pure @safe {
    for(uint i=0; i<levels; i++) app.put("    ");
}
