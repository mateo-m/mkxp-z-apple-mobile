//
//  http-binding.cpp
//  mkxp-z
//
//  Created by ゾロアーク on 12/29/20.
//

#include <stdio.h>
#include <string>

#include "util/json5pp.hpp"
#include "binding-util.h"

#include "net/net.h"

#if RAPI_MAJOR >= 2
#include <ruby/thread.h>
#endif

VALUE stringMap2hash(mkxp_net::StringMap &map) {
    VALUE ret = rb_hash_new();
    for (auto const &item : map) {
        VALUE key = mkxp_str_new_cstr(item.first.c_str());
        VALUE val = mkxp_str_new_cstr(item.second.c_str());
        rb_hash_aset(ret, key, val);
    }
    return ret;
}

mkxp_net::StringMap hash2StringMap(VALUE hash) {
    mkxp_net::StringMap ret;
    Check_Type(hash, T_HASH);
    
    VALUE keys = rb_funcall(hash, rb_intern("keys"), 0);
    for (int i = 0; i < RARRAY_LEN(keys); i++) {
        VALUE key = rb_ary_entry(keys, i);
        VALUE val = rb_hash_aref(hash, key);
        SafeStringValue(key);
        SafeStringValue(val);
        
        ret.emplace(RSTRING_PTR(key), RSTRING_PTR(val));
    }
    return ret;
}

bool strContainsStr(std::string &first, std::string second) {
    return first.find(second) != std::string::npos;
}

VALUE getResponseBody(mkxp_net::HTTPResponse &res) {
#if RAPI_FULL >= 190
    auto it = res.headers().find("Content-Type");
    if (it == res.headers().end())
        return rb_str_new(res.body().c_str(), res.body().length());
    
    std::string &ctype = it->second;
    
    if (strContainsStr(ctype, "text/plain")        || strContainsStr(ctype, "application/json") ||
        strContainsStr(ctype, "application/xml")   || strContainsStr(ctype, "text/html")        ||
        strContainsStr(ctype, "text/css")          || strContainsStr(ctype, "text/javascript")  ||
        strContainsStr(ctype, "application/x-sh")  || strContainsStr(ctype, "image/svg+xml")    ||
        strContainsStr(ctype, "application/x-httpd-php"))
        return mkxp_str_new(res.body().c_str(), res.body().length());
    
#endif
    return rb_str_new(res.body().c_str(), res.body().length());
}

VALUE formResponse(mkxp_net::HTTPResponse &res) {
    VALUE ret = rb_hash_new();
    
    rb_hash_aset(ret, ID2SYM(rb_intern("status")), INT2NUM(res.status()));
    rb_hash_aset(ret, ID2SYM(rb_intern("body")), getResponseBody(res));
    rb_hash_aset(ret, ID2SYM(rb_intern("headers")), stringMap2hash(res.headers()));
    return ret;
}

void* httpGetInternal(void *req) {
    VALUE ret;
    
    mkxp_net::HTTPResponse res = ((mkxp_net::HTTPRequest*)req)->get();
    ret = formResponse(res);
    
    return (void*)ret;
}

RB_METHOD_GUARD(httpGet) {
    RB_UNUSED_PARAM;
    
    VALUE path, rheaders, redirect;
    rb_scan_args(argc, argv, "12", &path, &rheaders, &redirect);
    SafeStringValue(path);
    
    bool rd;
    rb_bool_arg(redirect, &rd);
    mkxp_net::HTTPRequest req(RSTRING_PTR(path), rd);
    if (rheaders != Qnil) {
        auto headers = hash2StringMap(rheaders);
        req.headers().insert(headers.begin(), headers.end());
    }
#if RAPI_MAJOR >= 2
    return (VALUE)drop_gvl_guard(httpGetInternal, &req, 0, 0);
#else
    return (VALUE)httpGetInternal(&req);
#endif
}
RB_METHOD_GUARD_END

typedef struct {
    mkxp_net::HTTPRequest *req;
    mkxp_net::StringMap *postData;
} httpPostInternalArgs;

