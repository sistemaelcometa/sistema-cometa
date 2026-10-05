-- RPCs transaccionales para Punta del Este: unidades, reservas, cobros y gastos.

create or replace function pde_payment_status_from_amount(
  total_amount numeric,
  paid_amount numeric
)
returns pde_reservation_status
language sql
immutable
as $$
  select case
    when coalesce(paid_amount, 0) >= coalesce(total_amount, 0) and coalesce(total_amount, 0) > 0 then 'paid'::pde_reservation_status
    when coalesce(paid_amount, 0) > 0 then 'deposit_received'::pde_reservation_status
    else 'reserved'::pde_reservation_status
  end;
$$;

create or replace function ensure_pde_unit(
  target_organization_id uuid,
  unit_name text
)
returns pde_units
language plpgsql
security definer
set search_path = public
as $$
declare
  cleaned_name text := nullif(trim(coalesce(unit_name, '')), '');
  existing_unit pde_units;
begin
  if cleaned_name is null then
    raise exception 'El departamento es obligatorio.';
  end if;

  select *
    into existing_unit
  from pde_units
  where organization_id = target_organization_id
    and status = 'active'
    and lower(name) = lower(cleaned_name)
  for update;

  if found then
    return existing_unit;
  end if;

  insert into pde_units (
    organization_id,
    name,
    created_by
  )
  values (
    target_organization_id,
    cleaned_name,
    auth.uid()
  )
  returning * into existing_unit;

  return existing_unit;
end;
$$;

create or replace function ensure_pde_category(
  target_organization_id uuid,
  category_name text
)
returns expense_categories
language plpgsql
security definer
set search_path = public
as $$
declare
  cleaned_name text := nullif(trim(coalesce(category_name, '')), '');
  existing_category expense_categories;
begin
  if cleaned_name is null then
    raise exception 'La categoria del gasto es obligatoria.';
  end if;

  select *
    into existing_category
  from expense_categories
  where organization_id = target_organization_id
    and status = 'active'
    and scope in ('pde', 'both')
    and lower(name) = lower(cleaned_name)
  for update;

  if found then
    return existing_category;
  end if;

  insert into expense_categories (
    organization_id,
    name,
    scope,
    created_by
  )
  values (
    target_organization_id,
    cleaned_name,
    'pde',
    auth.uid()
  )
  returning * into existing_category;

  return existing_category;
end;
$$;

create or replace function ensure_pde_guest_contact(
  target_organization_id uuid,
  guest_name text,
  guest_phone text default null,
  guest_email text default null
)
returns contacts
language plpgsql
security definer
set search_path = public
as $$
declare
  cleaned_name text := nullif(trim(coalesce(guest_name, '')), '');
  cleaned_phone text := nullif(trim(coalesce(guest_phone, '')), '');
  cleaned_email text := nullif(lower(trim(coalesce(guest_email, ''))), '');
  existing_contact contacts;
begin
  if cleaned_name is null then
    raise exception 'El huesped es obligatorio.';
  end if;

  select *
    into existing_contact
  from contacts
  where organization_id = target_organization_id
    and status = 'active'
    and is_guest = true
    and (
      (cleaned_email is not null and lower(email) = cleaned_email)
      or (
        cleaned_email is null
        and cleaned_phone is not null
        and phone = cleaned_phone
      )
      or (
        cleaned_email is null
        and cleaned_phone is null
        and lower(trim(coalesce(first_name, '') || ' ' || coalesce(last_name, ''))) = lower(cleaned_name)
      )
    )
  order by created_at
  limit 1
  for update;

  if found then
    update contacts
    set
      first_name = cleaned_name,
      phone = coalesce(cleaned_phone, phone),
      email = coalesce(cleaned_email, email),
      is_guest = true
    where id = existing_contact.id
    returning * into existing_contact;

    return existing_contact;
  end if;

  insert into contacts (
    organization_id,
    contact_type,
    first_name,
    phone,
    email,
    is_guest,
    created_by
  )
  values (
    target_organization_id,
    'person',
    cleaned_name,
    cleaned_phone,
    cleaned_email,
    true,
    auth.uid()
  )
  returning * into existing_contact;

  return existing_contact;
