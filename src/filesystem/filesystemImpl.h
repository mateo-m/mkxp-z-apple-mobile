//
//  filesystemImpl.h
//  Player
//
//  Created by ゾロアーク on 11/21/20.
//

#ifndef filesystemImpl_h
#define filesystemImpl_h

#include <string>
#include <SDL_video.h>

namespace filesystemImpl {
bool fileExists(const char *path);

std::string contentsOfFileAsString(const char *path);

bool setCurrentDirectory(const char *path);
    
std::string getCurrentDirectory();
    
std::string normalizePath(const char *path, bool preferred, bool absolute);

/* Collapse ./ and ../ in a game-relative path. Returns "." when the
 * path denotes the current directory (e.g. ".", "./", "foo/.."). */
std::string collapseRelativePath(const char *path);

std::string getDefaultGameRoot();

std::string getPathForAsset(const char *baseName, const char *ext);
std::string contentsOfAssetAsString(const char *baseName, const char *ext);

std::string getResourcePath();

std::string selectPath(SDL_Window *win, const char *msg, const char *prompt);

};
#endif /* filesystemImpl_h */
