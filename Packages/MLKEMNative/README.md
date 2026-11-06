# MLKEMNative

Vendored [mlkem-native](https://github.com/pq-code-package/mlkem-native) — ML-KEM-768 (FIPS 203) in portable C, used for the
X25519MLKEM768 key share on iOS 18–25, where CryptoKit has no ML-KEM. On iOS 26+ the app uses CryptoKit
(`Shared/Networking/Protocols/TLS/MLKEM768Shim.swift` picks the implementation).

- Source: tag **v2.0.0**, commit `d1b2fe782888bdb761a50336012923180be7f502`, directory `mlkem/`.
- Licence: Apache-2.0 OR ISC OR MIT (see `LICENSE`, copied verbatim from the release).
- What was left out: `mlkem/src/native/` and `mlkem/src/fips202/native/` (assembly backends), `mlkem_native_asm.S`,
  `mlkem/README.md`. The build is portable C only.
- Build: one compilation unit, `Sources/CMLKEMNative/aw_mlkem.c`, which sets `MLK_CONFIG_FILE` to
  `aw_mlkem_config.h` (ML-KEM-768, namespace `aw_mlkem768`, internal symbols `static`,
  randomness from `SecRandomCopyBytes`) and includes `vendor/mlkem_native.c`. `vendor/` is excluded from the target, so
  its files are only reached through that include.
- Public C API: `Sources/CMLKEMNative/include/CMLKEMNative.h`; Swift API: `MLKEM768Native` in `Sources/MLKEMNative`.

## Tests

`swift test` in this directory (runs on macOS 26+ for the CryptoKit cases):
- known-answer vectors: the ML-KEM-768 block of `examples/monolithic_build/expected_test_vectors.h` from the same
  release (keygen from `d || z`, encapsulation with `m`; pk/sk/ct checked by SHA-256, shared secret in full);
- cross-checks with CryptoKit: the same 64-byte seed gives the same public key, and encapsulation/decapsulation
  interoperate in both directions.

## Updating

1. `git clone --depth 1 --branch <tag> https://github.com/pq-code-package/mlkem-native`
2. Replace `Sources/CMLKEMNative/vendor/` with the new `mlkem/`, then delete the same files as above.
3. Diff the new `mlkem/mlkem_native_config.h` against the previous one for renamed `MLK_CONFIG_*` options used in
   `aw_mlkem_config.h`; refresh the vectors in the tests from the new `expected_test_vectors.h`.
4. Update the tag and commit here, run `swift test` and the app's `MLKEM768ShimTests`.
