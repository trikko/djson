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

/++  Binding system for djson.
     Provides UDAs and methods to convert between D types and JValue. ++/
module djson.binding;

import djson.value;
import std.traits;
import std.conv;
import std.string;
import std.meta : AliasSeq;
import std.range : isInputRange;
import std.json : JSONValue;

// Implementation of the `@JSON` and `@JSONOptional` UDAs
package struct JSONImpl(bool _optional = false) {
    JSONKeySegment[] segments;
    enum isOptional = _optional;

    // Support marker usage
    this(typeof(null)) pure @safe {}

    this(Args...)(Args args) pure @safe {
        static if (Args.length == 1 && is(Args[0] == string)) {
            string s = args[0];
            if (s.length > 1 && s[0] == '/') {
                // JSON Pointer: split and decode tokens
                import djson.value : JValue;
                import std.string : split;
                foreach (part; s[1..$].split("/"))
                    segments ~= JSONKeySegment(JValue.decodePointerToken(part));
                return;
            }
        }
        foreach (arg; args) {
            static if (is(typeof(arg) == string))
                segments ~= JSONKeySegment(arg);
            else static if (isIntegral!(typeof(arg)))
                segments ~= JSONKeySegment(cast(size_t)arg);
            else
                static assert(0, "JSON segments must be string or integer");
        }
    }
}

/++  UDA to mark a field for JSON binding and/or specify a custom path.
     Can be applied to:
       - A struct/class: all public fields are included.
       - A field: that field is included.
       - A field with path: `@JSON("flat_key")`, `@JSON("/ptr/path")`, or `@JSON("variadic", 1, "key")`.
 ++/
alias JSON = JSONImpl!false;

/++  UDA to mark a field as optional. 
     If missing in JSON, the field will retain its `init` value.
     Supports the same path mapping as `@JSON`. ++/
alias JSONOptional = JSONImpl!true;

/++  UDA to explicitly ignore a field from JSON binding. 
     Useful when the parent struct is marked with @JSON. ++/
enum JSONIgnore;

/++  A single segment in a JSONKey path: either a string key or an array index. ++/
package struct JSONKeySegment {
    bool isIndex;
    string key;
    size_t index;

    this(string k) pure @safe { isIndex = false; key = k; }
    this(size_t i) pure @safe { isIndex = true; index = i; }
}


/++  UDA to apply a preprocessing function during fromJSON.
     The function signature must be `FieldType func(JValue v)`. ++/
struct JSONPreProcess(alias func) {
    alias preprocess = func;
}

/++  UDA to apply a postprocessing function during toJSON.
     The function signature must be `JValue func(FieldType v)`. ++/
struct JSONPostProcess(alias func) {
    alias postprocess = func;
}


/++  Convert a JValue to a D type T.
     Throws JSONException if a required field is missing or types mismatch. ++/
T fromJSON(T)(JValue v) {
    static if (is(T == JValue)) {
        return v;
    } else static if (is(T == JSONValue)) {
        return v.toStdJSON();
    } else static if (isBasicType!T || is(T == string)) {
        return v.get!T();
    } else static if (isArray!T) {
        alias E = ForeachType!T;
        T result;
        result.reserve(v.length);
        foreach(el; v) {
            result ~= fromJSON!E(el);
        }
        return result;
    } else static if (isAssociativeArray!T) {
        alias K = KeyType!T;
        alias V = ValueType!T;
        static assert(is(K == string), "JSON associative arrays must have string keys");
        T result;
        foreach(string key, val; v) {
            result[key] = fromJSON!V(val);
        }
        return result;
    } else static if (is(T == struct) || is(T == class)) {
        static if (is(T == class)) {
            T obj = new T();
        } else {
            T obj;
        }

        foreach(member; FieldNameTuple!T) {
            alias memberType = typeof(__traits(getMember, T, member));
            
            // 1. Check if included
            static if (isIncluded!(T, member)) {
                // 2. Determine JSON key path
                alias keyPath = keyPathOf!(T, member);

                // 3. Handle existence
                JValue* keyPtr = v.getPtrBySegments(keyPath);
                if (keyPtr is null) {
                    static if (hasUDA!(__traits(getMember, T, member), JSONOptional)) {
                        continue;
                    } else {
                        import std.algorithm : map;
                        import std.array : join;
                        string pathStr = keyPath.map!(s => s.isIndex ? s.index.to!string : s.key).join(".");
                        throw new JSONException("Missing required field: " ~ pathStr);
                    }
                }

                // 4. Extract and assign
                JValue val = *keyPtr;

                static if (hasPreProcess!(T, member)) {
                    __traits(getMember, obj, member) = getPreProcess!(T, member)(val);
                } else {
                    __traits(getMember, obj, member) = fromJSON!memberType(val);
                }
            }
        }
        return obj;
    } else {
        static assert(0, "Unsupported type for fromJSON: " ~ T.stringof);
    }
}

