-- CommCenter Pro v0.6.1
-- Treatment Area cad_activity actor-kind hotfix.
--
-- v0.5.2 introduced treatment-area custody confirmation and correctly records
-- the confirmation source as actor_kind='treatment'. The original cad_activity
-- CHECK constraint only allowed staff/field/system, so Treatment Area Station
-- could reconcile custody successfully up to the audit-log INSERT and then fail
-- with:
--
-- new row for relation "cad_activity" violates check constraint
-- "cad_activity_actor_kind_check"
--
-- This migration expands only the audit-log actor classification. It does not
-- change treatment-area permissions or incident/custody behavior.

alter table public.cad_activity
  drop constraint if exists cad_activity_actor_kind_check;

alter table public.cad_activity
  add constraint cad_activity_actor_kind_check
  check(actor_kind in ('staff','field','system','treatment'));
