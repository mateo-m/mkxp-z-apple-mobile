//
//  crypto-binding.cpp
//  mkxp-z
//
//  MKXPCrypto: a minimal libcrypto (EVP) surface for the Ruby VMs
//  that cannot link a native openssl extension (the 1.8 / 1.9 era
//  exts predate OpenSSL 3 and cannot build). Preload facades build
//  the familiar OpenSSL::Cipher / Digest / HMAC / PKCS5 API on top
//  of this module, so crypto-dependent game code (AES-zip
//  updaters, HMAC-signed APIs) behaves the same on every VM.
//
//  Deliberately one-shot: callers accumulate input Ruby-side and
//  hand over complete buffers. For the block/stream ciphers games
//  use (CBC, CTR), concatenated one-shot output is byte-identical
//  to incremental output, and it keeps this file free of
//  cross-call context lifetimes. AEAD modes that need tag plumbing
//  (GCM/CCM/OCB/Poly1305) are rejected by the facade instead of
//  pretending.
//

#include <stdio.h>
#include <string>

#include "binding-util.h"

#include <openssl/evp.h>
#include <openssl/hmac.h>
#include <openssl/rand.h>

static const EVP_MD *lookupDigest(VALUE name) {
    SafeStringValue(name);
    return EVP_get_digestbyname(RSTRING_PTR(name));
}

static const EVP_CIPHER *lookupCipher(VALUE name) {
    SafeStringValue(name);
    return EVP_get_cipherbyname(RSTRING_PTR(name));
}

RB_METHOD(cryptoDigestSupported) {
    VALUE name;
    rb_get_args(argc, argv, "o", &name RB_ARG_END);
    return lookupDigest(name) ? Qtrue : Qfalse;
}

RB_METHOD(cryptoCipherSupported) {
    VALUE name;
    rb_get_args(argc, argv, "o", &name RB_ARG_END);
    return lookupCipher(name) ? Qtrue : Qfalse;
}

RB_METHOD(cryptoDigest) {
    VALUE name, data;
    rb_get_args(argc, argv, "oo", &name, &data RB_ARG_END);
    const EVP_MD *md = lookupDigest(name);
    if (!md)
        rb_raise(rb_eArgError, "unknown digest: %s", RSTRING_PTR(name));
    SafeStringValue(data);

    unsigned char out[EVP_MAX_MD_SIZE];
    unsigned int outLen = 0;
    if (!EVP_Digest(RSTRING_PTR(data), RSTRING_LEN(data), out, &outLen, md, NULL))
        rb_raise(rb_eRuntimeError, "digest failed");
    return rb_str_new((const char *)out, outLen);
}

RB_METHOD(cryptoHmac) {
    VALUE name, key, data;
    rb_get_args(argc, argv, "ooo", &name, &key, &data RB_ARG_END);
    const EVP_MD *md = lookupDigest(name);
    if (!md)
        rb_raise(rb_eArgError, "unknown digest: %s", RSTRING_PTR(name));
    SafeStringValue(key);
    SafeStringValue(data);

    unsigned char out[EVP_MAX_MD_SIZE];
    unsigned int outLen = 0;
    if (!HMAC(md, RSTRING_PTR(key), (int)RSTRING_LEN(key),
              (const unsigned char *)RSTRING_PTR(data), RSTRING_LEN(data),
              out, &outLen))
        rb_raise(rb_eRuntimeError, "HMAC failed");
    return rb_str_new((const char *)out, outLen);
}

RB_METHOD(cryptoPbkdf2Hmac) {
    VALUE pass, salt, iters, keyLen, name;
    rb_get_args(argc, argv, "ooooo", &pass, &salt, &iters, &keyLen, &name RB_ARG_END);
    const EVP_MD *md = lookupDigest(name);
    if (!md)
        rb_raise(rb_eArgError, "unknown digest: %s", RSTRING_PTR(name));
    SafeStringValue(pass);
    SafeStringValue(salt);
    int iterations = NUM2INT(iters);
    int outLen = NUM2INT(keyLen);
    if (iterations < 1 || outLen < 1 || outLen > 4096)
        rb_raise(rb_eArgError, "invalid PBKDF2 parameters");

    std::string out(outLen, '\0');
    if (!PKCS5_PBKDF2_HMAC(RSTRING_PTR(pass), (int)RSTRING_LEN(pass),
                           (const unsigned char *)RSTRING_PTR(salt),
                           (int)RSTRING_LEN(salt),
                           iterations, md, outLen, (unsigned char *)&out[0]))
        rb_raise(rb_eRuntimeError, "PBKDF2 failed");
    return rb_str_new(out.data(), outLen);
}

