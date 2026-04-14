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

/++ Comprehensive unit tests for the djson library. ++/
module djson.tests;

version(unittest):

import djson;
import std.exception;
import std.math;
import std.concurrency;

unittest {
    // 1. Basic parsing and primitive types
    auto json = parseJSON(`{"str":"hello", "num":42, "num_f":3.14, "b1":true, "b2":false, "n":null}`);
    
    assert(json.get!string("str") == "hello");
    assert(json.get!long("num") == 42);
    assert(isClose(json.get!double("num_f"), 3.14));
    assert(json.get!bool("b1") == true);
    assert(json.get!bool("b2") == false);
    
    assert(json.safe!long("missing_num").or(99) == 99);
    assert(json.safe!string("missing_str").or("default") == "default");
    
    string df = json.safe!string("missing_str");
    assert(df == ""); // T.init
}

unittest {
    // 2. Nested objects and arrays
    auto json = parseJSON(`
    {
        "field": {
            "sub": {
                "value": "deep"
            }
        },
        "array": [
            {"id": 0},
            {"id": 1, "value": "element_value"}
        ]
    }
    `);

    // Multiple string args
    assert(json.get!string("field", "sub", "value") == "deep");
    
    // JSON Pointers
    assert(json.get!string("/field/sub/value") == "deep");
    assert(json.get!string("/array/1/value") == "element_value");
    assert(json.get!long("/array/0/id") == 0);
    
    // safe nested
    assert(json.safe!string("/field/sub/missing").or("no") == "no");
    assert(json.safe!string("array", 1, "missing").or("no") == "no");
    
    // nested object extraction
    JObject sub = json.get!JObject("/field/sub");
    assert(sub.pairs.length == 1);
    
    JArray arr = json.get!JArray("/array");
    assert(arr.elements.length == 2);
    
    // Test size and lengths
    assert(json.get!JValue("/array").length == 2);
}

unittest {
    // 3. Modifying / accessing JValue lazily
    auto json = parseJSON(`[1,2,3, {"a": "b"}]`);
    assert(json.length == 4);
    
    assert(json[0].get!long == 1);
    assert(json[3].get!string("a") == "b");
    
    auto e = collectException!JSONException(json[4]);
    assert(e !is null);
}

unittest {
    // 4. SafeResult casting
    auto json = parseJSON(`{"k": "v"}`);
    string val = json.safe!string("k").or("fallback");
    assert(val == "v");
    
    string val2 = json.safe!string("missing").or("fallback");
    assert(val2 == "fallback");
    
    string val3 = json.safe!string("missing"); // implicitly getThis -> T.init
    assert(val3 == "");
}

unittest {
    // 5. Standard Compliance (Escapes, types)
    auto json = parseJSON(`{"escaped": "\"\\/\b\f\n\r\t \u20AC"}`);
    string e = json.get!string("escaped");
    assert(e == "\"\\/\b\f\n\r\t €");
    
    // Whitespace skipping
    auto j2 = parseJSON("   \n\t{ \n\t\"a\" : \t 1 \n }  ");
    assert(j2.get!long("a") == 1);
}

// Multithreading compatibility test
void worker(string payload) {
    auto json = parseJSON(payload);
    assert(json.get!long("a") == 42);
}

unittest {
    // 6. Multithreading
    // `parseJSON` returns an unshared JValue, but since string is immutable,
    // and JValue is a value type, it can be seamlessly passed around or parsed concurrently in isolation.
    string payload = `{"a": 42}`;
    
    auto t1 = spawn(&worker, payload);
    auto t2 = spawn(&worker, payload);
    // basic wait is automatic or we can trust the GC. No shared mutable state is used in DJSON.
}

unittest {
    // 7. validate parseAll
    auto validJson = parseJSON(`{"a": [1,2,3], "b": {"c": null}}`);
    validJson.parseAll(); // should not throw
    
    auto invalidJson = parseJSON(`{"a": [1,2,3`); // unterminated array but lazy
    // Because it's lazy, we might not see the error until parseAll
    auto e = collectException!JSONPartialException(invalidJson.parseAll());
    assert(e !is null);
    
    auto invalidKey = parseJSON(`{a: [1,2,3]}`); // key without quotes
    auto syntaxE = collectException!JSONSyntaxException(invalidKey.parseAll());
    assert(syntaxE !is null);
}

