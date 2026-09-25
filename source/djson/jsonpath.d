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

/++ JSONPath (RFC 9535) support: expression compiler and queries over a `JValue` tree.

    The same compiler is used by `JValue.select` and by `walkJSON`; `get`, `set` and the
    other path-based methods keep using JSON Pointers. It also accepts
    JSON Pointers (expressions starting with `/`), with the same rules as `JValue.get`.

    Supported syntax: `$`, `.name`, `['name']`, `[n]` (negative counts from the end),
    `[*]`, `.*`, descendants (`..name`, `..*`, `..[n]`), unions (`['a','b']`, `[0,2]`)
    and slices (`[1:5]`, `[::-1]`). Filter expressions (`[?...]`) are not supported.
++/
module djson.jsonpath;

import djson.value;
import djson.parser : isDigitChar, maxNestingDepth, parseNextPair, parseNextElement;

/++ One step of the path from the root to a node. ++/
struct PathItem {
    string key;   /++ Member name, when the node is inside an object ++/
    size_t index; /++ Element index, when the node is inside an array ++/
    bool isIndex; /++ True if the node is an array element ++/

    /++ Normalized JSONPath form of the step, e.g. `['name']` or `[3]`. ++/
    string toString() const @safe pure {
        import std.conv : to;
        return isIndex ? "[" ~ index.to!string ~ "]" : "['" ~ escapePathKey(key) ~ "']";
    }
}

/++ Normalized JSONPath of a node, e.g. `$['coordinates'][3]['x']`. ++/
string pathToString(const(PathItem)[] path) @safe pure {
    string result = "$";
    foreach (item; path) result ~= item.toString();
    return result;
}

/++  Nodes selected by `JValue.select`, in JSONPath result order.

     Iterate with `foreach (ref v; result)` (or `foreach (path, ref v; result)` to
     also get the normalized path of each node). Nodes are returned by reference,
     so they can be modified in place.

     Each node is located by its position from the queried node, so results stay
     valid while other parts of the document are read or values are changed.
     Removing members or elements, or replacing a container that holds a result,
     invalidates the results that depend on it: accessing them throws `JSONException`.

     On truncated input the nodes available so far are returned and `isComplete` is false. ++/
struct JSONPathResult {
    private JValue* root;
    private size_t[] positions; // child positions of every match, concatenated
    private size_t[] ends;      // match i spans positions[ends[i - 1] .. ends[i]]
    private size_t first;       // current front, for the range interface
    private bool complete = true;

    /++  False if the document is truncated where the query needed data (see `JValue.appendData`):
         more nodes may match once the rest arrives. Nodes whose value is itself truncated are
         included; reading them throws `JSONPartialException`, like `get`. ++/
    @property bool isComplete() const @safe pure nothrow @nogc { return complete; }

    /++ Number of selected nodes. ++/
    @property size_t length() const @safe pure nothrow @nogc { return ends.length - first; }

    /++ True if no node was selected. ++/
    @property bool empty() const @safe pure nothrow @nogc { return first >= ends.length; }

    /++ Range interface: first selected node. ++/
    @property ref JValue front() { return this[0]; }

    /++ Range interface: drops the first selected node. ++/
    void popFront() @safe pure nothrow @nogc { first++; }

    /++ The `i`-th selected node. ++/
    ref JValue opIndex(size_t i) {
        if (i >= length) throw new JSONException("JSONPath result index out of bounds");
        return *resolve(first + i);
    }

    /++ Path of the `i`-th selected node. ++/
    PathItem[] path(size_t i) {
        if (i >= length) throw new JSONException("JSONPath result index out of bounds");
        const(size_t)[] pos = positionsOf(first + i);
        PathItem[] result = new PathItem[pos.length];
        JValue* current = root;
        foreach (k, p; pos) {
            JValue* parent = current;
            current = child(parent, p);
            result[k] = parent.type == JType.Object ? PathItem(parent.obj.pairs[p].key) : PathItem(null, p, true);
        }
        return result;
    }

    /++ Iterates the selected nodes by reference. ++/
    int opApply(scope int delegate(ref JValue) dg) {
        foreach (i; 0 .. length) {
            if (auto r = dg(*resolve(first + i))) return r;
        }
        return 0;
    }