void* httpPostInternal(void *args) {
    VALUE ret;
    
    mkxp_net::HTTPRequest *req = ((httpPostInternalArgs*)args)->req;
    mkxp_net::StringMap *postData = ((httpPostInternalArgs*)args)->postData;
    
    mkxp_net::HTTPResponse res = req->post(*postData);
    ret = formResponse(res);
    
    return (void*)ret;
}

RB_METHOD_GUARD(httpPost) {
    RB_UNUSED_PARAM;
    
    VALUE path, postDataHash, rheaders, redirect;
    rb_scan_args(argc, argv, "22", &path, &postDataHash, &rheaders, &redirect);
    SafeStringValue(path);
    
    bool rd;
    rb_bool_arg(redirect, &rd);
    mkxp_net::HTTPRequest req(RSTRING_PTR(path), rd);
    if (rheaders != Qnil) {
        auto headers = hash2StringMap(rheaders);
        req.headers().insert(headers.begin(), headers.end());
    }
    
    mkxp_net::StringMap postData = hash2StringMap(postDataHash);
    httpPostInternalArgs args {&req, &postData};
#if RAPI_MAJOR >= 2
    return (VALUE)drop_gvl_guard(httpPostInternal, &args, 0, 0);
#else
    return (VALUE)httpPostInternal(&args);
#endif
}
RB_METHOD_GUARD_END

typedef struct {
    mkxp_net::HTTPRequest *req;
    const char *body;
    const char *ctype;
} httpPostBodyInternalArgs;

void* httpPostBodyInternal(void *args) {
    VALUE ret;
    
    mkxp_net::HTTPRequest *req = ((httpPostBodyInternalArgs*)args)->req;
    const char *reqbody = ((httpPostBodyInternalArgs*)args)->body;
    const char *reqctype = ((httpPostBodyInternalArgs*)args)->ctype;
    
    mkxp_net::HTTPResponse res = req->post(reqbody, reqctype);
    ret = formResponse(res);
    
    return (void*)ret;
}

RB_METHOD_GUARD(httpPostBody) {
    RB_UNUSED_PARAM;
    
    VALUE path, body, ctype, rheaders;
    rb_scan_args(argc, argv, "31", &path, &body, &ctype, &rheaders);
    SafeStringValue(path);
    SafeStringValue(body);
    SafeStringValue(ctype);
    
    
    mkxp_net::HTTPRequest req(RSTRING_PTR(path));
    if (rheaders != Qnil) {
        auto headers = hash2StringMap(rheaders);
        req.headers().insert(headers.begin(), headers.end());
    }
    
    httpPostBodyInternalArgs args {&req, RSTRING_PTR(body), RSTRING_PTR(ctype)};
#if RAPI_MAJOR >= 2
    return (VALUE)drop_gvl_guard(httpPostBodyInternal, &args, 0, 0);
#else
    return (VALUE)httpPostBodyInternal(&args);
#endif
}
RB_METHOD_GUARD_END

/* HTTPLite.download(url, filename, progress_cb_name = nil, headers = nil)
 *
 * JoiPlay-compatible streaming download: writes the response body to
 * `filename` and reports progress by calling the *top-level method*
 * named by `progress_cb_name` with (received_bytes, total_bytes).
 * (Top-level `def foo` methods are private methods of Object;
 * rb_funcall ignores visibility, which is exactly JoiPlay's
 * "global function name" contract.) Returns {status:, headers:}.
 *
 * The transfer runs with the GVL released; each progress event
 * reacquires it just long enough to run the callback. A callback
 * that raises cancels the transfer and its exception propagates to
 * the caller. */

typedef struct {
    mkxp_net::HTTPRequest *req;
    std::string destPath;
    ID cbId;                    // 0 = no callback
    int cbState;                // rb_protect state from a raised callback
    long long lastPercent;      // throttle: last reported percent
    uint64_t lastBytes;         //   ... or byte watermark when total unknown
    int status;
    mkxp_net::StringMap responseHeaders;
} httpDownloadArgs;