unittest {
    // 8. Mutation and Assignment
    auto json = JValue();
    
    // Auto-vivification test
    json.set(42, "/field/id");
    assert(json.get!long("/field/id") == 42);
    
    json["number"] = 10;
    assert(json.get!long("number") == 10);
    
    // Auto-vivify array
    json.set("el", "/arr/2");
    assert(json.get!string("/arr/2") == "el");
    assert(json.get!JArray("/arr").elements.length == 3);
}

unittest {
    // 9. Serialization
    auto json = parseJSON(`{"b": 2, "a": 1}`);
    json["c"] = 3;
    
    // Compact serialization test (keeps parsing order and appends)
    string res = json.toJSON();
    assert(res == `{"b":2,"a":1,"c":3}`);
    
    // Pretty serialization test
    string pretty = json.toJSON(true);
    assert(pretty == "{\n    \"b\": 2,\n    \"a\": 1,\n    \"c\": 3\n}");
}

unittest {
    // 10. Interoperability
    // Use fully qualified names to avoid conflicts if std.json is imported elsewhere
    import std.json;
    auto json = djson.parseJSON(`{"list": [1,2,3], "name": "test"}`);
    
    auto stdJ = json.toStdJSON();
    assert(stdJ.type == std.json.JSONType.object);
    assert(stdJ["name"].str == "test");
    assert(stdJ["list"].array[1].integer == 2);
}

unittest {
    import std.json;
    // 11. Custom opCast
    auto json = djson.parseJSON(`{"arr": [1, 2], "val": 3}`);
    JObject obj = json.get!JObject();
    JArray arr = json.get!JArray("arr");
    
    // Cast to String
    string objStr = cast(string)obj;
    assert(objStr == `{"arr":[1,2],"val":3}`);
    
    string arrStr = cast(string)arr;
    assert(arrStr == `[1,2]`);
    
    // Cast to JSONValue
    JSONValue jv = cast(JSONValue)obj;
    assert(jv["val"].integer == 3);
    
    JSONValue jvArr = cast(JSONValue)arr;
    assert(jvArr.array[0].integer == 1);
}

unittest {
    // 12. Lazy parsing still works after eager optimization
    
    // Pure lazy: only parse what's needed
    auto json = parseJSON(`{"a": 1, "b": {"c": "deep"}, "d": [10, 20, 30]}`);
    assert(json.get!long("a") == 1); // only "a" is parsed
    assert(json.get!string("b", "c") == "deep"); // "b" parsed on demand
    assert(json.get!long("d", 1) == 20); // "d" parsed on demand
    
    // Partial lazy then parseAll: access some fields, then parse the rest
    auto json2 = parseJSON(`{"x": 100, "y": {"z": [1,2,3]}, "w": "end"}`);
    assert(json2.get!long("x") == 100); // partially parsed
    json2.parseAll(); // should complete the rest without issues
    assert(json2.get!string("w") == "end");
    assert(json2.get!long("y", "z", 2) == 3);
    
    // Verify serialization after mixed lazy/eager access
    string s = json2.toJSON();
    assert(s == `{"x":100,"y":{"z":[1,2,3]},"w":"end"}`);
    
    // Pure eager via parseAll on fresh node
    auto json3 = parseJSON(`[{"id": 1}, {"id": 2}]`);
    json3.parseAll();
    assert(json3[0].get!long("id") == 1);
    assert(json3[1].get!long("id") == 2);
    assert(json3.length == 2);
}

