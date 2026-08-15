#!/bin/zsh
set -euo pipefail

SERVICE="de.topoexplorer.cdse"

echo "CDSE Client-ID einfügen und mit Return bestätigen:"
security add-generic-password -U -s "$SERVICE" -a client-id -w

echo "CDSE Client-Secret einfügen und mit Return bestätigen:"
security add-generic-password -U -s "$SERVICE" -a client-secret -w

echo "CDSE-Zugangsdaten wurden im macOS-Schlüsselbund gespeichert."
