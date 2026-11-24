-- Liquidacion completa de un silo/silo bolsa, registrada como baja fisica.
-- No modifica cosechas ni Caja. Se anula con void_cometa_grain_operation.
begin;
create or replace function clear_cometa_grain_store(
 target_organization_id uuid,operation_id uuid,target_store_id uuid,entry_date date,
 expected_balances jsonb,entry_detail text,entry_reference text default ''
)
returns uuid language plpgsql security definer set search_path=public as $$
declare payload jsonb; expected jsonb; actual jsonb; existing cometa_grain_events; part jsonb;
begin
 if not has_org_role(target_organization_id,array['owner','admin','editor']::app_role[]) then raise exception 'No tenes permisos para liquidar stock.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(target_organization_id::text,78));
 if jsonb_typeof(expected_balances) is distinct from 'array' then raise exception 'Revisa las partidas a liquidar.'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('harvest_id',(value->>'harvest_id')::uuid,'tonnes',(value->>'tonnes')::numeric) order by (value->>'harvest_id')::uuid),'[]'::jsonb)
 into expected from jsonb_array_elements(expected_balances);
 payload:=jsonb_build_object('batch_exit',true,'stock_clear',true,'store',target_store_id,'date',entry_date,'balances',expected,'detail',entry_detail,'reference',entry_reference);
 select * into existing from cometa_grain_events e where e.operation_id=clear_cometa_grain_store.operation_id limit 1;
 if found then
  if existing.organization_id<>target_organization_id or existing.request is distinct from payload then raise exception 'La operacion ya existe con otros datos.'; end if;
  return operation_id;
 end if;
 if operation_id is null or exists(select 1 from cometa_harvests h where h.id=operation_id) or entry_date is null then raise exception 'Revisa la fecha y la operacion.'; end if;
 if not exists(select 1 from cometa_grain_stores s where s.id=target_store_id and s.organization_id=target_organization_id) then raise exception 'El almacenamiento no pertenece a esta organizacion.'; end if;
 if entry_detail is null or length(trim(entry_detail)) not between 1 and 200 or length(coalesce(entry_reference,''))>200 then raise exception 'Completa el motivo de la liquidacion (hasta 200 caracteres).'; end if;
 select coalesce(jsonb_agg(jsonb_build_object('harvest_id',b.harvest_id,'tonnes',b.tonnes) order by b.harvest_id),'[]'::jsonb) into actual
 from (
  select e.harvest_id,sum(case when e.destination_id=target_store_id then e.tonnes else 0 end-case when e.source_id=target_store_id then e.tonnes else 0 end) as tonnes
  from cometa_grain_events e where e.organization_id=target_organization_id and e.voided_at is null and (e.source_id=target_store_id or e.destination_id=target_store_id)
  group by e.harvest_id
  having sum(case when e.destination_id=target_store_id then e.tonnes else 0 end-case when e.source_id=target_store_id then e.tonnes else 0 end)>0
 ) b;
 if actual='[]'::jsonb then raise exception 'El almacenamiento ya esta sin stock.'; end if;
 if actual is distinct from expected then raise exception 'El stock cambio. Cerra esta ventana y volve a abrirla antes de liquidar.'; end if;
 if exists(select 1 from cometa_grain_events e where e.organization_id=target_organization_id and e.voided_at is null and e.event_date>entry_date and e.harvest_id in (select (value->>'harvest_id')::uuid from jsonb_array_elements(actual))) then
  raise exception 'La fecha debe ser igual o posterior a la ultima operacion de cada partida.';
 end if;
 for part in select value from jsonb_array_elements(actual) loop
  insert into cometa_grain_events(operation_id,organization_id,harvest_id,event_date,kind,source_id,tonnes,recipient,reference,request,created_by)
  values(operation_id,target_organization_id,(part->>'harvest_id')::uuid,entry_date,'sale',target_store_id,(part->>'tonnes')::numeric,trim(entry_detail),trim(coalesce(entry_reference,'')),payload,auth.uid());
 end loop;
 return operation_id;
end $$;
revoke all on function clear_cometa_grain_store(uuid,uuid,uuid,date,jsonb,text,text) from public,anon;
grant execute on function clear_cometa_grain_store(uuid,uuid,uuid,date,jsonb,text,text) to authenticated;
commit;
