//
//  net.h
//  mkxp-z
//
//  Created by ゾロアーク on 12/29/20.
//

#ifndef net_h
#define net_h

#include <unordered_map>
#include <string>
#include <functional>

namespace mkxp_net {

typedef std::unordered_map<std::string, std::string> StringMap;

/* Called with (received, total) as the transfer progresses. `total` is 0
 * when the server sent no Content-Length. Return false to cancel. */
typedef std::function<bool(uint64_t, uint64_t)> DownloadProgressFn;

class HTTPResponse {
public:
    int status();
    std::string &body();
    StringMap &headers();
    ~HTTPResponse();

private:
    int _status;
    std::string _body;
    StringMap _headers;
    HTTPResponse();

    friend class HTTPRequest;
};

class HTTPRequest {
public:
    HTTPRequest(const char *dest, bool follow_redirects = true);
    ~HTTPRequest();

    StringMap &headers();

    std::string destination;

    HTTPResponse get();
    HTTPResponse post(StringMap &postData);
    HTTPResponse post(const char *body, const char *content_type);

    /* Streams the response body to `destPath` (via a temp file that is
     * renamed into place on success, so a failed transfer never leaves a
     * truncated file behind). Returns a response whose body is empty;
     * check status(). Progress callback is optional. */
    HTTPResponse download(const char *destPath, DownloadProgressFn progress = nullptr);
private:
    StringMap _headers;
    bool follow_location;
};
}

#endif /* net_h */
