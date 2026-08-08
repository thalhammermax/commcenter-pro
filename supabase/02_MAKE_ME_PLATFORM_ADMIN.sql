-- STEP 1:
-- In Supabase Dashboard -> Authentication -> Users, copy your existing named staff user's UUID.
-- Replace YOUR_USER_UUID below, then run this script in SQL Editor.

do $$
declare
  v_user uuid := 'YOUR_USER_UUID';
begin
  insert into public.profiles(id,display_name)
  select id,coalesce(raw_user_meta_data->>'display_name',split_part(coalesce(email,'admin'),'@',1))
  from auth.users
  where id=v_user
  on conflict(id) do nothing;

  if not exists(select 1 from public.profiles where id=v_user) then
    raise exception 'That Auth user UUID does not exist.';
  end if;

  insert into public.platform_admins(user_id)
  values(v_user)
  on conflict(user_id) do nothing;
end $$;
