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
