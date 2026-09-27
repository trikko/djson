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

/++ Internal and public parsing logic for djson.
    This module implements lazy parsing, skipping, and full eager parsing. ++/
module djson.parser;

import djson.value;
import std.string;
import std.conv;
import std.array;
import std.exception;


/++ Main entry point to parse a JSON string.
    Returns a JValue that will be parsed lazily as fields are accessed. ++/
JValue parseJSON(string data) pure @safe {
    return JValue.mkUnparsed(data);
}

/++ Helper function to strip leading JSON-standard whitespace.
    Whitespace includes space, tab, newline, and carriage return. ++/
pragma(inline, true)
public string stripJSONWhitespace(string s) @safe pure {
    if (s.length > 0 && s[0] > ' ') return s;
    size_t i = 0;
    while (i < s.length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) {
        i++;
    }
    return s[i..$];
}

package void evaluateNode(JValue* v) @trusted {
    if (v.type != JType.Unparsed) return;
    
    string s = stripJSONWhitespace(v.unparsed.raw);
    if (s.length == 0) throw new JSONPartialException("Unexpected end of JSON");

    char c = s[0];
    if (c == '{') {
        v.type = JType.Object;
        v.obj.pairs = null;
        v.obj.unparsedData = s[1..$];
        v.obj.isFullyParsed = false;
        v.obj.hasPendingTail = false;
    } else if (c == '[') {
        v.type = JType.Array;
        v.arr.elements = null;
        v.arr.unparsedData = s[1..$];
        v.arr.isFullyParsed = false;
        v.arr.hasPendingTail = false;
    } else if (c == '"') {
        string currentS = s[1..$];
        string strVal = consumeString(currentS);
        s = currentS;
        v.type = JType.String;
        v.str = strVal;
    } else if (c == 't' || c == 'f') {
        if (s.startsWith("true")) {
            s = s[4..$];
            v.type = JType.Bool;
            v.boolean = true;
        } else if (s.startsWith("false")) {
            s = s[5..$];
            v.type = JType.Bool;
            v.boolean = false;
        } else {
            throwInvalidLiteral(s, c == 't' ? "true" : "false", "Invalid boolean");
        }
    } else if (c == 'n') {
        if (s.startsWith("null")) {
            s = s[4..$];
            v.type = JType.Null;
        } else {
            throwInvalidLiteral(s, "null", "Invalid null");
        }
    } else if (isDigitChar(c) || c == '-') {
        string currentS = s;
        double numVal = consumeNumber(currentS);
        s = currentS;
        v.type = JType.Number;
        v.number = numVal;
    } else {
        throw new JSONSyntaxException("Invalid JSON token: " ~ c);
    }

    // Containers keep their tail in unparsedData (which overlaps primitive.tail)
    if (v.type != JType.Object && v.type != JType.Array) v.primitive.tail = s;
}