typedef struct {
    httpDownloadArgs *args;
    uint64_t current;
    uint64_t total;
} httpDownloadProgressEvent;

static VALUE httpDownloadInvokeCb(VALUE data) {
    httpDownloadProgressEvent *ev = (httpDownloadProgressEvent*)data;
    return rb_funcall(rb_cObject, ev->args->cbId, 2,
                      ULL2NUM(ev->current), ULL2NUM(ev->total));
}

static void *httpDownloadFireCb(void *data) {
    httpDownloadProgressEvent *ev = (httpDownloadProgressEvent*)data;
    int state = 0;
    rb_protect(httpDownloadInvokeCb, (VALUE)ev, &state);
    if (state)
        ev->args->cbState = state;
    return 0;
}

void *httpDownloadInternal(void *a) {
    httpDownloadArgs *args = (httpDownloadArgs*)a;

    mkxp_net::HTTPResponse res = args->req->download(
        args->destPath.c_str(),
        [args](uint64_t current, uint64_t total) -> bool {
            if (!args->cbId)
                return true;

            /* Throttle GVL ping-pong: percent steps when the size is
             * known, 1 MiB steps when it isn't. Always report the
             * final event so callers see 100%. */
            bool fire;
            if (total) {
                long long percent = (long long)(current * 100 / total);
                fire = (percent != args->lastPercent) || current == total;
                if (fire)
                    args->lastPercent = percent;
            } else {
                fire = (current - args->lastBytes) >= (1 << 20);
                if (fire)
                    args->lastBytes = current;
            }
            if (!fire)
                return true;

            httpDownloadProgressEvent ev = {args, current, total};
#if RAPI_MAJOR >= 2
            rb_thread_call_with_gvl(httpDownloadFireCb, &ev);
#else
            httpDownloadFireCb(&ev);
#endif
            return args->cbState == 0;
        });

    args->status = res.status();
    args->responseHeaders = res.headers();
    return 0;
}

RB_METHOD_GUARD(httpDownload) {
    RB_UNUSED_PARAM;

    VALUE path, filename, cbname, rheaders;
    rb_scan_args(argc, argv, "22", &path, &filename, &cbname, &rheaders);
    SafeStringValue(path);
    SafeStringValue(filename);

    mkxp_net::HTTPRequest req(RSTRING_PTR(path));
    if (rheaders != Qnil) {
        auto headers = hash2StringMap(rheaders);
        req.headers().insert(headers.begin(), headers.end());
    }

    httpDownloadArgs args;
    args.req = &req;
    args.destPath = RSTRING_PTR(filename);
    args.cbId = 0;
    args.cbState = 0;
    args.lastPercent = -1;
    args.lastBytes = 0;
    args.status = 0;

    if (cbname != Qnil) {
        if (RB_TYPE_P(cbname, RUBY_T_SYMBOL)) {
            args.cbId = SYM2ID(cbname);
        } else {
            SafeStringValue(cbname);
            args.cbId = rb_intern(RSTRING_PTR(cbname));
        }
    }

    try {
#if RAPI_MAJOR >= 2
        drop_gvl_guard(httpDownloadInternal, &args, 0, 0);
#else
        httpDownloadInternal(&args);
#endif
    }
    catch (const Exception &e) {
        /* A raising progress callback cancels the transfer; surface
         * the callback's own exception, not the cancel error. */
        if (args.cbState)
            rb_jump_tag(args.cbState);
        throw;
    }

    VALUE ret = rb_hash_new();
    rb_hash_aset(ret, ID2SYM(rb_intern("status")), INT2NUM(args.status));
    rb_hash_aset(ret, ID2SYM(rb_intern("headers")), stringMap2hash(args.responseHeaders));
    return ret;
}
RB_METHOD_GUARD_END

