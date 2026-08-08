/*
 ** filesystem-binding.cpp
 **
 ** This file is part of mkxp.
 **
 ** Copyright (C) 2013 - 2021 Amaryllis Kulla <ancurio@mapleshrine.eu>
 **
 ** mkxp is free software: you can redistribute it and/or modify
 ** it under the terms of the GNU General Public License as published by
 ** the Free Software Foundation, either version 2 of the License, or
 ** (at your option) any later version.
 **
 ** mkxp is distributed in the hope that it will be useful,
 ** but WITHOUT ANY WARRANTY; without even the implied warranty of
 ** MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 ** GNU General Public License for more details.
 **
 ** You should have received a copy of the GNU General Public License
 ** along with mkxp.  If not, see <http://www.gnu.org/licenses/>.
 */

#include "src/config.h"

#include "binding-util.h"

#include "filesystem.h"
#include "sharedstate.h"
#include "src/util/util.h"

#if RAPI_FULL > 187
#include "ruby/encoding.h"
#include "ruby/intern.h"
#else
#include "intern.h"
#endif

#if RAPI_MAJOR >= 2
#include <ruby/thread.h>
#endif

static void mkxp_define_alias_once(VALUE klass, const char *aliasName,
                                   const char *origName) {
    ID aliasId = rb_intern(aliasName);
    ID origId = rb_intern(origName);
    if (rb_method_boundp(klass, aliasId, /*ex=*/0)) return;
    // Ruby 1.8 has File.exist? but no Dir.exist? (added in 1.9).
    // Skip aliasing when the VM never shipped the original method.
    if (!rb_method_boundp(klass, origId, /*ex=*/0)) return;
    rb_define_alias(klass, aliasName, origName);
}

static void fileIntFreeInstance(void *inst) {
    SDL_RWops *ops = static_cast<SDL_RWops *>(inst);
    
    SDL_RWclose(ops);
    SDL_FreeRW(ops);
}

#if RAPI_FULL > 187
DEF_TYPE_CUSTOMFREE(FileInt, fileIntFreeInstance);
#else
DEF_ALLOCFUNC_CUSTOMFREE(FileInt, fileIntFreeInstance);
#endif

static VALUE fileIntForPath(const char *path, bool rubyExc) {
    VALUE klass = rb_const_get(rb_cObject, rb_intern("FileInt"));
    
    VALUE obj = rb_obj_alloc(klass);
    
    SDL_RWops *ops = SDL_AllocRW();
    
    try {
        shState->fileSystem().openReadRaw(*ops, path);
    } catch (const Exception &e) {
        SDL_FreeRW(ops);
        
        throw e;
    }
    
    setPrivateData(obj, ops);
    
    return obj;
}

#if RAPI_MAJOR >= 2
typedef struct {
    SDL_RWops *ops;
    void *dst;
    int length;
} fileIntReadCbArgs;

void call_RWread_cb(fileIntReadCbArgs *args) {
    SDL_RWread(args->ops, args->dst, 1, args->length);
}
#endif

RB_METHOD(fileIntRead) {
    
    int length = -1;
    rb_get_args(argc, argv, "|i", &length RB_ARG_END);
    
    SDL_RWops *ops = getPrivateData<SDL_RWops>(self);
    
    if (length == -1) {
        Sint64 cur = SDL_RWtell(ops);
        Sint64 end = SDL_RWseek(ops, 0, SEEK_END);
        
        // Sometimes SDL_RWseek will fail for no reason
        // with encrypted archives, so let's just ask
        // for the size up front
        if (end < 0)
            end = ops->size(ops);
        
        length = end - cur;
        SDL_RWseek(ops, cur, SEEK_SET);
    }
    
    if (length == 0)
        return Qnil;
    
    VALUE data = rb_str_new(0, length);
    
    
    
#if RAPI_MAJOR >= 2
    fileIntReadCbArgs cbargs {ops, RSTRING_PTR(data), length};
    rb_thread_call_without_gvl([](void* args) -> void* {
        call_RWread_cb((fileIntReadCbArgs*)args);
        return 0;
    }, (void*)&cbargs, 0, 0);
#else
    SDL_RWread(ops, RSTRING_PTR(data), 1, length);
#endif
    
    return data;
}

