-- Numeracion interna mensual, adjuntos posteriores y exportaciones.
-- La limpieza borra SOLO objetos de Storage confirmados en una exportacion.
begin;
alter table cometa_movements add column if not exists receipt_month date;
alter table cometa_movements add column if not exists receipt_number integer;
alter table cometa_movements add column if not exists receipt_archived_at timestamptz;
create table if not exists cometa_receipt_counters(
 organization_id uuid not null references organizations(id) on delete cascade,
 period_month date not null,last_number integer not null default 0,
 primary key(organization_id,period_month)
);
with numbered as (
 select m.id,date_trunc('month',m.movement_date)::date as period_month,
 row_number() over(partition by m.organization_id,date_trunc('month',m.movement_date) order by m.movement_date,m.created_at,m.id)::integer as n
 from cometa_movements m
)
update cometa_movements m set receipt_month=n.period_month,receipt_number=n.n
from numbered n where m.id=n.id and m.receipt_number is null;
insert into cometa_receipt_counters
select organization_id,receipt_month,max(receipt_number) from cometa_movements group by organization_id,receipt_month
on conflict(organization_id,period_month) do update set last_number=greatest(cometa_receipt_counters.last_number,excluded.last_number);
alter table cometa_movements alter column receipt_month set not null;
alter table cometa_movements alter column receipt_number set not null;
create unique index if not exists cometa_receipt_number_idx on cometa_movements(organization_id,receipt_month,receipt_number);

create or replace function assign_cometa_receipt_number()
returns trigger language plpgsql security definer set search_path=public as $$
begin
 new.receipt_month:=date_trunc('month',new.movement_date)::date;
 insert into cometa_receipt_counters(organization_id,period_month,last_number) values(new.organization_id,new.receipt_month,1)
 on conflict(organization_id,period_month) do update set last_number=cometa_receipt_counters.last_number+1
 returning last_number into new.receipt_number;
 return new;
end;
$$;
drop trigger if exists cometa_receipt_number_on_insert on cometa_movements;
create trigger cometa_receipt_number_on_insert before insert on cometa_movements for each row execute function assign_cometa_receipt_number();

create table if not exists cometa_receipt_exports(
 id uuid primary key default gen_random_uuid(),
 organization_id uuid not null references organizations(id) on delete cascade,
 period_month date not null,
 entries jsonb not null,
 manifest jsonb,
 status text not null default 'preparing' check(status in ('preparing','ready','cleaned')),
 created_by uuid references profiles(id),
 created_at timestamptz not null default now(),
 ready_at timestamptz,
 cleanup_confirmed_at timestamptz,
 cleaned_at timestamptz
);
alter table cometa_receipt_counters enable row level security;
alter table cometa_receipt_exports enable row level security;
revoke all on cometa_receipt_counters,cometa_receipt_exports from public,anon,authenticated;
grant select on cometa_receipt_exports to authenticated;
drop policy if exists cometa_exports_read on cometa_receipt_exports;
create policy cometa_exports_read on cometa_receipt_exports for select to authenticated using(is_org_member(organization_id));

create or replace function attach_cometa_receipt(target_organization_id uuid,target_movement_id uuid,receipt_operation_id uuid,file_path text,file_name text)
returns cometa_movements language plpgsql security definer set search_path=public as $$
declare saved cometa_movements; previous cometa_movements;
begin
 if auth.uid() is null or not has_org_role(target_organization_id,array['owner','admin','editor']::app_role[]) then raise exception 'No tenes permisos para adjuntar comprobantes.';end if;
 select * into previous from cometa_movements where id=target_movement_id and organization_id=target_organization_id for update;
 if not found or previous.status<>'valid' then raise exception 'El movimiento no existe o esta anulado.';end if;
 if receipt_operation_id is null or file_path is null or file_path not like 'org/'||target_organization_id::text||'/cometa/'||receipt_operation_id::text||'/%'
 or nullif(trim(file_name),'') is null or length(file_name)>250
 or not exists(select 1 from storage.objects o where o.bucket_id='receipts' and o.name=file_path) then raise exception 'El comprobante no existe o no corresponde a esta organizacion.';end if;
 if previous.receipt_path=file_path and previous.receipt_archived_at is null then return previous;end if;
 if previous.receipt_path is not null and previous.receipt_archived_at is null then raise exception 'El movimiento ya tiene un comprobante online.';end if;
 if previous.receipt_archived_at is not null and previous.receipt_path=file_path then raise exception 'Usa una carga nueva para restaurar el comprobante.';end if;
 update cometa_movements set receipt_path=file_path,receipt_name=file_name,receipt_archived_at=null where id=previous.id returning * into saved;
 insert into audit_logs(organization_id,actor_user_id,action,entity_type,entity_id,old_values,new_values)
 values(target_organization_id,auth.uid(),'cometa_receipt_attached','cometa_movement',saved.id,to_jsonb(previous),to_jsonb(saved));
 return saved;
