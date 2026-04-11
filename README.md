# djson

A lazy JSON parser for the D programming language. Parses only what you access: no wasted work.

## Features

- **Lazy parsing**: only the fields you access get parsed. Perfect for extracting a few values from large JSON payloads
- **Eager mode**: call `parseAll()` for a fully-parsed tree when you need everything
- **Insertion-order preservation**: object keys always iterate in the original JSON order
- **Fluent access API**: variadic arguments and JSON pointer paths (`/a/b/0`)
- **Safe access**: `.safe!T()` returns a result with a `.found` flag instead of throwing
- **Resumable Streaming Parsing**: append data to a partial JSON object and resume parsing seamlessly
- **Mutation**: set values, add keys, remove branches, then serialize back to JSON
- **`std.json` interop**: convert to/from `std.json.JSONValue` when needed
- **Strict JSON compliance**: passes 283/283 tests from the [JSONTestSuite](https://github.com/nst/JSONTestSuite)
- **Performance**: faster than `std.json`

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

// Set by JSON pointer path (auto-vivifies intermediate nodes)
json.set(42, "/x/y/z");

// Overwrite nested objects
json["a"] = parseJSON(`{"nested": true}`);

// Remove keys and array elements
json.remove("b");

auto arr = parseJSON(`[1, 2, 3, 4, 5]`);
arr.remove(cast(size_t) 2);  // removes element at index 2 → [1, 2, 4, 5]
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
