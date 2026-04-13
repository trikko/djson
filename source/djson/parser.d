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
import std.ascii;
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
    } else if (c == '[') {
        v.type = JType.Array;
        v.arr.elements = null;
        v.arr.unparsedData = s[1..$];
        v.arr.isFullyParsed = false;
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
            throw new JSONSyntaxException("Invalid boolean");
        }
    } else if (c == 'n') {
        if (s.startsWith("null")) {
            s = s[4..$];
            v.type = JType.Null;
        } else {
            throw new JSONSyntaxException("Invalid null");
        }
    } else if (isDigit(c) || c == '-') {
        string currentS = s;
        double numVal = consumeNumber(currentS);
        s = currentS;
        v.type = JType.Number;
        v.number = numVal;
    } else {
        throw new JSONSyntaxException("Invalid JSON token: " ~ c);
    }
}

package bool parseNextPair(JValue* v, string seekKey = null) @trusted {
    if (v.type != JType.Object || v.obj.isFullyParsed) return false;
    
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
    
    // Skip to next token to update s for parent
    skipValue(s);
    
    if (stripJSONWhitespace(s).length == 0) {
        throw new JSONPartialException("Pending stream: value might be incomplete");
    }
    
    v.obj.pairs ~= JObject.Pair(key, child);
    v.obj.unparsedData = s;
    
    if (seekKey !is null && key == seekKey) return true;
    return true;
}

package bool parseNextElement(JValue* v) @trusted {
    if (v.type != JType.Array || v.arr.isFullyParsed) return false;
    
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
    
    // Skip to next token to update s
    skipValue(s);
    
    if (stripJSONWhitespace(s).length == 0) {
        throw new JSONPartialException("Pending stream: value might be incomplete");
    }
    
    v.arr.elements ~= child;
    v.arr.unparsedData = s;
    
    return true;
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
    } else if (isDigit(c) || c == '-') { // number
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
        while(i < s.length && isDigit(s[i])) i++;
    } else {
        throw new JSONSyntaxException("Invalid number format");
    }
    
    if (i < s.length && s[i] == '.') {
        i++;
        if (i >= s.length || !isDigit(s[i])) throw new JSONSyntaxException("Invalid number format: expected digit after .");
        while(i < s.length && isDigit(s[i])) i++;
    }
    if (i < s.length && (s[i] == 'e' || s[i] == 'E')) {
        i++;
        if (i < s.length && (s[i] == '+' || s[i] == '-')) i++;
        if (i >= s.length || !isDigit(s[i])) throw new JSONSyntaxException("Invalid number format: expected digit after e/E");
        while(i < s.length && isDigit(s[i])) i++;
    }
    return i;
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

    // Float path: use to!double
    string numStr = s[0..len];
    s = s[len..$];
    try {
        return to!double(numStr);
    } catch(Exception e) {
        throw new JSONSyntaxException("Invalid number format: " ~ numStr);
    }
}

private string consumeString(ref string s) @trusted {
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
                    string hex = rawSlice[j+1 .. j+5];
                    j += 4;
                    import std.format : formattedRead;
                    uint val;
                    formattedRead(hex, "%x", &val);
                    
                    if (val >= 0xD800 && val <= 0xDBFF) {
                        // High surrogate, expect low surrogate
                        if (j + 6 < rawSlice.length && rawSlice[j+1] == '\\' && rawSlice[j+2] == 'u') {
                            string hex2 = rawSlice[j+3 .. j+7];
                            uint val2;
                            formattedRead(hex2, "%x", &val2);
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

/++  Fully parse JSON string eagerly (no lazy evaluation).
     Returns a completely parsed JValue in a single pass — faster than parseJSON + parseAll(). ++/
JValue parseJSONComplete(string data) @trusted {
    string s = data;
    s = stripJSONWhitespace(s);
    if (s.length == 0) throw new JSONException("Empty JSON input");
    JValue result = parseValueFull(s);
    return result;
}

package JValue parseValueFull(ref string s) @trusted {
    s = stripJSONWhitespace(s);
    if (s.length == 0) throw new JSONPartialException("Unexpected end of JSON");

    char c = s[0];
    if (c == '"') {
        s = s[1..$];
        JValue v;
        v.type = JType.String;
        v.str = consumeString(s);
        return v;
    } else if (c == '{') {
        return parseObjectFull(s);
    } else if (c == '[') {
        return parseArrayFull(s);
    } else if (c == 't') {
        if (s.length >= 4 && s[0..4] == "true") {
            s = s[4..$];
            return JValue(true);
        }
        throw new JSONSyntaxException("Invalid boolean");
    } else if (c == 'f') {
        if (s.length >= 5 && s[0..5] == "false") {
            s = s[5..$];
            return JValue(false);
        }
        throw new JSONSyntaxException("Invalid boolean");
    } else if (c == 'n') {
        if (s.length >= 4 && s[0..4] == "null") {
            s = s[4..$];
            JValue v;
            v.type = JType.Null;
            return v;
        }
        throw new JSONSyntaxException("Invalid null");
    } else if (isDigit(c) || c == '-') {
        JValue v;
        v.type = JType.Number;
        v.number = consumeNumber(s);
        return v;
    }
    throw new JSONSyntaxException("Invalid JSON token: " ~ c);
}

private JValue parseObjectFull(ref string s) @trusted {
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

        JValue child = parseValueFull(s);
        v.obj.pairs ~= JObject.Pair(key, child);

        s = stripJSONWhitespace(s);
        if (s.length == 0) throw new JSONPartialException("Unterminated object");
        if (s[0] == '}') {
            s = s[1..$];
            break;
        }
        if (s[0] != ',') throw new JSONSyntaxException("Expected ',' between object entries");
        s = s[1..$]; // skip ','
    }
    return v;
}

private JValue parseArrayFull(ref string s) @trusted {
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

    while (true) {
        JValue child = parseValueFull(s);
        v.arr.elements ~= child;

        s = stripJSONWhitespace(s);
        if (s.length == 0) throw new JSONPartialException("Unterminated array");
        if (s[0] == ']') {
            s = s[1..$];
            break;
        }
        if (s[0] != ',') throw new JSONSyntaxException("Expected ',' between array entries");
        s = s[1..$]; // skip ','
    }
    return v;
}
