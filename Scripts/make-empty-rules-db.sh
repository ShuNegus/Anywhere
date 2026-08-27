#!/bin/sh
# Creates a schema-valid, empty Rules.db so the package builds without the
# real dataset. The app degrades gracefully: no built-in service rule sets,
# no country bypass list, no ADBlock rules. Everything else works.
set -e
DB="$(dirname "$0")/../LocalPackages/AnywhereRules/Sources/AnywhereRules/Resources/Rules.db"
mkdir -p "$(dirname "$DB")"
rm -f "$DB"
sqlite3 "$DB" <<'SQL'
CREATE TABLE rules (source TEXT NOT NULL, type INTEGER NOT NULL, value TEXT NOT NULL);
CREATE INDEX idx_rules_source ON rules(source);
CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
INSERT INTO metadata VALUES ('supportedCountryCodes','[]');
INSERT INTO metadata VALUES ('languageToCountry','{}');
INSERT INTO metadata VALUES ('supportedServices','[]');
SQL
echo "Created empty $DB"