end;
$$;

create or replace function refresh_pde_reservation_status(
  target_reservation_id uuid
)
returns pde_reservations
language plpgsql
security definer
set search_path = public
as $$
declare
  target_reservation pde_reservations;
  paid_amount numeric(14, 2);
begin
  select *
    into target_reservation
  from pde_reservations
  where id = target_reservation_id
  for update;

  if not found then
    raise exception 'La reserva no existe.';
  end if;

  if target_reservation.status in ('cancelled', 'finished') then
    return target_reservation;
  end if;

  select coalesce(sum(amount), 0)
    into paid_amount
  from pde_reservation_payments
  where reservation_id = target_reservation_id
    and status = 'valid';

  update pde_reservations
  set status = pde_payment_status_from_amount(total_amount, paid_amount)
  where id = target_reservation_id
  returning * into target_reservation;

  return target_reservation;
end;
$$;

create or replace function get_pde_data(
  target_organization_id uuid
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with payment_totals as (
    select
      p.reservation_id,
      coalesce(sum(p.amount) filter (where p.status = 'valid'), 0) as paid_amount,
      coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id', p.id,
            'date', p.payment_date,
            'amount', p.amount,
            'currency', p.currency,
            'method', p.payment_method,
            'type', p.payment_type,
            'detail', p.notes
          )
          order by p.payment_date, p.created_at
        ) filter (where p.status = 'valid'),
        '[]'::jsonb
      ) as payments
    from pde_reservation_payments p
    where p.organization_id = target_organization_id
    group by p.reservation_id
  ),
  units as (
    select
      u.id,
      u.name,
      u.description,
      u.display_color
    from pde_units u
    where u.organization_id = target_organization_id
      and u.status = 'active'
      and is_org_member(target_organization_id)
    order by u.name
  ),
  reservations as (
    select
      r.id,
      u.name as unit,
      r.guest_name_snapshot as guest,
      r.guest_phone_snapshot as phone,
      r.guest_email_snapshot as email,
      r.start_date as "from",
      r.end_date as "to",
      r.total_amount as total,
      r.currency,
      coalesce(pt.paid_amount, 0) as paid,
      case r.status
        when 'paid' then 'Pagada'
        when 'deposit_received' then 'Seña recibida'
        when 'reserved' then 'Reservada'
        when 'cancelled' then 'Cancelada'
        when 'finished' then 'Finalizada'
      end as status,
      r.status::text as "rawStatus",
      r.notes,
      r.cancel_reason as "cancelReason",
      r.created_at as "createdAt",
      coalesce(pt.payments, '[]'::jsonb) as payments
    from pde_reservations r
    join pde_units u on u.id = r.unit_id
    left join payment_totals pt on pt.reservation_id = r.id
    where r.organization_id = target_organization_id
      and is_org_member(target_organization_id)
    order by r.start_date desc, u.name, r.created_at desc
  ),
  expenses as (
    select
      a.id,
      e.id as "expenseId",
      u.name as unit,
      e.target_type::text as "targetType",
      e.expense_date as date,
      c.name as rubric,
      a.allocated_amount as amount,
      e.currency,
      e.description as detail,
      e.payment_method as "paymentMethod",
      e.notes,
      e.status::text as status,
      e.created_at as "createdAt"
    from pde_expense_allocations a
    join pde_expenses e on e.id = a.expense_id
    join pde_units u on u.id = a.unit_id
    left join expense_categories c on c.id = e.category_id
    where e.organization_id = target_organization_id
      and e.status = 'valid'
      and is_org_member(target_organization_id)
    order by e.expense_date desc, e.created_at desc, u.name
  )
  select jsonb_build_object(
    'units', coalesce((select jsonb_agg(to_jsonb(units)) from units), '[]'::jsonb),
    'reservations', coalesce((select jsonb_agg(to_jsonb(reservations)) from reservations), '[]'::jsonb),
    'expenses', coalesce((select jsonb_agg(to_jsonb(expenses)) from expenses), '[]'::jsonb)
  );
$$;