package bool parseNextPair(JValue* v) @trusted {
    if (v.type != JType.Object || v.obj.isFullyParsed) return false;

    if (v.obj.hasPendingTail) {
        // Last pair already registered: just advance past its (now complete) value
        string tail = v.obj.unparsedData;
        skipValue(tail);
        v.obj.unparsedData = tail;
        v.obj.hasPendingTail = false;
        return true;
    }
    
    string s = stripJSONWhitespace(v.obj.unparsedData);
    if (s.length == 0) {
        throw new JSONPartialException("Unterminated object");
    }
    
    if (s[0] == '}') {
        v.obj.isFullyParsed = true;
        v.obj.unparsedData = s[1..$]; // skip }
        return false;
    }
    
    if (v.obj.pairs.length > 0) {
        if (s[0] == ',') {
            s = stripJSONWhitespace(s[1..$]);
        } else {
            throw new JSONSyntaxException("Expected ',' between object entries");
        }
    }

    if (s.length == 0) {
        throw new JSONPartialException("Expected string as key");
    }
    if (s[0] != '"') {
        throw new JSONSyntaxException("Expected string as key");
    }
    
    s = s[1..$];
    string key = consumeString(s);
    
    s = stripJSONWhitespace(s);
    if (s.length == 0) {
        throw new JSONPartialException("Expected ':' after key");
    }
    if (s[0] != ':') {
        throw new JSONSyntaxException("Expected ':' after key");
    }
    s = stripJSONWhitespace(s[1..$]);
    
    // Now s points to the start of the value.
    // Wrap it as unparsed value.
    JValue child = JValue.mkUnparsed(s);
    
    // Strings, objects and arrays are delimited: register them even if still incomplete,
    // so that their already-received content can be navigated lazily.
    if (s.length > 0 && isDelimitedStart(s[0])) {
        string afterValue = s;
        try {
            skipValue(afterValue);
        } catch (JSONPartialException e) {
            appendChild(v.obj.pairs, JObject.Pair(key, child));
            v.obj.unparsedData = s;
            v.obj.hasPendingTail = true;
            return true;
        }
        s = afterValue;
    } else {
        // Skip to next token to update s for parent
        skipValue(s);
        
        if (stripJSONWhitespace(s).length == 0) {
            throw new JSONPartialException("Pending stream: value might be incomplete");
        }
    }
    
    appendChild(v.obj.pairs, JObject.Pair(key, child));
    v.obj.unparsedData = s;
    return true;
}

package bool parseNextElement(JValue* v) @trusted {
    if (v.type != JType.Array || v.arr.isFullyParsed) return false;

    if (v.arr.hasPendingTail) {
        // Last element already registered: just advance past it (now complete)
        string tail = v.arr.unparsedData;
        skipValue(tail);
        v.arr.unparsedData = tail;
        v.arr.hasPendingTail = false;
        return true;
    }
    
    string s = stripJSONWhitespace(v.arr.unparsedData);
    if (s.length == 0) {
        throw new JSONPartialException("Unterminated array");
    }
    
    if (s[0] == ']') {
        v.arr.isFullyParsed = true;
        v.arr.unparsedData = s[1..$]; // skip ]
        return false;
    }
    
    if (v.arr.elements.length > 0) {
        if (s[0] == ',') {
            s = stripJSONWhitespace(s[1..$]);
        } else {
            throw new JSONSyntaxException("Expected ',' between array entries");
        }
    }
    
    // s points to the start of the value.
    JValue child = JValue.mkUnparsed(s);
    
    // Strings, objects and arrays are delimited: register them even if still incomplete
    if (s.length > 0 && isDelimitedStart(s[0])) {
        string afterValue = s;
        try {
            skipValue(afterValue);
        } catch (JSONPartialException e) {
            appendChild(v.arr.elements, child);
            v.arr.unparsedData = s;
            v.arr.hasPendingTail = true;
            return true;
        }
        s = afterValue;
    } else {
        // Skip to next token to update s
        skipValue(s);
        
        if (stripJSONWhitespace(s).length == 0) {
            throw new JSONPartialException("Pending stream: value might be incomplete");
        }
    }
    
    appendChild(v.arr.elements, child);
    v.arr.unparsedData = s;
    
    return true;
}

/++ Throws JSONPartialException if `s` is a truncated prefix of `literal`, JSONSyntaxException otherwise. ++/
private void throwInvalidLiteral(string s, string literal, string msg) @safe {
    if (s.length < literal.length && literal.startsWith(s)) throw new JSONPartialException("Unterminated " ~ literal);
    throw new JSONSyntaxException(msg);
}

/++ Appends a child, reserving room for a few more on the first append to skip the early reallocations. ++/
pragma(inline, true)
private void appendChild(T)(ref T[] list, T child) @safe pure nothrow {
    if (list.length == 0) list.reserve(4);
    list ~= child;
}

/++ ASCII digit check on a `char` (std.ascii.isDigit takes a dchar and is not inlined across modules). ++/
pragma(inline, true)
package bool isDigitChar(char c) @safe pure nothrow @nogc {
    return c >= '0' && c <= '9';
}