unittest {
    // 13. Overwriting nested objects with primitives and vice-versa
    
    // Overwrite an object with a primitive
    auto json = parseJSON(`{"a": {"b": 10}, "c": 3}`);
    assert(json.get!long("a", "b") == 10); // nested access works
    json["a"] = 5; // overwrite object {"b":10} with integer 5
    assert(json.get!long("a") == 5);
    assert(json.get!long("c") == 3); // other keys unaffected
    
    // Overwrite a primitive with a string
    json["a"] = "hello";
    assert(json.get!string("a") == "hello");
    
    // Overwrite a primitive with null
    json["a"] = null;
    assert(json.safe!long("a").found == false); // it's null now, not a number
    
    // Overwrite via set with JSON pointer
    auto json2 = parseJSON(`{"x": {"y": {"z": 42}}}`);
    json2.set(99, "/x/y/z");
    assert(json2.get!long("/x/y/z") == 99);
    
    // Overwrite entire sub-object via set
    json2.set("replaced", "/x/y");
    assert(json2.get!string("/x/y") == "replaced");
    // The old nested "z" is gone — can't traverse a string
    assert(json2.safe!long("/x/y/z").found == false);
    
    // Setting a deep path that requires overwriting a primitive should throw
    auto e = collectException!JSONException(json2.set(1, "/x/y/z"));
    assert(e !is null);
    
    // Overwrite array element with different type
    auto json3 = parseJSON(`[1, "two", 3]`);
    json3[0] = "one";
    assert(json3[0].get!string == "one");
    json3[1] = 2;
    assert(json3[1].get!long == 2);
    
    // Serialization after overwrites  
    assert(json3.toJSON() == `["one",2,3]`);
}

unittest {
    // 14. Key and path existence checks with has()

    auto json = parseJSON(`{
        "name": "test",
        "nested": {"a": 1, "b": {"c": true}},
        "list": [10, 20, 30],
        "empty_obj": {},
        "empty_arr": [],
        "null_val": null
    }`);

    // Simple key existence
    assert(json.has("name") == true);
    assert(json.has("nested") == true);
    assert(json.has("missing") == false);
    assert(json.has("") == false); // empty key doesn't exist

    // Nested key existence (variadic)
    assert(json.has("nested", "a") == true);
    assert(json.has("nested", "b") == true);
    assert(json.has("nested", "b", "c") == true);
    assert(json.has("nested", "missing") == false);
    assert(json.has("nested", "b", "missing") == false);
    assert(json.has("nested", "a", "sub") == false); // "a" is 1, not an object

    // JSON pointer path existence
    assert(json.has("/name") == true);
    assert(json.has("/nested/a") == true);
    assert(json.has("/nested/b/c") == true);
    assert(json.has("/nested/missing") == false);
    assert(json.has("/totally/wrong/path") == false);

    // Array index existence
    assert(json.has("list", 0) == true);
    assert(json.has("list", 2) == true);
    assert(json.has("list", 3) == false); // out of bounds
    assert(json.has("list", 100) == false);
    
    // Array index via JSON pointer
    assert(json.has("/list/0") == true);
    assert(json.has("/list/2") == true);
    assert(json.has("/list/3") == false);

    // Empty containers
    assert(json.has("empty_obj") == true); // the key exists
    assert(json.has("empty_arr") == true);
    
    // Null value: the key exists, but has no useful value
    assert(json.has("null_val") == true);
}

unittest {
    // 15. Null value checking with isNull
    
    auto json = parseJSON(`{"a": null, "b": 42, "c": "hello", "d": [null, 1, null]}`);
    
    // Object values
    assert(json["a"].isNull == true);
    assert(json["b"].isNull == false);
    assert(json["c"].isNull == false);
    
    // Null inside arrays
    assert(json["d"][0].isNull == true);
    assert(json["d"][1].isNull == false);
    assert(json["d"][2].isNull == true);
    
    // Nested null
    auto json2 = parseJSON(`{"x": {"y": null}}`);
    assert(json2["x"].isNull == false); // the object itself is not null
    assert(json2["x"]["y"].isNull == true); // the nested value is null
    
    // Safe access combined with isNull
    assert(json.has("a") == true); // key exists...
    assert(json["a"].isNull == true); // ...but value is null
}

