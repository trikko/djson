# djson

A lazy JSON parser for the D programming language. Parses only what you access: no wasted work.

## Features

- **Lazy parsing**: only the fields you access get parsed. Perfect for extracting a few values from large JSON payloads
- **Eager mode**: call `parseAll()` for a fully-parsed tree when you need everything
- **Insertion-order preservation**: object keys always iterate in the original JSON order
- **Fluent access API**: variadic arguments and JSON pointer paths (`/a/b/0`)
- **Safe access**: `.safe!T()` returns a result with a `.found` flag instead of throwing
- **Resumable Streaming Parsing**: append data to a partial JSON object and resume parsing seamlessly
- **Binding**: bind D structs and classes to JSON objects and arrays
- **Mutation**: set values, add keys, remove branches, then serialize back to JSON
- **Interop with `std.json`**: convert to/from `std.json.JSONValue` when needed
- **Strict JSON compliance**: passes 283/283 tests from the [JSONTestSuite](https://github.com/nst/JSONTestSuite)
- **Performance**: faster than `std.json`

## Documentation

- [API Reference](https://trikko.github.io/djson/djson.html)

## Installation

```
dub add djson
```

## Quick Start

```d
import djson;

auto json = parseJSON(`{
    "name": "djson",
    "version": 1,
    "features": ["lazy", "fast", "safe"],
    "config": {"debug": false, "maxDepth": 64}
}`);

// Access values: only the accessed fields are parsed
string name = json.get!string("name");         // "djson"
int ver = json.get!int("version");             // 1
string feat = json.get!string("features", 1);  // "fast"
bool dbg = json.get!bool("config", "debug");   // false
```

## API Reference

### Parsing

```d
// Lazy parse: returns immediately, parses on demand
auto json = parseJSON(`{"key": "value"}`);

// Eager parse: fully parses the entire tree in one pass
json.parseAll();
```

### Partial Streaming & Resumable Parsing

DJSON supports parsing partial JSON strings from a stream. If the parser hits the end of the provided string while a value is still being read, it throws a `JSONPartialException`. You can then append more data and resume parsing exactly where it left off.

```d
// Start with a partial JSON string
auto json = parseJSON(`{"hello": "world", "partial" :`);

// Accessing a completed key works
writeln(json.get!string("hello")); // "world"

// Accessing an incomplete key throws JSONPartialException
try {
    json.get!string("partial");
} catch (JSONPartialException e) {
    // Current chunk is incomplete, need more data
}

// Append the rest of the stream
json.appendData(`"world"}`);

// Now it works!
writeln(json.get!string("partial")); // "world"
```

This works by leveraging the lazy nature of the parser: DJSON only resumes parsing for the node that was actually interrupted.

### Reading Values

```d
auto json = parseJSON(`{"user": {"name": "Alice", "age": 30}, "tags": ["admin"]}`);

// Direct access
string name = json.get!string("user", "name");  // variadic path
int age = json.get!int("user", "age");

// JSON pointer syntax
string name2 = json.get!string("/user/name");
string tag = json.get!string("/tags/0");

// Safe access (never throws)
auto result = json.safe!string("user", "email");
if (result.found) {
    writeln(result.value);
} else {
    writeln("not found");
}

// With default fallback
string email = json.safe!string("user", "email").or("n/a");

// Operator []
auto user = json["user"];
string n = user["name"].get!string;
```

### Checking Existence

```d
auto json = parseJSON(`{"a": 1, "b": null, "list": [10, 20]}`);

json.has("a")           // true
json.has("missing")     // false
json.has("a", "sub")    // false: "a" is not an object
json.has("/list/0")     // true: JSON pointer
json.has("list", 1)     // true: variadic with index

// Null checking
json["b"].isNull        // true
json["a"].isNull        // false
```

### Iteration

```d
// Array iteration
auto arr = parseJSON(`[10, 20, 30]`);
foreach (el; arr) {
    writeln(el.get!int);
}

// Array with index
foreach (size_t i, el; arr) {
    writefln("[%d] = %d", i, el.get!int);
}

// Object iteration: preserves insertion order
auto obj = parseJSON(`{"z": 1, "a": 2, "m": 3}`);
foreach (string key, val; obj) {
    writefln("%s = %d", key, val.get!int);
}
// Output: z = 1, a = 2, m = 3 (insertion order, not alphabetical)
```

### Mutation

```d
auto json = parseJSON(`{"a": 1}`);

// Set by key
json["b"] = "hello";
json["c"] = true;

// Appending to arrays (auto-promotes primitives to arrays)
json["a"] ~= 2; // "a" became [1, 2]

// Set/Append by JSON pointer path (auto-vivifies intermediate nodes)
json.set(42, "/x/y/z");
json.append("item", "/list/tags"); // creates {"list": {"tags": ["item"]}}

// Overwrite nested objects
json["a"] = parseJSON(`{"nested": true}`);

// Remove keys and array elements
json.remove("b");

auto arr = parseJSON(`[1, 2, 3, 4, 5]`);
arr.remove(2);  // removes element at index 2 → [1, 2, 4, 5]
```

### Construction (Builders)

DJSON provides a concise way to build JSON structures manually using `JSOB` (JSON Object Builder) and `JSAB` (JSON Array Builder).

```d
import djson;

// Build a complex JSON structure fluently
auto json = JSOB(
    "name", "djson",
    "version", 1,
    "features", JSAB("lazy", "fast", "safe"),
    "metadata", JSOB(
        "author", "Andrea Fontana",
        "tags", JSAB(1, 2, 3)
    )
);

// Add to an existing object
json["new_key"] = "new_value";
```

### Serialization

```d
auto json = parseJSON(`{"b": 2, "a": 1}`);
json["c"] = 3;

// Compact
json.toJSON();       // `{"b":2,"a":1,"c":3}`

// Pretty-printed
json.toJSON(true);
// {
//     "b": 2,
//     "a": 1,
//     "c": 3
// }
```

### Interoperability with std.json

```d
import std.json;
import djson;

auto json = djson.parseJSON(`{"key": "value"}`);
JSONValue stdVal = json.toStdJSON();

assert(stdVal["key"].str == "value");
```

### JSON Binding

DJSON provides a binding system to convert between D structs/classes and `JValue`.

#### Basic Usage

You can then use `fromJSON!T` to create a D object from a `JValue`, and `toJSON` to create a `JValue` from a D object.

```d
import djson;

struct User {
    // You can also apply @JSON to the whole struct/class.
    // Here we apply it to a block of fields.
    @JSON {
        string name;
        int age;
    }

    // This field is not included by default
    string other;
}

// Convert from JValue to struct
auto json = parseJSON(`{"name": "Alice", "age": 30}`);
User u = fromJSON!User(json);

assert(u.name == "Alice");
assert(u.age == 30);

u.age = 35;

// Convert from struct to JValue
JValue v = toJSON(u);
assert(v["name"].get!string == "Alice");
```

#### UDAs for Customization

The binding system can be customized using User Defined Attributes (UDAs):

- `@JSON`: If applied to a struct or class, all public fields are included by default. If applied to a field, that field is included even if it's not public or the parent isn't marked with `@JSON`. It also supports custom paths via variadic arguments or JSON pointers (e.g., `@JSON("path", "to", "key")`, `@JSON("/path/to/key")`).
- `@JSONIgnore`: Explicitly exclude a field from binding.
- `@JSONOptional`: If the field is missing in the JSON input, `fromJSON` will not throw an exception and will leave the field with its default `.init` value. Supports the same path mapping as `@JSON`.
- `@JSONPreProcess!func`: Apply a custom transformation function when reading from JSON. The function must have the signature `FieldType func(JValue v)`.
- `@JSONPostProcess!func`: Apply a custom transformation function when writing to JSON. The function must have the signature `JValue func(FieldType v)`.

```d
import djson;
import djson.binding;
import std.string : toUpper;

@JSON
struct Config {
    // Rename field in JSON
    @JSON("max_threads") int threads;
    
    // Optional field with default value
    @JSONOptional string host = "localhost";
    
    // Ignore this field
    @JSONIgnore string internalKey;
    
    // Custom pre-processing (e.g., uppercase a string)
    @JSONPreProcess!((v) => v.get!string.toUpper)
    string category;
}

auto json = parseJSON(`{"max_threads": 8, "category": "production"}`);
Config cfg = fromJSON!Config(json);

assert(cfg.threads == 8);
assert(cfg.host == "localhost");
assert(cfg.category == "PRODUCTION");
```

#### Deep Path Binding

`@JSONKey` supports variadic arguments and JSON pointers to bind D fields directly to nested JSON structures. You can also bind entire sub-structs for a more organized data model.

```d
@JSON
struct Profile {
    string name;
    int level;
}

struct GameData {
    // Bind to a deep path using JSON Pointer
    @JSON("/server/status/code") 
    int statusCode;

    // Bind using variadic segments, including array indices
    @JSON("players", 0, "name") 
    string firstPlayerName;

    // Bind using JSON Pointer for the second player
    @JSON("/players/1/name")
    string secondPlayerName;

    // Bind an entire substructure
    @JSON 
    Profile leader;
}

auto json = parseJSON(`{
    "server": {"status": {"code": 200}},
    "leader": {"name": "Alice", "level": 10},
    "players": [
        {"name": "Bob", "level": 5},
        {"name": "Charlie", "level": 8}
    ]
}`);

GameData data = fromJSON!GameData(json);
assert(data.statusCode == 200);
assert(data.firstPlayerName == "Bob");
assert(data.secondPlayerName == "Charlie");
assert(data.leader.name == "Alice");

// Serialization preserves the deep structure
JValue v = toJSON(data);
assert(v.get!int("/server/status/code") == 200);
assert(v.get!string("players", 0, "name") == "Bob");
```

## Building & Testing

```bash
# Run unit tests
dub test

# Run with LDC2 for best performance
dub test --compiler=ldc2

# Run benchmarks (in external_tests/) against std.json
cd external_tests
./run_benchmark.d          # JSONTestSuite benchmark
./run_real_bench.d         # Real-world benchmark (auto-downloads data)
./run_speed_test_large.d   # Large string benchmark
./run_nst_suite.d          # JSON compliance test suite
./run_compare.d            # Value comparison with std.json
```

## License

MIT: see LICENSE for details.
