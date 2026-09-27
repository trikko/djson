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

/++ Full 64x64 -> 128 bit product, as [low, high]. ++/
pragma(inline, true)
private ulong[2] mul128(ulong a, ulong b) @trusted pure nothrow @nogc {
    version (LDC) {
        import ldc.llvmasm : __ir_pure;
        return __ir_pure!(`%a = zext i64 %0 to i128
            %b = zext i64 %1 to i128
            %m = mul i128 %a, %b
            %lo = trunc i128 %m to i64
            %s = lshr i128 %m, 64
            %hi = trunc i128 %s to i64
            %r0 = insertvalue [2 x i64] undef, i64 %lo, 0
            %r1 = insertvalue [2 x i64] %r0, i64 %hi, 1
            ret [2 x i64] %r1`, ulong[2])(a, b);
    } else {
        immutable ulong aLo = a & 0xFFFF_FFFF, aHi = a >> 32;
        immutable ulong bLo = b & 0xFFFF_FFFF, bHi = b >> 32;
        immutable ulong ll = aLo * bLo, lh = aLo * bHi, hl = aHi * bLo, hh = aHi * bHi;
        immutable ulong mid = (ll >> 32) + (lh & 0xFFFF_FFFF) + (hl & 0xFFFF_FFFF);
        return [(mid << 32) | (ll & 0xFFFF_FFFF), hh + (lh >> 32) + (hl >> 32) + (mid >> 32)];
    }
}

/++ Eisel-Lemire: correctly rounded w * 10^q for a nonzero exact decimal mantissa `w`.
    Follows the fast_float implementation; returns false (slow path) for results that would be
    subnormal or overflow, and for the rare products too close to call. ++/
private bool eiselLemire(ulong w, int q, out double result) @trusted pure nothrow @nogc {
    import core.bitop : bsr;
    import djson.pow5 : pow5Table, pow5MinExponent, pow5MaxExponent;

    if (q < pow5MinExponent || q > pow5MaxExponent) return false;

    immutable lz = 63 - bsr(w);
    w <<= lz;

    // 128-bit approximation of w * 5^q, refined with the low half of the table entry when the
    // bits that decide the rounding are all ones
    immutable pow5 = pow5Table[q - pow5MinExponent];
    ulong[2] product = mul128(w, pow5[0]);
    enum ulong precisionMask = ulong.max >> 55; // 52 mantissa bits + 3
    if ((product[1] & precisionMask) == precisionMask) {
        immutable second = mul128(w, pow5[1]);
        product[0] += second[1];
        if (second[1] > product[0]) product[1]++;
    }
    if (product[0] == ulong.max && (q < -27 || q > 55)) return false;

    immutable upperBit = cast(int)(product[1] >> 63);
    ulong mantissa = product[1] >> (upperBit + 64 - 52 - 3);
    int power2 = (((152_170 + 65_536) * q) >> 16) + 63 + upperBit - lz + 1023;
    if (power2 <= 0) return false; // subnormal

    // Exact halfway case: round to even
    if (product[0] <= 1 && q >= -4 && q <= 23 && (mantissa & 3) == 1
            && (mantissa << (upperBit + 64 - 52 - 3)) == product[1])
        mantissa &= ~1UL;

    mantissa += mantissa & 1;
    mantissa >>= 1;
    if (mantissa >= (2UL << 52)) {
        mantissa = 1UL << 52;
        power2++;
    }
    mantissa &= ~(1UL << 52);
    if (power2 >= 0x7FF) return false; // overflow

    ulong bits = mantissa | (cast(ulong)power2 << 52);
    result = *cast(double*)&bits;
    return true;
}

/++ Consumes a number from string and returns it, mutating s.
    Validates the number and accumulates its decimal mantissa in a single pass, then converts it
    exactly with doubles (Clinger) for up to 15 digits and a decimal exponent within ±22, with
    Eisel-Lemire for up to 19 digits, and with std.conv only for the remaining cases. ++/
private double consumeNumber(ref string s) @trusted {
    size_t i = 0;
    immutable n = s.length;
    bool neg = false;
    if (i < n && s[i] == '-') { neg = true; i++; }
    if (i >= n) throw new JSONPartialException("Unterminated number");

    ulong mantissa = 0;
    int digits = 0;     // significant digits accumulated (leading zeros excluded)
    int exp10 = 0;
    bool truncated = false;

    if (s[i] == '0') {
        i++;
    } else if (s[i] >= '1' && s[i] <= '9') {
        do {
            if (digits < 19) { mantissa = mantissa * 10 + (s[i] - '0'); digits++; }
            else truncated = true;
            i++;
        } while (i < n && isDigitChar(s[i]));
    } else {
        throw new JSONSyntaxException("Invalid number format");
    }

    if (i < n && s[i] == '.') {
        i++;
        if (i >= n) throw new JSONPartialException("Unterminated number");
        if (!isDigitChar(s[i])) throw new JSONSyntaxException("Invalid number format: expected digit after .");
        do {
            if (mantissa == 0 && s[i] == '0') exp10--;
            else if (digits < 19) { mantissa = mantissa * 10 + (s[i] - '0'); digits++; exp10--; }
            else truncated = true;
            i++;
        } while (i < n && isDigitChar(s[i]));
    }

    if (i < n && (s[i] == 'e' || s[i] == 'E')) {
        i++;
        bool expNeg = false;
        if (i < n && (s[i] == '+' || s[i] == '-')) { expNeg = s[i] == '-'; i++; }
        if (i >= n) throw new JSONPartialException("Unterminated number");
        if (!isDigitChar(s[i])) throw new JSONSyntaxException("Invalid number format: expected digit after e/E");
        int e = 0;
        do {
            if (e < 100_000) e = e * 10 + (s[i] - '0');
            i++;
        } while (i < n && isDigitChar(s[i]));
        exp10 += expNeg ? -e : e;
    }

    string numStr = s[0 .. i];
    s = s[i .. $];

    if (!truncated) {
        double result;
        bool ok = true;
        if (mantissa == 0) result = 0.0;
        else if (digits <= 15 && exp10 >= 0 && exp10 <= 22) result = cast(double)mantissa * exactPowersOf10[exp10];
        else if (digits <= 15 && exp10 < 0 && exp10 >= -22) result = cast(double)mantissa / exactPowersOf10[-exp10];
        else ok = eiselLemire(mantissa, exp10, result);
        if (ok) return neg ? -result : result;
    }

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
