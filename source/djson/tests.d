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

unittest {
    // Partial: navigating inside incomplete containers
    auto json = parseJSON(`{
  "users": [
    { "id": 1, "name": "Alice", "role": "Admin" },
    { "id": 2, "name": "Bob", "role": "User" },
    { "id": 3, "name": "Cha`);

    // Elements already received are reachable even though "users" is not closed
    assert(json.get!string("/users/1/name") == "Bob");
    assert(json.get!long("/users/0/id") == 1);
    assert(json.get!long("/users/2/id") == 3);

    // The truncated parts still report a partial stream
    assert(collectException!JSONPartialException(json.get!string("/users/2/name")) !is null);
    assert(collectException!JSONPartialException(json["users"].length) !is null);
    assert(collectException!JSONPartialException(json.parseAll()) !is null);

    json.appendData(`rlie"}]}`);
    assert(json.get!string("/users/2/name") == "Charlie");
    assert(json["users"].length == 3);
    json.parseAll();

    // A closed container at the end of the buffer is complete
    auto nested = parseJSON(`{"a": {"b":1}`);
    assert(nested.get!long("/a/b") == 1);

    // A trailing number is still ambiguous
    auto nums = parseJSON(`[1, 2`);
    assert(nums.get!long(0) == 1);
    assert(collectException!JSONPartialException(nums.get!long(1)) !is null);
}

unittest {
    // Partial: out-of-range index on an incomplete array reports a partial stream
    auto json = parseJSON(`{"users": [{"name": "Alice"}, {"name": "Bob"}, {"name": "Cha`);
    auto e = collectException!JSONException(json.get!string("/users/3/name"));
    assert(e !is null && cast(JSONPartialException) e !is null);
    assert(e.msg == "Incomplete JSON: 'users' » '3' not yet available");
    auto ek = collectException!JSONPartialException(json.get!string("/users/2/pizza"));
    assert(ek !is null && ek.msg == "Incomplete JSON: 'users' » '2' » 'pizza' not yet available");
    auto ev = collectException!JSONPartialException(json.get!string("/users/2/name"));
    assert(ev !is null && ev.msg == "Incomplete JSON: value at 'users' » '2' » 'name' is truncated");
    assert(collectException!JSONPartialException(json.set("x", "/users/3/name")) !is null);

    json.appendData(`rlie"}]}`);
    auto e2 = collectException!JSONException(json.get!string("/users/3/name"));
    assert(e2 !is null && cast(JSONPartialException) e2 is null); // now a plain "not found"
}

unittest {
    // "Path not found" reports the full path up to the missing segment
    auto json = parseJSON(`{"users": [{"name": "Alice"}, {"": "empty key"}]}`);
    assert(collectException!JSONException(json.get!string("/users/0/")).msg == "Path not found: 'users' » '0' » ''");
    assert(collectException!JSONException(json.get!string("/users/5/name")).msg == "Path not found: 'users' » '5'");
    assert(collectException!JSONException(json.get!string("users", 0, "age")).msg == "Path not found: 'users' » '0' » 'age'");
    assert(json.get!string("/users/1/") == "empty key");

    // Other traversal errors use the same path format
    assert(collectException!JSONException(json.get!string("/users/x")).msg == "Expected numeric index for array: 'users' » 'x'");
    assert(collectException!JSONException(json.get!string("/users/0/name/first")).msg == "Cannot traverse primitive value: 'users' » '0' » 'name' » 'first'");
    assert(collectException!JSONException(json.get!string("users", 0, "name", "first")).msg == "Cannot traverse primitive value: 'users' » '0' » 'name' » 'first'");
    assert(collectException!JSONException(parseJSON(`"hello"`).get!string("/hello")).msg == "Cannot traverse primitive value: 'hello'");
    assert(collectException!JSONException(json.set(1, "/users/0/name/first/x")).msg == "Cannot traverse primitive value: 'users' » '0' » 'name' » 'first'");
    assert(collectException!JSONException(json.set(1, "users", 0, "name", "first", "x")).msg == "Cannot traverse primitive value: 'users' » '0' » 'name' » 'first'");
    assert(collectException!JSONException(json.append(1, "/users/0/name/x")).msg == "Cannot traverse primitive value: 'users' » '0' » 'name' » 'x'");
    assert(collectException!JSONException(json.append(1, "/users/x/tags")).msg == "Expected numeric index for array: 'users' » 'x'");

    // Append through array indices
    auto nested = parseJSON(`{"l": [{"t": [1]}]}`);
    nested.append(2, "/l/0/t");
    nested.append(5, "/l/0/new");
    nested.append(7, "/fresh/0");
    assert(nested.get!long("/l/0/t/1") == 2);
    assert(nested.get!long("/l/0/new/0") == 5);
    assert(nested.get!long("/fresh/0/0") == 7);

    // Variadic set works on lazily parsed documents
    auto lazyDoc = parseJSON(`{"a": {"b": 1}, "l": [{"x": 1}]}`);
    lazyDoc.set(2, "a", "c");
    lazyDoc.set(3, "l", 0, "y");
    assert(lazyDoc.get!long("/a/c") == 2 && lazyDoc.get!long("/a/b") == 1);
    assert(lazyDoc.get!long("/l/0/y") == 3);
}

