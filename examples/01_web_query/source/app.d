module app;

import serverino;
import djson;
import std.exception;
import std.array : replace;

mixin ServerinoMain;

@onServerInit ServerinoConfig configure() {
    return ServerinoConfig.create().addListener("127.0.0.1", 8082);
}

@endpoint @route!"/"
void handleIndex(Request request, Output output) {
    if (!output.serveFile("public/index.html")) {
        output.status = 404;
        output ~= "Not found";
    }
}

@endpoint @route!(r => r.path == "/query")
void handleQuery(Request request, Output output) {
    if (request.method != Request.Method.Post) {
        output.status = 405;
        return;
    }
    
    string jsonStr = request.post.read("json_data", "");
    string jsonPath = request.post.read("json_query", "");

    output.addHeader("Content-Type", "application/json");

    string status = "complete";
    string resultStr = "null";
    string errorMsg = "";
    string warningMsg = "";
    string extraData = "";

    try {
        auto doc = parseJSON(jsonStr);
        
        try {
            auto val = doc.get!JValue(jsonPath);
            resultStr = val.toString();
        } catch (JSONPartialException e) {
            status = "partial";
            errorMsg = e.msg;
        } catch (Exception e) {
            status = "error";
            errorMsg = e.msg;
        }

        // Document-level checks, independent of the query result
        try {
            doc.parseAll();
            string extra = doc.trailingData();
            if (extra.length > 0) {
                if (status == "complete") status = "extra";
                warningMsg = "Unexpected data after end of JSON";
                extraData = extra;
            }
        } catch (JSONPartialException e) {
            if (status == "complete") status = "partial";
        } catch (Exception e) {
        }
    } catch (JSONPartialException e) {
        status = "partial";
        errorMsg = e.msg;
    } catch (Exception e) {
        status = "error";
        errorMsg = e.msg;
    }

    string escapeJson(string s) {
        return s.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t");
    }

    string warning = warningMsg.length > 0
        ? `, "warning": "` ~ escapeJson(warningMsg) ~ `", "extra": "` ~ escapeJson(extraData) ~ `"`
        : "";

    if (errorMsg.length > 0) {
        output ~= `{"status": "` ~ status ~ `", "error": "` ~ escapeJson(errorMsg) ~ `"` ~ warning ~ `}`;
    } else {
        output ~= `{"status": "` ~ status ~ `", "result": ` ~ resultStr ~ warning ~ `}`;
    }
}