/++ True if `c` opens a value whose end is explicitly delimited (string, object, array). ++/
pragma(inline, true)
private bool isDelimitedStart(char c) @safe pure nothrow @nogc {
    return c == '{' || c == '[' || c == '"';
}

/++  Skips the current JSON value and updates `s` to point after it.
     It works iteratively by maintaining depth. ++/
public void skipValue(ref string s) @trusted {
    s = stripJSONWhitespace(s);
    if (s.length == 0) return;
    
    char c = s[0];
    if (c == '{' || c == '[') {
        // block skipping
        int depth = 0;
        size_t i = 0;
        bool inString = false;
        
        while(i < s.length) {
            char chr = s[i];
            if (inString) {
                if (chr == '\\') i++; // skip escaped char
                else if (chr == '"') inString = false;
            } else {
                if (chr == '"') inString = true;
                else if (chr == '{' || chr == '[') depth++;
                else if (chr == '}' || chr == ']') {
                    depth--;
                    if (depth == 0) {
                        s = s[i+1..$];
                        return;
                    }
                }
            }
            i++;
        }
        throw new JSONPartialException("Unterminated block during skip");
    } else if (c == '"') {
        s = s[1..$];
        consumeStringImpl(s, false); // skips the string safely
    } else if (c == 't') { // true
        if (s.length < 4) throw new JSONPartialException("Unterminated true");
        s = s[4..$];
    } else if (c == 'f') { // false
        if (s.length < 5) throw new JSONPartialException("Unterminated false");
        s = s[5..$];
    } else if (c == 'n') { // null
        if (s.length < 4) throw new JSONPartialException("Unterminated null");
        s = s[4..$];
    } else if (isDigitChar(c) || c == '-') { // number
        size_t i = scanNumber(s);
        s = s[i..$];
    } else {
        throw new JSONSyntaxException("Invalid character during skip: " ~ c);
    }
}

private size_t scanNumber(string s) @safe {
    size_t i = 0;
    if (i < s.length && s[i] == '-') i++;
    if (i < s.length && s[i] == '0') {
        i++;
    } else if (i < s.length && s[i] >= '1' && s[i] <= '9') {
        i++;
        while(i < s.length && isDigitChar(s[i])) i++;
    } else if (i >= s.length) {
        throw new JSONPartialException("Unterminated number");
    } else {
        throw new JSONSyntaxException("Invalid number format");
    }
    
    if (i < s.length && s[i] == '.') {
        i++;
        if (i >= s.length) throw new JSONPartialException("Unterminated number");
        if (!isDigitChar(s[i])) throw new JSONSyntaxException("Invalid number format: expected digit after .");
        while(i < s.length && isDigitChar(s[i])) i++;
    }
    if (i < s.length && (s[i] == 'e' || s[i] == 'E')) {
        i++;
        if (i < s.length && (s[i] == '+' || s[i] == '-')) i++;
        if (i >= s.length) throw new JSONPartialException("Unterminated number");
        if (!isDigitChar(s[i])) throw new JSONSyntaxException("Invalid number format: expected digit after e/E");
        while(i < s.length && isDigitChar(s[i])) i++;
    }
    return i;
}

private static immutable double[23] exactPowersOf10 = [
    1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11,
    1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22
];

/++ Converts an already validated JSON number with at most 15 significant digits and a
    decimal exponent within ±22 (or, where `real` is x87 extended precision, up to 19 digits
    and ±27). Returns false when the input needs the slow path. ++/
