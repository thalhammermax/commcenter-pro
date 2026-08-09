-- DEVELOPMENT ONLY.
-- Run this ONLY if you already ran an older CommCenter Pro starter schema
-- and there is NO real data you need to preserve.
-- It removes only known CommCenter Pro public objects; it does not reset the whole Supabase project.

drop view if exists public.dispatch_log cascade;

drop table if exists public.poi_aliases cascade;
drop table if exists public.event_pois cascade;
drop table if exists public.event_w3w_squares cascade;
drop table if exists public.map_control_points cascade;
drop table if exists public.event_maps cascade;
drop table if exists public.ems_handoffs cascade;
drop table if exists public.ems_encounters cascade;
drop table if exists public.treatment_area_sessions cascade;
drop table if exists public.ems_treatment_areas cascade;
drop table if exists public.ems_unit_config cascade;
drop table if exists public.event_landmarks cascade;
drop table if exists public.cad_activity cascade;
drop table if exists public.unit_status_log cascade;
drop table if exists public.incident_units cascade;
drop table if exists public.incident_departments cascade;
drop table if exists public.incidents cascade;
drop table if exists public.field_sessions cascade;
drop table if exists public.units cascade;
drop table if exists public.staff_department_access cascade;
drop table if exists public.event_departments cascade;
drop table if exists public.event_staff cascade;
drop table if exists public.events cascade;
drop table if exists public.organization_members cascade;
drop table if exists public.organizations cascade;
drop table if exists public.platform_admins cascade;
drop table if exists public.profiles cascade;

drop function if exists public.handle_new_user() cascade;
drop function if exists public.is_platform_admin() cascade;
drop function if exists public.platform_create_organization(text) cascade;
drop function if exists public.add_existing_org_member(uuid,text,text) cascade;
drop function if exists public.has_org_access(uuid) cascade;
drop function if exists public.is_org_admin(uuid) cascade;
drop function if exists public.has_event_staff_access(uuid) cascade;
drop function if exists public.can_admin_event(uuid) cascade;
drop function if exists public.can_dispatch_event(uuid) cascade;
drop function if exists public.field_has_event_access(uuid) cascade;
drop function if exists public.field_has_unit_access(uuid) cascade;
drop function if exists public.storage_event_access(text) cascade;
drop function if exists public.storage_event_admin(text) cascade;
drop function if exists public.staff_events_for_org(uuid) cascade;
drop function if exists public.create_event(uuid,text,text,text,text) cascade;
drop function if exists public.set_event_field_access(uuid,text,boolean) cascade;
drop function if exists public.create_incident(uuid,uuid[],text,text,double precision,double precision,double precision,double precision,text,text,text,uuid) cascade;
drop function if exists public.assign_unit(uuid,uuid) cascade;
drop function if exists public.close_incident(uuid,text) cascade;
drop function if exists public.treatment_enter_event(text,text,text) cascade;
drop function if exists public.treatment_claim_area(uuid,uuid) cascade;
drop function if exists public.treatment_release_area(uuid) cascade;
drop function if exists public.treatment_end_session(uuid) cascade;
drop function if exists public.treatment_set_status(uuid,text,boolean) cascade;
drop function if exists public.ems_create_encounter(uuid,uuid,uuid,uuid,text) cascade;
drop function if exists public.ems_request_handoff(uuid,uuid,uuid,text) cascade;
drop function if exists public.ems_accept_handoff(uuid) cascade;
drop function if exists public.ems_decline_handoff(uuid,text) cascade;
drop function if exists public.ems_cancel_handoff(uuid) cascade;
drop function if exists public.ems_release_encounter(uuid,text) cascade;
drop function if exists public.ems_mark_transporting(uuid,text) cascade;
drop function if exists public.ems_complete_transport(uuid,text) cascade;
drop function if exists public.field_enter_event(text,text,text) cascade;
drop function if exists public.field_claim_unit(uuid,uuid) cascade;
drop function if exists public.field_release_unit(uuid) cascade;
drop function if exists public.field_end_session(uuid) cascade;
drop function if exists public.field_set_unit_status(uuid,text,uuid,timestamptz) cascade;
drop function if exists public.w3w_for_coordinate(uuid,double precision,double precision) cascade;
drop function if exists public.w3w_squares_in_bounds(uuid,double precision,double precision,double precision,double precision,integer) cascade;

drop policy if exists "CommCenter event asset read" on storage.objects;
drop policy if exists "CommCenter event asset insert" on storage.objects;
drop policy if exists "CommCenter event asset update" on storage.objects;
drop policy if exists "CommCenter event asset delete" on storage.objects;
