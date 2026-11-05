-- Solo Mauro Molinero, PELLEGRINI / DPTO 4.
-- Proximo ajuste 01/12/2026; cada cuatro meses desde esa fecha.
-- Conserva importes, fechas de inicio/fin, cobros, pagos y ajustes historicos.
begin;
do $$
declare
 target_lease urban_leases;
 saved_lease urban_leases;
 matches integer;
begin
 select count(*) into matches
 from urban_leases l
 join urban_units u on u.id=l.unit_id and u.organization_id=l.organization_id
 join urban_buildings b on b.id=u.building_id and b.organization_id=l.organization_id
 join contacts c on c.id=l.primary_tenant_contact_id and c.organization_id=l.organization_id
 where l.organization_id='98a857e1-dacc-4890-90e9-1f1ac8de9782'::uuid
   and lower(trim(b.name))='pellegrini' and lower(trim(u.name))='dpto 4'
   and lower(regexp_replace(trim(concat_ws(' ',c.first_name,c.last_name)), '\s+', ' ', 'g'))='mauro molinero'
   and l.status='active' and extract(day from l.start_date)=15;
 if matches<>1 then raise exception 'Se esperaba un unico contrato activo de Mauro Molinero en PELLEGRINI / DPTO 4. Coincidencias: %',matches;end if;

 select l.* into target_lease
 from urban_leases l
 join urban_units u on u.id=l.unit_id and u.organization_id=l.organization_id
 join urban_buildings b on b.id=u.building_id and b.organization_id=l.organization_id
 join contacts c on c.id=l.primary_tenant_contact_id and c.organization_id=l.organization_id
 where l.organization_id='98a857e1-dacc-4890-90e9-1f1ac8de9782'::uuid
   and lower(trim(b.name))='pellegrini' and lower(trim(u.name))='dpto 4'
   and lower(regexp_replace(trim(concat_ws(' ',c.first_name,c.last_name)), '\s+', ' ', 'g'))='mauro molinero'
   and l.status='active' and extract(day from l.start_date)=15
 for update of l;

 if target_lease.next_adjustment_date is null or target_lease.next_adjustment_date not in (date '2026-11-01',date '2026-12-01') then
   raise exception 'La fecha de actualizacion cambio (%). No se modifico el contrato.',target_lease.next_adjustment_date;
 end if;
 if target_lease.start_date>date '2026-12-01' or target_lease.end_date<date '2026-12-01' then
   raise exception 'La nueva fecha queda fuera del contrato. No se modifico el contrato.';
 end if;
 if target_lease.next_adjustment_date=date '2026-12-01' and target_lease.adjustment_frequency_months=4 then
   raise notice 'El contrato ya esta configurado para el 01/12/2026 cada 4 meses.';
 else
   update urban_leases
   set next_adjustment_date=date '2026-12-01',adjustment_frequency_months=4
   where id=target_lease.id returning * into saved_lease;
   insert into audit_logs(organization_id,actor_user_id,action,entity_type,entity_id,old_values,new_values)
   values(target_lease.organization_id,auth.uid(),'urban_lease_update_shifted_to_december','urban_lease',target_lease.id,
     jsonb_build_object('next_adjustment_date',target_lease.next_adjustment_date,'adjustment_frequency_months',target_lease.adjustment_frequency_months),
     jsonb_build_object('next_adjustment_date',saved_lease.next_adjustment_date,'adjustment_frequency_months',saved_lease.adjustment_frequency_months));
 end if;
end;
$$;
select b.name as edificio,u.name as departamento,concat_ws(' ',c.first_name,c.last_name) as inquilino,
 l.next_adjustment_date as proxima_actualizacion,l.adjustment_frequency_months as frecuencia_meses,
 array(select to_char(d,'DD/MM/YYYY') from generate_series(l.next_adjustment_date::timestamp,l.end_date::timestamp,interval '4 months') d) as proximas_actualizaciones
from urban_leases l
join urban_units u on u.id=l.unit_id
join urban_buildings b on b.id=u.building_id
join contacts c on c.id=l.primary_tenant_contact_id
where l.organization_id='98a857e1-dacc-4890-90e9-1f1ac8de9782'::uuid
 and lower(trim(b.name))='pellegrini' and lower(trim(u.name))='dpto 4'
 and lower(regexp_replace(trim(concat_ws(' ',c.first_name,c.last_name)), '\s+', ' ', 'g'))='mauro molinero' and l.status='active';
commit;
