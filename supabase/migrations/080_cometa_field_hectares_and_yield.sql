-- Superficie de lotes y copia historica de la superficie al cosechar.
begin;
alter table cometa_fields add column if not exists hectares numeric(12,3) check(hectares>0 and hectares::text not in ('NaN','Infinity','-Infinity'));
alter table cometa_harvests add column if not exists field_hectares numeric(12,3) check(field_hectares>0 and field_hectares::text not in ('NaN','Infinity','-Infinity'));

create or replace function save_cometa_field(target_organization_id uuid,entry_name text,entry_hectares numeric default null,target_field_id uuid default null)
returns uuid language plpgsql security definer set search_path=public as $$
declare saved_id uuid;
begin
 if not has_org_role(target_organization_id,array['owner','admin','editor']::app_role[]) then raise exception 'No tenes permisos para guardar lotes.'; end if;
 if entry_hectares is not null and (entry_hectares::text in ('NaN','Infinity','-Infinity') or entry_hectares<=0 or entry_hectares>=1e9 or entry_hectares<>round(entry_hectares,3)) then raise exception 'Ingresa hectareas positivas, con hasta 3 decimales.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(target_organization_id::text,78));
 if target_field_id is not null and not exists(select 1 from cometa_fields where id=target_field_id and organization_id=target_organization_id and deleted_at is null) then raise exception 'El lote fue eliminado o no pertenece a esta organizacion.'; end if;
 saved_id:=configure_cometa_grain(target_organization_id,'field',entry_name,'',null,target_field_id);
 update cometa_fields set hectares=entry_hectares where id=saved_id and organization_id=target_organization_id;
 return saved_id;
end $$;

-- Conserva la superficie usada al registrar la cosecha; editar el lote despues
-- no modifica el rendimiento de las cosechas anteriores. No inventa superficies
-- para cosechas ya guardadas antes de esta migracion.
create or replace function check_cometa_harvest_field()
returns trigger language plpgsql security definer set search_path=public as $$
begin
 select hectares into new.field_hectares from cometa_fields where id=new.field_id and organization_id=new.organization_id and deleted_at is null for share;
 if not found then raise exception 'El lote fue eliminado o no pertenece a esta organizacion.'; end if;
 return new;
end $$;
revoke all on function save_cometa_field(uuid,text,numeric,uuid),check_cometa_harvest_field() from public,anon;
grant execute on function save_cometa_field(uuid,text,numeric,uuid) to authenticated;
commit;