unittest {
    // 16. Removing values from objects and arrays
    
    // Remove keys from an object
    auto json = parseJSON(`{"a": 1, "b": 2, "c": 3, "d": 4}`);
    assert(json.remove("b") == true);
    assert(json.has("b") == false);
    assert(json.length == 3);
    assert(json.toJSON() == `{"a":1,"c":3,"d":4}`);
    
    // Remove non-existent key returns false
    assert(json.remove("missing") == false);
    assert(json.length == 3); // unchanged
    
    // Remove first and last elements
    assert(json.remove("a") == true);
    assert(json.remove("d") == true);
    assert(json.toJSON() == `{"c":3}`);
    
    // Remove last remaining key
    assert(json.remove("c") == true);
    assert(json.length == 0);
    assert(json.toJSON() == `{}`);
    
    // Remove from empty object returns false
    assert(json.remove("anything") == false);
    
    // Remove elements from an array
    auto arr = parseJSON(`[10, 20, 30, 40, 50]`);
    assert(arr.remove(cast(size_t)2) == true); // remove 30
    assert(arr.length == 4);
    assert(arr.toJSON() == `[10,20,40,50]`);
    
    // Remove first element (index shift)
    assert(arr.remove(cast(size_t)0) == true); // remove 10
    assert(arr.toJSON() == `[20,40,50]`);
    
    // Remove last element
    assert(arr.remove(cast(size_t)2) == true); // remove 50
    assert(arr.toJSON() == `[20,40]`);
    
    // Out of bounds returns false
    assert(arr.remove(cast(size_t)5) == false);
    assert(arr.length == 2);
    
    // Remove nested branch from object
    auto nested = parseJSON(`{"keep": 1, "remove_me": {"deep": {"data": [1,2,3]}}}`);
    assert(nested.has("remove_me", "deep", "data") == true);
    assert(nested.remove("remove_me") == true);
    assert(nested.has("remove_me") == false);
    assert(nested.has("keep") == true);
    assert(nested.toJSON() == `{"keep":1}`);
    
    // Remove from a non-container returns false
    auto prim = parseJSON(`42`);
    prim.evaluateSelf();
    assert(prim.remove("key") == false);
    assert(prim.remove(cast(size_t)0) == false);
}

unittest {
    // 17. foreach iteration on arrays
    
    auto arr = parseJSON(`[10, 20, 30, 40]`);
    
    // foreach without explicit type
    int sum = 0;
    foreach(el; arr) {
        sum += el.get!int;
    }
    assert(sum == 100);
    
    // foreach with explicit type
    sum = 0;
    foreach(JValue el; arr) {
        sum += el.get!int;
    }
    assert(sum == 100);
    
    // foreach with index (no explicit type)
    size_t[] indices;
    int[] values;
    foreach(size_t i, el; arr) {
        indices ~= i;
        values ~= el.get!int;
    }
    assert(indices == [0, 1, 2, 3]);
    assert(values == [10, 20, 30, 40]);
    
    // foreach with explicit index type
    indices = [];
    foreach(size_t i, JValue el; arr) {
        indices ~= i;
    }
    assert(indices == [0, 1, 2, 3]);
    
    // break works
    int count = 0;
    foreach(el; arr) {
        count++;
        if (count == 2) break;
    }
    assert(count == 2);
}

unittest {
    // 18. foreach iteration on objects — insertion order preserved
    
    auto obj = parseJSON(`{"z": 1, "a": 2, "m": 3, "b": 4}`);
    
    // foreach key-value — verify insertion order
    string[] keys;
    int[] vals;
    foreach(string key, val; obj) {
        keys ~= key;
        vals ~= val.get!int;
    }
    assert(keys == ["z", "a", "m", "b"]); // insertion order, NOT alphabetical
    assert(vals == [1, 2, 3, 4]);
    
    // foreach key-value without explicit type
    keys = [];
    foreach(string key, val; obj) {
        keys ~= key;
    }
    assert(keys == ["z", "a", "m", "b"]);
    
    // foreach values only (no key)
    vals = [];
    foreach(val; obj) {
        vals ~= val.get!int;
    }
    assert(vals == [1, 2, 3, 4]);
    
    // foreach with index on object (index = position, not key)
    size_t[] positions;
    foreach(size_t i, val; obj) {
        positions ~= i;
    }
    assert(positions == [0, 1, 2, 3]);
    
    // Iteration after mutation preserves order
    obj["z"] = 99; // update first
    obj["new"] = 5; // append
    keys = [];
    vals = [];
    foreach(string key, val; obj) {
        keys ~= key;
        vals ~= val.get!int;
    }
    assert(keys == ["z", "a", "m", "b", "new"]);
    assert(vals == [99, 2, 3, 4, 5]);
    
    // Iteration after removal preserves relative order
    obj.remove("m");
    keys = [];
    foreach(string key, val; obj) {
        keys ~= key;
    }
    assert(keys == ["z", "a", "b", "new"]);
}