end;
$$;

create or replace function begin_cometa_receipt_export(target_organization_id uuid,export_month date)
returns cometa_receipt_exports language plpgsql security definer set search_path=public as $$
declare snapshot jsonb;saved cometa_receipt_exports;
begin
 if auth.uid() is null or not has_org_role(target_organization_id,array['owner','admin','editor']::app_role[]) then raise exception 'No tenes permisos para exportar comprobantes.';end if;
 if export_month is null then raise exception 'Elegi un mes.';end if;
 select jsonb_agg(jsonb_build_object('movement_id',m.id,'path',m.receipt_path,'receipt_name',m.receipt_name,
 'receipt_number',m.receipt_number,'receipt_month',m.receipt_month,'movement_date',m.movement_date,'kind',m.kind,'category',c.name,
 'concept',m.concept,'counterparty',m.counterparty,'document_number',m.document_number,'amount',m.amount,'currency',m.currency,
 'status',m.status,'receipt_archived_at',m.receipt_archived_at) order by m.receipt_number)
 into snapshot from cometa_movements m join cometa_categories c on c.id=m.category_id and c.organization_id=m.organization_id
 where m.organization_id=target_organization_id and m.receipt_month=date_trunc('month',export_month)::date;
 if snapshot is null or not exists(select 1 from jsonb_array_elements(snapshot) e where e->>'path' is not null and e->>'receipt_archived_at' is null) then raise exception 'No hay comprobantes online para descargar en ese mes.';end if;
 insert into cometa_receipt_exports(organization_id,period_month,entries,created_by)
 values(target_organization_id,date_trunc('month',export_month)::date,snapshot,auth.uid()) returning * into saved;
 return saved;
end;
$$;

create or replace function complete_cometa_receipt_export(target_organization_id uuid,target_export_id uuid,file_manifest jsonb)
returns void language plpgsql security definer set search_path=public as $$
declare saved cometa_receipt_exports;expected integer;
begin
 if auth.uid() is null or not has_org_role(target_organization_id,array['owner','admin','editor']::app_role[]) then raise exception 'No tenes permisos para completar exportaciones.';end if;
 select * into saved from cometa_receipt_exports where id=target_export_id and organization_id=target_organization_id for update;
 if not found then raise exception 'La exportacion no existe.';end if;
 if saved.status='cleaned' then raise exception 'La exportacion ya fue limpiada.';end if;
 select count(*) into expected from jsonb_array_elements(saved.entries) e where e->>'path' is not null and e->>'receipt_archived_at' is null;
 if jsonb_typeof(file_manifest)<>'array' or jsonb_array_length(file_manifest)<>expected then raise exception 'La descarga no incluye todos los comprobantes.';end if;
 if exists(
  select 1 from jsonb_array_elements(file_manifest) f
  where f->>'sha256' is null or f->>'sha256'!~'^[a-f0-9]{64}$' or coalesce(f->>'bytes','')!~'^[1-9][0-9]*$'
   or not exists(select 1 from jsonb_array_elements(saved.entries) e where e->>'movement_id'=f->>'movement_id' and e->>'path'=f->>'path' and e->>'receipt_archived_at' is null)
 ) or (select count(distinct f->>'movement_id') from jsonb_array_elements(file_manifest) f)<>expected then raise exception 'El indice de archivos no corresponde a la exportacion.';end if;
 if saved.status='ready' then
  if saved.manifest is distinct from file_manifest then raise exception 'La exportacion ya fue completada con otro indice.';end if;
  return;
 end if;
 update cometa_receipt_exports set status='ready',manifest=file_manifest,ready_at=now() where id=saved.id;
 insert into audit_logs(organization_id,actor_user_id,action,entity_type,entity_id,new_values)
 values(target_organization_id,auth.uid(),'cometa_receipts_exported','cometa_receipt_export',saved.id,jsonb_build_object('period',saved.period_month,'files',expected));
end;
$$;

