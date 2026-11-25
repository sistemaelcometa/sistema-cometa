-- Las bolsas usadas y vacias se archivan. Los silos fijos y bolsas nuevas siguen activos.
-- El estado surge de los movimientos validos y se revierte al anular una salida.
begin;
create or replace function cometa_bag_is_archived(target_store_id uuid)
returns boolean language sql stable security definer set search_path=public as $$
 select s.kind='bag'
  and exists(select 1 from cometa_grain_events e where e.organization_id=s.organization_id and e.destination_id=s.id and e.voided_at is null)
  and coalesce((select sum(case when e.destination_id=s.id then e.tonnes else 0 end-case when e.source_id=s.id then e.tonnes else 0 end)
    from cometa_grain_events e where e.organization_id=s.organization_id and e.voided_at is null and (e.destination_id=s.id or e.source_id=s.id)),0)<=0
 from cometa_grain_stores s where s.id=target_store_id;
$$;
revoke all on function cometa_bag_is_archived(uuid) from public,anon,authenticated;

-- Protege tambien pestañas antiguas y todos los RPC de cosechas y traslados.
create or replace function guard_cometa_bag_destination()
returns trigger language plpgsql security definer set search_path=public as $$
begin
 perform pg_advisory_xact_lock(hashtextextended(new.organization_id::text,78));
 if new.destination_id is not null and new.voided_at is null and cometa_bag_is_archived(new.destination_id) then
  raise exception 'Esta bolsa ya se uso y esta archivada. Crea una bolsa nueva para cargar mercaderia.';
 end if;
 return new;
end $$;
drop trigger if exists cometa_bag_destination on cometa_grain_events;
create trigger cometa_bag_destination before insert on cometa_grain_events for each row execute function guard_cometa_bag_destination();
revoke all on function guard_cometa_bag_destination() from public,anon,authenticated;

create or replace function get_cometa_grain(target_organization_id uuid)
returns jsonb language plpgsql stable security definer set search_path=public as $$
declare result jsonb;
begin
 if not is_org_member(target_organization_id) then raise exception 'No tenes permisos para ver estas cosechas.'; end if;
 with events as (select * from cometa_grain_events where organization_id=target_organization_id),
 balances as (
  select harvest_id,store_id,sum(delta) as tonnes from (
   select harvest_id,destination_id as store_id,tonnes as delta from events where voided_at is null and destination_id is not null
   union all select harvest_id,source_id,-tonnes from events where voided_at is null and source_id is not null
  ) x group by harvest_id,store_id having sum(delta)>0
 ) select jsonb_build_object(
  'fields',coalesce((select jsonb_agg(to_jsonb(f) order by f.name) from cometa_fields f where f.organization_id=target_organization_id),'[]'::jsonb),
  'stores',coalesce((select jsonb_agg(to_jsonb(s)||jsonb_build_object('archived',cometa_bag_is_archived(s.id)) order by s.location,s.name,s.bag_number) from cometa_grain_stores s where s.organization_id=target_organization_id),'[]'::jsonb),
  'harvests',coalesce((select jsonb_agg(to_jsonb(h)||jsonb_build_object('field_name',f.name,'voided',not exists(select 1 from events e where e.harvest_id=h.id and e.voided_at is null)) order by h.harvest_date desc,h.created_at desc) from cometa_harvests h join cometa_fields f on f.id=h.field_id where h.organization_id=target_organization_id),'[]'::jsonb),
  'balances',coalesce((select jsonb_agg(to_jsonb(b)) from balances b),'[]'::jsonb),
  'events',coalesce((select jsonb_agg(to_jsonb(e) order by e.event_date desc,e.sequence desc) from events e),'[]'::jsonb)
 ) into result;
 return result;
end $$;
revoke all on function get_cometa_grain(uuid) from public,anon;
grant execute on function get_cometa_grain(uuid) to authenticated;
commit;