unittest {
    // 19. foreach on lazy (not yet parsed) nodes
    
    auto json = parseJSON(`{"items": [{"id": 1}, {"id": 2}, {"id": 3}]}`);
    // Don't call parseAll — iterate lazily
    int[] ids;
    foreach(el; json["items"]) {
        ids ~= el.get!int("id");
    }
    assert(ids == [1, 2, 3]);
    
    // foreach on nested lazy object
    auto json2 = parseJSON(`{"a": {"x": 10, "y": 20}, "b": {"x": 30}}`);
    int total = 0;
    foreach(string key, sub; json2) {
        foreach(string innerKey, val; sub) {
            total += val.get!int;
        }
    }
    assert(total == 60);
}

unittest {
    // 20. JSON Pointer escaping (RFC 6901)

    // 20a. ~1 decodes to / — key containing a forward slash
    auto json = parseJSON(`{
        "application/json": true,
        "text/plain": 42
    }`);

    // Variadic always works (no splitting)
    assert(json.get!bool("application/json") == true);
    assert(json.get!int("text/plain") == 42);

    // JSON Pointer with ~1 escaping
    assert(json.get!bool("/application~1json") == true);
    assert(json.get!int("/text~1plain") == 42);
    assert(json.has("/application~1json") == true);
    assert(json.has("/missing~1key") == false);

    // 20b. ~0 decodes to ~ — key containing a tilde
    auto json2 = parseJSON(`{"~tilde": 99, "a~b": "hello"}`);
    assert(json2.get!int("/~0tilde") == 99);
    assert(json2.get!string("/a~0b") == "hello");
    
    // 20c. Combined: key containing both ~ and /
    auto json3 = parseJSON(`{"a~1b/c": "deep"}`);
    // The key is literally: a~1b/c
    // To access it via JSON Pointer: ~0 for ~, ~1 for /
    // So the key "a~1b/c" encodes as "a~01b~1c"
    assert(json3.get!string("/a~01b~1c") == "deep");

    // 20d. ~01 edge case: must decode to ~1, NOT /
    // The key is literally "~1" (tilde followed by 1)
    auto json4 = parseJSON(`{"~1": "val"}`);
    assert(json4.get!string("/~01") == "val"); // ~01 → ~1 (first ~0→~, leaving ~1 as literal)

    // 20e. Empty string key "" — JSON Pointer "//" second segment is ""
    auto json5 = parseJSON(`{"": {"nested": 7}}`);
    assert(json5.get!int("//nested") == 7); // path: empty key → "nested"

    // 20f. set via JSON Pointer with ~1 escaping
    auto json6 = parseJSON(`{}`);
    json6.set(123, "/content~1type");
    assert(json6.get!int("content/type") == 123); // readable via variadic

    // 20g. Root pointer "/" — per RFC 6901, "/" accesses the key ""
    auto json7 = parseJSON(`{"": "rootkey"}`);
    // Note: our implementation treats "/" as "return self"; accessing "" key
    // requires the path "//" (empty reference token after the split)
    assert(json7.get!string("") == "rootkey");
}

