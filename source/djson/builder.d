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

/++ Helper functions for building JSON objects and arrays fluently. ++/
module djson.builder;

import djson.value;
import std.traits : isSomeString;

/++ 
    Builds a JSON object from a sequence of key-value pairs.
    Example: `auto obj = JSOB("name", "Alice", "age", 30);`
++/
JValue JSOB(T...)(T vals)
{
    JValue res;
    res.type = JType.Object;
    res.obj.isFullyParsed = true;

    static if (vals.length > 0)
    {
        static if (vals.length % 2 != 0)
        {
            static assert(0, "JSOB expects an even number of arguments (key, value pairs)");
        }
        else
        {
            foreach(i, v; vals)
            {
                static if (i % 2 == 0)
                {
                    static if (!isSomeString!(typeof(v)))
                    {
                        static assert(0, "JSOB keys must be strings, not " ~ typeof(v).stringof);
                    }
                }
                else
                {
                    res[vals[i-1]] = v;
                }
            }
        }
    }
    return res;
}

/++ 
    Builds a JSON array from a sequence of values.
    Example: `auto arr = JSAB(1, 2, "three", JSOB("key", "val"));`
++/
JValue JSAB(T...)(T vals)
{
    JValue res;
    res.type = JType.Array;
    res.arr.isFullyParsed = true;

    foreach(i, v; vals)
    {
        res[i] = v;
    }
    return res;
}

unittest
{
    import std.conv : to;

    // Test JSOB
    auto obj = JSOB(
        "string", "value",
        "int", 123,
        "bool", true,
        "null", null,
        "sub", JSOB("key", "val")
    );

    assert(obj.type == JType.Object);
    assert(obj.get!string("string") == "value");
    assert(obj.get!int("int") == 123);
    assert(obj.get!bool("bool") == true);
    assert(obj.get!string("sub", "key") == "val");
    assert(obj.has("null"));
    
    // Test JSAB
    auto arr = JSAB(1, "two", 3.0, JSOB("a", "b"));
    assert(arr.type == JType.Array);
    assert(arr.length == 4);
    assert(arr.get!int(0) == 1);
    assert(arr.get!string(1) == "two");
    assert(arr.get!double(2) == 3.0);
    assert(arr.get!string(3, "a") == "b");

    // Test nested
    auto nested = JSOB(
        "array", JSAB(1, 2, JSOB("x", "y")),
        "obj", JSOB("list", JSAB("a", "b"))
    );
    assert(nested.get!string("array", 2, "x") == "y");
    assert(nested.get!string("obj", "list", 1) == "b");
}
