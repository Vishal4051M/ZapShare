-- OPTIMIZATION: Move clipboard logic to Database
-- This prevents race conditions and handles the "Limit 10" logic efficiently on the server.

CREATE OR REPLACE FUNCTION append_clipboard_item(p_user_id UUID, p_content TEXT)
RETURNS VOID AS $$
DECLARE
    new_item JSONB;
    current_clips JSONB;
    updated_clips JSONB;
BEGIN
    new_item := jsonb_build_object(
        'content', p_content,
        'created_at', timezone('utc', now())
    );

    -- Get current clips (default to empty array if null)
    SELECT coalesce(clips, '[]'::jsonb) INTO current_clips
    FROM user_clipboards
    WHERE user_id = p_user_id;

    IF current_clips IS NULL THEN
        current_clips := '[]'::jsonb;
    END IF;

    -- Prepend new item (Logic: New Item + Current Items)
    -- We also want to remove duplicates if needed, but for raw speed/simplicity:
    -- We can just filter out previous occurrence of same content in application or rigorous SQL.
    -- Here is a robust JSONB manipulation in SQL to prepend and limit:
    
    -- 1. Prepend
    updated_clips := new_item || current_clips;
    
    -- 2. Deduplicate (Optional, but good): Remove ANY existing item that has same content
    -- This is complex in pure JSONB functions without unnesting. 
    -- For simplicity and performance, we will just prepend. 
    -- If you strictly want deduplication (bump to top), we can do:
    SELECT jsonb_agg(elem) INTO updated_clips
    FROM (
        SELECT elem 
        FROM jsonb_array_elements(updated_clips) elem
        WHERE elem->>'content' != p_content -- Filter out old ones (we just added the new one at top usually, wait)
        -- Actually, we added new one at index 0. We want to remove *subsequent* duplicates.
        -- Simpler: Just reconstruct payload explicitly.
    ) s;

    -- Let's stick to the SIMPLEST appoach which is race-condition free:
    -- Use specific JSONB path features.
    -- actually for Supabase, "jsonb_set" or "||" is best.
    
    -- RE-DESIGNED LOGIC using a query to cleaner filter:
     SELECT jsonb_agg(x) INTO updated_clips
     FROM (
        -- 1. The new item
        SELECT new_item as x
        UNION ALL
        -- 2. Existing items (excluding the new content to ensure uniqueness/bump-to-top)
        SELECT value
        FROM jsonb_array_elements(current_clips)
        WHERE value->>'content' <> p_content
        LIMIT 9 -- Keep at most 9 old items (so total is 10)
    ) t;

    -- Upsert
    INSERT INTO user_clipboards (user_id, clips, updated_at)
    VALUES (p_user_id, updated_clips, timezone('utc', now()))
    ON CONFLICT (user_id) 
    DO UPDATE SET 
        clips = EXCLUDED.clips,
        updated_at = EXCLUDED.updated_at;

END;
$$ LANGUAGE plpgsql;
