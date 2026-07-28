#!/bin/bash
# Usage: ./build.ps1 [files...]
# Example: ./build.ps1 head.html *.css storman.html *.js *.wasm > storman.bundle.html
echo --% >/dev/null;: ' | out-null
<#'
set -euo pipefail
for file in "$@"; do
    if [[ ! -f "$file" ]]; then
        if [[ "$file" == *[\*\?\[]* ]]; then
            continue
        fi
        echo "build.ps1: file not found: $file" >&2
        exit 1
    fi
    filename=${file##*/}
    extension=${filename##*.}
    extension=${extension,,}
    case "$extension" in
        html)
            cat -- "$file"
            ;;
        css)
            printf '\n<style id="%s">\n' "$filename"
            cat -- "$file"
            printf '\n</style>\n'
            ;;
        js)
            printf '\n<script id="%s">\n' "$filename"
            cat -- "$file"
            printf '\n</script>\n'
            ;;
        json)
            printf '\n<script id="%s" type="application/json">\n' "$filename"
            cat -- "$file"
            printf '\n</script>\n'
            ;;
        *)
            printf '\n<script id="%s" type="application/octet-stream">\n' "$filename"
            base64 "$file"
            printf '\n</script>\n'
            ;;
    esac
done
exit #>
$ErrorActionPreference = "Stop"
$output = ""

$files = foreach ($file in $args) {
    $resolvedPaths = @(Resolve-Path -Path $file -ErrorAction SilentlyContinue)
    if ($resolvedPaths.Count -eq 0) {
        if ([Management.Automation.WildcardPattern]::ContainsWildcardCharacters([string]$file)) {
            continue
        }
        throw "build.ps1: no files matched: $file"
    }
    foreach ($resolvedPath in $resolvedPaths) {
        if (-not (Test-Path -LiteralPath $resolvedPath.Path -PathType Leaf)) {
            throw "build.ps1: not a file: $($resolvedPath.Path)"
        }
        $resolvedPath.Path
    }
}

foreach ($path in $files) {
    $filename = [IO.Path]::GetFileName($path)
    switch ([IO.Path]::GetExtension($filename).ToLowerInvariant()) {
        ".html" {
            $output += [IO.File]::ReadAllText($path)
        }
        ".css" {
            $output += "`n<style id=`"$filename`">`n"
            $output += [IO.File]::ReadAllText($path)
            $output += "`n</style>`n"
        }
        ".js" {
            $output += "`n<script id=`"$filename`">`n"
            $output += [IO.File]::ReadAllText($path)
            $output += "`n</script>`n"
        }
        ".json" {
            $output += "`n<script id=`"$filename`" type=`"application/json`">`n"
            $output += [IO.File]::ReadAllText($path)
            $output += "`n</script>`n"
        }
        default {
            $output += "`n<script id=`"$filename`" type=`"application/octet-stream`">`n"
            $output += [Convert]::ToBase64String(
                [IO.File]::ReadAllBytes($path),
                [Base64FormattingOptions]::InsertLineBreaks
            )
            $output += "`n</script>`n"
        }
    }
}

Write-Output -NoEnumerate $output
