-- ============================================
-- DIAGNOSTIC: Check what Google OAuth is providing
-- ============================================
-- Run this query to see what metadata Google sent
-- Replace 'your@email.com' with your actual email

SELECT 
  id,
  email,
  raw_user_meta_data,
  raw_user_meta_data->>'picture' as picture_field,
  raw_user_meta_data->>'avatar_url' as avatar_url_field,
  raw_user_meta_data->>'name' as name_field,
  raw_user_meta_data->>'full_name' as full_name_field
FROM auth.users
WHERE email = 'your@email.com';

-- ============================================
-- This will show you EXACTLY what fields Google provided
-- Look at the raw_user_meta_data column to see all available fields
-- ============================================
