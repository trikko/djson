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

/++ Single-pass, callback-based traversal of a JSON document.

    `walkJSON` reads the document once, without building a tree, and calls a
    callback for every node selected by a JSONPath (RFC 9535) expression or
    a JSON Pointer (RFC 6901).
    Subtrees that no expression can reach are skipped without decoding them.

Example:
---
double x = 0, y = 0;
size_t n;
text.walkJSON!(
    "$.coordinates[*].x", (double v) { x += v; n++; },
    "$.coordinates[*].y", (double v) { y += v; },
);
---

Expressions starting with `/` are JSON Pointers and select a single node, with
the same rules as `JValue.get` (`/users/1/name`). Expressions starting with `$`
are JSONPath. Supported JSONPath subset: `$`, `.name`, $(D_INLINECODE ['name']), `[n]`, `[*]`, `.*`,
descendants (`..name`, `..*`, `..[n]`), unions (`['a','b']`, `[0,2]`) and
slices with non-negative bounds (`[1:5]`, `[::2]`). Filters (`[?...]`) and
negative indices need data that is not available in a single pass, so they
are rejected at compile time (`JValue.select` supports negative indices).
++/
module djson.walk;

import djson.value;
import djson.parser;
import djson.jsonpath;
import std.traits;

/++ Value a callback can return to control the traversal. ++/
enum WalkControl {
    next, /++ Keep walking (same as returning nothing) ++/
    stop  /++ Stop the traversal immediately ++/
}

/++  Walks `text` once, calling each callback for the nodes selected by its JSONPath.

     `Handlers` alternates expressions and callbacks:
     `walkJSON!("$.a", cb1, "$.b[*]", cb2, "/c/0", cb3)(text)`. An expression is
     a JSONPath (starting with `$`) or a JSON Pointer (starting with `/`).

     A callback takes the node value and, optionally, its path:
     `(T value)` or `(T value, const(PathItem)[] path)`. `T` selects the
     conversion, exactly like `JValue.get!T` (`double`, `long`, `string`,
     `bool`, `JValue`, ...); untyped lambdas receive a `JValue`. Objects and
     arrays are passed as lazy `JValue`s over the original text. A callback
     may return `WalkControl.stop` to end the traversal.

     When several expressions select the same node, their callbacks run in
     declaration order. A selected object or array is reported after the
     callbacks for its own descendants.

     As with lazy parsing, subtrees that no expression can reach are only
     skipped, so malformed content inside them is not reported.

     Throws: `JSONSyntaxException` on invalid JSON, `JSONPartialException` on
     truncated input, `JSONException` if a value cannot be converted to the
     callback parameter type. ++/
void walkJSON(Handlers...)(string text) {
    static assert(Handlers.length > 0 && Handlers.length % 2 == 0,
        "walkJSON expects pairs of expressions and callbacks");
    static foreach (i; 0 .. Handlers.length / 2) {
        static assert(is(typeof(Handlers[2 * i]) : string),
            "walkJSON: argument " ~ (2 * i).stringof ~ " must be a JSONPath or JSON Pointer string");
    }

    Walker!Handlers walker;
    walker.run(text);
}

/++ Compiles an expression at compile time, turning syntax errors into compile errors. ++/
private template CompiledPattern(string path) {
    enum compiled = compilePattern(path);
    static assert(compiled.error is null, "Invalid expression `" ~ path ~ "`: " ~ compiled.error);
    enum unsupported = walkUnsupported(compiled.segments);
    static assert(unsupported is null, "Expression `" ~ path ~ "` cannot be used with walkJSON: " ~ unsupported);
    static immutable Segment[] segments = compiled.segments;
}

/++ Selectors that need the length of an array cannot be evaluated in a single pass. ++/
private string walkUnsupported(const(Segment)[] segments) @safe pure nothrow @nogc {
    foreach (ref seg; segments) {
        foreach (ref sel; seg.selectors) {
            if (sel.kind == Selector.Kind.index && sel.index < 0)
                return "negative indices need the array length (use JValue.select)";
            if (sel.kind == Selector.Kind.slice && ((sel.hasStart && sel.start < 0) || (sel.hasEnd && sel.end < 0) || sel.step < 0))
                return "negative slice bounds and steps need the array length (use JValue.select)";
        }
    }
    return null;
}