create or replace function authorize_cometa_receipt_cleanup(target_organization_id uuid,target_export_id uuid)
returns void language plpgsql security definer set search_path=public as $$
begin
 if auth.uid() is null or not has_org_role(target_organization_id,array['owner','admin','editor']::app_role[]) then raise exception 'No tenes permisos para liberar espacio.';end if;
 update cometa_receipt_exports set cleanup_confirmed_at=coalesce(cleanup_confirmed_at,now())
 where id=target_export_id and organization_id=target_organization_id and status='ready';
 if not found then raise exception 'Primero completa y guarda la descarga del mes.';end if;
end;
$$;

create or replace function can_delete_exported_cometa_receipt(object_name text)
returns boolean language sql stable security definer set search_path=public as $$
 select exists(
  select 1 from cometa_receipt_exports x cross join lateral jsonb_array_elements(x.entries) e
  join cometa_movements m on m.id=(e->>'movement_id')::uuid and m.organization_id=x.organization_id
  where x.status='ready' and x.cleanup_confirmed_at is not null and e->>'path'=object_name
    and m.receipt_path=object_name and e->>'receipt_archived_at' is null
    and has_org_role(x.organization_id,array['owner','admin','editor']::app_role[])
 );
$$;
drop policy if exists storage_cometa_exported_receipts_delete on storage.objects;
create policy storage_cometa_exported_receipts_delete on storage.objects for delete to authenticated
using(bucket_id='receipts' and can_delete_exported_cometa_receipt(name));

create or replace function finish_cometa_receipt_cleanup(target_organization_id uuid,target_export_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare saved cometa_receipt_exports;changed integer;remaining integer;
begin
 if auth.uid() is null or not has_org_role(target_organization_id,array['owner','admin','editor']::app_role[]) then raise exception 'No tenes permisos para liberar espacio.';end if;
 select * into saved from cometa_receipt_exports where id=target_export_id and organization_id=target_organization_id for update;
 if not found or saved.cleanup_confirmed_at is null or saved.status not in ('ready','cleaned') then raise exception 'Falta confirmar que guardaste la descarga.';end if;
 update cometa_movements m set receipt_archived_at=now()
 where m.organization_id=target_organization_id and m.receipt_archived_at is null and exists(
  select 1 from jsonb_array_elements(saved.entries) e where e->>'movement_id'=m.id::text and e->>'path'=m.receipt_path and e->>'receipt_archived_at' is null
 ) and not exists(select 1 from storage.objects o where o.bucket_id='receipts' and o.name=m.receipt_path);
 get diagnostics changed=row_count;
 select count(*) into remaining from jsonb_array_elements(saved.entries) e
 where e->>'path' is not null and e->>'receipt_archived_at' is null
   and exists(select 1 from storage.objects o where o.bucket_id='receipts' and o.name=e->>'path');
 if remaining=0 and saved.status<>'cleaned' then
  update cometa_receipt_exports set status='cleaned',cleaned_at=now() where id=saved.id;
  insert into audit_logs(organization_id,actor_user_id,action,entity_type,entity_id,new_values)
  values(target_organization_id,auth.uid(),'cometa_receipts_storage_freed','cometa_receipt_export',saved.id,jsonb_build_object('period',saved.period_month));
 end if;
 return jsonb_build_object('archived',changed,'remaining',remaining);
end;
$$;

revoke all on function assign_cometa_receipt_number() from public,anon,authenticated;
revoke all on function attach_cometa_receipt(uuid,uuid,uuid,text,text) from public,anon;
revoke all on function begin_cometa_receipt_export(uuid,date) from public,anon;
revoke all on function complete_cometa_receipt_export(uuid,uuid,jsonb) from public,anon;
revoke all on function authorize_cometa_receipt_cleanup(uuid,uuid) from public,anon;
revoke all on function can_delete_exported_cometa_receipt(text) from public,anon;
revoke all on function finish_cometa_receipt_cleanup(uuid,uuid) from public,anon;
grant execute on function attach_cometa_receipt(uuid,uuid,uuid,text,text) to authenticated;
grant execute on function begin_cometa_receipt_export(uuid,date) to authenticated;
grant execute on function complete_cometa_receipt_export(uuid,uuid,jsonb) to authenticated;
grant execute on function authorize_cometa_receipt_cleanup(uuid,uuid) to authenticated;
grant execute on function can_delete_exported_cometa_receipt(text) to authenticated;
grant execute on function finish_cometa_receipt_cleanup(uuid,uuid) to authenticated;
commit;