unittest {
    // 21. Resumable Stream Parsing (Partial JSON)
    
    // Parse a stream that is abruptly cut off mid-way
    auto json = parseJSON(`{"hello": "world", "partial" :`);
    
    // Values parsed before the cutoff work fine
    assert(json.get!string("hello") == "world");
    
    // Values in the cutoff region throw cleanly without corrupting state
    auto e1 = collectException!JSONPartialException(json.get!string("partial"));
    assert(e1 !is null);
    
    // Trying to write to the partial block also throws because it must 
    // evaluate the pending stream tail first before mutating
    auto e2 = collectException!JSONPartialException(json.set(123, "new_key"));
    assert(e2 !is null);
    
    // Now the stream continues, we append the rest of the data
    json.appendData(`"world", "num":`);
    
    // The 'partial' key is now fully terminated by the comma! So it succeeds.
    assert(json.get!string("partial") == "world");
    
    // But 'num' is partial, and setting new keys still throws because the object tail is incomplete.
    auto e3 = collectException!JSONPartialException(json.set(456, "another"));
    assert(e3 !is null);
    // Let's finish it
    json.appendData(` 42}`);
    
    // The previously failing reads and writes now succeed!
    assert(json.get!string("partial") == "world");
    assert(json.get!long("num") == 42);
    
    // Mutation now works flawlessly on the completely parsed object
    json.set(123, "new_key");
    assert(json.get!long("new_key") == 123);
    
    // Resumable parsing in arrays
    auto arr = parseJSON(`[1, 2, `);
    auto e4 = collectException!JSONPartialException(arr.get!long(2));
    assert(e4 !is null); // [1, 2,  <- incomplete
    
    // Overwriting array is blocked
    auto e5 = collectException!JSONPartialException({ arr[3] = 99; }());
    assert(e5 !is null);
    
    // Check length
    auto e6 = collectException!JSONPartialException(arr.length);
    assert(e6 !is null);
    
    arr.appendData(`3]`);
    
    assert(arr.length == 3);
    
    // Access and mutation work!
    assert(arr.get!long(2) == 3);
    arr[3] = 99;
    assert(arr.get!long(3) == 99);
    
}

unittest {
    // 22. JSON Binding system (fromJSON/toJSON)
    import std.string : toUpper, toLower;
    
    // 22a. Basic struct binding
    @JSON
    struct Simple {
        string name;
        int age;
    }
    
    auto json = parseJSON(`{"name": "Alice", "age": 30}`);
    auto s = fromJSON!Simple(json);
    assert(s.name == "Alice");
    assert(s.age == 30);
    
    auto j2 = toJSON(s);
    assert(j2.get!string("name") == "Alice");
    assert(j2.get!int("age") == 30);

    // 22b. Exclusion and Renaming
    struct Custom {
        string secret; // Not marked with JSON, should be ignored
        
        @JSON
        {
            @JSON("user_id") int id;
            string visible;
        }
    }
    
    auto jsonC = parseJSON(`{"user_id": 1, "secret": "shh", "visible": "hello"}`);
    auto c = fromJSON!Custom(jsonC);
    assert(c.id == 1);
    assert(c.secret == ""); // stayed .init
    assert(c.visible == "hello");
    
    auto jc2 = toJSON(c);
    assert(jc2.has("user_id"));
    assert(!jc2.has("secret"));
    assert(jc2.get!string("visible") == "hello");

    // 22c. Preprocessing and Postprocessing
    // Static: just because we are inside a unittest block and struct has lambdas. 
    // If struct was placed outside, it doesn't need to be static.
    static struct Processed {
        @JSON
        {
            @JSONPreProcess!((v) => v.get!string.toUpper) string name;
            @JSONPostProcess!((v) => JValue(v.toLower)) string city;
        }
    }
    
    auto jsonP = parseJSON(`{"name": "alice", "city": "London"}`);
    auto p = fromJSON!Processed(jsonP);
    assert(p.name == "ALICE");
    assert(p.city == "London"); // not processed on input
    
    auto jp2 = toJSON(p);
    assert(jp2.get!string("name") == "ALICE"); // not processed on output
    assert(jp2.get!string("city") == "london"); // processed on output

    // 22d. Strictness: Required vs Optional
    struct Strict {
        @JSON
        {
            int req;
            @JSONOptional int opt;
        }
    }
    
    // Missing required should throw
    auto jsonS1 = parseJSON(`{"opt": 1}`);
    auto e1 = collectException!JSONException(fromJSON!Strict(jsonS1));
    assert(e1 !is null);
    
    // Missing optional should work
    auto jsonS2 = parseJSON(`{"req": 100}`);
    auto s2 = fromJSON!Strict(jsonS2);
    assert(s2.req == 100);
    assert(s2.opt == 0);

    // 22e. Classes and Nested types
    struct Address {
        @JSON:
        string street;
        int zip;
    }

    // Static: just because class is inside a unittest block.
    static class User {
        @JSON:
        string name;
        @JSONOptional Address addr;
    }
    
    auto jsonU = parseJSON(`{"name": "Bob", "addr": {"street": "Main St", "zip": 12345}}`);
    auto u = fromJSON!User(jsonU);
    assert(u.name == "Bob");
    assert(u.addr.street == "Main St");
    assert(u.addr.zip == 12345);
    
    auto ju2 = toJSON(u);
    assert(ju2.get!string("addr", "street") == "Main St");
    
    // 22f. Arrays and AA
    struct Container {
        @JSON:
        int[] scores;
        string[string] metadata;
    }
    
    auto jsonCon = parseJSON(`{"scores": [10, 20], "metadata": {"env": "prod"}}`);
    auto con = fromJSON!Container(jsonCon);
    assert(con.scores == [10, 20]);
    assert(con.metadata["env"] == "prod");

    // 22g. Whole-struct marking and protection
    // Static: just because we are inside a unittest block and struct has a method.
    @JSON
    static struct Ergonomic {
        string name;        // Included (public)
        private string key; // Ignored (private)
        @JSON int secret;   // Included (explicitly marked)
        @JSONIgnore int tmp; // Ignored (explicitly ignored)
        
        bool isOk() { return true; } // Ignored (method)
    }
    
    auto jsonE = parseJSON(`{"name": "Ergo", "key": "abc", "secret": 123, "tmp": 99}`);
    auto ergo = fromJSON!Ergonomic(jsonE);
    assert(ergo.name == "Ergo");
    assert(ergo.key == ""); 
    assert(ergo.secret == 123);
    assert(ergo.tmp == 0);
    
    auto je2 = toJSON(ergo);
    assert(je2.has("name"));
    assert(!je2.has("key"));
    assert(je2.has("secret"));
    assert(!je2.has("tmp"));
}

