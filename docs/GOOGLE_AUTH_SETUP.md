# Google Sign-In Setup Guide

To enable Google Sign-In in your ZapShare application, you need to create a Google Cloud Project and obtain a **Web Client ID**.

## Step 1: Create a Google Cloud Project

1. Go to the [Google Cloud Console](https://console.cloud.google.com/).
2. Click on the project selector dropdown in the top bar.
3. Click **"New Project"**.
4. Enter a name (e.g., "ZapShare") and click **Create**.
5. Once created, select the project.

## Step 2: Configure OAuth Consent Screen

1. In the left sidebar, navigate to **APIs & Services** > **OAuth consent screen**.
2. Select **External** (unless you are a G Suite user testing internally) and click **Create**.
3. Fill in the **App Information**:
   - **App name**: ZapShare
   - **User support email**: Your email address
   - **Developer contact information**: Your email address
4. Click **Save and Continue**.
5. (Optional) You can leave "Scopes" and "Test Users" as default for now.

## Step 3: Create Web Client ID (Important!)

This ID is required for Supabase to talk to Google.

1. Navigate to **APIs & Services** > **Credentials**.
2. Click **+ CREATE CREDENTIALS** at the top and select **OAuth client ID**.
3. For **Application type**, select **Web application**.
4. Name it "ZapShare Web".
5. **Authorized Redirect URIs**:
   - You **MUST** add your Supabase Callback URL here.
   - Go to your Supabase Dashboard -> Project Settings -> API.
   - Copy the "URL" (e.g., `https://xyz.supabase.co`).
   - Append `/auth/v1/callback` to it.
   - Final URL format: `https://your-project-ref.supabase.co/auth/v1/callback`
   - Paste this into the "Authorized redirect URIs" field in Google Cloud.
6. Click **Create**.
7. A popup will show your **Client ID** and **Client Secret**.
   - Copy the **Client ID**.
   - Copy the **Client Secret**.

## Step 4: Configure Supabase

1. Go to your [Supabase Dashboard](https://supabase.com/dashboard).
2. Select your project.
3. Navigate to **Authentication** > **Providers**.
4. Select **Google**.
5. Toggle **Enable Google**.
6. Paste the **Client ID** and **Client Secret** you copied in Step 3.
7. Click **Save**.

## Step 5: Configure Android (Native App)

Since this is a Flutter Android app, you also need an Android Client ID for the app validity checks, even if using the Web Client ID for authentication tokens.

1. Back in Google Cloud Console > **Credentials** > **+ CREATE CREDENTIALS** > **OAuth client ID**.
2. Application type: **Android**.
3. **Package name**: `com.example.zap_share`
4. **SHA-1 Certificate Fingerprint**:
   - You need to generate this from your debug keystore on your development machine.
   - **Windows PowerShell**:
     ```powershell
     keytool -list -v -keystore "C:\Users\<YourUser>\.android\debug.keystore" -alias androiddebugkey -storepass android -keypass android
     ```
   - Copy the `SHA1: ...` string and paste it into the Google Cloud field.
5. Click **Create**.

## Step 6: Update Environment Variables

1. Open your `.env` file in the project root.
2. Paste your **Web Client ID** (from Step 3) into the variable:
   ```env
   GOOGLE_WEB_CLIENT_ID=your-web-client-id-here.apps.googleusercontent.com
   ```
   *(Note: The Android Client ID does not go here. Only the Web Client ID is used for the token exchange.)*

---

**Done!** You can now restart the app and try signing in with Google.
