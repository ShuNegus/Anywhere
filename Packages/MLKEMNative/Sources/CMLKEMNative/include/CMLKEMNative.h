/*
 * Public API of the vendored mlkem-native, ML-KEM-768 (FIPS 203).
 * All functions return 0 on success.
 */
#ifndef CMLKEMNATIVE_H
#define CMLKEMNATIVE_H

#include <stdint.h>

#define aw_mlkem768_PUBLICKEYBYTES 1184
#define aw_mlkem768_SECRETKEYBYTES 2400
#define aw_mlkem768_CIPHERTEXTBYTES 1088
#define aw_mlkem768_SHAREDSECRETBYTES 32
#define aw_mlkem768_SYMBYTES 32

int aw_mlkem768_keypair(uint8_t *pk, uint8_t *sk);
/* coins = d || z (64 bytes) */
int aw_mlkem768_keypair_derand(uint8_t *pk, uint8_t *sk, const uint8_t *coins);
int aw_mlkem768_enc(uint8_t *ct, uint8_t *ss, const uint8_t *pk);
/* coins = m (32 bytes) */
int aw_mlkem768_enc_derand(uint8_t *ct, uint8_t *ss, const uint8_t *pk, const uint8_t *coins);
int aw_mlkem768_dec(uint8_t *ss, const uint8_t *ct, const uint8_t *sk);

#endif /* CMLKEMNATIVE_H */