unittest {
    // Trailing data after the end of the document
    auto obj = parseJSON(`{"a": 1}  xyz`);
    assert(obj.get!long("a") == 1);
    assert(obj.trailingData == "xyz");
    assert(parseJSON(`{"a": 1}  `).trailingData == "");

    // Also after parseAll (eager path) and on the lazy array path
    auto eager = parseJSON(`[1, 2] {"next": true}`);
    eager.parseAll();
    assert(eager.trailingData == `{"next": true}`);
    auto lazyArr = parseJSON(`[1, 2] 3`);
    assert(lazyArr.get!long(0) == 1);
    assert(lazyArr.trailingData == "3");

    // Primitive roots
    assert(parseJSON(`"hi" !`).trailingData == "!");
    auto num = parseJSON(`42 x`);
    assert(num.get!long == 42);
    assert(num.trailingData == "x");

    // Incomplete document: trailing data is not known yet
    auto partial = parseJSON(`{"a": [1, 2`);
    assert(collectException!JSONPartialException(partial.trailingData) !is null);
    partial.appendData(`]}`);
    assert(partial.trailingData == "");
    partial.appendData(` garbage`);
    assert(partial.trailingData == "garbage");

    // The eager parser rejects trailing data
    assert(collectException!JSONSyntaxException(parseJSONComplete(`{"a": 1} xyz`)) !is null);
    assert(parseJSONComplete(`{"a": 1}   `).get!long("a") == 1);
}