create or replace function save_pde_reservation(
  target_organization_id uuid,
  unit_name text,
  guest_name text,
  start_date date,
  end_date date,
  total_amount numeric,
  reservation_id uuid default null,
  currency char(3) default 'USD',
  guest_phone text default null,
  guest_email text default null,
  reservation_notes text default null,
  initial_paid_amount numeric default 0,
  initial_payment_date date default current_date,
  initial_payment_method payment_method default 'transfer',
  initial_payment_notes text default null,
  operation_id uuid default gen_random_uuid()
)
returns pde_reservations
language plpgsql
security definer
set search_path = public
as $$
declare
  selected_unit pde_units;
  selected_guest contacts;
  saved_reservation pde_reservations;
  old_reservation pde_reservations;
  existing_operation operation_results;
  request_hash text;
  cleaned_notes text := nullif(trim(coalesce(reservation_notes, '')), '');
begin
  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para guardar reservas.';
  end if;

  if end_date <= start_date then
    raise exception 'La fecha de salida debe ser posterior a la de ingreso.';
  end if;

  if total_amount < 0 then
    raise exception 'El total de la reserva no puede ser negativo.';
  end if;

  if coalesce(initial_paid_amount, 0) < 0 then
    raise exception 'El cobro inicial no puede ser negativo.';
  end if;

  request_hash := md5(jsonb_build_object(
    'reservation_id', reservation_id,
    'unit_name', unit_name,
    'guest_name', guest_name,
    'start_date', start_date,
    'end_date', end_date,
    'total_amount', total_amount,
    'currency', currency,
    'guest_phone', guest_phone,
    'guest_email', guest_email,
    'reservation_notes', reservation_notes,
    'initial_paid_amount', initial_paid_amount,
    'initial_payment_date', initial_payment_date,
    'initial_payment_method', initial_payment_method,
    'initial_payment_notes', initial_payment_notes
  )::text);

  select *
    into existing_operation
  from operation_results op
  where op.organization_id = target_organization_id
    and op.operation_id = save_pde_reservation.operation_id
  for update;

  if found then
    if existing_operation.request_hash <> request_hash then
      raise exception 'El operation_id ya fue usado con otros datos.';
    end if;

    if existing_operation.status = 'succeeded' then
      select *
        into saved_reservation
      from pde_reservations
      where id = existing_operation.result_entity_id;

      return saved_reservation;
    end if;

    raise exception 'La operacion todavia esta en proceso.';
  end if;

  insert into operation_results (
    organization_id,
    operation_id,
    operation_type,
    request_hash,
    status,
    created_by
  )
  values (
    target_organization_id,
    save_pde_reservation.operation_id,
    'save_pde_reservation',
    request_hash,
    'in_progress',
    auth.uid()
  );

  selected_unit := ensure_pde_unit(target_organization_id, unit_name);
  selected_guest := ensure_pde_guest_contact(target_organization_id, guest_name, guest_phone, guest_email);

  if reservation_id is null then
    insert into pde_reservations (
      organization_id,
      unit_id,
      guest_contact_id,
      guest_name_snapshot,
      guest_phone_snapshot,
      guest_email_snapshot,
      start_date,
      end_date,
      total_amount,
      currency,
      status,
      notes,
      operation_id,
      created_by
    )
    values (
      target_organization_id,
      selected_unit.id,
      selected_guest.id,
      trim(guest_name),
      nullif(trim(coalesce(guest_phone, '')), ''),
      nullif(lower(trim(coalesce(guest_email, ''))), ''),
      start_date,
      end_date,
      total_amount,
      currency,
      pde_payment_status_from_amount(total_amount, coalesce(initial_paid_amount, 0)),
      cleaned_notes,
      save_pde_reservation.operation_id,
      auth.uid()
    )
    returning * into saved_reservation;

    if coalesce(initial_paid_amount, 0) > 0 then
      insert into pde_reservation_payments (
        organization_id,
        reservation_id,
        payment_type,
        payment_date,
        amount,
        currency,
        payment_method,
        notes,
        operation_id,
        created_by
      )
      values (
        target_organization_id,
        saved_reservation.id,
        case when initial_paid_amount >= total_amount then 'balance'::pde_payment_type else 'deposit'::pde_payment_type end,
        initial_payment_date,
        initial_paid_amount,
        currency,
        initial_payment_method,
        nullif(trim(coalesce(initial_payment_notes, '')), ''),
        save_pde_reservation.operation_id,
        auth.uid()
      );
    end if;
  else
    select *
      into old_reservation
    from pde_reservations
    where id = save_pde_reservation.reservation_id
      and organization_id = target_organization_id
    for update;

    if not found then
      raise exception 'La reserva no existe.';
    end if;

    if old_reservation.status in ('cancelled', 'finished') then
      raise exception 'No se puede editar una reserva cancelada o finalizada.';
    end if;

    update pde_reservations
    set
      unit_id = selected_unit.id,
      guest_contact_id = selected_guest.id,
      guest_name_snapshot = trim(guest_name),
      guest_phone_snapshot = nullif(trim(coalesce(guest_phone, '')), ''),
      guest_email_snapshot = nullif(lower(trim(coalesce(guest_email, ''))), ''),
      start_date = save_pde_reservation.start_date,
      end_date = save_pde_reservation.end_date,
      total_amount = save_pde_reservation.total_amount,
      currency = save_pde_reservation.currency,
      notes = cleaned_notes
    where id = save_pde_reservation.reservation_id
    returning * into saved_reservation;
  end if;

  saved_reservation := refresh_pde_reservation_status(saved_reservation.id);

  insert into audit_logs (
    organization_id,
    actor_user_id,
    operation_id,
    action,
    entity_type,
    entity_id,
    old_values,
    new_values,
    metadata
  )
  values (
    target_organization_id,
    auth.uid(),
    save_pde_reservation.operation_id,
    case when old_reservation.id is null then 'pde_reservation_created' else 'pde_reservation_updated' end,
    'pde_reservation',
    saved_reservation.id,
    case when old_reservation.id is null then null else to_jsonb(old_reservation) end,
    to_jsonb(saved_reservation),
    jsonb_build_object('unitName', selected_unit.name, 'guestName', guest_name)
  );

  update operation_results
  set
    status = 'succeeded',
    result_entity_type = 'pde_reservation',
    result_entity_id = saved_reservation.id,
    result_payload = to_jsonb(saved_reservation),
    completed_at = now()
  where organization_id = target_organization_id
    and operation_results.operation_id = save_pde_reservation.operation_id;

  return saved_reservation;
