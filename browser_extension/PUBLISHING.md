# How to Publish ZapShare Extension

## 1. Prepare for Upload
A zip file `ZapShare_Extension.zip` has been created in your project root (`d:\Desktop\ZapShare-main\ZapShare_Extension.zip`). This is the file you will upload.

## 2. Publish to Chrome Web Store
1.  **Register**: Go to the [Chrome Web Store Developer Dashboard](https://chrome.google.com/webstore/developer/dashboard) and sign in. (There is a one-time $5 registration fee).
2.  **Create Item**: Click **"New Item"** and upload the `ZapShare_Extension.zip` file.
3.  **Store Listing**:
    *   **Description**: "Connect to ZapShare running on your local network to send and receive files seamlessly."
    *   **Category**: "Productivity" or "Workflow".
    *   **Language**: English.
    *   **Screenshots**: Take a screenshot of the popup UI and upload it (1280x800 is a good size).
    *   **Promo Tiles**: You may need a 440x280 and 920x680 image branding.
4.  **Privacy**:
    *   **Permissions**: State that you do not collect user data. The extension only opens local network tabs (`http://...`).
    *   **Host Permissions**: We don't request broad host permissions in manifest v3 (`activeTab` or similar usually suffices, but we technically just use `tabs.create` which doesn't need special permission for distinct URLs).
    *   **Cost**: "Free".
5.  **Submit**: Click **"Submit for Review"**. Review usually takes 24-48 hours.

## 3. Publish to Firefox Add-ons (AMO)
1.  **Register**: Go to the [Firefox Add-on Developer Hub](https://addons.mozilla.org/en-US/developers/) and sign in.
2.  **Submit New Add-on**: Click **"Submit a New Add-on"**.
3.  **Distribution**: Choose "On this site" (Recommended for public availability).
4.  **Upload**: Upload the `ZapShare_Extension.zip` file. Firefox will validate it immediately.
    *   *Note*: If there are warnings about `manifest_version: 3`, it's fine as Firefox supports MV3 now, but ensure you test it in Firefox first.
5.  **Metadata**:
    *   Fill in the name, summary, and description.
    *   Upload the logo and a screenshot.
    *   Select "Linux", "Mac", "Windows" compatibility.
6.  **Review**: Submit. Firefox reviews can be very fast (minutes or hours) for simple extensions.

## Important Note on Manifest V3
This extension is built with **Manifest V3**.
- **Chrome**: Fully supported and required.
- **Firefox**: Supported, but ensure you select "Manifest V3" if asked during submission or ensure the validator accepts it (it generally does now).

## Updates
To update later:
1.  Increment the `"version"` number in `manifest.json`.
2.  Re-zip the files.
3.  Upload the new zip to the respective dashboard.
