---
name: djson
description: Official reference for djson, the lazy JSON parser and serializer for the D programming language (pure D, JSON Pointer and JSONPath, single-pass walker, struct binding, mutation, streaming, std.json interop). Use it whenever the user asks about djson, or about reading, writing or querying JSON in D.
---

# djson

djson is a lazy JSON parser and serializer for the D programming language, in pure D,
with no dependencies. Version 0.9.5.

Read the reference before writing djson code. It is two files:

- **`llms-full.txt`** — the whole API in one file: parsing, reading, iteration, JSONPath,
  `walkJSON`, binding, builders, mutation, streaming, `std.json` interop, worked examples.
  This is the one to read.
  <https://trikko.github.io/djson/llms-full.txt>
- **`llms.txt`** — a page of overview, when the full one is more than you need.
  <https://trikko.github.io/djson/llms.txt>

In the packaged skill both sit next to this file; installed from the web, fetch
them from the addresses above.

djson is not `std.json`, `vibe.data.json` or `asdf`: if you remember their API, don't
mix it in. What follows are the rules that are easiest to get wrong.

## Shape of a program

```d
import djson;
import std.stdio;

void main()
{
    auto json = parseJSON(`{"user": {"name": "Alice", "tags": ["admin"]}, "orders": [{"total": 9.5}]}`);

    string name = json.get!string("user", "name");          // variadic path
    string tag  = json.get!string("/user/tags/0");           // JSON Pointer
    string mail = json.safe!string("user", "email").or("");  // no exception if missing

    foreach (ref total; json.select("$.orders[*].total"))    // JSONPath
        total = JValue(total.get!double * 2);

    json.set("alice@example.com", "user", "email");
    writeln(json.toJSON(true));
}
```

`dub add djson`. Everything is in `import djson;`.

## Names that clash with std.json

- `std.json` also has `parseJSON`, `toJSON` and `JSONException`: importing both modules
  makes the calls ambiguous (`parseJSON matches conflicting symbols`). Use
  `static import std.json;` (or a selective import of `JSONValue`) next to `import djson;`.

## Lazy parsing

- `parseJSON(text)` does not parse anything: it returns a lazy `JValue`, and each access
  parses only what it needs. Syntax errors are found when the broken part is read, and a
  part that is never read is never validated.
- `parseJSONComplete(text)` parses and validates everything at once (one pass, faster than
  `parseJSON` + `parseAll()`): use it when you will read most of the document or must
  reject invalid input.
- Text after the document is not an error for `parseJSON` (see `trailingData()`), it is for
  `parseJSONComplete`.

## Reading

- `get!T(path...)` throws `JSONException` if the path is missing or the type is wrong
  (`get!string` on a number, `get!int` on `null`). `safe!T(path...)` never throws for
  that: check `.found` or use `.or(fallback)`. `has(path...)` is true for a `null` value too;
  `isNull` tells them apart.
- A path is either variadic (`"users", 0, "name"`) or one JSON Pointer string starting
  with `/` (`"/users/0/name"`, `~1` for `/` and `~0` for `~` in keys). A single string
  without `/` is a plain key. JSONPath (`$...`) only works with `select` and `walkJSON`.
- Numbers are stored as `double`. `get!int` / `get!long` truncate (`3.7` → `3`) and
  integers above 2^53 lose precision: read them as strings if they must be exact.
- `json["key"]` and `json[0]` throw `JSONException` when missing; `getPtr("key")` returns
  `null` instead.
- `JSONPartialException` and `JSONSyntaxException` derive from `JSONException`: catch the
  specific ones first.

## Changing values

- `JValue` is a struct. `auto u = json["user"];` makes a copy that may or may not share
  data with the document, depending on what was already parsed: changes to the copy are
  not reliably visible in `json`. Change the document through it:
  `json["user"]["name"] = "Bob";`, `json.set("Bob", "user", "name");`,
  `foreach (ref v; ...)`, `ref JValue u = json["user"];` (D 2.111+) or
  `JValue* u = &json["user"];`.
