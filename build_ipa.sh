#!/bin/bash
set -e

echo "Cleaning previous builds..."
flutter clean

echo "Building Flutter iOS release (no codesign)..."
# We use --no-codesign to avoid signing issues if no dev team is set. 
# LiveContainer can often handle ad-hoc or unsigned binaries, or the user can sign it with AltStore/SideStore.
flutter build ios --release --no-codesign

echo "Creating IPA structure..."
rm -rf Payload ZapShare_LiveContainer.ipa
mkdir Payload

# Copy the built app to the Payload directory
cp -r build/ios/iphoneos/Runner.app Payload/

echo "Zipping IPA..."
zip -r ZapShare_LiveContainer.ipa Payload

echo "Cleaning up..."
rm -rf Payload

echo "✅ Success! ZapShare_LiveContainer.ipa is ready."
echo "You can now transfer this file to your iPhone and open it with LiveContainer."