// Regression tests: null promotion, streaming boundaries, number output, \u escapes, nesting depth
unittest {
    import std.exception : collectException;
    import std.array : replicate;

    // A lazily evaluated null can be promoted to object/array
    auto j = parseJSON(`{"a": null, "b": null, "c": null, "d": 1}`);
    j["a"]["x"] = 1;
    j["b"][1] = 2;
    j.set(3, "c", "y", "z");
    assert(j.toJSON() == `{"a":{"x":1},"b":[null,2],"c":{"y":{"z":3}},"d":1}`);

    // Numbers and literals split across chunks are incomplete, not invalid
    foreach (chunk; [`{"a": 1.`, `{"a": -`, `{"a": 1e`, `{"a": 1e+`]) {
        auto p = parseJSON(chunk);
        assert(collectException!JSONPartialException(p.get!double("a")) !is null, chunk);
        p.appendData(`5, "b": 2}`);
        assert(p.get!long("b") == 2);
    }
    auto lit = parseJSON(`tru`);
    assert(collectException!JSONPartialException(lit.get!bool) !is null);
    lit.appendData(`e`);
    assert(lit.get!bool == true);
    assert(collectException!JSONSyntaxException(parseJSON(`trux`).get!bool) !is null);

    // Streaming keeps working when data arrives in many small chunks
    auto s = parseJSON(`{"list": [`);
    foreach (i; 0 .. 50) s.appendData(i ? `, {"v": "x` : `{"v": "x`), s.appendData(`"}`);
    s.appendData(`], "end": true}`);
    assert(s["list"].length == 50);
    assert(s.get!string("list", 49, "v") == "x");
    assert(s.get!bool("end"));

    // Numbers round-trip exactly; NaN/infinity are written as null
    foreach (d; [3.14159265358979, 0.1, 1.0 / 3, 1e-300, 1e300, -2.5, 1e20]) {
        assert(parseJSON(JValue(d).toJSON()).get!double == d);
    }
    assert(JValue(0.1).toJSON() == "0.1");
    assert(JValue(double.nan).toJSON() == "null");
    assert(JValue(-double.infinity).toJSON() == "null");

    // Invalid hex digits in \u escapes are rejected
    assert(collectException!JSONSyntaxException(parseJSON(`"\u12zz"`).get!string) !is null);
    assert(parseJSON(`"è😀"`).get!string == "è😀");

    // Escaping does not decode UTF-8 and handles control characters
    assert(JValue("è\"\x01\n").toJSON() == `"è\"\u0001\n"`);

    // Deep nesting fails cleanly instead of overflowing the stack
    assert(collectException!JSONSyntaxException(parseJSONComplete("[".replicate(200_000))) !is null);
    auto deep = parseJSON("[".replicate(200_000));
    assert(collectException!JSONSyntaxException(deep.parseAll()) !is null);
    assert(parseJSONComplete("[".replicate(500) ~ "]".replicate(500)).length == 1);

    // has()/safe() do not throw on missing paths, but still report incomplete data
    auto h = parseJSON(`{"a": {"b": [1, 2]}}`);
    assert(h.has("a", "b", 1) && !h.has("a", "b", 2) && !h.has("a", "zz") && !h.has("/a/b/x"));
    assert(h.safe!int("a", "b", 0) == 1 && !h.safe!string("a", "b", 0).found);
    assert(collectException!JSONPartialException(parseJSON(`{"a": {"b": [1, `).has("a", "b", 5)) !is null);
}

unittest {
    // Short decimals are correctly rounded (std.conv.to!double is off by one ulp on these)
    assert(parseJSON(`6.482904`).get!double == 0x1.9ee7e62dc6e2bp+2);
    assert(parseJSON(`76.669041`).get!double == 0x1.32ad19157abb9p+6);
    assert(parseJSON(`408792230e22`).get!double == 0x1.9cc65093d4c6bp+101);

    // Fast path boundaries and fallbacks
    assert(parseJSON(`1e22`).get!double == 1e22 && parseJSON(`1e23`).get!double == 1e23);
    assert(parseJSON(`1e-22`).get!double == 1e-22 && parseJSON(`0.1`).get!double == 0.1);
    assert(parseJSON(`123456789012345.6`).get!double == 123456789012345.6);
    assert(parseJSON(`-4.556838993611245e-30`).get!double == -4.556838993611245e-30);
    assert(parseJSON(`0.00000000000000000000000000001`).get!double == 1e-29);
    auto negZero = parseJSON(`-0.0`).get!double;
    assert(negZero == 0 && negZero is -0.0);
    assert(parseJSON(`0.0e5`).get!double is 0.0);
}

