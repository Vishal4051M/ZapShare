# 🔍 Google Profile Picture Troubleshooting

## Problem: `avatar_url` is NULL in profiles table

This means Google OAuth is not providing the profile picture URL. Let's diagnose and fix this!

---

## 📋 Step 1: Check What Google is Sending

### **Option A: Check in Supabase Dashboard**

1. Go to **Supabase Dashboard** → **SQL Editor**
2. Run this query (replace with your email):

```sql
SELECT 
  email,
  raw_user_meta_data
FROM auth.users
WHERE email = 'your@email.com';
```

3. Look at the `raw_user_meta_data` column
4. Check if you see ANY of these fields:
   - `picture`
   - `avatar_url`
   - `photo`
   - `photoURL`

### **Option B: Check in App Console**

1. **Log out** of the app
2. **Log back in** with Google
3. Check the **console/logcat** immediately after login
4. Look for:
   ```
   🔐 ========== GOOGLE LOGIN DEBUG ==========
   📧 Email: ...
   📋 Raw Metadata:
      [all fields Google sent]
   ==========================================
   ```

---

## 🎯 Common Causes & Solutions

### **Cause 1: Google Account Has No Profile Picture**

**Check:**
- Does your Google account actually have a profile picture?
- Go to https://myaccount.google.com/
- Check if you see a profile picture there

**Solution:**
- Add a profile picture to your Google account
- Log out and log back in to ZapShare

---

### **Cause 2: OAuth Scopes Not Requesting Profile Data**

Google OAuth needs specific scopes to access profile pictures.

**Check Supabase Configuration:**

1. Go to **Supabase Dashboard** → **Authentication** → **Providers** → **Google**
2. Check the **Scopes** field
3. It should include:
   ```
   openid email profile
   ```

**If missing, add the scopes:**
1. Update the scopes to: `openid email profile`
2. Save changes
3. Log out and log back in

---

### **Cause 3: Supabase Not Configured for Profile Data**

**Update Supabase Google Provider Settings:**

1. Go to **Supabase Dashboard** → **Authentication** → **Providers** → **Google**
2. Make sure these are set:
   - ✅ **Enabled**: ON
   - ✅ **Scopes**: `openid email profile`
   - ✅ **Skip nonce check**: OFF (unless you have a specific reason)

3. **Advanced Settings** (if available):
   - Look for "Request additional user data" or similar
   - Enable profile data fetching

---

### **Cause 4: Google Cloud Console Configuration**

The Google OAuth app might not be configured to share profile data.

**Check Google Cloud Console:**

1. Go to https://console.cloud.google.com/
2. Select your project
3. Go to **APIs & Services** → **Credentials**
4. Find your OAuth 2.0 Client ID (the one used in Supabase)
5. Click **Edit**
6. Check **Authorized redirect URIs** includes your Supabase callback:
   ```
   https://[your-project-ref].supabase.co/auth/v1/callback
   ```

7. Go to **OAuth consent screen**
8. Check **Scopes**:
   - Should include: `email`, `profile`, `openid`
   - If missing, add them

---

## 🛠️ Quick Fixes to Try

### **Fix 1: Force Re-authentication**

Sometimes cached OAuth data doesn't include the picture.

```dart
// In your app, completely sign out and clear session
await SupabaseService().signOut();
// Then sign in again
```

### **Fix 2: Update Trigger to Handle Missing Picture**

If Google simply doesn't provide the picture, we can set a default or use Gravatar:

```sql
-- Update the trigger function
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
DECLARE
  avatar TEXT;
BEGIN
  -- Try to get avatar from Google
  avatar := COALESCE(
    NEW.raw_user_meta_data->>'picture',
    NEW.raw_user_meta_data->>'avatar_url',
    NEW.raw_user_meta_data->>'photo'
  );
  
  -- If still null, generate Gravatar URL
  IF avatar IS NULL THEN
    avatar := 'https://www.gravatar.com/avatar/' || 
              md5(lower(trim(NEW.email))) || 
              '?d=identicon&s=200';
  END IF;
  
  INSERT INTO public.profiles (id, email, full_name, avatar_url)
  VALUES (
    NEW.id,
    NEW.email,
    COALESCE(
      NEW.raw_user_meta_data->>'name',
      NEW.raw_user_meta_data->>'full_name',
      split_part(NEW.email, '@', 1)
    ),
    avatar
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
```

This will:
1. Try to get Google picture
2. If not available, generate a Gravatar (unique avatar based on email)

### **Fix 3: Manually Set Avatar URL**

If you know your Google profile picture URL:

```sql
UPDATE profiles
SET avatar_url = 'https://lh3.googleusercontent.com/a/YOUR_PHOTO_ID'
WHERE email = 'your@email.com';
```

---

## 🔬 Advanced Debugging

### **Test OAuth Response Directly**

1. Go to **Supabase Dashboard** → **Authentication** → **Users**
2. Find your user
3. Click to view details
4. Check **Raw User Meta Data** section
5. This shows EXACTLY what Google sent

### **Check Supabase Logs**

1. Go to **Supabase Dashboard** → **Logs** → **Auth Logs**
2. Look for recent sign-in events
3. Check if there are any errors or warnings

---

## ✅ Verification Checklist

After trying fixes, verify:

- [ ] Google account has a profile picture
- [ ] Supabase Google provider has `profile` scope
- [ ] Google Cloud Console OAuth app is configured correctly
- [ ] Logged out and logged back in
- [ ] Checked console logs for metadata
- [ ] Checked `auth.users` table for `raw_user_meta_data`
- [ ] Checked `profiles` table for `avatar_url`

---

## 🎯 Next Steps

1. **Run the diagnostic query** in Supabase to see what metadata exists
2. **Log out and log back in** while watching the console
3. **Share the console output** with me - specifically the metadata fields
4. Based on what we see, we'll know exactly which fix to apply

---

## 💡 Alternative Solutions

If Google simply won't provide the picture, we have options:

### **Option 1: Use Gravatar**
- Automatically generates unique avatars based on email
- Already included in Fix 2 above

### **Option 2: Use UI Avatars**
- Generates avatars with user initials
- URL: `https://ui-avatars.com/api/?name=John+Doe&size=200`

### **Option 3: Let Users Upload**
- Add a feature to upload custom profile pictures
- Store in Supabase Storage
- Update `avatar_url` in profiles table

### **Option 4: Use Placeholder**
- Show a default icon when no picture available
- Already implemented in the UI (person icon fallback)

---

## 📞 What to Share for Help

If still stuck, share:
1. ✅ Output of the diagnostic SQL query
2. ✅ Console logs from login (the metadata section)
3. ✅ Screenshot of Supabase Google provider settings
4. ✅ Does your Google account have a profile picture?

This will help me identify the exact issue! 🚀
