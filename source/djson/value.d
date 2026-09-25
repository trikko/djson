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
import std.array : Appender, appender, join;
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
    bool hasPendingTail; /++ True if the last pair is registered but its value is still incomplete ++/

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
    bool hasPendingTail; /++ True if the last element is registered but still incomplete ++/

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
        struct PrimitiveData {
            ubyte[string.sizeof] valueSpace; // overlaps boolean/number/str
            string tail;
        }
        PrimitiveData primitive; /++ Raw data following a parsed primitive (see trailingData) ++/
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
    
    /++ Turns this node into an empty, fully parsed object (clearing any stale union data). ++/
    package void becomeObject() pure @trusted {
        type = JType.Object;
        obj = JObject.init;
        obj.isFullyParsed = true;
    }

    /++ Turns this node into an empty, fully parsed array (clearing any stale union data). ++/
    package void becomeArray() pure @trusted {
        type = JType.Array;
        arr = JArray.init;
        arr.isFullyParsed = true;
    }

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
        // At root level, data arriving after a completed value is kept as trailing data
        if (type == JType.Object && obj.isFullyParsed) obj.unparsedData ~= moreData;
        else if (type == JType.Array && arr.isFullyParsed) arr.unparsedData ~= moreData;
        else if (type == JType.String || type == JType.Number || type == JType.Bool || type == JType.Null) primitive.tail ~= moreData;
        appendDataImpl(moreData);
    }

    private void appendDataImpl(string moreData) @trusted {
        // Only the still-open part of the tree needs the new data: completed
        // children never read past their own end, so they are left alone.
        if (type == JType.Unparsed) {
            unparsed.raw ~= moreData;
        } else if (type == JType.Object) {
            if (obj.isFullyParsed) return;
            obj.unparsedData ~= moreData;
            if (obj.hasPendingTail) obj.pairs[$-1].value.appendDataImpl(moreData);
        } else if (type == JType.Array) {
            if (arr.isFullyParsed) return;
            arr.unparsedData ~= moreData;
            if (arr.hasPendingTail) arr.elements[$-1].appendDataImpl(moreData);
        }
    }

    /++  Returns the non-whitespace data following the end of the document (empty if none).
         Call it on the root value. Throws JSONPartialException if the document is not complete yet. ++/
    string trailingData() @trusted {
        evaluateSelf();
        if (type == JType.Object) {
            while(!obj.isFullyParsed) djson.parser.parseNextPair(&this);
            return stripJSONWhitespace(obj.unparsedData);
        } else if (type == JType.Array) {
            while(!arr.isFullyParsed) djson.parser.parseNextElement(&this);
            return stripJSONWhitespace(arr.unparsedData);
        }
        return stripJSONWhitespace(primitive.tail);
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

    /++ Returns true if this value represents JSON string. ++/
    @property bool isString() {
        evaluateSelf();
        return type == JType.String;
    }

    /++ Returns true if this value represents JSON number. ++/
    @property bool isNumber() {
        evaluateSelf();
        return type == JType.Number;
    }

    /++ Returns true if this value represents JSON bool. ++/
    @property bool isBool() {
        evaluateSelf();
        return type == JType.Bool;
    }

    /++ Returns true if this value represents JSON object. ++/
    @property bool isObject() {
        evaluateSelf();
        return type == JType.Object;
    }

    /++ Returns true if this value represents JSON array. ++/
    @property bool isArray() {
        evaluateSelf();
        return type == JType.Array;
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
            // Keep what follows the value, so trailingData() still works on the root
            if (result.type == JType.Object) result.obj.unparsedData = s;
            else if (result.type == JType.Array) result.arr.unparsedData = s;
            else result.primitive.tail = s;
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
        
        try {
            while(!obj.isFullyParsed) {
                if (djson.parser.parseNextPair(&this)) {
                    if (obj.pairs[$-1].key == key) {
                        return &obj.pairs[$-1].value;
                    }
                } else {
                    break;
                }
            }
        } catch (JSONPartialException e) {
            throw new JSONPartialException("Incomplete JSON: key '" ~ key ~ "' not yet available");
        }
        return null;
    }

    /++  Returns a pointer to an element in an array by its index.
         Returns null if out of bounds or if the node is not an array. ++/
    JValue* getPtr(size_t index) {
        evaluateSelf();
        if (type != JType.Array) return null;
        if (index < arr.elements.length) return &arr.elements[index];
        
        try {
            while(!arr.isFullyParsed && arr.elements.length <= index) {
                djson.parser.parseNextElement(&this);
            }
        } catch (JSONPartialException e) {
            import std.conv : to;
            throw new JSONPartialException("Incomplete JSON: index " ~ index.to!string ~ " not yet available");
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
            becomeObject();
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
            becomeArray();
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
            becomeArray();
            static if (is(T == JValue)) arr.elements = [value];
            else arr.elements = [JValue(value)];
        } else if (type == JType.Array) {
            while(!arr.isFullyParsed) djson.parser.parseNextElement(&this);
            static if (is(T == JValue)) arr.elements ~= value;
            else arr.elements ~= JValue(value);
        } else {
            // Promotion: primitive or object -> array
            JValue old = this;
            becomeArray();
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
        foreach(i, arg; args) {
            static assert(is(typeof(arg) == string) || isIntegral!(typeof(arg)), "Invalid argument type for get!T");
            current = resolvePathSegment(current, arg, argsPath(args[0 .. i + 1]));
        }
        return valueAtPath!T(current, argsPath(args));
    }
    
    /++ Returns the current node cast to type T. ++/
    T get(T)() {
        return as!T();
    }

    private T getByPath(T)(string path) {
        if (path == "/" || path.length == 0) return as!T();
        import std.algorithm : splitter;
        JValue* current = &this;
        size_t end = 1;
        foreach(part; path[1..$].splitter('/')) {
            end += part.length;
            current = resolvePathSegment(current, decodePointerToken(part), pointerPath(path[1 .. end].split("/")));
            end++; // skip '/'
        }
        return valueAtPath!T(current, pointerPath(path[1..$].split("/")));
    }

    /++  Resolves one segment of a read path, or returns null if it does not exist or cannot be traversed.
         Throws only JSONPartialException, when the data needed is not available yet. ++/
    private static JValue* stepPath(K)(JValue* current, K seg) {
        current.evaluateSelf();
        if (current.type == JType.Object) {
            static if (is(K == string)) return current.getPtr(seg);
            else return null;
        } else if (current.type == JType.Array) {
            static if (is(K == string)) {
                size_t idx;
                if (!parseIndex(seg, idx)) return null;
                return current.getPtr(idx);
            } else {
                return current.getPtr(cast(size_t)seg);
            }
        }
        return null;
    }

    /++  Resolves one segment of a read path. `where` is the full path up to `seg`, used only
         in error messages. Never returns null. ++/
    private static JValue* resolvePathSegment(K)(JValue* current, K seg, lazy string where) {
        JValue* next;
        try {
            next = stepPath(current, seg);
        } catch (JSONPartialException e) {
            throw new JSONPartialException("Incomplete JSON: " ~ where ~ " not yet available");
        }
        if (next) return next;
        if (current.type != JType.Object && current.type != JType.Array)
            throw new JSONException("Cannot traverse primitive value: " ~ where);
        static if (is(K == string)) {
            size_t idx;
            if (current.type == JType.Array && !parseIndex(seg, idx))
                throw new JSONException("Expected numeric index for array: " ~ where);
        }
        throw new JSONException("Path not found: " ~ where);
    }

    /++ Converts the value reached by a read path, reporting the path if it is still truncated. ++/
    private static T valueAtPath(T)(JValue* current, lazy string where) {
        try {
            return current.as!T();
        } catch (JSONPartialException e) {
            throw new JSONPartialException("Incomplete JSON: value at " ~ where ~ " is truncated");
        }
    }

    /++  Resolves a read path (variadic or JSON pointer) without throwing when it does not exist.
         Returns null if the path is missing; throws JSONPartialException if data is not available yet. ++/
    private JValue* findPath(Args...)(Args args) {
        static if (Args.length == 1 && is(Args[0] == string)) {
            string path = args[0];
            if (path.length > 0 && path[0] == '/') {
                if (path == "/") return &this;
                import std.algorithm : splitter;
                JValue* current = &this;
                foreach(part; path[1..$].splitter('/')) {
                    current = stepPath(current, decodePointerToken(part));
                    if (!current) return null;
                }
                return current;
            }
        }
        JValue* current = &this;
        foreach(arg; args) {
            current = stepPath(current, arg);
            if (!current) return null;
        }
        return current;
    }

    /++ True if the node (once evaluated) holds a value that `as!T` can return. ++/
    private bool hasType(T)() {
        evaluateSelf();
        static if (is(T == string)) return type == JType.String;
        else static if (is(T == bool)) return type == JType.Bool;
        else static if (is(T : double) || is(T : long)) return type == JType.Number;
        else static if (is(T == JObject)) return type == JType.Object;
        else static if (is(T == JArray)) return type == JType.Array;
        else return true;
    }

    /++ Safe version of `.get!T()` that returns a `SafeResult!T` instead of throwing. ++/
    SafeResult!T safe(T, Args...)(Args args) if (Args.length > 0) {
        try {
            JValue* p;
            try {
                p = findPath(args);
            } catch (JSONPartialException e) {
                // Rare: let get!T report which part of the path is not available yet
                return SafeResult!T(get!T(args), true);
            }
            if (!p || !p.hasType!T) return SafeResult!T(T.init, false);
            return SafeResult!T(valueAtPath!T(p, pathString(args)), true);
        } catch (JSONPartialException e) {
            throw e;
        } catch (Exception e) {
            return SafeResult!T(T.init, false);
        }
    }
    
    /++ Safe version of `.get!T()` that returns a `SafeResult!T` instead of throwing. ++/
    SafeResult!T safe(T)() {
        try {
            if (!hasType!T) return SafeResult!T(T.init, false);
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

    /++ Human-readable path used in error messages, e.g. `'users' » '0' » 'name'`. ++/
    private static string argsPath(Args...)(Args args) {
        string[] parts;
        foreach(arg; args) parts ~= format("'%s'", arg);
        return parts.join(" » ");
    }

    /++ Same as `argsPath`, for the raw (still encoded) tokens of a JSON pointer. ++/
    private static string pointerPath(string[] tokens) {
        string[] parts;
        foreach(t; tokens) parts ~= "'" ~ decodePointerToken(t) ~ "'";
        return parts.join(" » ");
    }

    /++ Error-message path for either a JSON pointer or variadic arguments. ++/
    private static string pathString(Args...)(Args args) {
        static if (Args.length == 1 && is(Args[0] == string)) {
            if (args[0].length > 0 && args[0][0] == '/') return pointerPath(args[0][1..$].split("/"));
        }
        return argsPath(args);
    }

    /++ Parses an array index from a path token, returning false if it is not a valid number. ++/
    private static bool parseIndex(string s, out size_t idx) {
        if (s.length == 0) return false;
        foreach(c; s) if (c < '0' || c > '9') return false;
        try { idx = to!size_t(s); } catch (Exception) { return false; }
        return true;
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
                    size_t idx;
                    try {
                        import std.conv : to;
                        idx = to!size_t(seg.key);
                    } catch (Exception) {
                        return null; // Not a valid index for an array
                    }
                    current = current.getPtr(idx);
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
                current.evaluateSelf();
                if (current.type != JType.Object && current.type != JType.Array && current.type != JType.Null)
                    throw new JSONException("Cannot traverse primitive value: " ~ argsPath(args[0 .. i + 1]));
                static if (is(typeof(arg) == string)) {
                    if (current.type == JType.Null) {
                        current.becomeObject();
                    }
                    if (current.type != JType.Object) throw new JSONException("Cannot traverse non-object node: " ~ argsPath(args[0 .. i + 1]));
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
                        current.becomeArray();
                    }
                    if (current.type != JType.Array) throw new JSONException("Cannot traverse non-array node: " ~ argsPath(args[0 .. i + 1]));
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
                    bool isNum = false;
                    size_t idx;
                    try {
                        import std.conv : to;
                        idx = to!size_t(part);
                        isNum = true;
                    } catch (Exception e) {}
                    if (isNum) {
                        (*current)[idx] = value; // forces array if null
                        return;
                    }
                }
                (*current)[part] = value; // fallback to object string key
            } else {
                current.evaluateSelf();
                
                if (current.type == JType.Null) {
                    bool isNextNum = false;
                    try { import std.conv : to; to!size_t(decodePointerToken(parts[i+1])); isNextNum = true; } catch(Exception e) {}
                    if (isNextNum) {
                        current.becomeArray();
                    } else {
                        current.becomeObject();
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
                    size_t idx;
                    try {
                        idx = to!size_t(part);
                    } catch (Exception e) {
                        throw new JSONException("Expected numeric index for array: " ~ pointerPath(parts[0 .. i + 1]));
                    }
                    while(!current.arr.isFullyParsed && current.arr.elements.length <= idx) djson.parser.parseNextElement(current);
                    if (current.arr.elements.length <= idx) current.arr.elements.length = idx + 1;
                    current = &current.arr.elements[idx];
                } else {
                    throw new JSONException("Cannot traverse primitive value: " ~ pointerPath(parts[0 .. i + 1]));
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
            bool isLast = (i == parts.length - 1);

            bool isNum = false;
            size_t idx;
            try { idx = to!size_t(part); isNum = true; } catch(Exception e) {}

            current.evaluateSelf();
            if (current.type == JType.Array) {
                if (!isNum) throw new JSONException("Expected numeric index for array: " ~ pointerPath(parts[0 .. i + 1]));
                current = current.getPtrMutableOrCreate(idx);
            } else if (current.type == JType.Null && isLast && isNum) {
                current = current.getPtrMutableOrCreate(idx); // a numeric last segment creates an array
            } else if (current.type == JType.Object || current.type == JType.Null) {
                current = current.getPtrMutableOrCreate(part);
            } else {
                throw new JSONException("Cannot traverse primitive value: " ~ pointerPath(parts[0 .. i + 1]));
            }
        }
        (*current) ~= value;
    }

    // Helper to get a mutable pointer to a field/index, or null if not found
    private JValue* getPtrMutable(K)(K key) {
        evaluateSelf();
        static if (is(K == string)) {
            if (type != JType.Object) return null;
            foreach(ref p; obj.pairs) if (p.key == key) return &p.value;
            while(!obj.isFullyParsed) {
                if (djson.parser.parseNextPair(&this)) {
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
                becomeObject();
            }
            if (type != JType.Object) throw new JSONException("Cannot traverse non-object node");
            JValue* p = getPtrMutable(key);
            if (p) return p;
            obj.pairs ~= JObject.Pair(key, JValue(null));
            return &obj.pairs[$-1].value;
        } else {
            if (type == JType.Null) {
                becomeArray();
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
            case JType.Number: writeNumber(app, number); break;
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
                if (fitsInLong(number)) jv = JSONValue(cast(long)number);
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
    // Only ASCII characters need escaping: copy everything else in runs, without decoding UTF-8
    size_t start = 0;
    foreach(i, char c; s) {
        string esc;
        switch(c) {
            case '"': esc = "\\\""; break;
            case '\\': esc = "\\\\"; break;
            case '\b': esc = "\\b"; break;
            case '\f': esc = "\\f"; break;
            case '\n': esc = "\\n"; break;
            case '\r': esc = "\\r"; break;
            case '\t': esc = "\\t"; break;
            default:
                if (c >= 0x20) continue;
        }
        app.put(s[start .. i]);
        if (esc) {
            app.put(esc);
        } else {
            import std.format : formattedWrite;
            formattedWrite(app, "\\u%04X", cast(uint)c);
        }
        start = i + 1;
    }
    app.put(s[start .. $]);
}

/++ True if `d` holds an integer that fits in a long. ++/
private bool fitsInLong(double d) pure nothrow @nogc @safe {
    return d >= -9.2e18 && d <= 9.2e18 && cast(long)d == d;
}

/++ Writes a number using the shortest of %.15g / %.17g that round-trips exactly.
    NaN and infinity have no JSON representation and are written as null. ++/
private void writeNumber(ref Appender!string app, double d) @safe {
    import std.format : formattedWrite, sformat;
    import std.math : isNaN, isInfinity;
    if (d.isNaN || d.isInfinity) {
        app.put("null");
    } else if (fitsInLong(d)) {
        formattedWrite(app, "%d", cast(long)d);
    } else {
        char[32] buf;
        auto str = sformat(buf[], "%.15g", d);
        if (to!double(str) != d) str = sformat(buf[], "%.17g", d);
        app.put(str);
    }
}

private void emitIndent(ref Appender!string app, uint levels) pure @safe {
    for(uint i=0; i<levels; i++) app.put("    ");
}