private bool tryFastFloat(string num, out double result) @safe pure nothrow @nogc {
    size_t i = 0;
    bool neg = false;
    if (num[0] == '-') { neg = true; i++; }

    ulong mantissa = 0;
    int digits = 0;   // significant digits (leading zeros excluded)
    int exp10 = 0;

    for (; i < num.length && isDigitChar(num[i]); i++) {
        if (mantissa == 0 && num[i] == '0') continue;
        if (++digits > 19) return false;
        mantissa = mantissa * 10 + (num[i] - '0');
    }
    if (i < num.length && num[i] == '.') {
        for (i++; i < num.length && isDigitChar(num[i]); i++) {
            exp10--;
            if (mantissa == 0 && num[i] == '0') continue;
            if (++digits > 19) return false;
            mantissa = mantissa * 10 + (num[i] - '0');
        }
    }
    if (i < num.length) { // 'e' or 'E'
        i++;
        bool expNeg = false;
        if (num[i] == '+' || num[i] == '-') { expNeg = num[i] == '-'; i++; }
        int e = 0;
        for (; i < num.length; i++) {
            if (e > 1000) return false;
            e = e * 10 + (num[i] - '0');
        }
        exp10 += expNeg ? -e : e;
    }

    if (digits > 15 || exp10 > 22 || exp10 < -22) {
        static if (real.mant_dig == 64) {
            if (mantissa == 0 || !extendedFastFloat(mantissa, exp10, result)) return false;
            if (neg) result = -result;
            return true;
        } else {
            if (mantissa != 0) return false;
        }
    }

    double m = cast(double)mantissa;
    if (mantissa == 0) result = 0.0;
    else if (exp10 >= 0 && exp10 <= 22) result = m * exactPowersOf10[exp10];
    else if (exp10 < 0 && exp10 >= -22) result = m / exactPowersOf10[-exp10];
    else return false;

    if (neg) result = -result;
    return true;
}

static if (real.mant_dig == 64) {
    private static immutable real[28] exactPowersOf10Ext = () {
        real[28] p;
        p[0] = 1;
        foreach (k; 1 .. 28) p[k] = p[k - 1] * 10;
        return p;
    }();

    /++ Computes mantissa * 10^exp10 (|exp10| <= 27) in x87 extended precision: the 64-bit
        mantissa and the power of ten are exact, so the single operation is correctly rounded
        to 64 bits. Rounding that again to a double can only be wrong when the extended result
        lies exactly on a midpoint between two doubles: in that case return false. ++/
    private bool extendedFastFloat(ulong mantissa, int exp10, out double result) @trusted pure nothrow @nogc {
        if (exp10 > 27 || exp10 < -27) return false;
        real m = mantissa;
        real r = exp10 >= 0 ? m * exactPowersOf10Ext[exp10] : m / exactPowersOf10Ext[-exp10];
        ulong significand = *cast(ulong*)&r; // x87 layout: 64-bit significand in the low bytes
        if ((significand & 0x7FF) == 0x400) return false;
        result = cast(double)r;
        return true;
    }
}

/++ Consumes a number from string and returns it, mutating s ++/
private double consumeNumber(ref string s) @trusted {
    size_t len = scanNumber(s);

    // Fast path: try parsing as a simple integer in one pass (no allocation)
    {
        size_t j = 0;
        bool neg = false;
        if (j < len && s[j] == '-') { neg = true; j++; }

        long val = 0;
        bool isInt = (j < len);
        while (j < len) {
            char c = s[j];
            if (c >= '0' && c <= '9') {
                val = val * 10 + (c - '0');
            } else {
                isInt = false;
                break;
            }
            j++;
        }

        if (isInt && len <= 18) {
            s = s[len..$];
            return neg ? -cast(double)val : cast(double)val;
        }
    }

    // Fast float path (Clinger): exact when mantissa and power of ten are both exact doubles
    {
        double fast;
        if (tryFastFloat(s[0..len], fast)) {
            s = s[len..$];
            return fast;
        }
    }
    // Float path: use to!double
    string numStr = s[0..len];
    s = s[len..$];
    try {
        return to!double(numStr);
    } catch(Exception e) {
        throw new JSONSyntaxException("Invalid number format: " ~ numStr);
    }
}

package string consumeString(ref string s) @trusted {
    return consumeStringImpl(s, true);
}