unittest {
    import std.array : replicate;

    // walkJSON: typed callbacks, only selected nodes are converted
    string doc = `{"coordinates": [
        {"x": 1.5, "y": 2, "z": 3, "name": "a", "opts": {"1": [1, true]}},
        {"y": 4, "x": 2.5, "z": 5, "name": "bè", "opts": {"1": [1, true]}}
    ], "info": "some info"}`;

    double x = 0, y = 0, z = 0;
    size_t n;
    doc.walkJSON!(
        "$.coordinates[*].x", (double v) { x += v; n++; },
        "$.coordinates[*].y", (double v) { y += v; },
        "$.coordinates[*].z", (int v) { z += v; },
    );
    assert(n == 2 && x == 4 && y == 6 && z == 8);

    // Paths, unions and descendants
    string[] seen;
    doc.walkJSON!("$.coordinates[*]['x','name']", (JValue v, const(PathItem)[] path) {
        seen ~= pathToString(path) ~ "=" ~ v.toJSON();
    });
    assert(seen == [`$['coordinates'][0]['x']=1.5`, `$['coordinates'][0]['name']="a"`,
                    `$['coordinates'][1]['x']=2.5`, `$['coordinates'][1]['name']="bè"`]);

    string[] names;
    doc.walkJSON!("$..name", (string s) { names ~= s; });
    assert(names == ["a", "bè"]);

    size_t trues;
    doc.walkJSON!("$..[1]", (JValue v) { if (v.safe!bool.found) trues++; });
    assert(trues == 2); // opts["1"][1] in both elements; coordinates[1] is an object

    // Wildcards on objects and arrays, untyped lambdas receive a JValue
    size_t members;
    doc.walkJSON!("$.*", (v) { members++; });
    assert(members == 2);

    // Selected containers are lazy JValues, reported after their descendants
    string[] order;
    doc.walkJSON!(
        "$.coordinates[1]", (JValue v) { order ~= "object:" ~ v.get!string("name"); },
        "$.coordinates[1].x", (double v) { order ~= "x"; },
    );
    assert(order == ["x", "object:bè"]);

    // Several expressions on the same node run in declaration order
    string[] calls;
    doc.walkJSON!("$.info", (string s) { calls ~= "first"; }, "$['info']", (string s) { calls ~= "second"; });
    assert(calls == ["first", "second"]);

    // Root, stop, slices
    size_t roots;
    doc.walkJSON!("$", (JValue v) { roots++; assert(v.get!string("info") == "some info"); });
    assert(roots == 1);

    long[] picked;
    `[0, 1, 2, 3, 4, 5, 6, 7, 8, 9]`.walkJSON!("$[1:8:3]", (long v) { picked ~= v; });
    assert(picked == [1, 4, 7]);
    picked = null;
    `[0, 1, 2, 3, 4, 5]`.walkJSON!("$[:2, 4:, 3]", (long v) { picked ~= v; });
    assert(picked == [0, 1, 3, 4, 5]);
    picked = null;
    `[0, 1, 2]`.walkJSON!("$[::0]", (long v) { picked ~= v; });
    assert(picked.length == 0);

    picked = null;
    `[1, 2, 3, {"broken": ]`.walkJSON!("$[*]", (JValue v) {
        picked ~= v.get!long;
        return picked.length == 2 ? WalkControl.stop : WalkControl.next;
    });
    assert(picked == [1, 2]);

    // Names only match object members, indices only match array elements
    size_t hits;
    `{"0": 1, "a": [10]}`.walkJSON!("$[0]", (JValue v) { hits++; }, "$.a['0']", (JValue v) { hits++; });
    assert(hits == 0);
    `{"0": 1, "a": [10]}`.walkJSON!("$['0']", (long v) { hits += v; }, "$.a[0]", (long v) { hits += v; });
    assert(hits == 11);

    // Escaped keys and quoted names
    string got;
    `{"a\"b": "q", "città": "roma", "😀": "smile"}`.walkJSON!(
        `$['a\"b']`, (string s) { got ~= s; },
        "$.città", (string s) { got ~= "," ~ s; },
        `$["😀"]`, (string s) { got ~= "," ~ s; },
    );
    assert(got == "q,roma,smile");
    assert(PathItem("it's").toString() == `['it\'s']` && PathItem(null, 3, true).toString() == "[3]");

    // Errors: conversion, syntax in walked parts, truncation, trailing data
    assert(collectException!JSONException(`{"a": "x"}`.walkJSON!("$.a", (double v) {})) !is null);
    assert(collectException!JSONSyntaxException(`{"a": 1 "b": 2}`.walkJSON!("$.b", (double v) {})) !is null);
    assert(collectException!JSONSyntaxException(`{"a": tru}`.walkJSON!("$.a", (bool v) {})) !is null);
    assert(collectException!JSONPartialException(`{"a": [1, 2`.walkJSON!("$.a[*]", (double v) {})) !is null);
    assert(collectException!JSONPartialException(`{"a": {"b": 1`.walkJSON!("$.z", (double v) {})) !is null);
    assert(collectException!JSONSyntaxException(`{"a": 1} x`.walkJSON!("$.a", (double v) {})) !is null);
    assert(collectException!JSONException(``.walkJSON!("$.a", (double v) {})) !is null);
    assert(collectException!JSONSyntaxException(("[".replicate(2000) ~ "]".replicate(2000)).walkJSON!("$..*", (JValue v) {})) !is null);

    // Deep documents are fine when nothing below needs walking
    size_t deep;
    (`{"a": 1, "b": ` ~ "[".replicate(5000) ~ "]".replicate(5000) ~ "}").walkJSON!("$.a", (long v) { deep = v; });
    assert(deep == 1);

    // Invalid expressions are rejected at compile time
    static assert(!__traits(compiles, `[]`.walkJSON!("$[?(@.a)]", (JValue v) {})));
    static assert(!__traits(compiles, `[]`.walkJSON!("$[-1]", (JValue v) {})));
    static assert(!__traits(compiles, `[]`.walkJSON!("a.b", (JValue v) {})));
    static assert(!__traits(compiles, `[]`.walkJSON!("$.a", (JValue v) {}, "$.b")));

    import djson.jsonpath : compilePattern;
    foreach (bad; ["", "$.", "$..", "$.1a", "$[01]", "$['a'", "$[a]", "$.a[", "$[1,]", "$.[0]", `$['\q']`, `$['\uD800']`])
        assert(compilePattern(bad).error !is null, bad);
    foreach (good; ["$", "$.a.b", "$['a']['b']", "$..a", "$..*", "$..[0]", "$[*]", "$[ 1 , 'x' ]", "$[1:]", "$[::2]", "$[0]"])
        assert(compilePattern(good).error is null, good);
    assert(compilePattern("$..a[1:3]").segments.length == 2);

    // JSON Pointers follow the same rules as get(): "/" is the root, numeric tokens match
    // array indices and member names, ~0 and ~1 are decoded
    string ptr = `{"users": [{"name": "ann"}, {"name": "bob"}], "1": "one", "a/b": {"~": 7}, "": {"": 8}}`;
    string[] found;
    ptr.walkJSON!(
        "/users/1/name", (string v) { found ~= v; },
        "/1", (string v) { found ~= v; },
        "/a~1b/~0", (long v) { found ~= "seven"; },
        "/users/01/name", (string v) { found ~= "leading zero " ~ v; },
        "$.users[0].name", (string v) { found ~= v; },
        "//", (long v) { found ~= "eight"; },
    );
    assert(found == ["ann", "bob", "leading zero bob", "one", "seven", "eight"]);
    assert(parseJSON(ptr).get!string("/users/01/name") == "bob");

    size_t rootCalls;
    ptr.walkJSON!("/", (JValue v) { rootCalls++; });
    assert(rootCalls == 1);

    found = null;
    ptr.walkJSON!("/users/-", (JValue v) { found ~= "past end"; }, "/users/name", (JValue v) { found ~= "no"; });
    assert(found.length == 0);
    assert(compilePattern("/users/*").error is null); // "*" is a regular member name in a pointer
}