RB_METHOD(fileIntClose) {
    RB_UNUSED_PARAM;
    
    SDL_RWops *ops = getPrivateData<SDL_RWops>(self);
    SDL_RWclose(ops);
    
    return Qnil;
}

RB_METHOD(fileIntGetByte) {
    RB_UNUSED_PARAM;
    
    SDL_RWops *ops = getPrivateData<SDL_RWops>(self);
    
    unsigned char byte;
    size_t result = SDL_RWread(ops, &byte, 1, 1);
    
    return (result == 1) ? rb_fix_new(byte) : Qnil;
}

RB_METHOD(fileIntBinmode) {
    RB_UNUSED_PARAM;
    
    return Qnil;
}

#if RAPI_FULL <= 187
RB_METHOD(fileIntPos) {
    SDL_RWops *ops = getPrivateData<SDL_RWops>(self);
    
    long long pos = SDL_RWtell(ops); // Will return -1 if it doesn't work
    return LL2NUM(pos);
}
#endif

typedef struct {
    VALUE port;
    bool raw;
} LoadDataBodyArgs;

static VALUE kernelLoadDataBody(VALUE arg) {
    LoadDataBodyArgs *args = reinterpret_cast<LoadDataBodyArgs *>(arg);

    VALUE data = fileIntRead(0, 0, args->port);
    if (args->raw)
        return data;

    VALUE marsh = rb_const_get(rb_cObject, rb_intern("Marshal"));
    return rb_funcall2(marsh, rb_intern("load"), 1, &data);
}

static VALUE kernelLoadDataEnsure(VALUE port) {
    return rb_funcall2(port, rb_intern("close"), 0, NULL);
}

VALUE
kernelLoadDataInt(const char *filename, bool rubyExc, bool raw) {
    //rb_gc_start();

    VALUE port = fileIntForPath(filename, rubyExc);
    LoadDataBodyArgs args = { port, raw };

    /* If Marshal.load raises, close the port anyway. Without the
     * ensure, the raise keeps the file handle open until the GC
     * collects the port. */
#if RAPI_FULL < 270
    return rb_ensure((VALUE(*)(ANYARGS))kernelLoadDataBody, (VALUE)&args,
                     (VALUE(*)(ANYARGS))kernelLoadDataEnsure, port);
#else
    return rb_ensure(kernelLoadDataBody, (VALUE)&args,
                     kernelLoadDataEnsure, port);
#endif
}

RB_METHOD_GUARD(kernelLoadData) {
    RB_UNUSED_PARAM;
    
    VALUE filename;
    VALUE raw;
    rb_scan_args(argc, argv, "11", &filename, &raw);
    SafeStringValue(filename);
    
    bool rawv;
    rb_bool_arg(raw, &rawv);
    return kernelLoadDataInt(RSTRING_PTR(filename), true, rawv);
}
RB_METHOD_GUARD_END

RB_METHOD(kernelSaveData) {
    RB_UNUSED_PARAM;
    
    VALUE obj;
    VALUE filename;
    
    rb_get_args(argc, argv, "oS", &obj, &filename RB_ARG_END);
    
    VALUE file = rb_file_open_str(filename, "wb");
    
    VALUE marsh = rb_const_get(rb_cObject, rb_intern("Marshal"));
    
    VALUE v[] = {obj, file};
    rb_funcall2(marsh, rb_intern("dump"), ARRAY_SIZE(v), v);
    
    rb_io_close(file);
    
    return Qnil;
}

struct ProtectedCallArgs {
    VALUE recv;
    ID mid;
    int argc;
    const VALUE *argv;
};

static VALUE protectedFuncall2(VALUE arg) {
    ProtectedCallArgs *args = reinterpret_cast<ProtectedCallArgs *>(arg);
    return rb_funcall2(args->recv, args->mid, args->argc,
                       const_cast<VALUE *>(args->argv));
}

static VALUE callAliasProtected(VALUE recv, const char *aliasName,
                                int argc, const VALUE *argv, int *state) {
    ProtectedCallArgs args = {recv, rb_intern(aliasName), argc, argv};
    return rb_protect(protectedFuncall2, reinterpret_cast<VALUE>(&args), state);
}