/++ True if `sel` selects the child reached through `item`. Negative values are rejected at compile time. ++/
pragma(inline, true)
private bool matches(ref const Selector sel, ref const PathItem item) @safe pure nothrow @nogc {
    final switch (sel.kind) {
        case Selector.Kind.name: return !item.isIndex && item.key == sel.name;
        case Selector.Kind.index: return item.isIndex && item.index == sel.index;
        case Selector.Kind.wildcard: return true;
        case Selector.Kind.slice:
            long i = cast(long)item.index;
            return item.isIndex && sel.step > 0 && i >= sel.start && (!sel.hasEnd || i < sel.end)
                && (i - sel.start) % sel.step == 0;
        case Selector.Kind.pointerToken:
            return item.isIndex ? sel.tokenIsIndex && item.index == sel.index : item.key == sel.name;
    }
}

/++  Moves the matching state of a pattern from a node to one of its children.
     Bit `i` of a mask means "the first `i` segments match the path so far". ++/
pragma(inline, true)
private ulong advance(const(Segment)[] pattern, ulong mask, ref const PathItem item) @safe pure nothrow @nogc {
    ulong next = 0;
    foreach (i, ref seg; pattern) {
        if (!(mask & (1UL << i))) continue;
        if (seg.descendant) next |= 1UL << i;
        foreach (ref sel; seg.selectors) {
            if (matches(sel, item)) {
                next |= 1UL << (i + 1);
                break;
            }
        }
    }
    return next;
}

/++ True if a callback accepts the node path as a second argument. ++/
private template takesPath(alias cb) {
    static if (isSomeFunction!cb) enum takesPath = Parameters!cb.length == 2;
    else enum takesPath = __traits(compiles, cb(JValue.init, (const(PathItem)[]).init));
}

private struct Walker(Handlers...) {
    enum count = Handlers.length / 2;
    alias Masks = ulong[count];

    static immutable const(Segment)[][count] patterns = () {
        const(Segment)[][count] result;
        static foreach (h; 0 .. count) result[h] = CompiledPattern!(Handlers[2 * h]).segments;
        return result;
    }();

    enum needsPath = () {
        bool any;
        static foreach (h; 0 .. count) any = any || takesPath!(Handlers[2 * h + 1]);
        return any;
    }();

    string s;
    bool stopped;
    static if (needsPath) PathItem[] path;

    void run(string text) {
        s = stripJSONWhitespace(text);
        if (s.length == 0) throw new JSONException("Empty JSON input");

        Masks masks = 1; // every pattern starts with zero segments matched
        walkValue(masks, 0);
        if (!stopped && stripJSONWhitespace(s).length > 0)
            throw new JSONSyntaxException("Unexpected data after end of JSON");
    }

    void walkValue(ref const Masks masks, uint depth) {
        s = stripJSONWhitespace(s);
        if (s.length == 0) throw new JSONPartialException("Unexpected end of JSON");

        bool matched, live;
        static foreach (h; 0 .. count) {
            matched = matched || (masks[h] & (1UL << patterns[h].length)) != 0;
            live = live || (masks[h] & ((1UL << patterns[h].length) - 1)) != 0;
        }

        char c = s[0];
        if (c == '{' || c == '[') {
            if (!live) {
                if (!matched) { skipValue(s); return; }
                string start = s;
                skipValue(s);
                dispatch(masks, JValue.mkUnparsed(start[0 .. start.length - s.length]), depth);
                return;
            }
            if (depth >= maxNestingDepth) throw new JSONSyntaxException("Nesting too deep");
            string start = s;
            if (c == '{') walkObject(masks, depth);
            else walkArray(masks, depth);
            if (matched && !stopped) dispatch(masks, JValue.mkUnparsed(start[0 .. start.length - s.length]), depth);
        } else if (matched) {
            dispatch(masks, parseValueFull(s, depth), depth);
        } else {
            skipValue(s);
        }
    }