unittest {
    // 23. Custom serialization for a field
    // Demonstrates string "part1|part2|part3" converted to/from SubStructure
    import std.string : split;

    struct SubStructure {
        string field1;
        string field2;
        string field3;
    }

    static SubStructure parseSub(JValue v) {
        string[] parts = v.get!string.split("|");
        return SubStructure(parts[0], parts[1], parts[2]);
    }

    static JValue serializeSub(SubStructure s) {
        return JValue(s.field1 ~ "|" ~ s.field2 ~ "|" ~ s.field3);
    }

    static struct CustomSerialized {
        @JSON {
            @JSONPreProcess!parseSub
            @JSONPostProcess!serializeSub
            SubStructure info;
        }
    }

    auto json = parseJSON(`{"info": "test|stupid|serialization"}`);
    auto obj = fromJSON!CustomSerialized(json);

    assert(obj.info.field1 == "test");
    assert(obj.info.field2 == "stupid");
    assert(obj.info.field3 == "serialization");

    auto j2 = toJSON(obj);
    assert(j2.get!string("info") == "test|stupid|serialization");
}

unittest {
    // 24. JSON pointer binding

    @JSON
    struct User {
        string name;
        int age;
    }

    struct Couple {

        // Bind deep fields (two different syntax)
        @JSON("/first/name") string firstUserName;
        @JSON("first", "age") int firstUserAge;
        
        // Bind a sub struct
        @JSON User second;
    }

    auto json = parseJSON(`{"first" : { "name" : "Alice", "age" : 30}, "second" : {"name" : "Bob", "age" : 32}}`);

    Couple c = json.fromJSON!Couple;

    assert(c.firstUserName == "Alice");
    assert(c.firstUserAge == 30);
    assert(c.second.name == "Bob");
    assert(c.second.age == 32);

    // Changes
    c.firstUserAge = 28;
    c.second.name = "Foo";

    assert(c.toJSON().toString() == `{"first":{"name":"Alice","age":28},"second":{"name":"Foo","age":32}}`);
}
unittest {
    // 25. JSONOptional with paths
    struct OptionalPaths {
        @JSONOptional("custom_id") int id = 42;
        @JSONOptional("/deep/key") string deep = "default";
        @JSONOptional("tags", 0) string firstTag = "none";
    }

    // Case 1: All missing
    {
        auto j = parseJSON(`{}`);
        auto o = fromJSON!OptionalPaths(j);
        assert(o.id == 42);
        assert(o.deep == "default");
        assert(o.firstTag == "none");
    }

    // Case 2: Some present
    {
        auto j = parseJSON(`{"custom_id": 10, "deep": {"key": "found"}}`);
        auto o = fromJSON!OptionalPaths(j);
        assert(o.id == 10);
        assert(o.deep == "found");
        assert(o.firstTag == "none");
    }

    // Case 3: All present
    {
        auto j = parseJSON(`{"custom_id": 99, "deep": {"key": "yes"}, "tags": ["tag1"]}`);
        auto o = fromJSON!OptionalPaths(j);
        assert(o.id == 99);
        assert(o.deep == "yes");
        assert(o.firstTag == "tag1");
    }
}