unittest {
    import std.algorithm : map, sum;
    import std.array : array;

    // select(): examples from RFC 9535, section 1.5
    string store = `{ "store": {
        "book": [
          { "category": "reference", "author": "Nigel Rees", "title": "Sayings of the Century", "price": 8.95 },
          { "category": "fiction", "author": "Evelyn Waugh", "title": "Sword of Honour", "price": 12.99 },
          { "category": "fiction", "author": "Herman Melville", "title": "Moby Dick", "isbn": "0-553-21311-3", "price": 8.99 },
          { "category": "fiction", "author": "J. R. R. Tolkien", "title": "The Lord of the Rings", "isbn": "0-395-19395-8", "price": 22.99 }
        ],
        "bicycle": { "color": "red", "price": 399 }
      } }`;
    auto json = parseJSON(store);

    string[] authors;
    foreach (ref v; json.select("$.store.book[*].author")) authors ~= v.get!string;
    assert(authors == ["Nigel Rees", "Evelyn Waugh", "Herman Melville", "J. R. R. Tolkien"]);
    assert(json.select("$..author").map!(v => v.get!string).array == authors);
    assert(json.select("$.store.*").length == 2);
    assert(json.select("$.store..price").map!(v => v.get!double).array == [8.95, 12.99, 8.99, 22.99, 399]);
    assert(json.select("$..book[2]")[0].get!string("title") == "Moby Dick");
    assert(json.select("$..book[-1]")[0].get!string("title") == "The Lord of the Rings");
    assert(json.select("$..book[0,1]").length == 2 && json.select("$..book[:2]").length == 2);
    assert(json.select("$..*").length == 27);
    assert(json.select("$").length == 1 && json.select("$.nothing").empty);
    assert(json.select("/store/book/0/title")[0].get!string == "Sayings of the Century");

    // Paths of the selected nodes
    string[] paths;
    foreach (path, ref v; json.select("$..isbn")) paths ~= pathToString(path);
    assert(paths == [`$['store']['book'][2]['isbn']`, `$['store']['book'][3]['isbn']`]);
    assert(pathToString(json.select("$..color").path(0)) == `$['store']['bicycle']['color']`);

    // Nodes are returned by reference and can be modified in place
    foreach (ref price; json.select("$..price")) price = JValue(price.get!double * 2);
    assert(json.get!double("/store/bicycle/price") == 798);
    assert(json.select("$..price").map!(v => v.get!double).sum == 2 * (8.95 + 12.99 + 8.99 + 22.99 + 399));

    // Slices and negative indices (RFC 9535, section 2.3.4)
    auto arr = parseJSON(`[0, 1, 2, 3, 4, 5, 6]`);
    long[] ints(string q) { return arr.select(q).map!(v => v.get!long).array; }
    assert(ints("$[1:3]") == [1, 2]);
    assert(ints("$[5:]") == [5, 6]);
    assert(ints("$[1:5:2]") == [1, 3]);
    assert(ints("$[5:1:-2]") == [5, 3]);
    assert(ints("$[::-1]") == [6, 5, 4, 3, 2, 1, 0]);
    assert(ints("$[-2:]") == [5, 6] && ints("$[:-5]") == [0, 1]);
    assert(ints("$[-1, 0, -8, 9]") == [6, 0]);
    assert(ints("$[::0]").length == 0 && ints("$[4:2]").length == 0);

    // Only the parts needed by the query are parsed
    auto lazyDoc = parseJSON(`{"a": {"b": 1}, "c": [}`);
    assert(lazyDoc.select("$.a.b")[0].get!long == 1);

    // Partial JSON: select returns what is available and reports whether more may match
    auto stream = parseJSON(`{"users":[{"name":"Alice"},{"name":"Bo`);
    auto names = stream.select("$.users[*].name");
    assert(names.length == 2 && !names.isComplete);
    assert(names[0].get!string == "Alice");
    assert(collectException!JSONPartialException(names[1].get!string) !is null); // truncated value
    assert(stream.select("$..name").length == 2 && !stream.select("$..name").isComplete);
    assert(stream.select("$.users[0].name").isComplete);
    auto missing = stream.select("$.users[2].name");
    assert(missing.empty && !missing.isComplete);
    assert(stream.select("$.other").empty && !stream.select("$.other").isComplete);
    assert(stream.select("$.users[-1]").empty);    // the final length is not known yet
    assert(stream.select("$.users[:1]").length == 1);

    stream.appendData(`b"}, {"name": "Carol"}]}`);
    names = stream.select("$.users[*].name");
    assert(names.isComplete && names.map!(v => v.get!string).array == ["Alice", "Bob", "Carol"]);
    assert(stream.select("$.users[-1].name")[0].get!string == "Carol");

    auto numbers = parseJSON(`{"a": [1, 2`).select("$.a[*]");
    assert(numbers.length == 1 && !numbers.isComplete); // 2 may still be growing
    assert(parseJSON(`{"a": 1, "b`).select("$.a").isComplete);
    assert(parseJSON(`{"a": 1, "b`).select("$.*").length == 1);
    assert(collectException!JSONSyntaxException(parseJSON(`{"a": 1 "b": 2}`).select("$.b")) !is null);

    // remove() parses lazy parents first, and refuses truncated ones without changing anything
    auto lazyParent = parseJSON(`{"a": {"b": 1, "c": 2}}`);
    assert(lazyParent.select("$.a.b").remove() == 1);
    assert(lazyParent.toJSON() == `{"a":{"c":2}}`);
    auto truncated = parseJSON(`{"a": [1, 2, 3`);
    assert(collectException!JSONPartialException(truncated.select("$.a[0]").remove()) !is null);
    truncated.appendData("]}");
    assert(truncated.toJSON() == `{"a":[1,2,3]}`);

    // Results survive further lazy parsing, and detect structural changes
    auto doc = parseJSON(`{"a": [10, 20, 30], "b": {"c": 1}}`);
    auto first = doc.select("$.a[0]");
    assert(doc.get!long("/b/c") == 1); // parses more of the root object
    first[0] = JValue(11);
    assert(doc.get!long("/a/0") == 11);
    auto last = doc.select("$.a[2]");
    doc["a"].remove(0);
    doc["a"].remove(0);
    assert(collectException!JSONException(last[0]) !is null);

    // remove(): delete all selected nodes at once
    auto users = parseJSON(`{"users": [{"name": "ann", "password": "x"}, {"name": "bob", "password": "y"}]}`);
    assert(users.select("$.users[*].password").remove() == 2);
    assert(users.toJSON() == `{"users":[{"name":"ann"},{"name":"bob"}]}`);

    auto nested = parseJSON(`{"x": {"x": 1}, "y": [{"x": 2}, 3], "z": [1, 2, 3, 4]}`);
    assert(nested.select("$..x").remove() == 3); // ancestors and descendants together
    assert(nested.select("$.z[0,0,-1]").remove() == 2); // duplicates are removed once
    assert(nested.select("$").remove() == 0);
    assert(nested.toJSON() == `{"y":[{},3],"z":[2,3]}`);

    // Invalid expressions throw
    assert(collectException!JSONException(json.select("$..book[?@.isbn]")) !is null);
    assert(collectException!JSONException(json.select("store.book")) !is null);
    assert(collectException!JSONException(json.select("$[-0]")) !is null);
    assert(collectException!JSONException(json.select("$[9007199254740992]")) !is null);

    // walkJSON rejects what needs the array length, and points to select()
    static assert(!__traits(compiles, `[]`.walkJSON!("$[-1]", (JValue v) {})));
    static assert(!__traits(compiles, `[]`.walkJSON!("$[::-1]", (JValue v) {})));
    static assert(__traits(compiles, `[]`.walkJSON!("$[1:]", (JValue v) {})));
}

