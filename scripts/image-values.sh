#!/usr/bin/env bash

# Read exactly one field from the top-level image mapping in a Helm values file.
read_image_field() {
  local file="$1"
  local field="$2"

  awk -v field="$field" '
    $0 == "image:" { in_image = 1; next }
    in_image && /^[^[:space:]]/ { in_image = 0 }
    in_image && $1 == field ":" {
      value = $0
      sub(/^[^:]+:[[:space:]]*/, "", value)
      print value
      count++
    }
    END { if (count != 1) exit 1 }
  ' "$file"
}