end;
$$;

create or replace function register_pde_payment(
  target_organization_id uuid,
  reservation_id uuid,
  payment_date date,
  amount numeric,
  currency char(3) default 'USD',
  payment_method payment_method default 'transfer',
  payment_type pde_payment_type default 'balance',
  payment_notes text default null,
  operation_id uuid default gen_random_uuid()
)
returns pde_reservation_payments
language plpgsql
security definer
set search_path = public
as $$
declare
  target_reservation pde_reservations;
  saved_payment pde_reservation_payments;
  existing_operation operation_results;
  request_hash text;
begin
  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para registrar cobros.';
  end if;

  if amount <= 0 then
    raise exception 'El importe del cobro debe ser mayor a cero.';
  end if;

  request_hash := md5(jsonb_build_object(
    'reservation_id', reservation_id,
    'payment_date', payment_date,
    'amount', amount,
    'currency', currency,
    'payment_method', payment_method,
    'payment_type', payment_type,
    'payment_notes', payment_notes
  )::text);

  select *
    into existing_operation
  from operation_results op
  where op.organization_id = target_organization_id
    and op.operation_id = register_pde_payment.operation_id
  for update;

  if found then
    if existing_operation.request_hash <> request_hash then
      raise exception 'El operation_id ya fue usado con otros datos.';
    end if;

    if existing_operation.status = 'succeeded' then
      select *
        into saved_payment
      from pde_reservation_payments
      where id = existing_operation.result_entity_id;

      return saved_payment;
    end if;

    raise exception 'La operacion todavia esta en proceso.';
  end if;

  insert into operation_results (
    organization_id,
    operation_id,
    operation_type,
    request_hash,
    status,
    created_by
  )
  values (
    target_organization_id,
    register_pde_payment.operation_id,
    'register_pde_payment',
    request_hash,
    'in_progress',
    auth.uid()
  );

  select *
    into target_reservation
  from pde_reservations
  where id = register_pde_payment.reservation_id
    and organization_id = target_organization_id
    and status in ('reserved', 'deposit_received', 'paid')
  for update;

  if not found then
    raise exception 'La reserva no existe o no esta vigente.';
  end if;

  insert into pde_reservation_payments (
    organization_id,
    reservation_id,
    payment_type,
    payment_date,
    amount,
    currency,
    payment_method,
    notes,
    operation_id,
    created_by
  )
  values (
    target_organization_id,
    reservation_id,
    payment_type,
    payment_date,
    amount,
    currency,
    payment_method,
    nullif(trim(coalesce(payment_notes, '')), ''),
    register_pde_payment.operation_id,
    auth.uid()
  )
  returning * into saved_payment;

  perform refresh_pde_reservation_status(register_pde_payment.reservation_id);

  insert into audit_logs (
    organization_id,
    actor_user_id,
    operation_id,
    action,
    entity_type,
    entity_id,
    old_values,
    new_values,
    metadata
  )
  values (
    target_organization_id,
    auth.uid(),
    register_pde_payment.operation_id,
    'pde_payment_registered',
    'pde_reservation_payment',
    saved_payment.id,
    null,
    to_jsonb(saved_payment),
    jsonb_build_object('reservationId', register_pde_payment.reservation_id)
  );

  update operation_results
  set
    status = 'succeeded',
    result_entity_type = 'pde_reservation_payment',
    result_entity_id = saved_payment.id,
    result_payload = to_jsonb(saved_payment),
    completed_at = now()
  where organization_id = target_organization_id
    and operation_results.operation_id = register_pde_payment.operation_id;

  return saved_payment;
