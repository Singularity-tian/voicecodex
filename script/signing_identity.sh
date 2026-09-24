#!/usr/bin/env bash
# Literal local signing configuration. This file is sourced by the build script;
# the user's saved identity is data and is never sourced or evaluated.

voicecodex_list_signing_identities() {
  /usr/bin/security find-identity -v -p codesigning
}

voicecodex_select_signing_identity() {
  local override="$1" config_file="$2" allow_adhoc_default="$3"
  local selected="$override" contents size identities line fingerprint name match=""
  local identity_pattern='^[[:space:]]*[0-9]+\)[[:space:]]+([[:xdigit:]]{40})[[:space:]]+"(.*)"$'
  if [[ -z "$selected" && ( -e "$config_file" || -L "$config_file" ) ]]; then
    if [[ ! -f "$config_file" || ! -r "$config_file" ]]; then
      echo "The saved signing identity cannot be read; set VOICECODEX_SIGNING_IDENTITY explicitly." >&2
      return 1
    fi
    contents="$(cat "$config_file")" || return 1
    size="$(wc -c < "$config_file")"
    if [[ ! "$contents" =~ ^[[:xdigit:]]{40}$ || "$size" -gt 41 ]]; then
      echo "The saved signing identity is invalid; expected one certificate fingerprint." >&2
      return 1
    fi
    selected="$contents"
  fi
  if [[ -z "$selected" ]]; then
    if [[ "$allow_adhoc_default" == true ]]; then
      printf '%s\n' '-'
      return
    fi
    echo "Choose VOICECODEX_SIGNING_IDENTITY and install with --remember-signing-identity." >&2
    echo "For an intentional temporary ad hoc build, set VOICECODEX_SIGNING_IDENTITY=-." >&2
    return 1
  fi
  if [[ "$selected" == '-' ]]; then
    printf '%s\n' '-'
    return
  fi
  if ! identities="$(voicecodex_list_signing_identities)"; then
    echo "Available code-signing identities could not be checked; signing was not changed." >&2
    return 1
  fi
  while IFS= read -r line; do
    [[ "$line" =~ $identity_pattern ]] || continue
    fingerprint="${BASH_REMATCH[1]}"
    name="${BASH_REMATCH[2]}"
    if [[ "$selected" == "$name" || "$(printf '%s' "$selected" | tr '[:lower:]' '[:upper:]')" == "$fingerprint" ]]; then
      if [[ -n "$match" && "$match" != "$fingerprint" ]]; then
        echo "The signing identity name is ambiguous; use its full certificate fingerprint." >&2
        return 1
      fi
      match="$fingerprint"
    fi
  done <<< "$identities"
  if [[ -z "$match" ]]; then
    echo "The selected signing identity is unavailable. No ad hoc fallback was used." >&2
    return 1
  fi
  printf '%s\n' "$match"
}

voicecodex_remember_signing_identity() (
  local fingerprint="$1" config_file="$2" directory temporary
  if [[ ! "$fingerprint" =~ ^[[:xdigit:]]{40}$ ]]; then
    echo "Only a verified certificate identity can be remembered." >&2
    return 1
  fi
  umask 077
  directory="$(dirname "$config_file")"
  mkdir -p "$directory" || return 1
  temporary="$(mktemp "$directory/.signing-identity.XXXXXX")" || return 1
  trap 'rm -f "$temporary"' EXIT
  printf '%s\n' "$fingerprint" > "$temporary" || return 1
  chmod 600 "$temporary" || return 1
  mv -f "$temporary" "$config_file"
)

voicecodex_verify_installed_bundle() {
  /usr/bin/codesign --verify --strict "$1"
}

voicecodex_finish_install_signing() {
  local fingerprint="$1" config_file="$2" bundle="$3" remember="$4"
  voicecodex_verify_installed_bundle "$bundle" || return 1
  if [[ "$remember" == true ]]; then
    voicecodex_remember_signing_identity "$fingerprint" "$config_file" || return 1
    echo "Saved signing identity for future local builds."
  fi
}
