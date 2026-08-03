//
//  net.cpp
//  mkxp-z
//
//  Created by ゾロアーク on 12/29/20.
//

#include <stdio.h>
#include <cstdint>

/* TLS for the in-engine HTTP client. Deliberately NOT keyed on MKXPZ_SSL:
 * upstream uses that flag as a combined "with-https" build variant that
 * also switches on the xBRZ shader paths (see src/display/*). This fork
 * wants TLS without dragging in untested renderer code, so the network
 * layer has its own flag. */
#if defined(MKXPZ_NET_TLS)
#define CPPHTTPLIB_OPENSSL_SUPPORT
#endif
#include "httplib.h"

#include "util/exception.h"

#include "LUrlParser.h"
#include "net.h"
#include "app_bridge.h"

const char* httpErrorNames[] = {
    "Success",
    "Unknown",
    "Connection",
    "Bind IP Address",
    "Read",
    "Write",
    "Exceed Redirect Count",
    "Canceled",
    "SSLConnection",
    "SSL Loading Certs",
    "SSL Server Verification",
    "Unsupported Multipart Boundary Chars"
};

const char *urlErrorNames[] = {
    "OK",
    "Uninitialized",
    "No URL Character",
    "Invalid Scheme Name",
    "No Double Slash",
    "No At Sign",
    "Unexpected End-Of-Line",
    "No Slash"
};

LUrlParser::ParseURL readURL(const char *url) {
    LUrlParser::ParseURL p = LUrlParser::ParseURL::parseURL(std::string(url));
    if (!p.isValid() || p.errorCode_){
        throw Exception(Exception::MKXPError, "Invalid URL: %s", urlErrorNames[p.errorCode_]);
    }
    return p;
}

std::string getHost(LUrlParser::ParseURL url) {
    std::string host;
    host += url.scheme_;
    host += "://";
    host += url.host_;

    int port;
    if (!url.port_.empty() && url.getPort(&port)) {
        host += ":";
        host += std::to_string(port);
    }
    return host;
}

std::string getPath(LUrlParser::ParseURL url) {
    std::string path = "/";
    path += url.path_;

    if (!url.query_.empty()) {
        path += "?";
        path += url.query_;
    }

    return path;
}


using namespace mkxp_net;

/* The host's per-game network toggle is enforced here, at the native
 * client, so every Ruby-visible path over it (HTTPLite, the HTTP shim,
 * the old-VM Net::HTTP facade) goes offline together: requests throw,
 * and the Ruby-side wrappers translate that into the same empty
 * responses games saw before the engine had networking. */
static void ensureNetworkAllowed() {
    if (!mkxp_getNetworkEnabled())
        throw Exception(Exception::MKXPError,
                        "Network access is disabled for this game");
}

/* Shared client setup: TLS server verification against the host-provided
 * CA bundle (fails closed when none was set), plus timeouts so a game
 * firing an update check against a dead server doesn't hang the script
 * thread for minutes.
 *
 * tlsCompat caps the handshake at TLS 1.2. Anti-DDoS appliances in
 * front of some fangame hosts filter handshakes by TLS fingerprint
 * and silently drop OpenSSL's default TLS 1.3 ClientHello while
 * accepting its TLS 1.2 one (observed on rebornevo.com update
 * downloads, 2026-08: the server resets or ignores the 1.3 hello,
 * which surfaces as httplib SSLConnection). Requests start with the
 * modern profile and retry once with this one when the SSL layer
 * itself fails; certificate verification is identical in both. */
static void configureClient(httplib::Client &client, bool tlsCompat = false) {
#ifdef MKXPZ_NET_TLS
    const char *caPath = mkxp_getCABundlePath();
    if (caPath && caPath[0])
        client.set_ca_cert_path(caPath);
    client.enable_server_certificate_verification(true);
    if (tlsCompat) {
        if (SSL_CTX *ctx = client.ssl_context())
            SSL_CTX_set_max_proto_version(ctx, TLS1_2_VERSION);
    }
#else
    (void)tlsCompat;
#endif
    client.set_connection_timeout(10, 0);
    client.set_read_timeout(30, 0);
    client.set_write_timeout(30, 0);
}

/* True when a failed attempt should run again with the TLS compat
 * profile (see configureClient). Only the SSL-layer failure retries:
 * connection refusals, timeouts, and HTTP errors mean the same thing
 * under either profile. */
static bool shouldRetryWithTLSCompat(httplib::Error err, bool alreadyCompat) {
#ifdef MKXPZ_NET_TLS
    return !alreadyCompat && err == httplib::Error::SSLConnection;
#else
    (void)err;
    (void)alreadyCompat;
    return false;
#endif
}

HTTPResponse::HTTPResponse() :
    _headers(StringMap()),
    _status(0),
    _body(std::string())
{}

HTTPResponse::~HTTPResponse() {}

std::string &HTTPResponse::body() {
    return _body;
}

StringMap &HTTPResponse::headers() {
    return _headers;
}

int HTTPResponse::status() {
    return _status;
}

HTTPRequest::HTTPRequest(const char *dest, bool follow_redirects) :
    destination(std::string(dest)),
    _headers(StringMap()),
    follow_location(follow_redirects)
{}

HTTPRequest::~HTTPRequest() {}

StringMap &HTTPRequest::headers() {
    return _headers;
}