/++  Helper that reads a string. Mutates s to point past the closing quote.
     If `extract` is true, allocates and returns the decoded string (or slices).
     If `extract` is false, just performs skipping. ++/
private string consumeStringImpl(ref string s, bool extract) @trusted {
    size_t i = 0;
    bool hasEscapes = false;
    
    // We scan for the closing quote.

    while(i < s.length) {
        if (s[i] < 0x20) throw new JSONSyntaxException("Unescaped control character in string");
        if (s[i] == '\\') {
            hasEscapes = true;
            i += 2; // skip escape
            continue;
        }
        if (s[i] == '"') {
            break;
        }
        i++;
    }
    if (i >= s.length) throw new JSONPartialException("Unterminated string");
    
    string rawSlice = s[0..i];
    s = s[i+1..$]; // skip quote
    
    if (!extract) return null;
    
    if (!hasEscapes) {
        return rawSlice; // Zero-allocation slice!
    }
    
    // Need to decode escapes
    Appender!string app = appender!string();
    size_t j = 0;
    while(j < rawSlice.length) {
        if (rawSlice[j] == '\\') {
            j++;
            if (j >= rawSlice.length) throw new JSONSyntaxException("Invalid escape sequence");
            char ec = rawSlice[j];
            switch(ec) {
                case '"': app.put('"'); break;
                case '\\': app.put('\\'); break;
                case '/': app.put('/'); break;
                case 'b': app.put('\b'); break;
                case 'f': app.put('\f'); break;
                case 'n': app.put('\n'); break;
                case 'r': app.put('\r'); break;
                case 't': app.put('\t'); break;
                case 'u':
                    // Just accept u sequences as raw chars for now or decode utf16
                    // A proper full implementation would decode UTF-16 surrogates to UTF-8
                    if (j + 4 >= rawSlice.length) throw new JSONSyntaxException("Invalid unicode escape");
                    uint val = parseHex4(rawSlice[j+1 .. j+5]);
                    j += 4;
                    
                    if (val >= 0xD800 && val <= 0xDBFF) {
                        // High surrogate, expect low surrogate
                        if (j + 6 < rawSlice.length && rawSlice[j+1] == '\\' && rawSlice[j+2] == 'u') {
                            uint val2 = parseHex4(rawSlice[j+3 .. j+7]);
                            if (val2 >= 0xDC00 && val2 <= 0xDFFF) {
                                val = 0x10000 + ((val - 0xD800) << 10) + (val2 - 0xDC00);
                                j += 6;
                            } else {
                                throw new JSONSyntaxException("Invalid low surrogate");
                            }
                        } else {
                            throw new JSONSyntaxException("Expected low surrogate after high surrogate");
                        }
                    } else if (val >= 0xDC00 && val <= 0xDFFF) {
                        throw new JSONSyntaxException("Unexpected low surrogate");
                    }
                    
                    app.put(cast(dchar)val);
                    break;
                default: throw new JSONSyntaxException("Invalid escape character: " ~ ec);
            }
        } else {
            app.put(rawSlice[j]);
        }
        j++;
    }
    return app.data;
}

/++ Decodes exactly 4 hex digits of a \u escape. ++/
private uint parseHex4(string hex) @safe pure {
    uint val = 0;
    foreach (h; hex) {
        uint d;
        if (h >= '0' && h <= '9') d = h - '0';
        else if (h >= 'a' && h <= 'f') d = h - 'a' + 10;
        else if (h >= 'A' && h <= 'F') d = h - 'A' + 10;
        else throw new JSONSyntaxException("Invalid unicode escape: \\u" ~ hex);
        val = (val << 4) | d;
    }
    return val;
}

/++  Fully parse JSON string eagerly (no lazy evaluation).
     Returns a completely parsed JValue in a single pass — faster than parseJSON + parseAll(). ++/
JValue parseJSONComplete(string data) @trusted {
    string s = data;
    s = stripJSONWhitespace(s);
    if (s.length == 0) throw new JSONException("Empty JSON input");
    JValue result = parseValueFull(s);
    if (stripJSONWhitespace(s).length > 0) throw new JSONSyntaxException("Unexpected data after end of JSON");
    return result;
}

