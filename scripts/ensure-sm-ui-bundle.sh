#!/usr/bin/env bash
# Run before signing: Bundle.module aborts at launch without this font bundle.
set -euo pipefail

APP_PATH="${1:?usage: ensure-sm-ui-bundle.sh Pace.app [build-products-directory]}"
BUNDLE_NAME="SaaSMakerUI_SaaSMakerUI.bundle"
DESTINATION="$APP_PATH/Contents/Resources/$BUNDLE_NAME"

[[ -d "$APP_PATH/Contents" ]] || { echo "missing built Pace.app: $APP_PATH" >&2; exit 1; }
if [[ ! -d "$DESTINATION" && -n "${2:-}" && -d "$2/$BUNDLE_NAME" ]]; then
    mkdir -p "$APP_PATH/Contents/Resources"
    ditto "$2/$BUNDLE_NAME" "$DESTINATION"
fi

if [[ ! -d "$DESTINATION" ]]; then
    echo "missing SaaSMakerUI font bundle: $DESTINATION; Pace would crash at launch. Rebuild with package resources before packaging." >&2
    exit 1
fi
