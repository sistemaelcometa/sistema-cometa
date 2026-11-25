-- Limpieza puntual solicitada: SOLO anulados de Cosecha/Acopio. No ejecutar como migracion.
-- Caja, lotes, almacenamientos, numeros internos y movimientos validos se conservan.
-- Si existe una sola organizacion con historial agricola, se selecciona automaticamente.
-- Si hay varias, completar chosen_organization abajo con el UUID correspondiente.
begin;

create table if not exists cometa_grain_cleanup_archive (
 entity_type text not null check(entity_type in ('event','harvest')),
 entity_id uuid not null,
 organization_id uuid not null references organizations(id),
 operation_id uuid not null,
 original_row jsonb not null,
 cleaned_at timestamptz not null default now(),
 primary key(entity_type,entity_id)
);
create index if not exists cometa_grain_cleanup_operation_idx on cometa_grain_cleanup_archive(organization_id,operation_id);
alter table cometa_grain_cleanup_archive enable row level security;
revoke all on cometa_grain_cleanup_archive from public,anon,authenticated;

create temporary table cometa_cleanup_target(organization_id uuid primary key) on commit drop;
do $$
declare
 chosen_organization uuid:=null; -- Reemplazar NULL por 'uuid-de-la-organizacion' si hay varias.
 candidates uuid[];
begin
 if chosen_organization is null then
  select array_agg(distinct organization_id) into candidates from (
   select organization_id from cometa_harvests
   union select organization_id from cometa_grain_events
   union select organization_id from cometa_grain_cleanup_archive
  ) x;
  if coalesce(cardinality(candidates),0)<>1 then raise exception 'No se puede elegir una organizacion automaticamente. Completa chosen_organization con el UUID de El Cometa.'; end if;
  chosen_organization:=candidates[1];
 end if;
 if not exists(select 1 from organizations where id=chosen_organization) then raise exception 'La organizacion elegida no existe.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(chosen_organization::text,78));
 insert into cometa_cleanup_target values(chosen_organization);
end $$;

-- Conservar los saldos por partida y destino, incluyendo los que estan en cero.
create temporary table cometa_cleanup_before on commit drop as
 select e.harvest_id,x.store_id,sum(x.delta) as tonnes
 from cometa_grain_events e join cometa_cleanup_target t on t.organization_id=e.organization_id
 cross join lateral (values(e.destination_id,e.tonnes),(e.source_id,-e.tonnes)) x(store_id,delta)
 where e.voided_at is null and x.store_id is not null
 group by e.harvest_id,x.store_id;
create temporary table cometa_cleanup_events on commit drop as
 select e.* from cometa_grain_events e join cometa_cleanup_target t on t.organization_id=e.organization_id where e.voided_at is not null;

insert into cometa_grain_cleanup_archive(entity_type,entity_id,organization_id,operation_id,original_row)
select 'event',e.id,e.organization_id,e.operation_id,to_jsonb(e) from cometa_cleanup_events e
on conflict(entity_type,entity_id) do nothing;
delete from cometa_grain_events e using cometa_cleanup_events c where e.id=c.id and e.organization_id=c.organization_id and e.voided_at is not null;

-- Una cosecha se quita solo cuando todos sus movimientos fueron anulados y eliminados.
create temporary table cometa_cleanup_harvests on commit drop as
 select h.* from cometa_harvests h join cometa_cleanup_target t on t.organization_id=h.organization_id
 where exists(select 1 from cometa_cleanup_events e where e.harvest_id=h.id)
 and not exists(select 1 from cometa_grain_events e where e.harvest_id=h.id);
insert into cometa_grain_cleanup_archive(entity_type,entity_id,organization_id,operation_id,original_row)
select 'harvest',h.id,h.organization_id,h.id,to_jsonb(h) from cometa_cleanup_harvests h
on conflict(entity_type,entity_id) do nothing;
delete from cometa_harvests h using cometa_cleanup_harvests c where h.id=c.id and h.organization_id=c.organization_id;

-- Un reintento desde una pestaña vieja no debe recrear una operacion limpiada.
create or replace function reject_cleaned_cometa_grain_operation()
returns trigger language plpgsql security definer set search_path=public as $$
declare candidate uuid;
begin
 if tg_table_name='cometa_harvests' then candidate:=new.id; else candidate:=new.operation_id; end if;
 perform pg_advisory_xact_lock(hashtextextended(new.organization_id::text,78));
 if exists(select 1 from cometa_grain_cleanup_archive a where a.organization_id=new.organization_id and a.operation_id=candidate) then
  raise exception 'Esta operacion fue anulada y limpiada. Crea un registro nuevo para cargar datos reales.';
 end if;
 return new;
end $$;
drop trigger if exists cometa_harvest_cleaned_guard on cometa_harvests;
create trigger cometa_harvest_cleaned_guard before insert on cometa_harvests for each row execute function reject_cleaned_cometa_grain_operation();
drop trigger if exists cometa_event_cleaned_guard on cometa_grain_events;
create trigger cometa_event_cleaned_guard before insert on cometa_grain_events for each row execute function reject_cleaned_cometa_grain_operation();
revoke all on function reject_cleaned_cometa_grain_operation() from public,anon,authenticated;

create temporary table cometa_cleanup_after on commit drop as
 select e.harvest_id,x.store_id,sum(x.delta) as tonnes
 from cometa_grain_events e join cometa_cleanup_target t on t.organization_id=e.organization_id
 cross join lateral (values(e.destination_id,e.tonnes),(e.source_id,-e.tonnes)) x(store_id,delta)
 where e.voided_at is null and x.store_id is not null
 group by e.harvest_id,x.store_id;
do $$ begin
 if exists((select * from cometa_cleanup_before except select * from cometa_cleanup_after)
  union all (select * from cometa_cleanup_after except select * from cometa_cleanup_before)) then
  raise exception 'La limpieza alteraria el stock. Se cancela toda la operacion.';
 end if;
end $$;

select t.organization_id,
 (select count(*) from cometa_cleanup_events) as movimientos_anulados_quitados,
 (select count(*) from cometa_cleanup_harvests) as cosechas_anuladas_quitadas,
 'Stock valido conservado. Caja sin cambios. Respaldo en cometa_grain_cleanup_archive.' as resultado
from cometa_cleanup_target t;
commit;
