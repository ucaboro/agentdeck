#!/bin/zsh
# Packages the extension as a .vsix (a zip with a manifest) without needing npm/vsce, then installs it.
set -euo pipefail
cd "$(dirname "$0")"
VERSION=$(/usr/bin/python3 -c 'import json;print(json.load(open("package.json"))["version"])')
OUT="$PWD/agentdeck-bridge-$VERSION.vsix"
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/extension"
cp package.json extension.js README.md "$STAGE/extension/"
cat > "$STAGE/extension.vsixmanifest" <<XML
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Language="en-US" Id="agentdeck-bridge" Version="$VERSION" Publisher="agentdeck" />
    <DisplayName>AgentDeck Bridge</DisplayName>
    <Description xml:space="preserve">Lets AgentDeck open a specific agent chat in Cursor.</Description>
    <Categories>Other</Categories>
    <Properties>
      <Property Id="Microsoft.VisualStudio.Code.Engine" Value="^1.80.0" />
      <Property Id="Microsoft.VisualStudio.Code.ExtensionKind" Value="ui" />
    </Properties>
  </Metadata>
  <Installation><InstallationTarget Id="Microsoft.VisualStudio.Code" /></Installation>
  <Dependencies />
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" Addressable="true" />
    <Asset Type="Microsoft.VisualStudio.Services.Content.Details" Path="extension/README.md" Addressable="true" />
  </Assets>
</PackageManifest>
XML
cat > "$STAGE/[Content_Types].xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension=".json" ContentType="application/json" />
  <Default Extension=".js" ContentType="application/javascript" />
  <Default Extension=".md" ContentType="text/markdown" />
  <Default Extension=".vsixmanifest" ContentType="text/xml" />
</Types>
XML
rm -f "$OUT"
(cd "$STAGE" && /usr/bin/zip -qr "$OUT" "[Content_Types].xml" extension.vsixmanifest extension)
echo "Built $OUT"
if [[ "${1:-}" != "--no-install" ]]; then
  CURSOR_CLI=/Applications/Cursor.app/Contents/Resources/app/bin/cursor
  [[ -x "$CURSOR_CLI" ]] || { echo "Cursor CLI not found at $CURSOR_CLI"; exit 1; }
  "$CURSOR_CLI" --install-extension "$OUT" --force
fi