/++  Convert a D type T to a JValue. ++/
JValue toJSON(T)(T value) {
    static if (is(T == JValue) || is(T == JSONValue)) {
        return JValue(value);
    } else static if (isBasicType!T || is(T == string)) {
        return JValue(value);
    } else static if (isArray!T) {
        JArray arr;
        foreach(ref el; value) {
            arr.elements ~= toJSON(el);
        }
        arr.isFullyParsed = true;
        return JValue(arr);
    } else static if (isAssociativeArray!T) {
        JObject obj;
        foreach(string key, ref val; value) {
            obj.pairs ~= JObject.Pair(key, toJSON(val));
        }
        obj.isFullyParsed = true;
        return JValue(obj);
    } else static if (is(T == struct) || is(T == class)) {
        static if (is(T == class)) {
            if (value is null) return JValue(null);
        }
        JValue root = JValue(null);
        foreach(member; FieldNameTuple!T) {
            // 1. Check if included
            static if (isIncluded!(T, member)) {
                // 2. Convert value
                JValue val;
                static if (hasPostProcess!(T, member)) {
                    val = getPostProcess!(T, member)(__traits(getMember, value, member));
                } else {
                    val = toJSON(__traits(getMember, value, member));
                }

                // 3. Determine JSON key path
                alias keyPath = keyPathOf!(T, member);

                // 4. Write at path (merges intermediate nodes)
                setBySegments(root, keyPath, val);
            }
        }
        return root;
    } else {
        static assert(0, "Unsupported type for toJSON: " ~ T.stringof);
    }
}

/++  Writes `val` at the path `segs` under `root`, creating the missing objects and arrays.
     As in `JValue.set`, a numeric segment is an index when the node is an array or does not
     exist yet, and a key when the node is an object. ++/
private void setBySegments(ref JValue root, const(JSONKeySegment)[] segs, JValue val) {
    assert(segs.length > 0);
    JValue* current = &root;
    foreach (i, seg; segs) {
        current.evaluateSelf();

        size_t idx = seg.index;
        bool useIndex = seg.isIndex;
        if (!useIndex && (current.type == JType.Array || current.type == JType.Null)) {
            try {
                idx = to!size_t(seg.key);
                useIndex = true;
            } catch (Exception) {}
        }

        if (i == segs.length - 1) {
            if (useIndex) (*current)[idx] = val;
            else (*current)[seg.key] = val;
            return;
        }

        // Intermediate node: assigning creates the container if `current` is null
        JValue* next = useIndex ? current.getPtr(idx) : current.getPtr(seg.key);
        if (next is null) {
            if (useIndex) {
                (*current)[idx] = JValue(null);
                next = current.getPtr(idx);
            } else {
                (*current)[seg.key] = JValue(null);
                next = current.getPtr(seg.key);
            }
        }
        current = next;
    }
}

// Helper traits

/++ JSON key path of a field: its name, or the path given by @JSON/@JSONOptional. Computed at compile time. ++/
private template keyPathOf(T, string member) {
    static immutable JSONKeySegment[] keyPathOf = computeKeyPath!(T, member)();
}

private JSONKeySegment[] computeKeyPath(T, string member)() {
    JSONKeySegment[] keyPath = [JSONKeySegment(member)];
    foreach(U; AliasSeq!(JSON, JSONOptional)) {
        foreach(uda; getUDAs!(__traits(getMember, T, member), U)) {
            static if (!is(uda)) {
                if (uda.segments.length > 0)
                    keyPath = uda.segments;
            }
        }
    }
    return keyPath;
}
private template isIncluded(T, string member) {
    alias m = __traits(getMember, T, member);
    enum hasFieldUDA = hasUDA!(m, JSON) || hasUDA!(m, JSONOptional);
    enum hasStructUDA = hasUDA!(T, JSON);
    enum isIgnored = hasUDA!(m, JSONIgnore);
    enum isPublic = __traits(getProtection, m) == "public";
    
    // Included if:
    // 1. Explicitly marked with @JSON
    // 2. Parent struct has @JSON AND field is public AND not ignored
    enum isIncluded = hasFieldUDA || (hasStructUDA && isPublic && !isIgnored);
}

private template hasPreProcess(T, string member) {
    enum hasPreProcess = hasUDA!(__traits(getMember, T, member), JSONPreProcess);
}

private auto getPreProcess(T, string member)(JValue v) {
    alias UDAs = getUDAs!(__traits(getMember, T, member), JSONPreProcess);
    return UDAs[0].preprocess(v);
}

private template hasPostProcess(T, string member) {
    enum hasPostProcess = hasUDA!(__traits(getMember, T, member), JSONPostProcess);
}

private JValue getPostProcess(T, string member, V)(V value) {
    alias UDAs = getUDAs!(__traits(getMember, T, member), JSONPostProcess);
    return UDAs[0].postprocess(value);
}
