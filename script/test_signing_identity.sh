#!/usr/bin/env bash
# Offline shell regressions: fake identity metadata and bundle verification only.
# No keychain access, code signing, app installation, or permission changes.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/signing_identity.sh"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/voicecodex-signing-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
PIN="$TEST_DIR/config/signing-identity"
FIRST='1111111111111111111111111111111111111111'
SECOND='ABCDEFABCDEFABCDEFABCDEFABCDEFABCDEFABCD'
MOCK_IDENTITIES="  1) $FIRST \"Developer ID Application: Example One (EXAMPLEONE)\"
  2) $SECOND \"Apple Development: Example Two (EXAMPLETWO)\"
     2 valid identities found"
MOCK_LIST_STATUS=0
MOCK_VERIFY_STATUS=0
CHECKS=0

voicecodex_list_signing_identities() {
  printf '%s\n' called >> "$TEST_DIR/identity-lookups"
  [[ "$MOCK_LIST_STATUS" == 0 ]] || return "$MOCK_LIST_STATUS"
  printf '%s\n' "$MOCK_IDENTITIES"
}

voicecodex_verify_installed_bundle() {
  [[ "$1" == "$TEST_DIR/Installed.app" ]] || return 1
  return "$MOCK_VERIFY_STATUS"
}

expect_identity() {
  local expected="$1" override="$2" adhoc_default="$3" actual
  actual="$(voicecodex_select_signing_identity "$override" "$PIN" "$adhoc_default")"
  [[ "$actual" == "$expected" ]] || { echo 'FAIL: selected an unexpected identity' >&2; exit 1; }
  CHECKS=$((CHECKS + 1))
}

expect_selection_failure() {
  local override="$1" adhoc_default="$2"
  if voicecodex_select_signing_identity "$override" "$PIN" "$adhoc_default" > "$TEST_DIR/output" 2> "$TEST_DIR/error"; then
    echo 'FAIL: invalid signing configuration was accepted' >&2
    exit 1
  fi
  [[ ! -s "$TEST_DIR/output" ]] || { echo 'FAIL: failed selection returned an identity' >&2; exit 1; }
  CHECKS=$((CHECKS + 1))
}

# An unconfigured CI build may be ad hoc, but a normal run/install is explicit.
expect_identity '-' '' true
expect_selection_failure '' false
[[ ! -e "$TEST_DIR/identity-lookups" ]]
expect_identity "$FIRST" "$FIRST" false
expect_identity "$SECOND" 'abcdefabcdefabcdefabcdefabcdefabcdefabcd' false
expect_identity "$FIRST" 'Developer ID Application: Example One (EXAMPLEONE)' false
[[ ! -e "$PIN" ]] # Merely resolving an identity cannot pin it.

# The saved identity is reused; explicit choices have precedence.
mkdir -p "$(dirname "$PIN")"
printf '%s\n' "$FIRST" > "$PIN"
expect_identity "$FIRST" '' false
expect_identity "$SECOND" "$SECOND" false
expect_identity '-' '-' false
expect_selection_failure 'Missing Certificate' true
printf '%s\n' '2222222222222222222222222222222222222222' > "$PIN"
expect_selection_failure '' true # Even CI cannot silently ignore a broken pin.

# Saved data is never executed; extra lines are rejected instead of sourced.
printf '$(touch "%s")\n' "$TEST_DIR/evaluated" > "$PIN"
expect_selection_failure '' false
[[ ! -e "$TEST_DIR/evaluated" ]]
printf '%s\n%s\n' "$FIRST" "$SECOND" > "$PIN"
expect_selection_failure '' false
expect_identity '-' '-' false # Explicit ad hoc does not consult the broken pin.

# Ambiguous names cannot switch certificates depending on keychain ordering.
MOCK_IDENTITIES="  1) $FIRST \"Same Name\"
  2) $SECOND \"Same Name\""
expect_selection_failure 'Same Name' false
expect_identity "$FIRST" "$FIRST" false
MOCK_LIST_STATUS=1
expect_selection_failure "$FIRST" true
MOCK_LIST_STATUS=0

# A failed installed-bundle check must preserve the previous pinned identity.
printf '%s\n' "$FIRST" > "$PIN"
MOCK_VERIFY_STATUS=1
if voicecodex_finish_install_signing "$SECOND" "$PIN" "$TEST_DIR/Installed.app" true > /dev/null; then
  echo 'FAIL: failed installation verification was accepted' >&2
  exit 1
fi
[[ "$(cat "$PIN")" == "$FIRST" ]]
CHECKS=$((CHECKS + 1))
MOCK_VERIFY_STATUS=0
voicecodex_finish_install_signing "$SECOND" "$PIN" "$TEST_DIR/Installed.app" false
[[ "$(cat "$PIN")" == "$FIRST" ]]
CHECKS=$((CHECKS + 1))
voicecodex_finish_install_signing "$SECOND" "$PIN" "$TEST_DIR/Installed.app" true > /dev/null
[[ "$(cat "$PIN")" == "$SECOND" ]]
[[ "$(/usr/bin/stat -f '%Lp' "$PIN")" == 600 ]]
[[ "$(wc -c < "$PIN" | tr -d '[:space:]')" == 41 ]]
CHECKS=$((CHECKS + 1))
if voicecodex_remember_signing_identity '-' "$PIN" 2> /dev/null; then
  echo 'FAIL: an ad hoc identity was remembered' >&2
  exit 1
fi
[[ "$(cat "$PIN")" == "$SECOND" ]]
CHECKS=$((CHECKS + 1))

echo "PASS: $CHECKS offline signing-selection and persistence checks."
