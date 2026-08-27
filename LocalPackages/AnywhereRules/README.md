# AnywhereRules

Stands in for the upstream `hiDandelion/AnywhereRules` package, whose
repository is gone (404). Same API — `AnywhereRules.databaseURL` — so no
application code changes.

## Rules.db

The database itself is **not tracked in git**. Put your own copy at
`Sources/AnywhereRules/Resources/Rules.db`, or generate an empty one:

    Scripts/make-empty-rules-db.sh

Without it the package will not build: `Package.swift` declares the file as
a copied resource.

### Schema

    rules(source TEXT, type INTEGER, value TEXT)   -- INDEX on source
    metadata(key TEXT PRIMARY KEY, value TEXT)

`source` is a country code, a service name, or the literal `ADBlock`.
`type` is a `RoutingRuleType` raw value: 0 = IPv4 CIDR, 1 = IPv6 CIDR,
2 = domain suffix, 3 = domain keyword.

`metadata` holds three JSON values, all read by the app:

| key | shape | drives |
| --- | --- | --- |
| `supportedCountryCodes` | `["RU", "CN", …]` | Country Bypass picker |
| `supportedServices` | `["Google", "YouTube", …]` | built-in service rule sets |
| `languageToCountry` | `{"ru": "RU", …}` | country suggested from system language |

An empty database is valid: the app falls back to empty lists and only
loses the built-in sets. Custom rule sets, `.arrs` imports and subscriptions
are unaffected.