end;
$$;

create or replace function archive_pde_reservation(
  target_organization_id uuid,
  reservation_id uuid,
  reason text default null,
  operation_id uuid default gen_random_uuid()
)
returns pde_reservations
language plpgsql
security definer
set search_path = public
as $$
declare
  old_reservation pde_reservations;
  archived_reservation pde_reservations;
  existing_operation operation_results;
  request_hash text;
begin
  if not has_org_role(target_organization_id, array['owner', 'admin']::app_role[]) then
    raise exception 'Solo duenio o administrador pueden eliminar reservas.';
  end if;

  request_hash := md5(jsonb_build_object(
    'reservation_id', reservation_id,
    'reason', reason
  )::text);

  select *
    into existing_operation
  from operation_results op
  where op.organization_id = target_organization_id
    and op.operation_id = archive_pde_reservation.operation_id
  for update;

  if found then
    if existing_operation.request_hash <> request_hash then
      raise exception 'El operation_id ya fue usado con otros datos.';
    end if;

    if existing_operation.status = 'succeeded' then
      select *
        into archived_reservation
      from pde_reservations
      where id = existing_operation.result_entity_id;

      return archived_reservation;
    end if;

    raise exception 'La operacion todavia esta en proceso.';
  end if;

  insert into operation_results (
    organization_id,
    operation_id,
    operation_type,
    request_hash,
    status,
    created_by
  )
  values (
    target_organization_id,
    archive_pde_reservation.operation_id,
    'archive_pde_reservation',
    request_hash,
    'in_progress',
    auth.uid()
  );

  select *
    into old_reservation
  from pde_reservations
  where id = archive_pde_reservation.reservation_id
    and organization_id = target_organization_id
  for update;

  if not found then
    raise exception 'La reserva no existe.';
  end if;

  update pde_reservations
  set
    status = 'cancelled',
    cancelled_at = now(),
    cancelled_by = auth.uid(),
    cancel_reason = nullif(trim(coalesce(reason, '')), '')
  where id = archive_pde_reservation.reservation_id
  returning * into archived_reservation;

  insert into audit_logs (
    organization_id,
    actor_user_id,
    operation_id,
    action,
    entity_type,
    entity_id,
    old_values,
    new_values,
    metadata
  )
  values (
    target_organization_id,
    auth.uid(),
    archive_pde_reservation.operation_id,
    'pde_reservation_archived',
    'pde_reservation',
    archived_reservation.id,
    to_jsonb(old_reservation),
    to_jsonb(archived_reservation),
    jsonb_build_object('reason', reason)
  );

  update operation_results
  set
    status = 'succeeded',
    result_entity_type = 'pde_reservation',
    result_entity_id = archived_reservation.id,
    result_payload = to_jsonb(archived_reservation),
    completed_at = now()
  where organization_id = target_organization_id
    and operation_results.operation_id = archive_pde_reservation.operation_id;

  return archived_reservation;