VALUE json2rb(json5pp::value const &v) {
    if (v.is_null())
        return Qnil;
    
    if (v.is_number())
        return rb_float_new(v.as_number());
    
    if (v.is_string())
        return mkxp_str_new_cstr(v.as_string().c_str());
    
    if (v.is_boolean())
        return rb_bool_new(v.as_boolean());
    
    if (v.is_integer())
        return LL2NUM(v.as_integer());
    
    if (v.is_array()) {
        auto &a = v.as_array();
        VALUE ret = rb_ary_new();
        for (auto item : a) {
            rb_ary_push(ret, json2rb(item));
        }
        return ret;
    }
    
    if (v.is_object()) {
        auto &o = v.as_object();
        VALUE ret = rb_hash_new();
        for (auto const &pair : o) {
            rb_hash_aset(ret, rb_str_new_cstr(pair.first.c_str()), json2rb(pair.second));
        }
        return ret;
    }
    
    // This should be unreachable
    return Qnil;
}

json5pp::value rb2json(VALUE v) {
    if (v == Qnil)
        return json5pp::value(nullptr);
    
    if (RB_TYPE_P(v, RUBY_T_FLOAT))
        return json5pp::value(RFLOAT_VALUE(v));
    
    if (RB_TYPE_P(v, RUBY_T_STRING))
        return json5pp::value(RSTRING_PTR(v));
    
    if (v == Qtrue || v == Qfalse)
        return json5pp::value(RTEST(v));
    
    if (RB_TYPE_P(v, RUBY_T_FIXNUM))
        return json5pp::value(NUM2DBL(v));
    
    if (RB_TYPE_P(v, RUBY_T_ARRAY)) {
        json5pp::value ret_value = json5pp::array({});
        auto &ret = ret_value.as_array();
        for (int i = 0; i < RARRAY_LEN(v); i++) {
            ret.push_back(rb2json(rb_ary_entry(v, i)));
        }
        return ret_value;
    }
    
    if (RTEST(rb_funcall(v, rb_intern("is_a?"), 1, rb_cHash))) {
        json5pp::value ret_value = json5pp::object({});
        auto &ret = ret_value.as_object();
        
        
        VALUE keys = rb_funcall(v, rb_intern("keys"), 0);
        
        for (int i = 0; i < RARRAY_LEN(keys); i++) {
            VALUE key = rb_ary_entry(keys, i); SafeStringValue(key);
            VALUE val = rb_hash_aref(v, key);
            ret.emplace(RSTRING_PTR(key), rb2json(val));
        }
        
        return ret_value;
    }
    
    throw Exception(Exception::MKXPError, "Invalid value for JSON: %s", RSTRING_PTR(rb_inspect(v)));
    
    // This should be unreachable
    return json5pp::value(0);
}

RB_METHOD_GUARD(httpJsonParse) {
    RB_UNUSED_PARAM;
    
    VALUE jsonv;
    rb_scan_args(argc, argv, "1", &jsonv);
    SafeStringValue(jsonv);
    
    json5pp::value v;
    try {
        v = json5pp::parse5(RSTRING_PTR(jsonv));
    }
    catch (const std::exception &e) {
        throw Exception(Exception::MKXPError, "Failed to parse JSON: %s", e.what());
    }
    
    return json2rb(v);
}
RB_METHOD_GUARD_END

RB_METHOD_GUARD(httpJsonStringify) {
    RB_UNUSED_PARAM;
    
    VALUE obj;
    rb_scan_args(argc, argv, "1", &obj);
    
    json5pp::value v = rb2json(obj);
    return mkxp_str_new_cstr(v.stringify5(json5pp::rule::space_indent<>()).c_str());
}
RB_METHOD_GUARD_END

void httpBindingInit() {
    VALUE mNet = rb_define_module("HTTPLite");
    _rb_define_module_function(mNet, "get", httpGet);
    _rb_define_module_function(mNet, "post", httpPost);
    _rb_define_module_function(mNet, "post_body", httpPostBody);
    _rb_define_module_function(mNet, "download", httpDownload);
    
    VALUE mNetJSON = rb_define_module_under(mNet, "JSON");
    _rb_define_module_function(mNetJSON, "stringify", httpJsonStringify);
    _rb_define_module_function(mNetJSON, "parse", httpJsonParse);
}
