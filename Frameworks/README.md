# Frameworks

## Turn.xcframework

The vk-turn TURN transport core, compiled from Go via `gomobile bind`.
Source package: `mobile/anywhere` in the `vk-turn-proxy` repository (branch `bublik-dev`).

The binary is **not** checked into git (~100 MB). Build it with:

```sh
./Scripts/build-turn-xcframework.sh
```

It must contain both slices — `ios-arm64` and `ios-arm64_x86_64-simulator` —
or simulator builds will fail to link.

It is a *static* framework (the binary is an `ar` archive), so it is linked into
`Anywhere Network Extension` only and needs no "Embed Frameworks" phase.
The generated Swift interface is `import Turn` → `AnywhereDialer`, `AnywhereStream`,
`AnywhereLogSink`, `AnywhereFreeMemory()`.