end;
$$;

create or replace function register_pde_expense(
  target_organization_id uuid,
  category_name text,
  expense_date date,
  amount numeric,
  description text,
  currency char(3) default 'USD',
  target_unit_name text default null,
  is_general boolean default false,
  payment_method payment_method default null,
  expense_notes text default null,
  operation_id uuid default gen_random_uuid()
)
returns pde_expenses
language plpgsql
security definer
set search_path = public
as $$
declare
  selected_unit pde_units;
  unit_209 pde_units;
  unit_601 pde_units;
  selected_category expense_categories;
  saved_expense pde_expenses;
  existing_operation operation_results;
  request_hash text;
  half_amount numeric(14, 2);
begin
  if not has_org_role(target_organization_id, array['owner', 'admin', 'editor']::app_role[]) then
    raise exception 'No tenes permisos para registrar gastos.';
  end if;

  if amount <= 0 then
    raise exception 'El importe del gasto debe ser mayor a cero.';
  end if;

  if nullif(trim(coalesce(description, '')), '') is null then
    raise exception 'El detalle del gasto es obligatorio.';
  end if;

  request_hash := md5(jsonb_build_object(
    'category_name', category_name,
    'expense_date', expense_date,
    'amount', amount,
    'description', description,
    'currency', currency,
    'target_unit_name', target_unit_name,
    'is_general', is_general,
    'payment_method', payment_method,
    'expense_notes', expense_notes
  )::text);

  select *
    into existing_operation
  from operation_results op
  where op.organization_id = target_organization_id
    and op.operation_id = register_pde_expense.operation_id
  for update;

  if found then
    if existing_operation.request_hash <> request_hash then
      raise exception 'El operation_id ya fue usado con otros datos.';
    end if;

    if existing_operation.status = 'succeeded' then
      select *
        into saved_expense
      from pde_expenses
      where id = existing_operation.result_entity_id;

      return saved_expense;
    end if;

    raise exception 'La operacion todavia esta en proceso.';
  end if;

  insert into operation_results (
    organization_id,
    operation_id,
    operation_type,
    request_hash,
    status,
    created_by
  )
  values (
    target_organization_id,
    register_pde_expense.operation_id,
    'register_pde_expense',
    request_hash,
    'in_progress',
    auth.uid()
  );

  selected_category := ensure_pde_category(target_organization_id, category_name);

  if is_general then
    unit_209 := ensure_pde_unit(target_organization_id, '209');
    unit_601 := ensure_pde_unit(target_organization_id, '601');
  else
    selected_unit := ensure_pde_unit(target_organization_id, target_unit_name);
  end if;

  insert into pde_expenses (
    organization_id,
    target_type,
    unit_id,
    category_id,
    expense_date,
    description,
    amount,
    currency,
    payment_method,
    notes,
    operation_id,
    created_by
  )
  values (
    target_organization_id,
    case when is_general then 'general_50_50'::pde_expense_target else 'unit'::pde_expense_target end,
    case when is_general then null else selected_unit.id end,
    selected_category.id,
    expense_date,
    trim(description),
    amount,
    currency,
    payment_method,
    nullif(trim(coalesce(expense_notes, '')), ''),
    register_pde_expense.operation_id,
    auth.uid()
  )
  returning * into saved_expense;

  if is_general then
    half_amount := round(amount / 2, 2);

    insert into pde_expense_allocations (
      organization_id,
      expense_id,
      unit_id,
      percentage_snapshot,
      allocated_amount,
      currency
    )
    values
      (target_organization_id, saved_expense.id, unit_209.id, 50, half_amount, currency),
      (target_organization_id, saved_expense.id, unit_601.id, 50, amount - half_amount, currency);
  else
    insert into pde_expense_allocations (
      organization_id,
      expense_id,
      unit_id,
      percentage_snapshot,
      allocated_amount,
      currency
    )
    values (
      target_organization_id,
      saved_expense.id,
      selected_unit.id,
      100,
      amount,
      currency
    );
  end if;

  insert into audit_logs (
    organization_id,
    actor_user_id,
    operation_id,
    action,
    entity_type,
    entity_id,
    old_values,
    new_values,
    metadata
  )
  values (
    target_organization_id,
    auth.uid(),
    register_pde_expense.operation_id,
    'pde_expense_registered',
    'pde_expense',
    saved_expense.id,
    null,
    to_jsonb(saved_expense),
    jsonb_build_object(
      'isGeneral', is_general,
      'targetUnitName', target_unit_name,
      'categoryName', category_name
    )
  );

  update operation_results
  set
    status = 'succeeded',
    result_entity_type = 'pde_expense',
    result_entity_id = saved_expense.id,
    result_payload = to_jsonb(saved_expense),
    completed_at = now()
  where organization_id = target_organization_id
    and operation_results.operation_id = register_pde_expense.operation_id;

  return saved_expense;
