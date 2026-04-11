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
import djson.tests;
