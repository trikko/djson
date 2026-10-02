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

/++ High-performance, lazy JSON library for D.

Example:
---
import djson;

@JSON struct Profile {        // all public fields are bound
    string name;
    string[] tags;
    @JSONOptional int age;    // keeps its init value if missing
}

void main() {
    // Lazy: only the parts you access are parsed (parseJSONComplete parses everything at once)
    auto json = parseJSON(`{
        "user": {
            "id": 123,
            "profile": { "name": "Alice", "tags": ["admin", "beta"] }
        },
        "orders": [ { "total": 9.5 }, { "total": 20 } ]
    }`);

    // 1. Read deep values (variadic or JSON pointer), or a default if missing
    string name = json.get!string("user", "profile", "name");
    string tag0 = json.get!string("/user/profile/tags/0");
    long   karma = json.safe!long("user", "karma").or(0);

    // 2. Check if a key or path exists
    if (json.has("user", "profile", "name")) { /* ... */ }
    bool hasEmail = json.has("/user/contact/email"); // false

    // 3. Iterate objects and arrays
    foreach (string key, ref value; json["user"]) { /* "id", "profile" */ }
    foreach (size_t i, ref order; json["orders"]) { /* ... */ }

    // 4. Query with JSONPath: results are references, editable in place
    double sum = 0;
    foreach (ref total; json.select("$.orders[*].total")) sum += total.get!double;

    // 5. Bind to D types and back
    Profile p = fromJSON!Profile(json["user"]["profile"]);
    JValue pj = toJSON(p);

    // 6. Set or update values (auto-vivifies missing nodes) and build new ones
    json.set("alice@example.com", "user", "contact", "email");
    json.set(1, "/meta/version");
    json["orders"] ~= JSOB("total", 5, "items", JSAB("pen", "ink"));

    // 7. Delete a value or a whole branch
    json["user"]["profile"].remove("tags");
    json.remove("meta");

    // 8. Serialize back to JSON
    string result = json.toJSON(true); // pretty print
}
---

To read large documents in a single pass without building a tree, see `walkJSON`.
For truncated input arriving from a stream, see `JValue.appendData`.

See_Also: djson.value, djson.parser, djson.jsonpath, djson.walk, djson.binding, djson.builder
++/
module djson;

public import djson.value;
public import djson.parser;
public import djson.binding;
public import djson.builder;
public import djson.jsonpath;
public import djson.walk;
import djson.tests;
