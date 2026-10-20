-- SOLO LECTURA: no borra, anula ni recalcula cobros o expensas.
-- Caso: COLONIZADORES / DPTO 3 / octubre de 2026.
-- Compara contrato, conceptos, liquidacion y dinero registrado.
with target_charges as (
  select ch.*, b.name as edificio, u.name as departamento,
    trim(coalesce(c.first_name, '') || ' ' || coalesce(c.last_name, '')) as inquilino,
    l.current_amount as alquiler_contrato, l.start_date as inicio_contrato,
    l.end_date as fin_contrato, l.status::text as estado_contrato, b.id as building_id
  from public.urban_charges ch
  join public.urban_units u on u.id = ch.unit_id
  join public.urban_buildings b on b.id = u.building_id
  join public.urban_leases l on l.id = ch.lease_id
  join public.contacts c on c.id = l.primary_tenant_contact_id
  where upper(trim(b.name)) = 'COLONIZADORES'
    and upper(trim(u.name)) = 'DPTO 3'
    and ch.period_month = date '2026-10-01'
), amounts as (
  select ch.*, ep.status::text as estado_expensas_mes_anterior,
    coalesce(expenses.amount, 0) as expensas_liquidacion,
    case when (ch.period_month - interval '1 month')::date < date_trunc('month', ch.inicio_contrato)::date
      then 0 else coalesce(expenses.amount, 0) end as expensas_aplicables,
    coalesce(items.total_due, 0) as total_conceptos,
    coalesce(items.detail, '[]'::jsonb) as conceptos,
    coalesce(paid.amount, 0) as pagos_imputados_validos,
    coalesce(paid.detail, '[]'::jsonb) as imputaciones,
    coalesce(payments.valid_count, 0) as cantidad_pagos_validos,
    coalesce(payments.valid_amount, 0) as dinero_registrado_valido,
    coalesce(payments.detail, '[]'::jsonb) as pagos
  from target_charges ch
  left join public.urban_expense_periods ep
    on ep.organization_id = ch.organization_id
   and ep.building_id = ch.building_id
   and ep.period_month = (ch.period_month - interval '1 month')::date
  left join lateral (
    select sum(a.tenant_amount) as amount
    from public.urban_expense_allocations a
    join public.urban_expense_periods p on p.id = a.period_id
    join public.urban_expense_items ei on ei.id = a.expense_item_id
    where a.organization_id = ch.organization_id and a.unit_id = ch.unit_id
      and p.building_id = ch.building_id
      and p.period_month = (ch.period_month - interval '1 month')::date
      and p.status in ('calculated', 'closed') and ei.status = 'valid'
      and a.transfer_to_tenant
  ) expenses on true
  left join lateral (
    select sum(ci.amount_due) as total_due,
      jsonb_agg(jsonb_build_object(
        'item_id', ci.id, 'tipo', ci.item_type::text,
        'descripcion', ci.description, 'origen', ci.source_entity_type,
        'importe', ci.amount_due, 'moneda', ci.currency
      ) order by ci.created_at, ci.id) as detail
    from public.urban_charge_items ci where ci.charge_id = ch.id
  ) items on true
  left join lateral (
    select sum(pa.allocated_amount) filter (where pay.status = 'valid' and pay.voided_at is null) as amount,
      jsonb_agg(jsonb_build_object(
        'payment_id', pay.id, 'estado_pago', pay.status::text,
        'fecha_pago', pay.payment_date, 'importe_recibido', pay.received_amount,
        'tipo_concepto', ci.item_type::text, 'item_id', ci.id,
        'imputado', pa.allocated_amount, 'anulado_el', pay.voided_at
      ) order by pay.created_at, ci.id) as detail
    from public.urban_charge_items ci
    join public.urban_payment_allocations pa on pa.charge_item_id = ci.id
    join public.urban_payments pay on pay.id = pa.payment_id
    where ci.charge_id = ch.id
  ) paid on true
  left join lateral (
    select count(*) filter (where pay.status = 'valid' and pay.voided_at is null) as valid_count,
      sum(pay.received_amount) filter (where pay.status = 'valid' and pay.voided_at is null) as valid_amount,
      jsonb_agg(jsonb_build_object(
        'payment_id', pay.id, 'fecha', pay.payment_date, 'importe', pay.received_amount,
        'estado', pay.status::text, 'moneda', pay.currency,
        'notas', pay.notes, 'anulado_el', pay.voided_at, 'creado_el', pay.created_at
      ) order by pay.created_at, pay.id) as detail
    from public.urban_payments pay
    where pay.organization_id = ch.organization_id and pay.unit_id = ch.unit_id
      and pay.lease_id = ch.lease_id
      and (
        (pay.payment_date >= ch.period_month and pay.payment_date < (ch.period_month + interval '1 month')::date)
        or exists (
          select 1 from public.urban_payment_allocations pa
          join public.urban_charge_items ci on ci.id = pa.charge_item_id
          where pa.payment_id = pay.id and ci.charge_id = ch.id
        )
      )
  ) payments on true
)
select id as charge_id, organization_id, edificio, departamento, inquilino,
  period_month, status::text as estado_guardado, inicio_contrato, fin_contrato,
  estado_contrato, alquiler_contrato, estado_expensas_mes_anterior,
  expensas_liquidacion, expensas_aplicables,
  alquiler_contrato + expensas_aplicables as total_base_pantalla,
  total_conceptos, pagos_imputados_validos,
  alquiler_contrato + expensas_aplicables - pagos_imputados_validos as saldo_base_exacto,
  total_conceptos - pagos_imputados_validos as saldo_conceptos_exacto,
  cantidad_pagos_validos, dinero_registrado_valido, conceptos, pagos, imputaciones
from amounts
order by created_at desc;