    /++ Iterates the selected nodes with their paths. ++/
    int opApply(scope int delegate(const(PathItem)[], ref JValue) dg) {
        foreach (i; 0 .. length) {
            if (auto r = dg(path(i), *resolve(first + i))) return r;
        }
        return 0;
    }

    /++  Removes the selected nodes from their parents and returns how many were removed.
         The queried node itself is never removed. The result is empty afterwards.
         Throws: `JSONPartialException`, without removing anything, if a parent is truncated. ++/
    size_t remove() {
        import std.algorithm : sort, uniq;
        import std.array : array;

        size_t[][] targets;
        foreach (i; first .. ends.length) {
            auto pos = positionsOf(i);
            if (pos.length > 0) targets ~= pos.dup;
        }

        // Deepest and rightmost first, so that removing a node never shifts a position still to be removed
        targets = targets.sort!((a, b) => a > b).uniq.array;

        // Lazy parents must be fully parsed first: the parser relies on the children already read.
        // Parsing only appends, so the positions stay valid. Truncated parents throw here, before any change.
        foreach (pos; targets) {
            JValue* parent = resolvePositions(pos[0 .. $ - 1]);
            if (parent.type == JType.Object) while (!parent.obj.isFullyParsed) parseNextPair(parent);
            else if (parent.type == JType.Array) while (!parent.arr.isFullyParsed) parseNextElement(parent);
        }

        foreach (pos; targets) {
            JValue* parent = resolvePositions(pos[0 .. $ - 1]);
            size_t p = pos[$ - 1];
            child(parent, p); // validates the position
            if (parent.type == JType.Object) parent.obj.pairs = parent.obj.pairs[0 .. p] ~ parent.obj.pairs[p + 1 .. $];
            else parent.arr.elements = parent.arr.elements[0 .. p] ~ parent.arr.elements[p + 1 .. $];
        }
        first = ends.length;
        return targets.length;
    }

    private const(size_t)[] positionsOf(size_t match) const @safe pure nothrow @nogc {
        return positions[match == 0 ? 0 : ends[match - 1] .. ends[match]];
    }

    private JValue* resolve(size_t match) {
        return resolvePositions(positionsOf(match));
    }

    private JValue* resolvePositions(const(size_t)[] pos) {
        JValue* current = root;
        foreach (p; pos) current = child(current, p);
        return current;
    }

    private static JValue* child(JValue* node, size_t pos) {
        if (node.type == JType.Object && pos < node.obj.pairs.length) return &node.obj.pairs[pos].value;
        if (node.type == JType.Array && pos < node.arr.elements.length) return &node.arr.elements[pos];
        throw new JSONException("JSONPath result is no longer valid: the document structure has changed");
    }
}

/++ A parsed JSONPath selector (one entry of a bracket list). ++/
package struct Selector {
    enum Kind : ubyte { name, index, wildcard, slice, pointerToken }
    Kind kind;
    string name;           // Kind.name, Kind.pointerToken
    long index;            // Kind.index (negative counts from the end), Kind.pointerToken if tokenIsIndex
    long start, end;       // Kind.slice, meaningful only if hasStart / hasEnd
    long step = 1;         // Kind.slice (0 selects nothing)
    bool hasStart, hasEnd; // Kind.slice
    bool tokenIsIndex;     // Kind.pointerToken: the token is also a valid array index
}

/++ A parsed JSONPath segment: `.name`, `[...]`, or their `..` (descendant) forms. ++/
package struct Segment {
    Selector[] selectors;
    bool descendant;
}

/++ Result of compiling an expression. `error` is null on success. ++/
package struct CompiledPath {
    Segment[] segments;
    string error;
}

/++ Longest supported expression: `walkJSON` keeps the matching state in a 64-bit mask. ++/
package enum maxPathSegments = 63;

/++ Compiles an expression, throwing `JSONException` if it is invalid. ++/
package CompiledPath compileOrThrow(string path) @safe pure {
    CompiledPath compiled = compilePattern(path);
    if (compiled.error !is null) throw new JSONException("Invalid JSONPath `" ~ path ~ "`: " ~ compiled.error);
    return compiled;
}

