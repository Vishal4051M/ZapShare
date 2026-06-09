-- NEW SCHEMA: Single row per user (JSONB)
-- Run this in your Supabase SQL Editor

-- 1. Create the optimized table
CREATE TABLE public.user_clipboards (
    user_id UUID REFERENCES auth.users NOT NULL PRIMARY KEY,
    clips JSONB DEFAULT '[]'::JSONB, -- Stores array of [{content, created_at}]
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT timezone('utc'::text, now())
);

-- 2. Enable Security
ALTER TABLE public.user_clipboards ENABLE ROW LEVEL SECURITY;

CREATE POLICY "Users can view own clipboard" 
ON public.user_clipboards FOR SELECT 
USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own clipboard" 
ON public.user_clipboards FOR INSERT 
WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own clipboard" 
ON public.user_clipboards FOR UPDATE 
USING (auth.uid() = user_id);

-- 3. (Optional) Migrate old data?
-- You can probably start fresh for efficiency, as the old table structure is incompatible.
-- DROP TABLE public.clipboard_items;