static bool mkxpRetryableFileError(VALUE exc) {
    return rb_obj_is_kind_of(exc, rb_eLoadError) ||
           rb_obj_is_kind_of(exc, getRbData()->exc[ErrnoENOENT]);
}

static VALUE resolvedPathValue(const std::string &path) {
    return rb_str_new(path.c_str(), path.size());
}

static VALUE callSingletonAlias(VALUE recv, const char *aliasName,
                                int argc, const VALUE *argv) {
    return rb_funcall2(recv, rb_intern(aliasName), argc,
                       const_cast<VALUE *>(argv));
}

static bool mkxp_try_singleton_alias(VALUE recv, const char *aliasName,
                                   int argc, const VALUE *argv) {
    VALUE sc = rb_singleton_class(recv);
    if (!rb_method_boundp(sc, rb_intern(aliasName), /*ex=*/0))
        return false;
    return RTEST(callSingletonAlias(recv, aliasName, argc, argv));
}

/* The casefold-aware predicates below dispatch the original
 * (raw-syscall) method through `self` so one implementation can
 * back File, FileTest and Dir alike; each receiver carries its own
 * `_mkxp_native_orig_*` alias. The PhysFS fallback makes lookups
 * case-insensitive on iOS's case-sensitive filesystem. */
RB_METHOD_GUARD(fileExist) {
    VALUE filename;
    rb_scan_args(argc, argv, "1", &filename);
    SafeStringValue(filename);

    if (mkxp_try_singleton_alias(self, "_mkxp_native_orig_exist?", 1, &filename))
        return Qtrue;

    if (shState->fileSystem().exists(RSTRING_PTR(filename)))
        return Qtrue;

    return Qfalse;
}
RB_METHOD_GUARD_END

RB_METHOD_GUARD(fileDirectory) {
    VALUE filename;
    rb_scan_args(argc, argv, "1", &filename);
    SafeStringValue(filename);

    if (mkxp_try_singleton_alias(self, "_mkxp_native_orig_directory?", 1, &filename))
        return Qtrue;

    if (shState->fileSystem().directoryExists(RSTRING_PTR(filename)))
        return Qtrue;

    return Qfalse;
}
RB_METHOD_GUARD_END

RB_METHOD_GUARD(fileFile) {
    VALUE filename;
    rb_scan_args(argc, argv, "1", &filename);
    SafeStringValue(filename);

    if (mkxp_try_singleton_alias(self, "_mkxp_native_orig_file?", 1, &filename))
        return Qtrue;

    std::string resolved = shState->fileSystem().resolvePath(RSTRING_PTR(filename));
    if (resolved.empty())
        return Qfalse;

    return shState->fileSystem().directoryExists(resolved.c_str()) ? Qfalse : Qtrue;
}
RB_METHOD_GUARD_END

RB_METHOD_GUARD(dirExist) {
    VALUE filename;
    rb_scan_args(argc, argv, "1", &filename);
    SafeStringValue(filename);

    if (mkxp_try_singleton_alias(self, "_mkxp_native_orig_exist?", 1, &filename))
        return Qtrue;

    if (shState->fileSystem().directoryExists(RSTRING_PTR(filename)))
        return Qtrue;

    return Qfalse;
}
RB_METHOD_GUARD_END

RB_METHOD(kernelRequireCasefold) {
    VALUE path;
    rb_scan_args(argc, argv, "1", &path);
    SafeStringValue(path);

    int state = 0;
    VALUE result = callAliasProtected(rb_mKernel, "_mkxp_native_require_alias", 1, &path, &state);
    if (!state)
        return result;

    VALUE exc = rb_errinfo();
    if (!mkxpRetryableFileError(exc))
        rb_exc_raise(exc);

    std::string resolved = shState->fileSystem().resolveFeaturePath(RSTRING_PTR(path));
    if (resolved.empty())
        rb_exc_raise(exc);

    VALUE resolvedValue = resolvedPathValue(resolved);
    rb_set_errinfo(Qnil);
    result = callAliasProtected(rb_mKernel, "_mkxp_native_require_alias", 1, &resolvedValue, &state);
    if (!state)
        return result;

    rb_exc_raise(rb_errinfo());
}