/++ Parses a JSONPath expression or a JSON Pointer. Works at compile time and at run time. ++/
package CompiledPath compilePattern(string path) @safe pure {
    CompiledPath fail(string msg, size_t at) {
        import std.conv : to;
        return CompiledPath(null, msg ~ " at position " ~ at.to!string);
    }

    if (path.length > 0 && path[0] == '/') return compilePointer(path);
    if (path.length == 0 || path[0] != '$') return fail("expression must start with '$' (JSONPath) or '/' (JSON Pointer)", 0);

    Segment[] segments;
    size_t i = 1;
    while (i < path.length) {
        Segment seg;
        string error;
        if (path[i] == '.') {
            i++;
            if (i < path.length && path[i] == '.') { seg.descendant = true; i++; }
            if (i >= path.length) return fail("expected a name, '*' or '[' after '.'", i);
            if (path[i] == '*') {
                seg.selectors = [Selector(Selector.Kind.wildcard)];
                i++;
            } else if (path[i] == '[') {
                if (!seg.descendant) return fail("unexpected '[' after '.'", i);
                seg.selectors = parseBracket(path, i, error);
            } else {
                size_t start = i;
                while (i < path.length && isNameChar(path[i])) i++;
                if (i == start || isDigitChar(path[start])) return fail("invalid member name", start);
                seg.selectors = [Selector(Selector.Kind.name, path[start .. i])];
            }
        } else if (path[i] == '[') {
            seg.selectors = parseBracket(path, i, error);
        } else {
            return fail("unexpected character '" ~ path[i .. i + 1] ~ "'", i);
        }
        if (error !is null) return fail(error, i);
        if (segments.length >= maxPathSegments) return fail("expression has too many segments", i);
        segments ~= seg;
    }
    return CompiledPath(segments, null);
}

/++ Compiles a JSON Pointer with the same rules as `JValue.get`: `/` alone is the root, and a
    numeric token selects both an array index and an object member with that name. ++/
private CompiledPath compilePointer(string path) @safe pure {
    import std.algorithm : splitter;
    if (path == "/") return CompiledPath(null, null);

    Segment[] segments;
    foreach (token; path[1 .. $].splitter('/')) {
        if (segments.length >= maxPathSegments) return CompiledPath(null, "JSON Pointer has too many segments");
        Selector sel = Selector(Selector.Kind.pointerToken, JValue.decodePointerToken(token));
        sel.tokenIsIndex = token.length > 0;
        foreach (c; token) {
            if (!isDigitChar(c) || sel.index > (long.max - 9) / 10) { sel.tokenIsIndex = false; break; }
            sel.index = sel.index * 10 + (c - '0');
        }
        segments ~= Segment([sel]);
    }
    return CompiledPath(segments, null);
}

// JSONPath member-name-shorthand characters (non-ASCII bytes are part of UTF-8 names)
private bool isNameChar(char c) @safe pure nothrow @nogc {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || isDigitChar(c) || c == '_' || c >= 0x80;
}