@("SWAR skipping behaves exactly like byte-by-byte skipping")
unittest {
    import std.array : replicate;

    string outcome(bool swar)(string text) {
        try {
            skipValueImpl!swar(text);
            return text;
        } catch (JSONPartialException e) return "<partial>";
        catch (JSONSyntaxException e) return "<syntax>";
    }

    immutable longText = "abcdefgh".replicate(5);
    foreach (text; [
        `"` ~ longText ~ `" tail`, `"` ~ longText ~ `\"` ~ longText ~ `" tail`, `"` ~ longText,
        `"` ~ longText ~ `\`, `"` ~ longText ~ "\x01\" tail", `"` ~ longText ~ "\\\x01\" tail",
        `"` ~ longText ~ "\xc3\xa9\" tail", `"abc\"` ~ longText ~ `" tail`,
        `{"a": [1, 2, {"b": "` ~ longText ~ `]}"}], "c": "\"}"} tail`,
        `[` ~ longText ~ `, "` ~ longText ~ "\x01" ~ `"] tail`, `[[[[[[[[[[]]]]]]]]]] tail`,
        `{"a": "` ~ longText ~ `"`, `[` ~ longText, `{"a": "\`, `[}] tail`, `true tail`, `-12.5e3 tail`,
    ]) {
        foreach (cut; 0 .. text.length + 1)
            assert(outcome!false(text[0 .. cut]) == outcome!true(text[0 .. cut]), text[0 .. cut]);
    }

    // walkJSON skips unselected subtrees with it
    long sum;
    (`[{"id": 1, "name": "` ~ longText ~ `"}, {"id": 2, "skip": {"deep": ["` ~ longText ~ `"]}}]`)
        .walkJSON!("$[*].id", (long v) { sum += v; });
    assert(sum == 3);
}