RB_METHOD(kernelLoadCasefold) {
    VALUE path;
    VALUE wrap = Qfalse;
    rb_scan_args(argc, argv, "11", &path, &wrap);
    SafeStringValue(path);

    VALUE args[] = {path, wrap};
    int state = 0;
    VALUE result = callAliasProtected(rb_mKernel, "_mkxp_native_load_alias", ARRAY_SIZE(args), args, &state);
    if (!state)
        return result;

    VALUE exc = rb_errinfo();
    if (!mkxpRetryableFileError(exc))
        rb_exc_raise(exc);

    std::string resolved = shState->fileSystem().resolveFeaturePath(RSTRING_PTR(path));
    if (resolved.empty())
        rb_exc_raise(exc);

    VALUE resolvedArgs[] = {resolvedPathValue(resolved), wrap};
    rb_set_errinfo(Qnil);
    result = callAliasProtected(rb_mKernel, "_mkxp_native_load_alias", ARRAY_SIZE(resolvedArgs), resolvedArgs, &state);
    if (!state)
        return result;

    rb_exc_raise(rb_errinfo());
}
#if RAPI_FULL > 187
#if RAPI_FULL < 270
static VALUE stringForceUTF8(VALUE arg)
#else
static VALUE stringForceUTF8(RB_BLOCK_CALL_FUNC_ARGLIST(arg, callback_arg))
#endif
{
    if (RB_TYPE_P(arg, RUBY_T_STRING) && ENCODING_IS_ASCII8BIT(arg) && !mkxpUsingRuby18Encoding())
        rb_enc_associate_index(arg, rb_utf8_encindex());
    
    return arg;
}

#if RAPI_FULL < 270
static VALUE customProc(VALUE arg, VALUE proc) {
    VALUE obj = stringForceUTF8(arg);
    obj = rb_funcall2(proc, rb_intern("call"), 1, &obj);
    
    return obj;
}
#endif

RB_METHOD(_marshalLoad) {
    RB_UNUSED_PARAM;
#if RAPI_FULL < 270
    VALUE port, proc = Qnil;
    rb_get_args(argc, argv, "o|o", &port, &proc RB_ARG_END);
#else
    VALUE port;
    rb_get_args(argc, argv, "o", &port RB_ARG_END);
#endif
    
    VALUE utf8Proc;
#if RAPI_FULL < 270
    if (NIL_P(proc))
        
        utf8Proc = rb_proc_new(RUBY_METHOD_FUNC(stringForceUTF8), Qnil);
    else
        utf8Proc = rb_proc_new(RUBY_METHOD_FUNC(customProc), proc);
#else
    utf8Proc = rb_proc_new(stringForceUTF8, Qnil);
#endif
    
    VALUE marsh = rb_const_get(rb_cObject, rb_intern("Marshal"));
    
    VALUE v[] = {port, utf8Proc};
    return rb_funcall2(marsh, rb_intern("_mkxp_load_alias"), ARRAY_SIZE(v), v);
}
#endif