private bool isPathSpace(char c) @safe pure nothrow @nogc {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

/++ Parses `[...]` starting at `path[i] == '['`; on failure sets `error` and leaves `i` at the problem. ++/
private Selector[] parseBracket(string path, ref size_t i, ref string error) @safe pure {
    Selector[] selectors;
    i++; // skip '['
    while (true) {
        while (i < path.length && isPathSpace(path[i])) i++;
        if (i >= path.length) { error = "unterminated '['"; return null; }

        char c = path[i];
        if (c == '\'' || c == '"') {
            string name = parseQuoted(path, i, error);
            if (error !is null) return null;
            selectors ~= Selector(Selector.Kind.name, name);
        } else if (c == '*') {
            selectors ~= Selector(Selector.Kind.wildcard);
            i++;
        } else if (c == '?') {
            error = "filter expressions are not supported";
            return null;
        } else if (isDigitChar(c) || c == '-' || c == ':') {
            Selector sel;
            bool hasFirst;
            long first = parseInteger(path, i, hasFirst, error);
            if (error !is null) return null;
            if (i < path.length && path[i] == ':') {
                sel.kind = Selector.Kind.slice;
                sel.hasStart = hasFirst;
                sel.start = first;
                i++;
                sel.end = parseInteger(path, i, sel.hasEnd, error);
                if (error !is null) return null;
                if (i < path.length && path[i] == ':') {
                    i++;
                    bool hasStep;
                    long step = parseInteger(path, i, hasStep, error);
                    if (error !is null) return null;
                    if (hasStep) sel.step = step;
                }
            } else if (hasFirst) {
                sel.kind = Selector.Kind.index;
                sel.index = first;
            } else {
                error = "invalid selector";
                return null;
            }
            selectors ~= sel;
        } else {
            error = "invalid selector";
            return null;
        }

        while (i < path.length && isPathSpace(path[i])) i++;
        if (i >= path.length) { error = "unterminated '['"; return null; }
        if (path[i] == ']') { i++; return selectors; }
        if (path[i] != ',') { error = "expected ',' or ']'"; return null; }
        i++;
    }
}

/++ Parses an optional integer as defined by RFC 9535: no leading zeros, no `-0`, within ±(2^53 - 1). ++/
private long parseInteger(string path, ref size_t i, out bool found, ref string error) @safe pure {
    enum long maxExactInt = (1L << 53) - 1;
    while (i < path.length && isPathSpace(path[i])) i++;
    bool negative = i < path.length && path[i] == '-';
    if (negative) i++;

    size_t start = i;
    long value = 0;
    while (i < path.length && isDigitChar(path[i])) {
        value = value * 10 + (path[i] - '0');
        if (value > maxExactInt) { error = "integer out of range"; return 0; }
        i++;
    }
    found = i > start;
    if (negative && !found) { error = "expected digits after '-'"; return 0; }
    if (found && path[start] == '0' && (i - start > 1 || negative)) error = "leading zeros are not allowed in integers";
    while (i < path.length && isPathSpace(path[i])) i++;
    return negative ? -value : value;
}

/++ Parses a quoted member name starting at the opening quote, decoding escapes. ++/
private string parseQuoted(string path, ref size_t i, ref string error) @safe pure {
    char quote = path[i++];
    string result;
    while (i < path.length && path[i] != quote) {
        char c = path[i];
        if (c < 0x20) { error = "control character in quoted name"; return null; }
        if (c != '\\') { result ~= c; i++; continue; }

        i++;
        if (i >= path.length) break;
        switch (path[i]) {
            case 'b': result ~= '\b'; break;
            case 'f': result ~= '\f'; break;
            case 'n': result ~= '\n'; break;
            case 'r': result ~= '\r'; break;
            case 't': result ~= '\t'; break;
            case '/': result ~= '/'; break;
            case '\\': result ~= '\\'; break;
            case '\'': result ~= '\''; break;
            case '"': result ~= '"'; break;
            case 'u':
                uint cp;
                if (!parseHexEscape(path, i, cp)) { error = "invalid \\u escape"; return null; }
                if (cp >= 0xD800 && cp <= 0xDBFF) {
                    uint low;
                    if (i + 2 >= path.length || path[i + 1] != '\\' || path[i + 2] != 'u') {
                        error = "unpaired surrogate in \\u escape";
                        return null;
                    }
                    i += 2;
                    if (!parseHexEscape(path, i, low) || low < 0xDC00 || low > 0xDFFF) {
                        error = "invalid low surrogate in \\u escape";
                        return null;
                    }
                    cp = 0x10000 + ((cp - 0xD800) << 10) + (low - 0xDC00);
                } else if (cp >= 0xDC00 && cp <= 0xDFFF) {
                    error = "unpaired surrogate in \\u escape";
                    return null;
                }
                result ~= encodeUTF8(cp);
                break;
            default:
                error = "invalid escape in quoted name";
                return null;
        }
        i++;
    }
    if (i >= path.length) { error = "unterminated quoted name"; return null; }
    i++; // closing quote
    return result;
}

/++ Reads the 4 hex digits after `path[i] == 'u'`, leaving `i` on the last digit. ++/
private bool parseHexEscape(string path, ref size_t i, out uint value) @safe pure nothrow @nogc {
    if (i + 4 >= path.length) return false;
    foreach (k; 1 .. 5) {
        char h = path[i + k];
        uint d;
        if (h >= '0' && h <= '9') d = h - '0';
        else if (h >= 'a' && h <= 'f') d = h - 'a' + 10;
        else if (h >= 'A' && h <= 'F') d = h - 'A' + 10;
        else return false;
        value = (value << 4) | d;
    }
    i += 4;
    return true;
}

private string encodeUTF8(uint cp) @safe pure {
    char[] buf;
    if (cp < 0x80) buf = [cast(char)cp];
    else if (cp < 0x800) buf = [cast(char)(0xC0 | (cp >> 6)), cast(char)(0x80 | (cp & 0x3F))];
    else if (cp < 0x10000) buf = [cast(char)(0xE0 | (cp >> 12)), cast(char)(0x80 | ((cp >> 6) & 0x3F)),
        cast(char)(0x80 | (cp & 0x3F))];
    else buf = [cast(char)(0xF0 | (cp >> 18)), cast(char)(0x80 | ((cp >> 12) & 0x3F)),
        cast(char)(0x80 | ((cp >> 6) & 0x3F)), cast(char)(0x80 | (cp & 0x3F))];
    return buf.idup;
}

private string escapePathKey(string key) @safe pure {
    import std.format : format;
    string result;
    foreach (char c; key) {
        if (c == '\'' || c == '\\') result ~= "\\" ~ c;
        else if (c < 0x20) result ~= format("\\u%04x", c);
        else result ~= c;
    }
    return result;
}

// ---------------------------------------------------------------------------
// Queries over a JValue tree
// ---------------------------------------------------------------------------

private struct Node {
    JValue* value;
    size_t[] positions; // child positions from the queried node
}

/++ State of a running query. ++/
private struct Query {
    Node[] output;
    bool complete = true; // false once any data needed by the query turned out to be truncated
}

/++  Evaluates a compiled expression from `root`, following RFC 9535 result order.

     Children are parsed lazily when a segment has a single name or non-negative index
     selector; otherwise the node's children are parsed completely first, so that
     pointers already collected into them cannot be moved by later parsing.

     Truncated input never throws: the nodes available so far are returned and the
     result is marked as incomplete. ++/
package JSONPathResult selectCompiled(JValue* root, const(Segment)[] segments) {
    Node[] nodes = [Node(root, null)];
    Query q;
    foreach (ref seg; segments) {
        q.output = null;
        foreach (ref node; nodes) {
            if (seg.descendant) selectDescendants(q, node, seg.selectors, 0);
            else applySelectors(q, node, seg.selectors);
        }
        nodes = q.output;
        if (nodes.length == 0) break;
    }

    JSONPathResult result;
    result.root = root;
    result.complete = q.complete;
    foreach (ref node; nodes) {
        result.positions ~= node.positions;
        result.ends ~= result.positions.length;
    }
    return result;
}

private void selectDescendants(ref Query q, ref Node node, const(Selector)[] selectors, uint depth) {
    if (depth >= maxNestingDepth) throw new JSONSyntaxException("Nesting too deep");
    applySelectors(q, node, selectors);

    JValue* v = node.value;
    parseChildren(q, v); // a truncated container still exposes the children received so far
    size_t count = v.type == JType.Object ? v.obj.pairs.length : v.type == JType.Array ? v.arr.elements.length : 0;
    foreach (p; 0 .. count) {
        Node child = childNode(node, p);
        selectDescendants(q, child, selectors, depth + 1);
    }
}

private void applySelectors(ref Query q, ref Node node, const(Selector)[] selectors) {
    JValue* v = node.value;
    if (!evaluate(q, v) || (v.type != JType.Object && v.type != JType.Array)) return;

    // A single name or non-negative index can be resolved lazily
    if (selectors.length == 1) {
        const sel = selectors[0];
        if (v.type == JType.Object && (sel.kind == Selector.Kind.name || sel.kind == Selector.Kind.pointerToken)) {
            ptrdiff_t p = findMember(q, v, sel.name);
            if (p >= 0) q.output ~= childNode(node, p);
            return;
        }
        if (v.type == JType.Array && ((sel.kind == Selector.Kind.index && sel.index >= 0)
                || (sel.kind == Selector.Kind.pointerToken && sel.tokenIsIndex))) {
            size_t idx = cast(size_t)sel.index;
            if (findElement(q, v, idx)) q.output ~= childNode(node, idx);
            return;
        }
    }

    // A truncated container still exposes the children received so far, but its final
    // length is unknown: selectors counting from the end are skipped
    bool lengthKnown = parseChildren(q, v);
    foreach (ref sel; selectors) {
        if (v.type == JType.Object) {
            final switch (sel.kind) {
                case Selector.Kind.name, Selector.Kind.pointerToken:
                    foreach (p, ref pair; v.obj.pairs) {
                        if (pair.key == sel.name) { q.output ~= childNode(node, p); break; }
                    }
                    break;
                case Selector.Kind.wildcard:
                    foreach (p; 0 .. v.obj.pairs.length) q.output ~= childNode(node, p);
                    break;
                case Selector.Kind.index, Selector.Kind.slice:
                    break;
            }
        } else {
            long len = cast(long)v.arr.elements.length;
            final switch (sel.kind) {
                case Selector.Kind.index:
                    if (sel.index < 0 && !lengthKnown) break;
                    long idx = sel.index < 0 ? len + sel.index : sel.index;
                    if (idx >= 0 && idx < len) q.output ~= childNode(node, cast(size_t)idx);
                    break;
                case Selector.Kind.pointerToken:
                    if (sel.tokenIsIndex && sel.index < len) q.output ~= childNode(node, cast(size_t)sel.index);
                    break;
                case Selector.Kind.wildcard:
                    foreach (p; 0 .. v.arr.elements.length) q.output ~= childNode(node, p);
                    break;
                case Selector.Kind.slice:
                    bool fromEnd = (sel.hasStart && sel.start < 0) || (sel.hasEnd && sel.end < 0) || sel.step < 0;
                    if (!fromEnd || lengthKnown) applySlice(q, node, sel, len);
                    break;
                case Selector.Kind.name:
                    break;
            }
        }
    }
}

/++ Array slice as defined by RFC 9535 (negative bounds count from the end, negative step reverses). ++/
private void applySlice(ref Query q, ref Node node, ref const Selector sel, long len) {
    long step = sel.step;
    if (step == 0) return;

    long normalize(long i) { return i >= 0 ? i : len + i; }
    long clamp(long i, long lo, long hi) { return i < lo ? lo : i > hi ? hi : i; }

    if (step > 0) {
        long lower = clamp(sel.hasStart ? normalize(sel.start) : 0, 0, len);
        long upper = clamp(sel.hasEnd ? normalize(sel.end) : len, 0, len);
        for (long i = lower; i < upper; i += step) q.output ~= childNode(node, cast(size_t)i);
    } else {
        long upper = clamp(sel.hasStart ? normalize(sel.start) : len - 1, -1, len - 1);
        long lower = clamp(sel.hasEnd ? normalize(sel.end) : -len - 1, -1, len - 1);
        for (long i = upper; lower < i; i += step) q.output ~= childNode(node, cast(size_t)i);
    }
}

/++ Evaluates a lazy node. Returns false (and marks the query incomplete) if its data is truncated. ++/
private bool evaluate(ref Query q, JValue* v) {
    try {
        v.evaluateSelf();
        return true;
    } catch (JSONPartialException e) {
        q.complete = false;
        return false;
    }
}

/++ Position of the first member named `key`, parsing the object only as far as needed. ++/
private ptrdiff_t findMember(ref Query q, JValue* v, string key) {
    foreach (p, ref pair; v.obj.pairs) {
        if (pair.key == key) return p;
    }
    try {
        while (!v.obj.isFullyParsed && parseNextPair(v)) {
            if (v.obj.pairs[$ - 1].key == key) return v.obj.pairs.length - 1;
        }
    } catch (JSONPartialException e) {
        q.complete = false;
    }
    return -1;
}

/++ True if the array has an element at `idx`, parsing it only as far as needed. ++/
private bool findElement(ref Query q, JValue* v, size_t idx) {
    try {
        while (!v.arr.isFullyParsed && v.arr.elements.length <= idx) parseNextElement(v);
    } catch (JSONPartialException e) {
        q.complete = false;
    }
    return idx < v.arr.elements.length;
}

/++ Parses all the children received so far. Returns false (and marks the query incomplete) if the node is truncated. ++/
private bool parseChildren(ref Query q, JValue* v) {
    if (!evaluate(q, v)) return false;
    try {
        if (v.type == JType.Object) while (!v.obj.isFullyParsed) parseNextPair(v);
        else if (v.type == JType.Array) while (!v.arr.isFullyParsed) parseNextElement(v);
        return true;
    } catch (JSONPartialException e) {
        q.complete = false;
        return false;
    }
}

private Node childNode(ref Node node, size_t p) {
    JValue* v = node.value;
    JValue* child = v.type == JType.Object ? &v.obj.pairs[p].value : &v.arr.elements[p];
    return Node(child, node.positions ~ p);
}
