-- Extracciones de varios silos en una sola operacion atomica. Solo stock.
begin;
create or replace function register_cometa_grain_batch(target_organization_id uuid,operation_id uuid,entry_date date,entry_kind text,sources jsonb,destination_store_id uuid default null,entry_detail text default '',entry_reference text default '')
returns uuid language plpgsql security definer set search_path=public as $$
declare payload jsonb; existing cometa_grain_events; part jsonb; origin uuid; source_store uuid; amount numeric; available numeric; latest date;
begin
 if not has_org_role(target_organization_id,array['owner','admin','editor']::app_role[]) then raise exception 'No tenes permisos para registrar extracciones.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(target_organization_id::text,78));
 payload:=jsonb_build_object('batch_exit',true,'date',entry_date,'kind',entry_kind,'sources',sources,'destination',destination_store_id,'detail',entry_detail,'reference',entry_reference);
 select * into existing from cometa_grain_events e where e.operation_id=register_cometa_grain_batch.operation_id limit 1;
 if found then
  if existing.organization_id<>target_organization_id or existing.request is distinct from payload then raise exception 'La operacion ya existe con otros datos.'; end if;
  return operation_id;
 end if;
 if operation_id is null or exists(select 1 from cometa_harvests h where h.id=operation_id) or entry_date is null or entry_kind is null or entry_kind not in ('sale','transfer') then raise exception 'Revisa la fecha y el tipo de extraccion.'; end if;
 if jsonb_typeof(sources) is distinct from 'array' or jsonb_array_length(sources) not between 1 and 100 then raise exception 'Agrega al menos un origen de la mercaderia.'; end if;
 if entry_detail is null or length(trim(entry_detail)) not between 1 and 200 or length(coalesce(entry_reference,''))>200 then raise exception 'Completa el detalle de la extraccion (hasta 200 caracteres).'; end if;
 if entry_kind='transfer' and not exists(select 1 from cometa_grain_stores s where s.id=destination_store_id and s.organization_id=target_organization_id) or entry_kind='sale' and destination_store_id is not null then raise exception 'Destino de traslado invalido.'; end if;
 for part in select value from jsonb_array_elements(sources) loop
  origin:=(part->>'harvest_id')::uuid;source_store:=(part->>'source_id')::uuid;amount:=(part->>'tonnes')::numeric;
  if amount is null or amount::text in ('NaN','Infinity','-Infinity') or amount<=0 or amount>=1e11 or amount<>round(amount,3) then raise exception 'Ingresa toneladas positivas con hasta 3 decimales en cada origen.'; end if;
  if not exists(select 1 from cometa_harvests h where h.id=origin and h.organization_id=target_organization_id) or not exists(select 1 from cometa_grain_stores s where s.id=source_store and s.organization_id=target_organization_id) or entry_kind='transfer' and source_store=destination_store_id then raise exception 'Origen o destino de mercaderia invalido.'; end if;
  select max(event_date) into latest from cometa_grain_events e where e.harvest_id=origin and e.voided_at is null;
  if latest is null or entry_date<latest then raise exception 'La fecha debe ser igual o posterior a la ultima operacion de cada partida (%).',latest; end if;
  select coalesce(sum(case when e.destination_id=source_store then e.tonnes else 0 end-case when e.source_id=source_store then e.tonnes else 0 end),0) into available from cometa_grain_events e where e.harvest_id=origin and e.voided_at is null;
  if amount>available then raise exception 'Una cantidad supera el saldo disponible de su origen: % toneladas.',available; end if;
  insert into cometa_grain_events(operation_id,organization_id,harvest_id,event_date,kind,source_id,destination_id,tonnes,recipient,reference,request,created_by)
  values(operation_id,target_organization_id,origin,entry_date,entry_kind,source_store,destination_store_id,amount,trim(entry_detail),trim(coalesce(entry_reference,'')),payload,auth.uid());
 end loop;
 return operation_id;
end $$;

create or replace function void_cometa_grain_operation(target_organization_id uuid,target_operation_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
 if not has_org_role(target_organization_id,array['owner','admin','editor']::app_role[]) then raise exception 'No tenes permisos para anular operaciones.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(target_organization_id::text,78));
 if not exists(select 1 from cometa_grain_events where organization_id=target_organization_id and operation_id=target_operation_id) then raise exception 'No se encontro la operacion.'; end if;
 if not exists(select 1 from cometa_grain_events where organization_id=target_organization_id and operation_id=target_operation_id and voided_at is null) then return; end if;
 -- Todos los origenes deben poder deshacerse; si falla uno no se anula ninguno.
 if exists(
  select 1 from (select harvest_id,max(sequence) as last_sequence from cometa_grain_events where organization_id=target_organization_id and operation_id=target_operation_id group by harvest_id) affected
  join cometa_grain_events later on later.harvest_id=affected.harvest_id
  where later.voided_at is null and later.operation_id<>target_operation_id and later.sequence>affected.last_sequence
 ) then raise exception 'Primero anula las operaciones posteriores de las partidas involucradas.'; end if;
 update cometa_grain_events set voided_at=coalesce(voided_at,now()) where organization_id=target_organization_id and operation_id=target_operation_id;
end $$;
revoke all on function register_cometa_grain_batch(uuid,uuid,date,text,jsonb,uuid,text,text),void_cometa_grain_operation(uuid,uuid) from public,anon;
grant execute on function register_cometa_grain_batch(uuid,uuid,date,text,jsonb,uuid,text,text),void_cometa_grain_operation(uuid,uuid) to authenticated;
commit;
