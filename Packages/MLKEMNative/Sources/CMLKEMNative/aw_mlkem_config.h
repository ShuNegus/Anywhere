/*
 * Build configuration for the vendored mlkem-native (see ../../README.md).
 * ML-KEM-768 only, portable C (no native backends), single compilation unit,
 * randomness from SecRandomCopyBytes.
 */
#ifndef AW_MLKEM_CONFIG_H
#define AW_MLKEM_CONFIG_H

#define MLK_CONFIG_PARAMETER_SET 768
#define MLK_CONFIG_NAMESPACE_PREFIX aw_mlkem768
#define MLK_CONFIG_INTERNAL_API_QUALIFIER static
#define MLK_CONFIG_CUSTOM_RANDOMBYTES

#include "vendor/mlkem_native_config.h"

#if !defined(__ASSEMBLER__)
#include <stddef.h>
#include <stdint.h>
#include <Security/SecRandom.h>

static inline int mlk_randombytes(uint8_t *out, size_t outlen)
{
    return SecRandomCopyBytes(kSecRandomDefault, outlen, out) == errSecSuccess ? 0 : -1;
}
#endif

#endif /* AW_MLKEM_CONFIG_H */