    void walkObject(ref const Masks masks, uint depth) {
        s = stripJSONWhitespace(s[1 .. $]); // skip '{'
        if (s.length == 0) throw new JSONPartialException("Unterminated object");
        if (s[0] == '}') { s = s[1 .. $]; return; }

        while (true) {
            s = stripJSONWhitespace(s);
            if (s.length == 0) throw new JSONPartialException("Unterminated object");
            if (s[0] != '"') throw new JSONSyntaxException("Expected string as key");
            s = s[1 .. $];
            PathItem item = PathItem(consumeString(s));

            s = stripJSONWhitespace(s);
            if (s.length == 0) throw new JSONPartialException("Expected ':' after key");
            if (s[0] != ':') throw new JSONSyntaxException("Expected ':' after key");
            s = s[1 .. $];

            walkChild(masks, item, depth);
            if (stopped) return;

            s = stripJSONWhitespace(s);
            if (s.length == 0) throw new JSONPartialException("Unterminated object");
            if (s[0] == '}') { s = s[1 .. $]; return; }
            if (s[0] != ',') throw new JSONSyntaxException("Expected ',' between object entries");
            s = s[1 .. $];
        }
    }

    void walkArray(ref const Masks masks, uint depth) {
        s = stripJSONWhitespace(s[1 .. $]); // skip '['
        if (s.length == 0) throw new JSONPartialException("Unterminated array");
        if (s[0] == ']') { s = s[1 .. $]; return; }

        PathItem item;
        item.isIndex = true;
        while (true) {
            walkChild(masks, item, depth);
            if (stopped) return;
            item.index++;

            s = stripJSONWhitespace(s);
            if (s.length == 0) throw new JSONPartialException("Unterminated array");
            if (s[0] == ']') { s = s[1 .. $]; return; }
            if (s[0] != ',') throw new JSONSyntaxException("Expected ',' between array entries");
            s = s[1 .. $];
        }
    }

    pragma(inline, true)
    void walkChild(ref const Masks masks, ref const PathItem item, uint depth) {
        Masks childMasks;
        static foreach (h; 0 .. count) childMasks[h] = advance(patterns[h], masks[h], item);
        static if (needsPath) {
            if (path.length <= depth) path.length = depth + 16;
            path[depth] = item;
        }
        walkValue(childMasks, depth + 1);
    }

    void dispatch(ref const Masks masks, JValue value, uint depth) {
        static if (needsPath) const(PathItem)[] current = path[0 .. depth];
        else const(PathItem)[] current = null;

        static foreach (h; 0 .. count) {
            if (!stopped && (masks[h] & (1UL << patterns[h].length))) {
                if (invoke!(Handlers[2 * h + 1])(value, current) == WalkControl.stop) stopped = true;
            }
        }
    }
}

/++ Converts the node to the callback parameter type and calls it. ++/
private WalkControl invoke(alias cb)(JValue value, const(PathItem)[] path) {
    static if (isSomeFunction!cb) {
        alias Params = Parameters!cb;
        static assert(Params.length == 1 || Params.length == 2,
            "walkJSON callbacks take (value) or (value, const(PathItem)[] path)");
        static if (Params.length == 2) static assert(is(const(PathItem)[] : Params[1]),
            "walkJSON: the second callback parameter must be const(PathItem)[]");

        alias T = Unqual!(Params[0]);
        static if (is(T == JValue)) T arg = value;
        else T arg = value.get!T;

        static if (Params.length == 2) alias call = () => cb(arg, path);
        else alias call = () => cb(arg);
    } else {
        static if (takesPath!cb) alias call = () => cb(value, path);
        else alias call = () => cb(value);
    }

    static if (is(typeof(call()) == WalkControl)) return call();
    else {
        call();
        return WalkControl.next;
    }
}
