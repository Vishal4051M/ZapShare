# Building for LG WebOS

This guide explains how to build the ZapShare application for LG TV (WebOS).

## Prerequisites

- Flutter SDK
- LG app packaging tools (ares-cli) - *Optional, you can also zip manually*

## 1. Build Flutter Web App

Run the following command to build the web version of the app. We use the HTML renderer for better compatibility with older TV browsers, but you can try `canvaskit` if performance is an issue on newer TVs.

```bash
flutter build web --release --no-tree-shake-icons --web-renderer html
```

## 2. Prepare for WebOS

The build output will be in `build/web`.
We have already added `appinfo.json` to the `web` folder, so it should automatically be copied to `build/web` during the build process.

**Verify:** Check if `build/web/appinfo.json` exists after building.

## 3. Package (.ipk)

You need to package the contents of `build/web` into an `.ipk` file.

### Option A: Using CLI (Recommended)

If you have `ares-cli` installed:

```bash
ares-package build/web
```

This will generate a `.ipk` file (e.g., `com.zapshare.app_1.0.0_all.ipk`) in your current directory.

### Option B: Manual Packaging (For Developer Mode / IPK Packager)

If you don't have the CLI, you can zip the contents of `build/web` (ensure `appinfo.json` is at the root of the zip) and rename it for some installers, or strictly follow the IPK format (which is a `debian-binary`, `control.tar.gz`, and `data.tar.gz`).
**Actually, it is highly recommended to use the standard tools or an extension.**

For simple testing on some LG TVs with "Developer Mode":
1. Open the "Developer Mode" app on TV.
2. Enable "Key Server".
3. Connect via IDE (VS Code with WebOS extension) or CLI.

## 4. Install on TV

```bash
ares-install -d <DEVICE_NAME> com.zapshare.app_1.0.0_all.ipk
```
(Replace `<DEVICE_NAME>` with your configured device name, usually `tv`).

## TV Specific Considerations

- **Navigation**: The app uses D-pad keys which map to Arrow keys in a web environment. Ensure `GenericShortcuts` or standard Focus traversal is working.
- **Back Button**: WebOS maps the remote Back button to the browser Back history. Ensure `WillPopScope` or equivalent handles this if needed.
- **Performance**: TVs have lower resources. Avoid heavy animations if possible.