end;
$$;

create or replace function void_pde_expense(
  target_organization_id uuid,
  expense_id uuid,
  reason text default null,
  operation_id uuid default gen_random_uuid()
)
returns pde_expenses
language plpgsql
security definer
set search_path = public
as $$
declare
  old_expense pde_expenses;
  voided_expense pde_expenses;
  existing_operation operation_results;
  request_hash text;
begin
  if not has_org_role(target_organization_id, array['owner', 'admin']::app_role[]) then
    raise exception 'Solo duenio o administrador pueden anular gastos.';
  end if;

  request_hash := md5(jsonb_build_object(
    'expense_id', expense_id,
    'reason', reason
  )::text);

  select *
    into existing_operation
  from operation_results op
  where op.organization_id = target_organization_id
    and op.operation_id = void_pde_expense.operation_id
  for update;

  if found then
    if existing_operation.request_hash <> request_hash then
      raise exception 'El operation_id ya fue usado con otros datos.';
    end if;

    if existing_operation.status = 'succeeded' then
      select *
        into voided_expense
      from pde_expenses
      where id = existing_operation.result_entity_id;

      return voided_expense;
    end if;

    raise exception 'La operacion todavia esta en proceso.';
  end if;

  insert into operation_results (
    organization_id,
    operation_id,
    operation_type,
    request_hash,
    status,
    created_by
  )
  values (
    target_organization_id,
    void_pde_expense.operation_id,
    'void_pde_expense',
    request_hash,
    'in_progress',
    auth.uid()
  );

  select *
    into old_expense
  from pde_expenses
  where id = void_pde_expense.expense_id
    and organization_id = target_organization_id
  for update;

  if not found then
    raise exception 'El gasto no existe.';
  end if;

  update pde_expenses
  set
    status = 'voided',
    voided_at = now(),
    voided_by = auth.uid(),
    void_reason = nullif(trim(coalesce(reason, '')), '')
  where id = void_pde_expense.expense_id
  returning * into voided_expense;

  insert into audit_logs (
    organization_id,
    actor_user_id,
    operation_id,
    action,
    entity_type,
    entity_id,
    old_values,
    new_values,
    metadata
  )
  values (
    target_organization_id,
    auth.uid(),
    void_pde_expense.operation_id,
    'pde_expense_voided',
    'pde_expense',
    voided_expense.id,
    to_jsonb(old_expense),
    to_jsonb(voided_expense),
    jsonb_build_object('reason', reason)
  );

  update operation_results
  set
    status = 'succeeded',
    result_entity_type = 'pde_expense',
    result_entity_id = voided_expense.id,
    result_payload = to_jsonb(voided_expense),
    completed_at = now()
  where organization_id = target_organization_id
    and operation_results.operation_id = void_pde_expense.operation_id;

  return voided_expense;
end;
$$;