RB_METHOD(cryptoRandomBytes) {
    VALUE len;
    rb_get_args(argc, argv, "o", &len RB_ARG_END);
    int n = NUM2INT(len);
    if (n < 0 || n > (16 * 1024 * 1024))
        rb_raise(rb_eArgError, "invalid random byte count");
    if (n == 0)
        return rb_str_new("", 0);

    std::string out(n, '\0');
    if (RAND_bytes((unsigned char *)&out[0], n) != 1)
        rb_raise(rb_eRuntimeError, "random generator failure");
    return rb_str_new(out.data(), n);
}

RB_METHOD(cryptoCipherKeyLength) {
    VALUE name;
    rb_get_args(argc, argv, "o", &name RB_ARG_END);
    const EVP_CIPHER *cipher = lookupCipher(name);
    if (!cipher)
        rb_raise(rb_eArgError, "unknown cipher: %s", RSTRING_PTR(name));
    return INT2NUM(EVP_CIPHER_key_length(cipher));
}

RB_METHOD(cryptoCipherIvLength) {
    VALUE name;
    rb_get_args(argc, argv, "o", &name RB_ARG_END);
    const EVP_CIPHER *cipher = lookupCipher(name);
    if (!cipher)
        rb_raise(rb_eArgError, "unknown cipher: %s", RSTRING_PTR(name));
    return INT2NUM(EVP_CIPHER_iv_length(cipher));
}

/* cipher(name, encrypt, key, iv, data, padding = true) -> String.
 * One-shot EVP transform. `iv` may be an empty string for modes
 * without one (ECB). Key and IV lengths must match the cipher
 * exactly - the facade validates and pads Ruby-side so error
 * messages stay in Ruby's vocabulary. */
RB_METHOD(cryptoCipherRun) {
    VALUE name, encrypt, key, iv, data, padding;
    padding = Qtrue;
    rb_get_args(argc, argv, "ooooo|o", &name, &encrypt, &key, &iv, &data,
                &padding RB_ARG_END);
    const EVP_CIPHER *cipher = lookupCipher(name);
    if (!cipher)
        rb_raise(rb_eArgError, "unknown cipher: %s", RSTRING_PTR(name));
    SafeStringValue(key);
    SafeStringValue(iv);
    SafeStringValue(data);

    if ((int)RSTRING_LEN(key) != EVP_CIPHER_key_length(cipher))
        rb_raise(rb_eArgError, "key length %ld does not match cipher (%d)",
                 (long)RSTRING_LEN(key), EVP_CIPHER_key_length(cipher));
    int ivLen = EVP_CIPHER_iv_length(cipher);
    if (ivLen > 0 && (int)RSTRING_LEN(iv) != ivLen)
        rb_raise(rb_eArgError, "iv length %ld does not match cipher (%d)",
                 (long)RSTRING_LEN(iv), ivLen);

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx)
        rb_raise(rb_eRuntimeError, "cipher context allocation failed");

    const unsigned char *ivPtr =
        ivLen > 0 ? (const unsigned char *)RSTRING_PTR(iv) : NULL;
    int enc = RTEST(encrypt) ? 1 : 0;
    std::string out;
    int outLen = 0, finalLen = 0;
    bool ok = EVP_CipherInit_ex(ctx, cipher, NULL,
                                (const unsigned char *)RSTRING_PTR(key),
                                ivPtr, enc) == 1;
    if (ok && !RTEST(padding))
        ok = EVP_CIPHER_CTX_set_padding(ctx, 0) == 1;
    if (ok) {
        out.resize(RSTRING_LEN(data) + EVP_CIPHER_CTX_block_size(ctx) + 1);
        ok = EVP_CipherUpdate(ctx, (unsigned char *)&out[0], &outLen,
                              (const unsigned char *)RSTRING_PTR(data),
                              (int)RSTRING_LEN(data)) == 1;
    }
    if (ok)
        ok = EVP_CipherFinal_ex(ctx, (unsigned char *)&out[0] + outLen,
                                &finalLen) == 1;
    EVP_CIPHER_CTX_free(ctx);
    if (!ok)
        rb_raise(rb_eRuntimeError,
                 "cipher operation failed (wrong key, IV, or corrupt data)");

    return rb_str_new(out.data(), outLen + finalLen);
}

void cryptoBindingInit() {
    VALUE module = rb_define_module("MKXPCrypto");

    _rb_define_module_function(module, "digest_supported?", cryptoDigestSupported);
    _rb_define_module_function(module, "cipher_supported?", cryptoCipherSupported);
    _rb_define_module_function(module, "digest", cryptoDigest);
    _rb_define_module_function(module, "hmac", cryptoHmac);
    _rb_define_module_function(module, "pbkdf2_hmac", cryptoPbkdf2Hmac);
    _rb_define_module_function(module, "random_bytes", cryptoRandomBytes);
    _rb_define_module_function(module, "cipher_key_length", cryptoCipherKeyLength);
    _rb_define_module_function(module, "cipher_iv_length", cryptoCipherIvLength);
    _rb_define_module_function(module, "cipher_run", cryptoCipherRun);
}