/++ Maximum nesting depth accepted by the eager parser (guards against stack overflow). ++/
enum maxNestingDepth = 1000;

package JValue parseValueFull(ref string s, uint depth = 0) @trusted {
    s = stripJSONWhitespace(s);
    if (s.length == 0) throw new JSONPartialException("Unexpected end of JSON");

    char c = s[0];
    if (c == '{' || c == '[') {
        if (depth >= maxNestingDepth) throw new JSONSyntaxException("Nesting too deep");
        return c == '{' ? parseObjectFull(s, depth + 1) : parseArrayFull(s, depth + 1);
    }
    JValue v;
    parseScalarInto(s, &v);
    return v;
}

/++ Parses the non-container value at the start of `s` (already stripped and non-empty) straight
    into `*dest`, which must be zero-initialized. Writing in place instead of returning a JValue
    avoids a store-forwarding stall when the caller copies the result into its scratch slot. ++/
pragma(inline, true)
private void parseScalarInto(ref string s, JValue* dest) @trusted {
    char c = s[0];
    if (c == '"') {
        s = s[1..$];
        dest.str = consumeString(s);
        dest.type = JType.String;
    } else if (isDigitChar(c) || c == '-') {
        dest.number = consumeNumber(s);
        dest.type = JType.Number;
    } else if (c == 't') {
        if (s.length < 4 || s[0..4] != "true") throw new JSONSyntaxException("Invalid boolean");
        s = s[4..$];
        dest.boolean = true;
        dest.type = JType.Bool;
    } else if (c == 'f') {
        if (s.length < 5 || s[0..5] != "false") throw new JSONSyntaxException("Invalid boolean");
        s = s[5..$];
        dest.boolean = false;
        dest.type = JType.Bool;
    } else if (c == 'n') {
        if (s.length < 4 || s[0..4] != "null") throw new JSONSyntaxException("Invalid null");
        s = s[4..$];
        dest.type = JType.Null;
    } else {
        throw new JSONSyntaxException("Invalid JSON token: " ~ c);
    }
}

/++ Per-thread scratch stacks used by the eager parser to collect the children of the containers
    being parsed, so that each container gets a single exact-size allocation instead of growing
    its array one append at a time. Nested containers use the slice above their parent's. ++/
private JValue[] valueScratch;
private size_t valueTop;  /// ditto
private JObject.Pair[] pairScratch; /// ditto
private size_t pairTop;   /// ditto

/++ Claims the next (zeroed) scratch slot and returns a pointer to it. The pointer is only valid
    until the next claim, which may move the stack. ++/
pragma(inline, true)
private T* claimScratch(T)(ref T[] stack, ref size_t top) @trusted {
    if (top == stack.length) {
        auto grown = new T[](stack.length ? stack.length * 2 : 256);
        grown[0 .. top] = stack[0 .. top];
        stack = grown;
    }
    return &stack[top++];
}

pragma(inline, true)
private void pushScratch(T)(ref T[] stack, ref size_t top, T item) @trusted {
    *claimScratch(stack, top) = item;
}

/++ Releases the scratch entries above `base`, clearing them so they don't keep GC memory alive. ++/
pragma(inline, true)
private void popScratch(T)(T[] stack, ref size_t top, size_t base) @trusted {
    stack[base .. top] = T.init;
    top = base;
}

/++ Per-thread bump allocator for the children arrays of eagerly parsed containers: small arrays
    are carved out of shared GC chunks, avoiding one GC allocation (and lock) per container.
    The chunks are plain GC memory, so they live as long as any array sliced from them. ++/
private void[] arenaChunk;
private size_t arenaUsed;  /// ditto
private enum arenaChunkSize = 64 * 1024;
private enum arenaMaxItemSize = 2 * 1024;

