#!/bin/bash
set -euo pipefail
# Called before Compile Sources. Release has neither an overlay flag nor instrumentation.
if [[ "${CONFIGURATION:-Debug}" != Debug ]]; then exit 0; fi
script_dir="$(cd "$(dirname "$0")" && pwd)"
output="${DERIVED_FILE_DIR:?DERIVED_FILE_DIR must be set}/LookinSwiftUIAOP"
toolchain="$(xcrun --find swiftc)"
host="$(dirname "$toolchain")/../lib/swift/host"
mkdir -p "$output"
if [[ ! -x "$output/instrument" || "$script_dir/Instrument.swift" -nt "$output/instrument" || "$toolchain" -nt "$output/instrument" ]]; then
    # Xcode's SDKROOT is iOS for app phases; the generator itself runs on macOS.
    env -u SDKROOT xcrun swiftc -sdk "$(env -u SDKROOT xcrun --sdk macosx --show-sdk-path)" -I "$host" -L "$host" \
        -Xlinker -rpath -Xlinker "$host" "$script_dir/Instrument.swift" -o "$output/instrument"
fi
"$output/instrument" "$output" "${LOOKIN_SWIFT_MODULE:-LookinServerSwift}" "$@"
