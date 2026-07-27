#!/usr/bin/env bash
# autoDev — shared config resolution for bash scripts (sibling of scripts/lib/config.mjs).
# Source this, then call autodev_resolve_config <repo-root> once; it sets:
#   AUTODEV_PROJECT_CONFIG    path to the committed .autodev/deployment.json
#   AUTODEV_LOCAL_CONFIG      path to the resolved local-override file, or "" if none
#   AUTODEV_CFG_LEGACY_SPLIT  "true" if a local-only field is still inline in
#                             deployment.json with no local file covering it
# Local file resolution (first found wins): repo-local .autodev/deployment.local.json,
# then ~/.config/autodev/<client_name>/deployment.local.json, then neither (legacy
# fallback — autodev_cfg_get reads straight from deployment.json in that case).
# $AUTODEV_LOCAL_CONFIG (pre-set before sourcing) forces an explicit local-file path;
# if that path doesn't exist, resolution yields no local file at all (it does NOT fall
# back to repo-local/global discovery).

autodev_resolve_config() {
  local repo="${1:?autodev_resolve_config: repo path required}"
  AUTODEV_PROJECT_CONFIG="$repo/.autodev/deployment.json"
  local forced="${AUTODEV_LOCAL_CONFIG:-}"
  AUTODEV_LOCAL_CONFIG=""

  if [[ -n "$forced" ]]; then
    # An explicit override wins outright — and when it points at a path that isn't
    # there, resolution ends with no local file rather than silently falling back to
    # repo-local/global discovery (matches config.mjs's findLocalConfig()).
    [[ -f "$forced" ]] && AUTODEV_LOCAL_CONFIG="$forced"
  elif [[ -f "$repo/.autodev/deployment.local.json" ]]; then
    AUTODEV_LOCAL_CONFIG="$repo/.autodev/deployment.local.json"
  elif [[ -f "$AUTODEV_PROJECT_CONFIG" ]]; then
    local client
    client=$(jq -r '.client_name // ""' "$AUTODEV_PROJECT_CONFIG" 2>/dev/null)
    if [[ -n "$client" && -f "$HOME/.config/autodev/$client/deployment.local.json" ]]; then
      AUTODEV_LOCAL_CONFIG="$HOME/.config/autodev/$client/deployment.local.json"
    fi
  fi

  AUTODEV_CFG_LEGACY_SPLIT="false"
  if [[ -f "$AUTODEV_PROJECT_CONFIG" ]]; then
    local path inline local_val
    for path in repo.local_path runner.home_dir runner.heartbeat_file runner.rate_limited_file runner.logs_dir; do
      inline=$(jq -r --arg p "$path" 'getpath($p | split("."))' "$AUTODEV_PROJECT_CONFIG" 2>/dev/null)
      local_val="null"
      [[ -n "$AUTODEV_LOCAL_CONFIG" ]] && local_val=$(jq -r --arg p "$path" 'getpath($p | split("."))' "$AUTODEV_LOCAL_CONFIG" 2>/dev/null)
      if [[ "$local_val" == "null" && -n "$inline" && "$inline" != "null" ]]; then
        AUTODEV_CFG_LEGACY_SPLIT="true"
      fi
    done
  fi
}

# autodev_cfg_get <dotted.jq.path> <default>
# Local-override file wins, else deployment.json (legacy inline / project defaults
# like tracker.instance_label), else the given default.
autodev_cfg_get() {
  local path="$1" default="${2:-}" val="null"
  if [[ -n "${AUTODEV_LOCAL_CONFIG:-}" ]]; then
    val=$(jq -r --arg p "$path" 'getpath($p | split("."))' "$AUTODEV_LOCAL_CONFIG" 2>/dev/null)
  fi
  if [[ -z "$val" || "$val" == "null" ]] && [[ -f "${AUTODEV_PROJECT_CONFIG:-}" ]]; then
    val=$(jq -r --arg p "$path" 'getpath($p | split("."))' "$AUTODEV_PROJECT_CONFIG" 2>/dev/null)
  fi
  if [[ -z "$val" || "$val" == "null" ]]; then val="$default"; fi
  printf '%s' "$val"
}