HTTPResponse HTTPRequest::get() {
    ensureNetworkAllowed();

    HTTPResponse ret;
    auto target = readURL(destination.c_str());

    for (int attempt = 0;; attempt++) {
        const bool tlsCompat = attempt > 0;
        httplib::Client client(getHost(target).c_str());
        configureClient(client, tlsCompat);
        client.set_follow_location(follow_location);

        httplib::Headers head;
        for (auto const &h : _headers)
            head.emplace(h.first, h.second);

        if (auto result = client.Get(getPath(target).c_str(), head)) {
            auto response = result.value();
            ret._status = response.status;
            ret._body = response.body;

            for (auto const &h : response.headers)
                ret._headers.emplace(h.first, h.second);
        }
        else {
            auto err = result.error();
            if (shouldRetryWithTLSCompat(err, tlsCompat))
                continue;
            std::string errname = httplib::to_string(err);
            throw Exception(Exception::MKXPError, "Failed to GET %s (%i: %s)", destination.c_str(), err, errname.c_str());
        }

        return ret;
    }
}

HTTPResponse HTTPRequest::post(StringMap &postData) {
    ensureNetworkAllowed();

    HTTPResponse ret;
    auto target = readURL(destination.c_str());

    for (int attempt = 0;; attempt++) {
        const bool tlsCompat = attempt > 0;
        httplib::Client client(getHost(target).c_str());
        configureClient(client, tlsCompat);
        client.set_follow_location(follow_location);

        httplib::Headers head;
        httplib::Params params;

        for (auto const &h : _headers)
            head.emplace(h.first, h.second);

        for (auto const &p : postData)
            params.emplace(p.first, p.second);

        if (auto result = client.Post(getPath(target).c_str(), head, params)) {
            auto response = result.value();
            ret._status = response.status;
            ret._body = response.body;

            for (auto h : response.headers)
                ret._headers.emplace(h.first, h.second);
        }
        else {
            auto err = result.error();
            if (shouldRetryWithTLSCompat(err, tlsCompat))
                continue;
            std::string errname = httplib::to_string(err);
            throw Exception(Exception::MKXPError, "Failed to POST %s (%i: %s)", destination.c_str(), err, errname.c_str());
        }
        return ret;
    }
}

HTTPResponse HTTPRequest::post(const char *body, const char *content_type) {
    ensureNetworkAllowed();

    HTTPResponse ret;
    auto target = readURL(destination.c_str());

    for (int attempt = 0;; attempt++) {
        const bool tlsCompat = attempt > 0;
        httplib::Client client(getHost(target).c_str());
        configureClient(client, tlsCompat);
        client.set_follow_location(true);

        httplib::Headers head;
        for (auto const &h : _headers)
            head.emplace(h.first, h.second);

        if (auto result = client.Post(getPath(target).c_str(), head, body, content_type)) {
            auto response = result.value();
            ret._status = response.status;
            ret._body = response.body;

            for (auto const &h : response.headers)
                ret._headers.emplace(h.first, h.second);
        }
        else {
            auto err = result.error();
            if (shouldRetryWithTLSCompat(err, tlsCompat))
                continue;
            std::string errname = httplib::to_string(err);
            throw Exception(Exception::MKXPError, "Failed to POST %s (%i: %s)", destination.c_str(), err, errname.c_str());
        }
        return ret;
    }
}

HTTPResponse HTTPRequest::download(const char *destPath, DownloadProgressFn progress) {
    ensureNetworkAllowed();

    HTTPResponse ret;
    auto target = readURL(destination.c_str());

    for (int attempt = 0;; attempt++) {
    const bool tlsCompat = attempt > 0;
    ret._headers.clear();

    httplib::Client client(getHost(target).c_str());
    configureClient(client, tlsCompat);
    client.set_follow_location(follow_location);

    httplib::Headers head;
    for (auto const &h : _headers)
        head.emplace(h.first, h.second);

    std::string tmpPath = std::string(destPath) + ".part";
    FILE *out = nullptr;
    bool writeFailed = false;
    int status = 0;

    auto result = client.Get(
        getPath(target).c_str(), head,
        [&](const httplib::Response &response) {
            status = response.status;
            for (auto const &h : response.headers)
                ret._headers.emplace(h.first, h.second);
            return true;
        },
        [&](const char *data, size_t len) {
            /* Only stream a successful response to disk; error bodies
             * (404 pages, auth challenges) are discarded so callers can
             * retry without cleanup. */
            if (status != 200)
                return true;
            if (!out) {
                out = fopen(tmpPath.c_str(), "wb");
                if (!out) {
                    writeFailed = true;
                    return false;
                }
            }
            if (fwrite(data, 1, len, out) != len) {
                writeFailed = true;
                return false;
            }
            return true;
        },
        [&](uint64_t current, uint64_t total) {
            if (progress)
                return progress(current, total);
            return true;
        });

    if (out)
        fclose(out);

    if (!result || writeFailed) {
        remove(tmpPath.c_str());
        if (writeFailed)
            throw Exception(Exception::MKXPError, "Failed to write %s while downloading %s", destPath, destination.c_str());
        auto err = result.error();
        if (shouldRetryWithTLSCompat(err, tlsCompat))
            continue;
        std::string errname = httplib::to_string(err);
        throw Exception(Exception::MKXPError, "Failed to download %s (%i: %s)", destination.c_str(), (int)err, errname.c_str());
    }

    ret._status = status;
    if (status == 200) {
        remove(destPath);
        if (rename(tmpPath.c_str(), destPath) != 0) {
            remove(tmpPath.c_str());
            throw Exception(Exception::MKXPError, "Failed to move %s into place", destPath);
        }
    } else {
        remove(tmpPath.c_str());
    }

    return ret;
    }
}