unittest {
    // 24. Builder API (JSOB and JSAB)
    auto json = JSOB(
        "name", "djson",
        "version", 1,
        "features", JSAB("lazy", "fast", "safe"),
        "config", JSOB("debug", false)
    );
    
    assert(json.get!string("name") == "djson");
    assert(json.get!int("version") == 1);
    assert(json.get!string("features", 1) == "fast");
    assert(json.get!bool("config", "debug") == false);
    
    // Serialization
    assert(json.toJSON() == `{"name":"djson","version":1,"features":["lazy","fast","safe"],"config":{"debug":false}}`);
    
    // JSAB for top-level array
    auto arr = JSAB(1, 2, "three");
    assert(arr.length == 3);
    assert(arr.toJSON() == `[1,2,"three"]`);
}

unittest {
    // 25. Array appending (~=) and auto-promotion
    auto json = JValue(null);
    json ~= 1;
    assert(json.length == 1);
    assert(json[0].get!int == 1);
    
    json ~= "two";
    assert(json.length == 2);
    assert(json[1].get!string == "two");
    
    // Promotion of primitive to array
    auto p = JValue(42);
    p ~= 43;
    assert(p.type == JType.Array);
    assert(p.length == 2);
    assert(p[0].get!int == 42);
    assert(p[1].get!int == 43);
}

unittest {
    // 26. Nested append with auto-vivification
    auto json = JSOB("k1", "v1");
    
    // Append to existing primitive (promotion)
    json.append("v2", "k1");
    assert(json["k1"].type == JType.Array);
    assert(json["k1"].length == 2);
    assert(json["k1"][1].get!string == "v2");
    
    // Append to non-existent path (auto-vivification)
    json.append(100, "new", "list");
    assert(json.has("new", "list"));
    assert(json.get!int("new", "list", 0) == 100);
    
    // Append via JSON Pointer
    json.append("world", "/hello/array");
    assert(json.get!string("/hello/array/0") == "world");
    json.append("!", "/hello/array");
    assert(json.get!string("/hello/array/1") == "!");
}

unittest {
    // isType properties
    auto json = parseJSON(`{"a": 1, "b": "str", "c": [], "d": {}, "e": true, "f": null, "g": false, "h": 1.2}`);

    assert(!json.isNull);
    assert(json.isObject);
    assert(!json.isArray);
    assert(!json.isString);
    assert(!json.isNumber);
    assert(!json.isBool);

    assert(json["a"].isNumber);
    assert(!json["a"].isString);

    assert(json["b"].isString);
    assert(!json["b"].isNumber);

    assert(json["c"].isArray);
    assert(!json["c"].isObject);

    assert(json["d"].isObject);
    assert(!json["d"].isArray);

    assert(json["e"].isBool);
    assert(!json["e"].isNull);

    assert(json["f"].isNull);
    assert(!json["f"].isBool);

    assert(json["g"].isBool);
    assert(!json["g"].isNumber);

    assert(json["h"].isNumber);
    assert(!json["h"].isString);
}
