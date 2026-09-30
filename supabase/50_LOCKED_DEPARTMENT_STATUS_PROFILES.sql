-- CommCenter Pro v0.15.7
-- Lock required CAD status profiles for EMS- and Guest-Logistics-enabled departments.
-- MOVE statuses remain independent on guest_logistics_movements and are NOT part
-- of event_departments.status_profile.

alter table public.event_departments
  alter column status_profile set default
  '["AVAILABLE","EN_ROUTE","ON_SCENE","WORKING","CLEAR","OUT_OF_SERVICE"]'::jsonb;

create or replace function private.enforce_department_module_status_profile()
returns trigger
language plpgsql
security definer
set search_path=public
as $$
begin
  -- EMS needs the standard CAD task progression plus the transport states used
  -- by patient-flow / transport workflows. If a department is both EMS and
  -- Guest Logistics enabled, the EMS-capable profile is the required superset.
  if coalesce(new.ems_enabled,false) then
    new.status_profile := '["AVAILABLE","EN_ROUTE","ON_SCENE","WORKING","TRANSPORTING","AT_HOSPITAL","CLEAR","OUT_OF_SERVICE"]'::jsonb;
  elsif coalesce(new.guest_logistics_enabled,false) then
    -- Guest Logistics MOVEs have their own status machine. This profile is only
    -- for normal CAD tickets that may also be assigned to a logistics unit.
    new.status_profile := '["AVAILABLE","EN_ROUTE","ON_SCENE","WORKING","CLEAR","OUT_OF_SERVICE"]'::jsonb;
  elsif new.status_profile is null
     or jsonb_typeof(new.status_profile) <> 'array'
     or jsonb_array_length(new.status_profile)=0
  then
    new.status_profile := '["AVAILABLE","EN_ROUTE","ON_SCENE","WORKING","CLEAR","OUT_OF_SERVICE"]'::jsonb;
  end if;

  return new;
end;
$$;

revoke all on function private.enforce_department_module_status_profile() from public;

drop trigger if exists enforce_department_module_status_profile on public.event_departments;
create trigger enforce_department_module_status_profile
before insert or update of status_profile,ems_enabled,guest_logistics_enabled
on public.event_departments
for each row
execute function private.enforce_department_module_status_profile();

-- Normalize existing module-enabled departments immediately so every deployment
-- has the statuses its workflows require. Generic departments retain any custom
-- profile they already have.
update public.event_departments
set status_profile=case
  when ems_enabled then '["AVAILABLE","EN_ROUTE","ON_SCENE","WORKING","TRANSPORTING","AT_HOSPITAL","CLEAR","OUT_OF_SERVICE"]'::jsonb
  when guest_logistics_enabled then '["AVAILABLE","EN_ROUTE","ON_SCENE","WORKING","CLEAR","OUT_OF_SERVICE"]'::jsonb
  else status_profile
end
where ems_enabled=true or guest_logistics_enabled=true;
