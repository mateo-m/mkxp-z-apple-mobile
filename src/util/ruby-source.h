#ifndef RUBY_SOURCE_H
#define RUBY_SOURCE_H

#include <cctype>
#include <cstddef>
#include <cstring>

// Ruby reads =begin and =end only at the start of a line, and only when
// a space, a tab, or the line end follows them.
inline bool rubyLineIsMarker(const char *line, const char *lineEnd, const char *marker)
{
    size_t n = strlen(marker);
    if (static_cast<size_t>(lineEnd - line) < n || strncmp(line, marker, n) != 0)
        return false;
    const char *after = line + n;
    return after == lineEnd || *after == ' ' || *after == '\t' || *after == '\r';
}

// True when the Ruby source has a line that is not blank, a comment,
// inside an =begin/=end block, or after __END__.
inline bool rubySourceHasCode(const char *src, size_t len)
{
    const char *end = src + len;
    bool inBlockComment = false;

    if (len >= 3 && memcmp(src, "\xEF\xBB\xBF", 3) == 0)
        src += 3;

    for (const char *line = src; line < end;) {
        const char *next = static_cast<const char *>(memchr(line, '\n', end - line));
        const char *lineEnd = next ? next : end;

        if (inBlockComment) {
            if (rubyLineIsMarker(line, lineEnd, "=end"))
                inBlockComment = false;
        } else if (rubyLineIsMarker(line, lineEnd, "=begin")) {
            inBlockComment = true;
        } else if (lineEnd - line >= 7 && strncmp(line, "__END__", 7) == 0 &&
                   (lineEnd - line == 7 || (lineEnd - line == 8 && line[7] == '\r'))) {
            return false;
        } else {
            const char *c = line;
            while (c < lineEnd && isspace(static_cast<unsigned char>(*c)))
                ++c;
            if (c < lineEnd && *c != '#')
                return true;
        }

        line = next ? next + 1 : end;
    }
    return false;
}

#endif // RUBY_SOURCE_H
