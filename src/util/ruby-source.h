#ifndef RUBY_SOURCE_H
#define RUBY_SOURCE_H

#include <cctype>
#include <cstddef>
#include <cstring>

// True when the Ruby source has a line that is not blank, a comment,
// or inside an =begin/=end block.
inline bool rubySourceHasCode(const char *src, size_t len)
{
    const char *end = src + len;
    bool inBlockComment = false;

    for (const char *line = src; line < end;) {
        const char *next = static_cast<const char *>(memchr(line, '\n', end - line));
        const char *lineEnd = next ? next : end;

        // =begin and =end count only at the start of a line.
        if (inBlockComment) {
            if (lineEnd - line >= 4 && strncmp(line, "=end", 4) == 0)
                inBlockComment = false;
        } else if (lineEnd - line >= 6 && strncmp(line, "=begin", 6) == 0) {
            inBlockComment = true;
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
