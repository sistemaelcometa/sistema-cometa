-- Eliminacion logica de bolsas vacias, conservando identidades e historial.
begin;
alter table cometa_grain_stores add column if not exists deleted_at timestamptz;
create or replace function delete_cometa_empty_bag(target_organization_id uuid,target_store_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare bag cometa_grain_stores;
begin
 if not has_org_role(target_organization_id,array['owner','admin','editor']::app_role[]) then raise exception 'No tenes permisos para eliminar silos bolsa.'; end if;
 perform pg_advisory_xact_lock(hashtextextended(target_organization_id::text,78));
 select * into bag from cometa_grain_stores s where s.id=target_store_id and s.organization_id=target_organization_id;
 if not found or bag.kind<>'bag' then raise exception 'El silo bolsa no pertenece a esta organizacion.'; end if;
 if exists(
  select e.harvest_id from cometa_grain_events e where e.organization_id=target_organization_id and e.voided_at is null and (e.destination_id=target_store_id or e.source_id=target_store_id)
  group by e.harvest_id having sum(case when e.destination_id=target_store_id then e.tonnes else 0 end-case when e.source_id=target_store_id then e.tonnes else 0 end)<>0
 ) then raise exception 'La bolsa tiene stock. Solo se pueden eliminar bolsas vacias.'; end if;
 update cometa_grain_stores set deleted_at=coalesce(deleted_at,now()) where id=target_store_id and organization_id=target_organization_id;
end $$;

-- Proteccion compartida por cosechas, traslados y versiones antiguas de la app.
create or replace function guard_cometa_bag_destination()
returns trigger language plpgsql security definer set search_path=public as $$
begin
 perform pg_advisory_xact_lock(hashtextextended(new.organization_id::text,78));
 if new.destination_id is not null and new.voided_at is null then
  if exists(select 1 from cometa_grain_stores s where s.id=new.destination_id and s.deleted_at is not null) then
   raise exception 'Esta bolsa fue eliminada. Crea una bolsa nueva para cargar mercaderia.';
  end if;
  if cometa_bag_is_archived(new.destination_id) then raise exception 'Esta bolsa ya se uso y esta archivada. Crea una bolsa nueva para cargar mercaderia.'; end if;
 end if;
 return new;
end $$;

-- Si se corrige una salida anterior y reaparece mercaderia, debe volver a verse.
create or replace function restore_cometa_bag_after_undo()
returns trigger language plpgsql security definer set search_path=public as $$
begin
 if new.voided_at is not distinct from old.voided_at then return new; end if;
 perform pg_advisory_xact_lock(hashtextextended(new.organization_id::text,78));
 update cometa_grain_stores s set deleted_at=null
 where s.organization_id=new.organization_id and s.kind='bag' and s.deleted_at is not null and s.id in (new.source_id,new.destination_id)
 and exists(select 1 from cometa_grain_events e where e.organization_id=s.organization_id and e.voided_at is null and (e.destination_id=s.id or e.source_id=s.id)
  group by e.harvest_id having sum(case when e.destination_id=s.id then e.tonnes else 0 end-case when e.source_id=s.id then e.tonnes else 0 end)>0);
 return new;
end $$;
drop trigger if exists cometa_restore_deleted_bag on cometa_grain_events;
create trigger cometa_restore_deleted_bag after update of voided_at on cometa_grain_events for each row execute function restore_cometa_bag_after_undo();
revoke all on function delete_cometa_empty_bag(uuid,uuid),guard_cometa_bag_destination(),restore_cometa_bag_after_undo() from public,anon;
revoke all on function guard_cometa_bag_destination(),restore_cometa_bag_after_undo() from authenticated;
grant execute on function delete_cometa_empty_bag(uuid,uuid) to authenticated;
commit;