- `foreach (el; arr)` gives copies; use `foreach (ref el; arr)` to change elements.
- `set(value, path...)` creates missing objects and arrays; an index past the end pads
  the array with `null`. To add at the end of an array use `append(value, path...)` or
  `json["list"] ~= value` (JSON Pointer `-` is not supported). `~=` on a non-array value
  turns it into an array `[old, new]`.
- `remove("key")` / `remove(index)` work on the node itself:
  `json["user"].remove("tags")`, not `json.remove("user", "tags")`.
- `toJSON()` on a `JValue` gives a string (`toJSON(true)`: indented). The free function
  `toJSON(x)` converts a D value to a `JValue`, so `myStruct.toJSON()` is a `JValue`:
  `myStruct.toJSON().toJSON()` is its JSON text.

## Binding structs

- Only fields marked for binding are converted: put `@JSON` on the struct (all public
  fields) or on each field. Without it `fromJSON!T` returns `T.init` **without any error**.
- A bound field missing from the JSON throws `JSONException`; mark it `@JSONOptional` to
  keep its `init` value. Keys in the JSON that no field uses are ignored.
- `@JSON("name")` renames, `@JSON("/a/b/0")` or `@JSON("a", "b", 0)` binds a nested
  value; `@JSONIgnore` excludes a field; `@JSONPreProcess!fn` / `@JSONPostProcess!fn`
  convert on the way in (`FieldType fn(JValue)`) and out (`JValue fn(FieldType)`).
- Classes need a default constructor.

## JSONPath and walkJSON

- `select("$..price")` returns references to the matching nodes, parsing only what the
  query needs; `select(...).remove()` deletes them. Filters (`[?...]`) are not supported.
- `walkJSON!(path, callback, ...)(text)` reads the text once without building a tree. The
  paths are template arguments, checked at compile time; negative indices, negative slice
  steps and filters are rejected there: use `select` for those. The callback parameter
  type picks the conversion (`(double v)`, `(string s)`, `(JValue v)`); return
  `WalkControl.stop` to end early.

## Streaming

- On truncated input reading the missing part throws `JSONPartialException`: call
  `appendData(moreText)` on the root and read again. Complete parts stay readable.
  `select` returns what is available and sets `isComplete` to false.

## std.json

- `json.toStdJSON()` gives a `std.json.JSONValue`; `JValue(jsonValue)` converts back, and a
  `JSONValue` can be assigned or `set` directly. `JSONValue` objects have no order, so the
  members come back sorted by key.

## Common mistakes

| Wrong | Right |
|---|---|
| `import std.json; import djson;` | `static import std.json; import djson;` |
| `json["a"]["b"].str`, `json["n"].integer` | `json.get!string("a", "b")`, `json.get!long("n")` |
| `json.get!string("a.b.c")`, `json.get!string("$.a.b")` | `json.get!string("a", "b", "c")` or `json.get!string("/a/b/c")` |
| `if ("k" in json)` | `if (json.has("k"))` |
| `json.get!string("k", "default")` | `json.safe!string("k").or("default")` |
| `try json["k"] catch ...` to test a key | `json.has("k")`, `json.getPtr("k") !is null` |
| `auto u = json["user"]; u["n"] = 1;` | `json["user"]["n"] = 1;` or `json.set(1, "user", "n");` |
| `foreach (el; json["list"]) el = ...` | `foreach (ref el; json["list"]) el = ...` |
| `struct S { int a; } fromJSON!S(json)` | `@JSON struct S { int a; }` |
| `json.toString(true)`, `json.toPrettyString` | `json.toJSON(true)` |
| `json.set(x, "/list/-")` | `json.append(x, "list")` or `json["list"] ~= x` |
| `json.remove("user", "tags")` | `json["user"].remove("tags")` |
| `json.select("$.a[?(@.x > 1)]")` | `foreach (ref v; json.select("$.a[*]")) if (v.get!double("x") > 1) ...` |
