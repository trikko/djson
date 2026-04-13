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

void main() {
    auto json = parseJSON(`{
        "user": {
            "id": 123,
            "profile": { "name": "Alice", "tags": ["admin", "beta"] }
        }
    }`);

    // 1. Read deep value (variadic or JSON pointer)
    string name = json.get!string("user", "profile", "name");
    string tag0 = json.get!string("/user/profile/tags/0");

    // 2. Check if a key or path exists
    if (json.has("user", "profile", "name")) { /* ... */ }
    bool hasEmail = json.has("/user/contact/email"); // false

    // 3. Set or update a value (auto-vivifies missing nodes)
    json.set("alice@example.com", "user", "contact", "email");
    json.set(1, "/meta/version");

    // 4. Delete a value or a whole branch
    json["user"]["profile"].remove("tags");
    json.remove("meta");

    // 5. Serialize back to JSON
    string result = json.toJSON(true); // pretty print
}
---

See_Also: djson.value, djson.parser
++/
module djson;

public import djson.value;
public import djson.parser;
public import djson.binding;
public import djson.builder;
import djson.tests;