void fileIntBindingInit() {
    VALUE klass = rb_define_class("FileInt", rb_cIO);
#if RAPI_FULL > 187
    rb_define_alloc_func(klass, classAllocate<&FileIntType>);
#else
    rb_define_alloc_func(klass, FileIntAllocate);
#endif
    
    _rb_define_method(klass, "read", fileIntRead);
    _rb_define_method(klass, "getbyte", fileIntGetByte);
#if RAPI_FULL <= 187
    // Ruby doesn't see this as an initialized stream,
    // so either that has to be fixed or necessary
    // IO functions have to be overridden
    rb_define_alias(klass, "getc", "getbyte");
    _rb_define_method(klass, "pos", fileIntPos);
#endif
    _rb_define_method(klass, "binmode", fileIntBinmode);
    _rb_define_method(klass, "close", fileIntClose);

    VALUE fileTest = rb_const_get(rb_cObject, rb_intern("FileTest"));
    VALUE fileSC = rb_singleton_class(rb_cFile);
    VALUE fileTestSC = rb_singleton_class(fileTest);
    VALUE dirSC = rb_singleton_class(rb_cDir);
    VALUE kernelSC = rb_singleton_class(rb_mKernel);

    mkxp_define_alias_once(fileSC, "_mkxp_native_orig_exist?", "exist?");
    mkxp_define_alias_once(fileSC, "_mkxp_native_orig_file?", "file?");
    mkxp_define_alias_once(fileSC, "_mkxp_native_orig_directory?", "directory?");
    mkxp_define_alias_once(fileTestSC, "_mkxp_native_orig_exist?", "exist?");
    mkxp_define_alias_once(fileTestSC, "_mkxp_native_orig_file?", "file?");
    mkxp_define_alias_once(fileTestSC, "_mkxp_native_orig_directory?", "directory?");
    mkxp_define_alias_once(dirSC, "_mkxp_native_orig_exist?", "exist?");
    mkxp_define_alias_once(kernelSC, "_mkxp_native_require_alias", "require");
    mkxp_define_alias_once(kernelSC, "_mkxp_native_load_alias", "load");

    rb_define_singleton_method(rb_cFile, "exist?", RUBY_METHOD_FUNC(fileExist), -1);
    rb_define_singleton_method(rb_cFile, "file?", RUBY_METHOD_FUNC(fileFile), -1);
    rb_define_singleton_method(rb_cFile, "directory?", RUBY_METHOD_FUNC(fileDirectory), -1);
    /* Pokemon Essentials preflights audio/graphics through
     * FileTest.audio_exist? -> safeExists? -> FileTest.exist? and
     * silently drops BGM when the check misses, so FileTest needs
     * the same casefold treatment as File (silent-title-music bug). */
    rb_define_singleton_method(fileTest, "exist?", RUBY_METHOD_FUNC(fileExist), -1);
    rb_define_singleton_method(fileTest, "file?", RUBY_METHOD_FUNC(fileFile), -1);
    rb_define_singleton_method(fileTest, "directory?", RUBY_METHOD_FUNC(fileDirectory), -1);
    rb_define_singleton_method(rb_cDir, "exist?", RUBY_METHOD_FUNC(dirExist), -1);

    /* Deprecated `exists?` spellings predate Ruby 3.2 and are raw
     * syscalls too; route them to the casefold impls when the VM
     * still ships them (on 3.2+ the legacy syntax-transform shims
     * in binding-mri.cpp forward to `exist?` and land here anyway). */
    if (rb_method_boundp(fileSC, rb_intern("exists?"), /*ex=*/0))
        rb_define_singleton_method(rb_cFile, "exists?", RUBY_METHOD_FUNC(fileExist), -1);
    if (rb_method_boundp(fileTestSC, rb_intern("exists?"), /*ex=*/0))
        rb_define_singleton_method(fileTest, "exists?", RUBY_METHOD_FUNC(fileExist), -1);
    if (rb_method_boundp(dirSC, rb_intern("exists?"), /*ex=*/0))
        rb_define_singleton_method(rb_cDir, "exists?", RUBY_METHOD_FUNC(dirExist), -1);
    _rb_define_module_function(rb_mKernel, "require", kernelRequireCasefold);
    _rb_define_module_function(rb_mKernel, "load", kernelLoadCasefold);
    
    _rb_define_module_function(rb_mKernel, "load_data", kernelLoadData);
    _rb_define_module_function(rb_mKernel, "save_data", kernelSaveData);
    
#if RAPI_FULL > 187
    /* We overload the built-in 'Marshal::load()' function to silently
     * insert our utf8proc that ensures all read strings will be
     * UTF-8 encoded.
     *
     * On iOS this init runs once per session; the alias must be
     * idempotent or it captures our own _marshalLoad wrapper from
     * the previous session as the "original", producing infinite
     * recursion. */
    VALUE marsh = rb_const_get(rb_cObject, rb_intern("Marshal"));
    VALUE marshSC = rb_singleton_class(marsh);
    if (!rb_method_boundp(marshSC, rb_intern("_mkxp_load_alias"), /*ex=*/0))
        rb_define_alias(marshSC, "_mkxp_load_alias", "load");
    _rb_define_module_function(marsh, "load", _marshalLoad);
#endif
}
