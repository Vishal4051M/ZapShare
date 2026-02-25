-- ============================================
-- IMPROVED TRIGGER: Handle Missing Avatar URL
-- ============================================
-- This version adds a Gravatar fallback if Google doesn't provide a picture
-- Run this in Supabase SQL Editor to replace the existing trigger
-- ============================================

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
DECLARE
  avatar TEXT;
  user_name TEXT;
BEGIN
  -- Try to get avatar from Google OAuth metadata
  avatar := COALESCE(
    NEW.raw_user_meta_data->>'picture',
    NEW.raw_user_meta_data->>'avatar_url',
    NEW.raw_user_meta_data->>'photo',
    NEW.raw_user_meta_data->>'photoURL'
  );
  
  -- If Google didn't provide a picture, generate Gravatar URL
  -- Gravatar creates a unique avatar based on email hash
  IF avatar IS NULL OR avatar = '' THEN
    avatar := 'https://www.gravatar.com/avatar/' || 
              md5(lower(trim(NEW.email))) || 
              '?d=identicon&s=400';
  END IF;
  
  -- Try to get user's name from various possible fields
  user_name := COALESCE(
    NEW.raw_user_meta_data->>'name',
    NEW.raw_user_meta_data->>'full_name',
    NEW.raw_user_meta_data->>'fullName',
    NEW.raw_user_meta_data->>'display_name',
    NEW.raw_user_meta_data->>'displayName',
    split_part(NEW.email, '@', 1)
  );
  
  -- Insert or update the profile
  INSERT INTO public.profiles (id, email, full_name, avatar_url)
  VALUES (
    NEW.id,
    NEW.email,
    user_name,
    avatar
  )
  ON CONFLICT (id) DO UPDATE
  SET 
    email = EXCLUDED.email,
    full_name = EXCLUDED.full_name,
    avatar_url = EXCLUDED.avatar_url,
    updated_at = NOW();
    
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ============================================
-- Update existing users with Gravatar if they have null avatar
-- ============================================
UPDATE profiles
SET avatar_url = 'https://www.gravatar.com/avatar/' || 
                 md5(lower(trim(email))) || 
                 '?d=identicon&s=400',
    updated_at = NOW()
WHERE avatar_url IS NULL OR avatar_url = '';

-- ============================================
-- Verify the update
-- ============================================
SELECT 
  email,
  full_name,
  avatar_url,
  CASE 
    WHEN avatar_url LIKE '%gravatar%' THEN '✅ Gravatar'
    WHEN avatar_url LIKE '%googleusercontent%' THEN '✅ Google'
    ELSE '❓ Other'
  END as avatar_source
FROM profiles
ORDER BY created_at DESC;