private T[] arenaCopy(T)(T[] items) @trusted {
    import core.memory : GC;
    import core.stdc.string : memcpy;

    if (items.length == 0) return null;
    immutable bytes = items.length * T.sizeof;
    if (bytes > arenaMaxItemSize) return items.dup;

    immutable offset = (arenaUsed + 15) & ~cast(size_t)15;
    if (offset + bytes > arenaChunk.length) {
        arenaChunk = GC.calloc(arenaChunkSize)[0 .. arenaChunkSize];
        arenaUsed = 0;
        return arenaCopy(items);
    }
    arenaUsed = offset + bytes;
    auto dest = arenaChunk.ptr + offset;
    memcpy(dest, items.ptr, bytes);
    return (cast(T*)dest)[0 .. items.length];
}

private JValue parseObjectFull(ref string s, uint depth) @trusted {
    s = s[1..$]; // skip '{'
    JValue v;
    v.type = JType.Object;
    v.obj.isFullyParsed = true;

    s = stripJSONWhitespace(s);
    if (s.length == 0) throw new JSONPartialException("Unterminated object");
    if (s[0] == '}') {
        s = s[1..$];
        return v;
    }

    immutable base = pairTop;
    scope(failure) popScratch(pairScratch, pairTop, base);

    while (true) {
        s = stripJSONWhitespace(s);
        if (s.length == 0 || s[0] != '"')
            throw new JSONSyntaxException("Expected string as key");
        s = s[1..$]; // skip opening quote
        string key = consumeString(s);

        s = stripJSONWhitespace(s);
        if (s.length == 0 || s[0] != ':')
            throw new JSONSyntaxException("Expected ':' after key");
        s = s[1..$]; // skip ':'

        s = stripJSONWhitespace(s);
        if (s.length == 0) throw new JSONPartialException("Unexpected end of JSON");
        if (s[0] == '{' || s[0] == '[') {
            pushScratch(pairScratch, pairTop, JObject.Pair(key, parseValueFull(s, depth)));
        } else {
            // The slot is claimed before parsing so that a failure clears it too
            auto slot = claimScratch(pairScratch, pairTop);
            slot.key = key;
            parseScalarInto(s, &slot.value);
        }

        s = stripJSONWhitespace(s);
        if (s.length == 0) throw new JSONPartialException("Unterminated object");
        if (s[0] == '}') {
            s = s[1..$];
            break;
        }
        if (s[0] != ',') throw new JSONSyntaxException("Expected ',' between object entries");
        s = s[1..$]; // skip ','
    }
    v.obj.pairs = arenaCopy(pairScratch[base .. pairTop]);
    popScratch(pairScratch, pairTop, base);
    return v;
}

private JValue parseArrayFull(ref string s, uint depth) @trusted {
    s = s[1..$]; // skip '['
    JValue v;
    v.type = JType.Array;
    v.arr.isFullyParsed = true;

    s = stripJSONWhitespace(s);
    if (s.length == 0) throw new JSONPartialException("Unterminated array");
    if (s[0] == ']') {
        s = s[1..$];
        return v;
    }

    immutable base = valueTop;
    scope(failure) popScratch(valueScratch, valueTop, base);

    while (true) {
        s = stripJSONWhitespace(s);
        if (s.length == 0) throw new JSONPartialException("Unexpected end of JSON");
        if (s[0] == '{' || s[0] == '[') pushScratch(valueScratch, valueTop, parseValueFull(s, depth));
        else parseScalarInto(s, claimScratch(valueScratch, valueTop));

        s = stripJSONWhitespace(s);
        if (s.length == 0) throw new JSONPartialException("Unterminated array");
        if (s[0] == ']') {
            s = s[1..$];
            break;
        }
        if (s[0] != ',') throw new JSONSyntaxException("Expected ',' between array entries");
        s = s[1..$]; // skip ','
    }
    v.arr.elements = arenaCopy(valueScratch[base .. valueTop]);
    popScratch(valueScratch, valueTop, base);
    return v;
}
